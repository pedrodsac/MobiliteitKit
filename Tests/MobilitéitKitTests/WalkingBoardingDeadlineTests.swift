import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct WalkingBoardingDeadlineTests {
    @Test(arguments: 0..<7)
    func respectsRealtimeAndServiceEligibility(patchCase: Int) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "ride,08:00:00,08:00:00,a,1\nride,08:10:00,08:10:00,b,2\nride,08:20:00,08:20:00,c,3\n"
                + "inactive,08:01:00,08:01:00,a,1\ninactive,08:30:00,08:30:00,b,2\n",
            trips: "route,service,ride,Destination\nroute,absent,inactive,Destination\n",
            serviceDates: "service,20260930,1\nabsent,20261001,1\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let snapshot = await router.snapshot
        let day = try GTFSDate(parsing: "20260930")
        let trip = try #require(snapshot.tripByID["ride"])
        let stop = try #require(snapshot.stopByID["b"])
        let status: RealtimeTripStatus = patchCase == 3 ? .cancelled : patchCase == 4 ? .unreachable : .active
        let event = RealtimeStopEventPatch(stopID: "b",
            effectiveDeparture: RealtimeTestFixture.date("08:15:00"),
            departureSource: patchCase == 2 ? .estimated : .reported,
            stopSequence: 2, boardingAllowed: patchCase != 5)
        let patch = Raptor.PatchOverlay(status: status,
            eventsByPosition: patchCase == 0 ? [:] : [1: event])
        let query = RouteQuery(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(allowedModes: patchCase == 6 ? .init(rawValue: 1) : .all),
            realtimePolicy: .disabled)
        let deadlines = try Raptor.walkingBoardingDeadlines(snapshot: snapshot, query: query,
            serviceDays: snapshot.serviceDays.filter { $0.date == day },
            patches: [.init(trip: trip, serviceDate: day): patch],
            scheduledLowerBound: RealtimeTestFixture.date("07:55:00"),
            profileUpperBound: RealtimeTestFixture.date("08:05:00"))
        if patchCase >= 3 { #expect(deadlines[stop] == .distantPast) }
        else {
            // A downstream departure beyond the profile end remains eligible.
            let expected = patchCase == 1 ? "08:15:00" : "08:10:00"
            #expect(deadlines[stop] == RealtimeTestFixture.date(expected))
        }
    }

    @Test func finalWalkingEgressNeedsNoFutureDeparture() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "ride,08:00:00,08:00:00,a,1\nride,08:20:00,08:20:00,c,2\n",
            trips: "route,service,ride,Destination\n",
            additionalStops: "d,Destination entrance,49.7001,6.2001\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database, walkingProvider: EgressWalking())
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"),
            destination: .stop(id: "d"), departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(maxTransfers: 0), realtimePolicy: .disabled))
        let page = try await session.initial(count: 1, searchHorizon: 3600)
        let journey = try #require(page.journeys.first)
        #expect(journey.scheduledArrival == RealtimeTestFixture.date("08:21:00"))
        #expect(journey.legs.contains { if case .walk = $0 { true } else { false } })
    }
}

private struct EgressWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        .init(durationSeconds: 60, distanceMeters: 20)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        .init(durationSeconds: 60, distanceMeters: 20, polyline: [request.source, request.destination])
    }
}
