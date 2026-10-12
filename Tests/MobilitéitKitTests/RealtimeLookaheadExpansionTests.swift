import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeLookaheadExpansionTests {
    @Test func cancelledPreliminaryRoutesExpandUsingOriginalBoardWindows() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,11:30:00,11:30:00,d,1\nfirst,12:00:00,12:00:00,c,2\n"
                + "second,14:00:00,14:00:00,d,1\nsecond,14:30:00,14:30:00,c,2\n"
                + "survivor,18:00:00,18:00:00,d,1\nsurvivor,18:30:00,18:30:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\n"
                + "route,service,survivor,Destination\n",
            additionalStops: "d,Far origin,50.164,6.088\n")
        defer { fixture.remove() }
        let provider = LookaheadExpansionRealtime()
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let anchor = RealtimeTestFixture.date("08:00:00")
        let session = try await router.makeSession(for: .init(origin: .stop(id: "d"),
            destination: .stop(id: "c"), departureTime: anchor,
            preferences: .init(maxTransfers: 0), realtimePolicy: .bestEffort()))
        let page = try await session.initialSuggestions(count: 1, searchHorizon: 3_600)
        let requests = await provider.requests
        let initial = try #require(requests.first)
        #expect(initial.minimumBoardCoverageMinutes == 0)
        let expanded = try #require(requests.first { $0.through > initial.through })
        #expect(expanded.minimumBoardCoverageMinutes == 0)
        #expect(expanded.refreshPolicy == .useCache)
        #expect(expanded.targets.contains { $0.stopID == "d"
            && $0.from <= RealtimeTestFixture.date("18:00:00")
            && $0.through >= RealtimeTestFixture.date("18:00:00") })
        #expect(requests.allSatisfy { $0.minimumBoardCoverageMinutes == 0 })
        let tripIDs = page.journeys.flatMap { journey in
            journey.legs.compactMap { leg -> String? in
                if case let .transit(ride) = leg { return ride.tripID }
                return nil
            }
        }
        #expect(tripIDs == ["survivor"])
    }
}

private actor LookaheadExpansionRealtime: RealtimeRoutingProvider {
    var requests: [RealtimeRoutingRequest] = []

    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        let day = try GTFSDate(parsing: "20260930")
        return .init(patches: ["first", "second"].map {
            .init(tripID: $0, serviceDate: day, status: .cancelled, events: [])
        }, requestedStopIDs: Set(request.stopIDs), coveredStopIDs: Set(request.stopIDs))
    }

    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from,
            through: through, refreshPolicy: refreshPolicy))
    }
}
