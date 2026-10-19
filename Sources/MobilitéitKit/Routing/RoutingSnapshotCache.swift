import Foundation

/// Where a router's routing snapshot came from.
public enum SnapshotSource: Hashable, Sendable {
    /// Built from the GTFS database.
    case database
    /// Loaded from the snapshot file in the caller's cache directory.
    case cache
}

/// Why a snapshot was built from the database although a cache directory was given.
enum SnapshotCacheMiss: Error, Equatable, Sendable {
    case noFile, unreadable, notASnapshot, formatVersion(UInt32), identity, checksum, corrupt(String), unidentifiable
}

enum SnapshotCacheWriteOutcome: Equatable, Sendable {
    case written(bytes: Int)
    /// The database changed while the snapshot was being built.
    case feedChanged
    case notEncodable(String)
    case failed(String)
}

struct SnapshotCacheLoad: Sendable {
    let snapshot: RoutingSnapshot
    let source: SnapshotSource
    let miss: SnapshotCacheMiss?
    let pendingWrite: SnapshotCacheWrite?
}

/// A snapshot built from the database, waiting to be stored. The caller runs it
/// off the critical path; it never throws.
struct SnapshotCacheWrite: Sendable {
    let snapshot: RoutingSnapshot
    let identity: Data
    let databaseURL: URL
    let directory: URL

    @discardableResult
    func perform() -> SnapshotCacheWriteOutcome {
        guard (try? SnapshotFeedIdentity.current(databaseURL: databaseURL)) == identity else { return .feedChanged }
        let file: Data
        do { file = try RoutingSnapshotCodec.encode(snapshot, identity: identity) } catch {
            return .notEncodable(String(describing: error))
        }
        do {
            try SnapshotCache.createDirectory(directory)
            try file.write(to: SnapshotCache.fileURL(in: directory), options: .atomic)
            return .written(bytes: file.count)
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// One snapshot file per cache directory. A different feed, a different format
/// version or a damaged file is replaced rather than kept next to the new one.
enum SnapshotCache {
    static let fileName = "routing-snapshot.bin"

    static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    /// Loads the stored snapshot when it matches the database, otherwise builds
    /// it. Any problem with the file falls back to the build.
    static func loadOrBuild(databaseURL: URL, directory: URL?) throws -> SnapshotCacheLoad {
        guard let directory else {
            return .init(snapshot: try SnapshotBuilder.load(databaseURL: databaseURL), source: .database, miss: nil, pendingWrite: nil)
        }
        let started = ContinuousClock.now
        guard let identity = try? SnapshotFeedIdentity.current(databaseURL: databaseURL) else {
            return .init(snapshot: try SnapshotBuilder.load(databaseURL: databaseURL), source: .database, miss: .unidentifiable, pendingWrite: nil)
        }
        let miss: SnapshotCacheMiss
        switch load(identity: identity, directory: directory, started: started) {
        case let .success(snapshot):
            return .init(snapshot: snapshot, source: .cache, miss: nil, pendingWrite: nil)
        case let .failure(reason):
            miss = reason
        }
        let snapshot = try SnapshotBuilder.load(databaseURL: databaseURL)
        return .init(snapshot: snapshot, source: .database, miss: miss,
                     pendingWrite: .init(snapshot: snapshot, identity: identity, databaseURL: databaseURL, directory: directory))
    }

    static func load(identity: Data, directory: URL, started: ContinuousClock.Instant = .now) -> Result<RoutingSnapshot, SnapshotCacheMiss> {
        let url = fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.noFile) }
        guard let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable) }
        return decode(file, identity: identity, started: started)
    }

    static func decode(_ file: Data, identity: Data, started: ContinuousClock.Instant = .now) -> Result<RoutingSnapshot, SnapshotCacheMiss> {
        do {
            return .success(try file.withUnsafeBytes { bytes in
                if Int(bitPattern: bytes.baseAddress) & 7 == 0 {
                    return try RoutingSnapshotCodec.decode(bytes, identity: identity, started: started)
                }
                // A mapping is page aligned; only a copied read can land elsewhere. Columns are read in place, so align.
                let copy = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 8), alignment: 8)
                defer { copy.deallocate() }
                copy.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                return try RoutingSnapshotCodec.decode(UnsafeRawBufferPointer(start: copy, count: bytes.count), identity: identity, started: started)
            })
        } catch let rejection as RoutingSnapshotCodec.Rejection {
            switch rejection {
            case .notASnapshot: return .failure(.notASnapshot)
            case let .formatVersion(version): return .failure(.formatVersion(version))
            case .identity: return .failure(.identity)
            case .checksum: return .failure(.checksum)
            }
        } catch let error as SnapshotFileError {
            if case let .corrupt(reason) = error { return .failure(.corrupt(reason)) }
            return .failure(.corrupt(String(describing: error)))
        } catch {
            return .failure(.corrupt(String(describing: error)))
        }
    }

    /// Creates the directory, excluded from backups: the file is derived data.
    static func createDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    static func remove(in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }
}

/// What makes a stored snapshot valid for a database: the file's name, size,
/// modification time, the SQLite header (change counter and schema cookie) and
/// the feed metadata (dates, maximum service time, generation, schema version).
/// The path is left out, because an app container can move.
enum SnapshotFeedIdentity {
    static func current(databaseURL: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw SnapshotFileError.corrupt("no file size") }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        let handle = try FileHandle(forReadingFrom: databaseURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        let headerHash = header.withUnsafeBytes { SnapshotChecksum.hash($0) }

        let database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
        let statement = try database.prepare("SELECT key,value FROM metadata ORDER BY key")
        var text = "name=\(databaseURL.lastPathComponent)\nsize=\(size)\nmodified=\(String(modified, radix: 16))\nheader=\(String(headerHash, radix: 16))\n"
        while try statement.step() { text += "\(statement.text(0) ?? "")=\(statement.text(1) ?? "")\n" }
        return Data(text.utf8)
    }
}
