import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in: uses an installed timetable and never touches the network.
/// `ROUTING_SNAPSHOT_DATABASE=<gtfs.sqlite> swift test --filter RoutingSnapshotInstalledTests`
@Suite struct RoutingSnapshotInstalledTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_SNAPSHOT_DATABASE"] != nil))
    func installedFeedLoadsExactlyAsBuilt() async throws {
        let database = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ROUTING_SNAPSHOT_DATABASE"]))
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        func milliseconds(_ body: () throws -> Void) rethrows -> Double {
            let started = ContinuousClock.now; try body(); return RoutingDiagnostics.elapsed(since: started)
        }

        var built: RoutingSnapshot!
        let buildTimes = try (0..<3).map { _ in try milliseconds { built = try SnapshotBuilder.load(databaseURL: database) } }
        let identity = try SnapshotFeedIdentity.current(databaseURL: database)
        var file = Data()
        let encodeMilliseconds = try milliseconds { file = try RoutingSnapshotCodec.encode(built, identity: identity) }
        let write = SnapshotCacheWrite(snapshot: built, identity: identity, databaseURL: database, directory: directory)
        let writeMilliseconds = milliseconds { _ = write.perform() }
        #expect((try Data(contentsOf: SnapshotCache.fileURL(in: directory))).count == file.count)

        var loaded: RoutingSnapshot!
        let loadTimes = try (0..<7).map { _ in
            try milliseconds {
                switch SnapshotCache.load(identity: try SnapshotFeedIdentity.current(databaseURL: database), directory: directory) {
                case let .success(snapshot): loaded = snapshot
                case let .failure(miss): Issue.record("cache miss: \(miss)")
                }
            }
        }
        #expect(snapshotDifferences(built, loaded).isEmpty, "\(snapshotDifferences(built, loaded))")
        let identityMilliseconds = try milliseconds { _ = try SnapshotFeedIdentity.current(databaseURL: database) }
        func rounded(_ values: [Double]) -> String { values.map { String(format: "%.0f", $0) }.joined(separator: ",") }
        print("SNAPSHOT_CACHE trips=\(built.trips.count) stopTimes=\(built.trips.reduce(0) { $0 + $1.times.count }) patterns=\(built.patterns.count) fileBytes=\(file.count) "
            + "buildMs=[\(rounded(buildTimes))] encodeMs=\(String(format: "%.0f", encodeMilliseconds)) writeMs=\(String(format: "%.0f", writeMilliseconds)) "
            + "identityMs=\(String(format: "%.1f", identityMilliseconds)) loadMs=[\(rounded(loadTimes))] reportedLoadMs=\(loaded.loadMilliseconds)")
    }
}
