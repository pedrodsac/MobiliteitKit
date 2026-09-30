import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RoutingDiagnosticsTests {
    @Test func operationsHaveIndependentTimingsAndCorrelationIDs() async throws {
        let fixture = try await RealtimeTestFixture()
        defer { fixture.remove() }
        let planner = JourneyPlanner()
        let request = JourneyPlanningRequest(origin: .stop(id: "a"), destination: .stop(id: "c"),
            time: .departAt(RealtimeTestFixture.date("07:55:00")))
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: request)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let refreshed = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.diagnostics.requestID != refreshed.diagnostics.requestID)
        #expect(initial.diagnostics.totalMilliseconds >= initial.diagnostics.milliseconds[.raptor, default: 0])
        #expect(initial.diagnostics.milliseconds[.snapshotPreparation] != nil)
        #expect(refreshed.diagnostics.milliseconds[.snapshotPreparation] == 0)
        #expect(refreshed.diagnostics.milliseconds[.realtime, default: 0] >= 0)
        #expect(refreshed.metrics.raptorNonWalkingMilliseconds == refreshed.metrics.raptorCPUMilliseconds)
        #expect(initial.journeys.map(\.id) == refreshed.journeys.map(\.id))
    }
    @Test func cachedRawPagesDoNotRepeatSearchCosts() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00")))
        let initial = try await session.initial()
        let cached = try await session.initial()
        #expect(initial.diagnostics.requestID != cached.diagnostics.requestID)
        #expect(cached.diagnostics.milliseconds[.raptor] == nil)
        #expect(cached.diagnostics.counters.isEmpty)
        #expect(initial.metrics.pointRaptorScans == cached.metrics.pointRaptorScans)
        #expect(initial.journeys.map(\.id) == cached.journeys.map(\.id))
    }

}
