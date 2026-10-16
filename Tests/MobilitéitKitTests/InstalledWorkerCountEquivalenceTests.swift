import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in. The scan splits its patterns into chunks sized from the worker count, and each chunk
/// evicts labels before the merge. If that changes the retained labels, a 6-core iPhone and a
/// 10-core Mac would return different journeys for the same query (CAND-23). This runs the
/// installed-feed equivalence queries with 10, 6 and 1 workers and reports every difference.
///
/// A difference is reported as a warning, because it is a finding rather than a regression.
/// Set `ROUTING_WORKER_EQUIVALENCE_STRICT=1` to fail on it, and `ROUTING_WORKER_EQUIVALENCE_OUTPUT`
/// to a directory to keep each run's records.
@Suite(.serialized) struct InstalledWorkerCountEquivalenceTests {
    static let reference = 10
    static let compared = [6, 1]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_EQUIVALENCE_DATABASE"] != nil))
    func journeysDoNotDependOnThePatternWorkerCount() async throws {
        let env = ProcessInfo.processInfo.environment
        let database = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_DATABASE"]))
        var outcomes: [Int: InstalledEquivalenceScenarios.Outcome] = [:]
        for workers in [Self.reference] + Self.compared {
            outcomes[workers] = try await Raptor.$activeProcessorCountOverride.withValue(workers) {
                try await InstalledEquivalenceScenarios.outcome(database: database)
            }
        }
        if let directory = env["ROUTING_WORKER_EQUIVALENCE_OUTPUT"] {
            for (workers, outcome) in outcomes {
                let data = try JSONSerialization.data(withJSONObject: outcome.records,
                                                      options: [.sortedKeys, .prettyPrinted])
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("workers-\(workers).json"))
            }
        }
        let baseline = try #require(outcomes[Self.reference])
        // The override must have taken effect, or the comparison proves nothing. Searches with
        // fewer than 32 marked patterns stay on one worker, so only the ceiling is checked.
        for (workers, outcome) in outcomes {
            #expect(!outcome.records.isEmpty)
            #expect(outcome.workerCounts.max().map { $0 <= min(workers, Raptor.maximumPatternWorkers) } == true)
        }
        #expect(baseline.workerCounts.max() == Self.reference)
        var differences: [String] = []
        for workers in Self.compared {
            let outcome = try #require(outcomes[workers])
            differences += Self.differences(baseline.records, outcome.records, label: "\(workers) vs \(Self.reference) workers")
        }
        if differences.isEmpty {
            print("WORKER_COUNT_EQUIVALENCE identical for \(Self.compared) against \(Self.reference) workers, "
                + "\(baseline.records.count) pages each")
        } else {
            print("WORKER_COUNT_EQUIVALENCE \(differences.count) differences")
            differences.forEach { print("WORKER_COUNT_EQUIVALENCE \($0)") }
            Issue.record("Results depend on the pattern worker count: \(differences.count) differing pages",
                         severity: env["ROUTING_WORKER_EQUIVALENCE_STRICT"] == "1" ? .error : .warning)
        }
    }

    /// One line per page whose record differs, naming what differs.
    static func differences(_ left: [[String: Any]], _ right: [[String: Any]], label: String) -> [String] {
        guard left.count == right.count else { return ["\(label): \(left.count) pages against \(right.count)"] }
        return zip(left, right).compactMap { a, b in
            guard canonical(a) != canonical(b) else { return nil }
            let page = "\(a["scenario"] as? String ?? "?")/\(a["operation"] as? String ?? "?")"
            var what: [String] = []
            for key in Set(a.keys).union(b.keys).sorted() where key != "journeys" && !equal(a[key], b[key]) {
                what.append("\(key) \(describe(a[key])) → \(describe(b[key]))")
            }
            let ids = { (page: [String: Any]) in
                (page["journeys"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            let (leftIDs, rightIDs) = (ids(a), ids(b))
            if leftIDs != rightIDs {
                let onlyLeft = Set(leftIDs).subtracting(rightIDs).count, onlyRight = Set(rightIDs).subtracting(leftIDs).count
                what.append("journey ids \(leftIDs.count) → \(rightIDs.count) (\(onlyLeft) only left, \(onlyRight) only right"
                    + (Set(leftIDs) == Set(rightIDs) ? ", same set in another order" : "") + ")")
            } else if canonical(a["journeys"]) != canonical(b["journeys"]) {
                what.append("journey details differ with the same ids")
            }
            return "\(label), \(page): " + what.joined(separator: "; ")
        }
    }

    private static func canonical(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
    private static func equal(_ left: Any?, _ right: Any?) -> Bool { canonical(left) == canonical(right) }
    private static func describe(_ value: Any?) -> String { value.map { "\($0)" } ?? "nil" }
}
