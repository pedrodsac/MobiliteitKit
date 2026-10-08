import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in only. Uses an installed timetable; never downloads data or calls ATP.
@Suite struct InstalledTimetableBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] != nil))
    func gromscheedLuxexpoKonradComparison() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"])
        let router = try await TransitRouter(databaseURL: URL(fileURLWithPath: path))
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-08T18:11:00+02:00"))
        let query = RouteQuery(origin: .stop(id: "000200508004"), destination: .stop(id: "000200417019"),
                               departureTime: anchor, preferences: .init(preferredMode: nil, avoidTightTransfers: false), realtimePolicy: .disabled)
        let session = try await router.makeSession(for: query)
        let page = try await session.initial(count: 100, searchHorizon: 3_600)
        for journey in page.journeys {
            print("KONRAD_COMPARISON \(journey.effectiveDeparture) \(journey.effectiveArrival) \(journey.legs.compactMap { if case let .transit(ride) = $0 { ride.route.shortName } else { nil } })")
        }
        let match = try #require(page.journeys.first {
            $0.legs.compactMap { if case let .transit(ride) = $0 { ride.route.shortName } else { nil } } == ["322", "6"]
        })
        #expect(match.effectiveArrival == ISO8601DateFormatter().date(from: "2026-10-08T18:39:10+02:00"))
    }

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
