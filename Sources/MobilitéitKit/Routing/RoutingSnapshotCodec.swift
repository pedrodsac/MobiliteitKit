import Foundation

/// The versioned binary form of ``RoutingSnapshot``.
///
/// File layout, all integers little-endian and every column padded to 8 bytes:
///
///     magic "MKROUTE1" | format version u32 | reserved u32
///     identity length u64 | identity bytes (padded)
///     payload length u64 | payload checksum u64 (XXH64) | payload
///
/// The payload stores the tables the database build produces and the expensive
/// indexes built from them (pattern grouping, departure-stop and occurrence
/// indexes, nearby-transfer stops, continuation sources). Cheap derivations
/// (lookup dictionaries, station groups, rule groups, service-day instants) are
/// recomputed on load by the same `SnapshotDerivedIndexes` code the build uses.
///
/// Bump `formatVersion` whenever the build logic or any stored table changes
/// meaning. `RoutingSnapshotCodecTests.goldenDigest` fails when the stored bytes
/// of its fixture change, which is the signal to bump it.
enum RoutingSnapshotCodec {
    static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("MKROUTE1".utf8)
    static let noReference = UInt32.max
    static let absent = Int64.min

    enum Section {
        static let info = SnapshotTag("INFO"), strings = SnapshotTag("STRINGS"), stops = SnapshotTag("STOPS")
        static let routes = SnapshotTag("ROUTES"), trips = SnapshotTag("TRIPS"), days = SnapshotTag("DAYS")
        static let rules = SnapshotTag("RULES"), paths = SnapshotTag("PATHS"), indexes = SnapshotTag("INDEXES")
        static let end = SnapshotTag("END")
    }

    // MARK: Framing

    static func encode(_ snapshot: RoutingSnapshot, identity: Data) throws -> Data {
        let payload = try encodePayload(snapshot)
        var file = SnapshotWriter(capacity: payload.count + identity.count + 64)
        file.rawBytesUnprefixed(magic)
        file.append(UInt64(formatVersion))
        file.column(Array(identity))
        file.append(UInt64(payload.count))
        let checksum = payload.withUnsafeBytes { SnapshotChecksum.hash($0) }
        file.append(checksum)
        file.rawBytesUnprefixed(payload)
        return Data(file.bytes)
    }

    enum Rejection: Error, Equatable, Sendable {
        case notASnapshot, formatVersion(UInt32), identity, checksum
    }

    /// Validates the framing and the identity, then decodes the payload. The
    /// identity is compared before the checksum is computed, so a stale file
    /// costs almost nothing.
    static func decode(_ file: UnsafeRawBufferPointer, identity: Data, started: ContinuousClock.Instant = .now) throws -> RoutingSnapshot {
        guard file.count >= 24, file.prefix(8).elementsEqual(magic) else { throw Rejection.notASnapshot }
        var cursor = try SnapshotCursor(file, offset: 8)
        let version = try cursor.u64()
        guard version == UInt64(formatVersion) else { throw Rejection.formatVersion(UInt32(truncatingIfNeeded: version)) }
        let stored = try cursor.column(UInt8.self)
        guard stored.count == identity.count, stored.elementsEqual(identity) else { throw Rejection.identity }
        let length = try cursor.u64(), checksum = try cursor.u64()
        let start = cursor.offset
        guard length <= UInt64(file.count - start) else { throw SnapshotFileError.corrupt("payload exceeds file") }
        let payload = UnsafeRawBufferPointer(rebasing: file[start..<(start + Int(length))])
        guard SnapshotChecksum.hash(payload) == checksum else { throw Rejection.checksum }
        return try decodePayload(payload, started: started)
    }
}

/// Maps strings to dense references. Equal UTF-8 bytes share one entry; strings
/// that are merely canonically equivalent stay distinct, so decoding restores
/// the exact bytes that were stored.
struct SnapshotStringTable {
    private var index: [[UInt8]: UInt32] = [:]
    private(set) var offsets: [UInt32] = [0]
    private(set) var blob: [UInt8] = []

    mutating func reference(_ string: String?) throws -> UInt32 {
        guard let string else { return RoutingSnapshotCodec.noReference }
        let bytes = Array(string.utf8)
        if let existing = index[bytes] { return existing }
        guard let id = UInt32(exactly: offsets.count - 1), id < RoutingSnapshotCodec.noReference,
              let end = UInt32(exactly: blob.count + bytes.count) else {
            throw SnapshotFileError.unencodable("string table too large")
        }
        blob.append(contentsOf: bytes); offsets.append(end); index[bytes] = id
        return id
    }
}
