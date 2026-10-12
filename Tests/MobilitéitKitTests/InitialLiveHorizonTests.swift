import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct InitialLiveHorizonTests {
    @Test func oneSpareScheduledChoiceDoesNotRequireASecondFullBatch() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "early0,08:30:00,08:30:00,d,1\nearly0,08:50:00,08:50:00,c,2\n"
                + "early1,09:00:00,09:00:00,d,1\nearly1,09:20:00,09:20:00,c,2\n"
                + "spare,11:00:00,11:00:00,d,1\nspare,11:20:00,11:20:00,c,2\n"
                + "night,20:00:00,20:00:00,d,1\nnight,20:20:00,20:20:00,c,2\n",
            trips: "route,service,early0,Destination\nroute,service,early1,Destination\n"
                + "route,service,spare,Destination\nroute,service,night,Destination\n",
            additionalStops: "d,Far origin,50.164,6.088\n")
        defer { fixture.remove() }
        let provider = HorizonRealtime(cancelledTripIDs: [])
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "d"),
            destination: .stop(id: "c"), departureTime: RealtimeTestFixture.date("08:00:00"),
            preferences: .init(maxTransfers: 0), realtimePolicy: .bestEffort()))
        let page = try await session.initialSuggestions(count: 2, searchHorizon: 3_600)
        #expect(page.journeys.count == 2)
        let maximumHorizon = try #require(page.diagnostics.searchPasses.map(\.horizonSeconds).max())
        #expect(maximumHorizon == 14_400.0)
    }

    @Test func sparseLongDistanceSearchAcquiresTheUsefulHorizonAndExpandsAfterCancellation() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,11:30:00,11:30:00,d,1\ntrip,12:00:00,12:00:00,c,2\n"
                + "later,14:00:00,14:00:00,d,1\nlater,14:30:00,14:30:00,c,2\n"
                + "last,18:00:00,18:00:00,d,1\nlast,18:30:00,18:30:00,c,2\n",
            trips: "route,service,trip,Destination\nroute,service,later,Destination\nroute,service,last,Destination\n",
            additionalStops: "d,Far origin,50.164,6.088\n")
        defer { fixture.remove() }
        let provider = HorizonRealtime()
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "d"),
            destination: .stop(id: "c"), departureTime: RealtimeTestFixture.date("08:00:00"),
            preferences: .init(maxTransfers: 0), realtimePolicy: .bestEffort()))
        let page = try await session.initialSuggestions(count: 1, searchHorizon: 3_600)
        let requests = await provider.requests
        let first = try #require(requests.first)
        #expect(first.through > RealtimeTestFixture.date("12:00:00"))
        #expect(requests.contains { $0.through >= RealtimeTestFixture.date("18:30:00") })
        let trips = page.journeys.flatMap { journey in journey.legs.compactMap { leg -> String? in
            if case let .transit(ride) = leg { return ride.tripID }
            return nil
        } }
        #expect(trips.contains("last"))
        #expect(!trips.contains("later"))
        #expect(!trips.contains("trip"))
    }
}

private actor HorizonRealtime: RealtimeRoutingProvider {
    var requests: [RealtimeRoutingRequest] = []
    let cancelledTripIDs: [String]
    init(cancelledTripIDs: [String] = ["trip", "later"]) { self.cancelledTripIDs = cancelledTripIDs }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        let day = try GTFSDate(parsing: "20260930")
        return .init(patches: cancelledTripIDs.map {
            .init(tripID: $0, serviceDate: day, status: .cancelled, events: [])
        }, requestedStopIDs: Set(request.stopIDs), coveredStopIDs: Set(request.stopIDs))
    }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
}
