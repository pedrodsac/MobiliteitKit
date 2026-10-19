import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing snapshot cache")
struct RoutingSnapshotCacheTests {
    private struct Workspace {
        let folder: URL
        let database: URL
        var cache: URL { folder.appendingPathComponent("cache", isDirectory: true) }
        var file: URL { SnapshotCache.fileURL(in: cache) }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private func workspace(generation: Int = 7) async throws -> Workspace {
        let folder = try temporaryDirectory()
        return Workspace(folder: folder, database: try await SnapshotFixture.install(generation: generation, in: folder))
    }

    private func router(_ space: Workspace, cache: URL? = nil) async throws -> TransitRouter {
        try await TransitRouter(databaseURL: space.database, snapshotCacheDirectory: cache ?? space.cache, clock: { date(hour: 6) })
    }

    /// Creates a router and waits for the background store of a freshly built snapshot.
    private func storedRouter(_ space: Workspace) async throws -> TransitRouter {
        let router = try await router(space)
        let outcome = await router.snapshotCacheWrite?.value
        if let outcome { #expect({ if case .written = outcome { true } else { false } }(), "\(outcome)") }
        return router
    }

    private func journeys(_ router: TransitRouter, from origin: String = "s1", to destination: String = "s6", hour: Int = 6, arriveBy: Bool = false) async throws -> [Journey] {
        let query = RouteQuery(origin: .stop(id: origin), destination: .stop(id: destination), departureTime: date(hour: hour),
                               direction: arriveBy ? .arriveBy : .departAfter, preferences: .init(maxTransfers: 3))
        return try await router.makeSession(for: query).boundedPage(count: 100).journeys
    }

    @Test func firstStartBuildsAndStoresThenLaterStartsLoad() async throws {
        let space = try await workspace(); defer { space.remove() }
        let built = try await router(space)
        #expect(built.snapshotSource == .database)
        #expect(built.snapshotCacheMiss == .noFile)
        let outcome = try #require(await built.snapshotCacheWrite?.value)
        guard case let .written(bytes) = outcome else { Issue.record("\(outcome)"); return }
        #expect(bytes == (try Data(contentsOf: space.file)).count)

        let loaded = try await router(space)
        #expect(loaded.snapshotSource == .cache)
        #expect(loaded.snapshotCacheMiss == nil)
        #expect(await loaded.snapshotCacheWrite == nil)
        #expect(snapshotDifferences(await built.snapshot, await loaded.snapshot).isEmpty)
    }

    @Test func cachedRouterAnswersLikeABuiltRouter() async throws {
        let space = try await workspace(); defer { space.remove() }
        let built = try await storedRouter(space)
        let loaded = try await router(space)
        #expect(loaded.snapshotSource == .cache)
        var compared = 0
        for (origin, destination, hour, arriveBy) in [("s1", "s6", 6, false), ("s2", "s4", 6, false), ("s1", "s6", 8, true), ("s3", "s4", 5, false), ("station", "s5", 6, false)] {
            let expected = try await journeys(built, from: origin, to: destination, hour: hour, arriveBy: arriveBy)
            #expect(try await journeys(loaded, from: origin, to: destination, hour: hour, arriveBy: arriveBy) == expected, "\(origin) to \(destination)")
            compared += expected.count
        }
        #expect(compared > 0)
    }

    @Test func aNewFeedReplacesTheStoredSnapshot() async throws {
        let space = try await workspace(); defer { space.remove() }
        _ = try await storedRouter(space)
        var files = SnapshotFixture.files()
        files["trips.txt"]! += "bus,weekday,extra,Extra,,0,,0,0\n"
        files["stop_times.txt"]! += "extra,07:00:00,07:00:00,s1,1,0,0,\nextra,07:10:00,07:10:00,s6,2,0,0,\n"
        let other = Workspace(folder: space.folder, database: try await SnapshotFixture.install(files: files, generation: 8, name: "next-generation.sqlite", in: space.folder))

        let next = try await router(other)
        #expect(next.snapshotSource == .database)
        #expect(next.snapshotCacheMiss == .identity)
        _ = await next.snapshotCacheWrite?.value
        let nextSnapshot = await next.snapshot
        #expect(nextSnapshot.info.generation == 8)
        #expect(try await router(other).snapshotSource == .cache)
        // The first database no longer matches the single stored file.
        #expect(try await router(space).snapshotCacheMiss == .identity)
    }

    @Test func aRewrittenDatabaseAtTheSamePathIsNotTrusted() async throws {
        let space = try await workspace(); defer { space.remove() }
        _ = try await storedRouter(space)
        var files = SnapshotFixture.files()
        files["stop_times.txt"] = files["stop_times.txt"]!.replacingOccurrences(of: "06:00:00,06:00:00,s1,1", with: "06:01:00,06:01:00,s1,1")
        _ = try await SnapshotFixture.install(files: files, generation: 7, in: space.folder)
        let rebuilt = try await router(space)
        #expect(rebuilt.snapshotSource == .database)
        #expect(rebuilt.snapshotCacheMiss == .identity)
        let snapshot = await rebuilt.snapshot
        let busA = try #require(snapshot.tripByID["busA"])
        let departure: Int32 = 6 * 3_600 + 60
        #expect(snapshot.trips[busA].times.first?.departure == departure)
    }

    @Test func movingTheContainerKeepsTheFileValidButTouchingTheDatabaseDoesNot() async throws {
        let space = try await workspace(); defer { space.remove() }
        _ = try await storedRouter(space)
        let moved = space.folder.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let newDatabase = moved.appendingPathComponent(space.database.lastPathComponent)
        try FileManager.default.moveItem(at: space.database, to: newDatabase)
        let relocated = Workspace(folder: space.folder, database: newDatabase)
        #expect(try await router(relocated).snapshotSource == .cache)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: newDatabase.path)
        #expect(try await router(relocated).snapshotCacheMiss == .identity)
    }

    @Test(arguments: ["empty", "text", "truncated", "bit flip", "newer format", "other feed"])
    func damagedFilesAreRebuiltAndHealed(damage: String) async throws {
        let space = try await workspace(); defer { space.remove() }
        let reference = try await storedRouter(space)
        var bytes = try Data(contentsOf: space.file)
        let expectedMiss: SnapshotCacheMiss
        switch damage {
        case "empty": bytes = Data(); expectedMiss = .notASnapshot
        case "text": bytes = Data(String(repeating: "not a snapshot ", count: 40).utf8); expectedMiss = .notASnapshot
        case "truncated": bytes = bytes.prefix(bytes.count / 2); expectedMiss = .corrupt("payload exceeds file")
        case "bit flip": bytes[bytes.count - 17] ^= 0x01; expectedMiss = .checksum
        case "newer format":
            bytes.withUnsafeMutableBytes { $0.storeBytes(of: UInt64(RoutingSnapshotCodec.formatVersion + 1), toByteOffset: 8, as: UInt64.self) }
            expectedMiss = .formatVersion(RoutingSnapshotCodec.formatVersion + 1)
        default: bytes[bytes.count / 2] ^= 0xFF; bytes[40] ^= 0xFF; expectedMiss = .identity
        }
        try bytes.write(to: space.file)

        let rebuilt = try await router(space)
        #expect(rebuilt.snapshotSource == .database)
        #expect(rebuilt.snapshotCacheMiss == expectedMiss || damage == "other feed")
        _ = await rebuilt.snapshotCacheWrite?.value
        #expect(snapshotDifferences(await reference.snapshot, await rebuilt.snapshot).isEmpty)
        #expect(try await router(space).snapshotSource == .cache)
    }

    @Test func anUnusableCacheLocationNeverBreaksRouting() async throws {
        let space = try await workspace(); defer { space.remove() }
        let blocker = space.folder.appendingPathComponent("blocker")
        try Data("a file where a directory should be".utf8).write(to: blocker)
        let blocked = try await router(space, cache: blocker)
        #expect(blocked.snapshotSource == .database)
        let outcome = try #require(await blocked.snapshotCacheWrite?.value)
        #expect({ if case .failed = outcome { true } else { false } }(), "\(outcome)")
        #expect(!(try await journeys(blocked)).isEmpty)
    }

    @Test func noDirectoryMeansNoFile() async throws {
        let space = try await workspace(); defer { space.remove() }
        let plain = try await TransitRouter(databaseURL: space.database, clock: { date(hour: 6) })
        #expect(plain.snapshotSource == .database)
        #expect(plain.snapshotCacheMiss == nil)
        #expect(await plain.snapshotCacheWrite == nil)
        #expect(!FileManager.default.fileExists(atPath: space.cache.path))
    }

    @Test func storingLeavesOneCompleteFileAndConcurrentStartsAgree() async throws {
        let space = try await workspace(); defer { space.remove() }
        let routers = try await withThrowingTaskGroup(of: TransitRouter.self) { group in
            for _ in 0..<4 { group.addTask { try await router(space) } }
            var all: [TransitRouter] = []
            for try await router in group { all.append(router) }
            return all
        }
        for router in routers { _ = await router.snapshotCacheWrite?.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: space.cache.path) == [SnapshotCache.fileName])
        let loaded = try await router(space)
        #expect(loaded.snapshotSource == .cache)
        for router in routers { #expect(snapshotDifferences(await router.snapshot, await loaded.snapshot).isEmpty) }
    }

    @Test func plannerStoresAndRemovesTheSnapshot() async throws {
        let space = try await workspace(); defer { space.remove() }
        let planner = JourneyPlanner(snapshotCacheDirectory: space.cache)
        let first = try await planner.router(for: space.database)
        #expect(first.snapshotSource == .database)
        _ = await first.snapshotCacheWrite?.value
        #expect(FileManager.default.fileExists(atPath: space.file.path))
        #expect(try await JourneyPlanner(snapshotCacheDirectory: space.cache).router(for: space.database).snapshotSource == .cache)

        JourneyPlanner.removeSnapshotCache(in: space.cache)
        #expect(!FileManager.default.fileExists(atPath: space.file.path))
        JourneyPlanner.removeSnapshotCache(in: space.cache) // already gone
        #expect(try await JourneyPlanner(snapshotCacheDirectory: space.cache).router(for: space.database).snapshotCacheMiss == .noFile)
    }

    @Test func aFileReadIntoMisalignedMemoryStillLoads() async throws {
        let space = try await workspace(); defer { space.remove() }
        let built = try await storedRouter(space)
        let identity = try SnapshotFeedIdentity.current(databaseURL: space.database)
        let file = try Data(contentsOf: space.file)
        // A slice that starts at an odd address, as a copied read could.
        let padded = Data([0]) + file
        let misaligned = padded.dropFirst()
        let address = misaligned.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }
        #expect(address & 7 != 0)
        guard case let .success(loaded) = SnapshotCache.decode(misaligned, identity: identity) else { Issue.record("not loaded"); return }
        #expect(snapshotDifferences(await built.snapshot, loaded).isEmpty)
    }

    @Test func identityIsStableUntilTheFeedChanges() async throws {
        let space = try await workspace(); defer { space.remove() }
        let identity = try SnapshotFeedIdentity.current(databaseURL: space.database)
        #expect(try SnapshotFeedIdentity.current(databaseURL: space.database) == identity)
        let text = String(decoding: identity, as: UTF8.self)
        #expect(text.contains("name=transit.sqlite") && text.contains("generation=7") && text.contains("feed_start=20260901"))
        #expect(!text.contains(space.folder.path))
    }
}
