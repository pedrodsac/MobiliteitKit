import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in. The scan merges its chunks in shards of stops that run at the same time. This runs the
/// installed-feed equivalence queries with one merge shard and with several, repeatedly, and fails if
/// any page differs. One shard merges in place; more shards give the tasks every chance to interleave.
/// Set `ROUTING_SHARD_EQUIVALENCE_REPEATS` to change how often each shard count runs (default 3).
@Suite(.serialized) struct InstalledShardCountEquivalenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_EQUIVALENCE_DATABASE"] != nil))
    func journeysDoNotDependOnTheMergeShardCount() async throws {
        let env = ProcessInfo.processInfo.environment
        let database = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_DATABASE"]))
        let repeats = env["ROUTING_SHARD_EQUIVALENCE_REPEATS"].flatMap(Int.init) ?? 3
        let reference = try await Raptor.$mergeShardCountOverride.withValue(1) {
            try await InstalledEquivalenceScenarios.outcome(database: database)
        }
        #expect(!reference.records.isEmpty)
        var differences: [String] = []
        for shards in [2, 3, 10, 16] {
            for run in 1...repeats {
                let outcome = try await Raptor.$mergeShardCountOverride.withValue(shards) {
                    try await InstalledEquivalenceScenarios.outcome(database: database)
                }
                differences += InstalledWorkerCountEquivalenceTests.differences(
                    reference.records, outcome.records, label: "\(shards) shards, run \(run)")
            }
        }
        differences.forEach { print("SHARD_COUNT_EQUIVALENCE \($0)") }
        if differences.isEmpty {
            print("SHARD_COUNT_EQUIVALENCE identical for 2, 3, 10 and 16 shards against 1, "
                + "\(repeats) runs each, \(reference.records.count) pages")
        }
        #expect(differences.isEmpty, "Results depend on the merge shard count")
    }
}
