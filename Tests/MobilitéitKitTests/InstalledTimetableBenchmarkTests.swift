import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in only. Uses an installed timetable; never downloads data or calls ATP.
@Suite struct InstalledTimetableBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] != nil))
    func installedTimetable() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"])
        let count = Int(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_SAMPLES"] ?? "1") ?? 1
        let planner = JourneyPlanner()
        let date = ISO8601DateFormatter().date(from: "2026-09-30T09:00:00+02:00")!
        for sample in 0..<count {
            let started = ContinuousClock.now
            let session = try await planner.makePlanningSession(databaseURL: URL(fileURLWithPath: path),
                request: .init(origin: .stop(id: "000220402034"), destination: .stop(id: "000400000095"),
                               time: .arriveBy(date), preferences: .init(maxTransfers: 3)))
            let result = try await session.calculate(refresh: .scheduleOnly)
            #expect(!result.journeys.isEmpty)
            print("BENCH sample=\(sample) total=\(RoutingDiagnostics.elapsed(since: started)) stages=\(result.diagnostics.milliseconds) rounds=\(result.metrics.searchRounds)")
        }
    }
}
