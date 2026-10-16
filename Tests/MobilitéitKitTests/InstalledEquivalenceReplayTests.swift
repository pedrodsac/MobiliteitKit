import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in, deterministic full-feed replay. The identical files can run against the
/// pre-optimization package; they use no new implementation interfaces.
/// The queries live in `InstalledEquivalenceScenarios`.
@Suite struct InstalledEquivalenceReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_EQUIVALENCE_DATABASE"] != nil))
    func completeJourneysAndPaging() async throws {
        let env = ProcessInfo.processInfo.environment
        let database = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_DATABASE"]))
        let output = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_OUTPUT"]))
        let outcome = try await InstalledEquivalenceScenarios.outcome(database: database)
        try JSONSerialization.data(withJSONObject: outcome.records, options: [.sortedKeys, .prettyPrinted]).write(to: output)
    }
}
