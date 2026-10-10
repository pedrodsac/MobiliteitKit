import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RoutingCacheEquivalenceTests {
    @Test func transportRedactsCredentialsFromDiagnosticURLs() throws {
        let input = try #require(URL(string: "https://name:secret@example.com/board?accessId=secret&APIKey=secret&token=secret&requestId=private&id=123"))
        let result = HTTPTaskMetricsDelegate.sanitized(input)
        #expect(result.absoluteString == "https://example.com/board?id=123")
    }

    @Test func indexedEventsPreserveFirstExactThenLegacyOccurrence() throws {
        let day = try GTFSDate(parsing: "20260904")
        let first = RealtimeStopEventPatch(stopID: "loop", effectiveDeparture: date(hour: 8), stopSequence: 3)
        let duplicate = RealtimeStopEventPatch(stopID: "loop", effectiveDeparture: date(hour: 9), stopSequence: 3)
        let legacy = RealtimeStopEventPatch(stopID: "loop", effectiveDeparture: date(hour: 10))
        let events = [legacy, first, duplicate] + (0..<8).map { RealtimeStopEventPatch(stopID: "other-\($0)") }
        let patch = RealtimeTripPatch(tripID: "ride", serviceDate: day, events: events)
        #expect(patch.event(stopID: "loop", sequence: 3) == first)
        #expect(patch.event(stopID: "loop", sequence: 4) == legacy)
        #expect(patch.event(stopID: "absent", sequence: 3) == nil)
    }

    @Test func reusedSessionMatchesFreshSessionForEveryPublishedJourney() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let planner = JourneyPlanner()
        let request = JourneyPlanningRequest(origin: .stop(id: "a"), destination: .stop(id: "c"),
            time: .departAt(RealtimeTestFixture.date("07:55:00")))
        let now = RealtimeTestFixture.date("07:55:00")
        let reused = try await planner.makePlanningSession(databaseURL: fixture.database, request: request, now: now)
        _ = try await reused.calculate(refresh: .scheduleOnly, now: now)
        let actual = try await reused.calculate(refresh: .scheduleOnly, now: now)
        let fresh = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database, request: request, now: now)
        let expected = try await fresh.calculate(refresh: .scheduleOnly, now: now)
        #expect(actual.journeys == expected.journeys)
        #expect(actual.recommendedJourneyID == expected.recommendedJourneyID)
        #expect(actual.hasEarlier == expected.hasEarlier && actual.hasLater == expected.hasLater)
    }

    @Test func walkingCacheSeparatesDirectionAndGraphRevision() async throws {
        let provider = RevisionWalkingProvider()
        let cache = WalkingRouteCache(provider: provider)
        let request = WalkingRequest(source: .init(latitude: 49.6, longitude: 6.1), destination: .init(latitude: 49.61, longitude: 6.11))
        #expect(try await cache.route(request).durationSeconds == 60)
        #expect(try await cache.route(request).durationSeconds == 60)
        #expect(await provider.calls == 1)
        await provider.update()
        #expect(try await cache.route(request).durationSeconds == 120)
        let reverse = WalkingRequest(source: request.destination, destination: request.source)
        #expect(try await cache.route(reverse).durationSeconds == 120)
        #expect(await provider.calls == 3)
    }
}

private actor RevisionWalkingProvider: WalkingRoutingProvider {
    var calls = 0
    var revision = 1
    func update() { revision += 1 }
    func cacheRevision() -> String? { String(revision) }
    func estimate(_ request: WalkingRequest) -> WalkingEstimate { .init(durationSeconds: revision * 60, distanceMeters: 100) }
    func route(_ request: WalkingRequest) -> WalkingRoute {
        calls += 1
        return .init(durationSeconds: revision * 60, distanceMeters: 100, polyline: [request.source, request.destination])
    }
}
