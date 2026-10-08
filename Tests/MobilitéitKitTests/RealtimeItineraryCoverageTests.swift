import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeItineraryCoverageTests {
    @Test func mergingTimestampFreeReportsPreservesTheirFreshnessContract() throws {
        let patch = RealtimeTripPatch(tripID: "trip", serviceDate: try GTFSDate(parsing: "20260930"), events: [
            .init(stopID: "a", effectiveDeparture: RealtimeTestFixture.date("08:05:00"), departureSource: .reported)
        ])
        let merged = patch.merging(patch)
        #expect(merged == patch)
        #expect(merged.events.first?.observedAt == nil)
        #expect(merged.events.first?.departureObservedAt == nil)
    }

    @Test(arguments: [RouteQueryDirection.departAfter, .arriveBy])
    func slowDiscoveryBranchesDoNotHideLiveConnectingTrips(direction: RouteQueryDirection) async throws {
        var times = "first,08:00:00,08:00:00,a,1\n"
        var trips = "route,service,first,Destination\nroute,service,second,Destination\n"
        var stops = ""
        for index in 1...24 {
            let time = String(format: "08:%02d:00", index)
            stops += "branch-\(index),Branch \(index),\(49.0 + Double(index) * 0.01),5.0\n"
            trips += "route,service,branch-trip-\(index),Destination\n"
            times += "first,\(time),\(time),branch-\(index),\(index + 1)\n"
            times += "branch-trip-\(index),08:40:00,08:40:00,branch-\(index),1\nbranch-trip-\(index),09:30:00,09:30:00,c,2\n"
        }
        times += "first,08:30:00,08:30:00,b,26\nsecond,08:35:00,08:35:00,b,1\nsecond,08:50:00,08:50:00,c,2\n"
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips, additionalStops: stops)
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            request.url!.query!.contains("id=branch-") ? .seconds(5) : .zero
        }) { request in
            if request.url!.query!.contains("id=a") {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                    + liveStop("b", planned: "08:30:00", predicted: "08:31:00", arrival: "08:31:00"),
                    realtime: "08:01:00")
            }
            return liveBoard(stops: liveStop("b", planned: "08:35:00", predicted: "08:39:00") + ","
                + liveStop("c", planned: "08:50:00", predicted: "08:54:00", arrival: "08:54:00"),
                time: "08:35:00", realtime: "08:39:00", stop: "b")
                .replacingOccurrences(of: "same-journey", with: "second-journey")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = ItineraryPriorityProvider(try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client))
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date(direction == .arriveBy ? "09:00:00" : "07:55:00"),
            direction: direction, preferences: .init(maxTransfers: 1),
            realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 1_000))))
        let page = try await session.initial(count: 10, searchHorizon: 3 * 3_600)
        let journey = try #require(page.journeys.first)
        let rides = journey.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
        #expect(rides.map(\.tripID) == ["first", "second"])
        #expect(rides.allSatisfy { $0.board.timingSource == .reported && $0.alight.timingSource == .reported })
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:54:00"))
        #expect(journey.statusEvidence.coverage == .live)
        let requestedStops = try #require(await provider.requests.first?.stopIDs)
        let connectingIndex = try #require(requestedStops.firstIndex(of: "b"))
        let branchIndex = requestedStops.firstIndex { $0.hasPrefix("branch-") } ?? requestedStops.count
        #expect(connectingIndex < branchIndex)
    }

    @Test(arguments: ["live", "cancelled", "missed"])
    func everyConnectingVehicleIsAcquiredAndTheItineraryIsRevalidated(outcome: String) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:15:00,08:15:00,b,1\nsecond,08:25:00,08:25:00,d,2\n"
                + "third,08:30:00,08:30:00,d,1\nthird,08:45:00,08:45:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\nroute,service,third,Destination\n",
            additionalStops: "d,Second transfer,49.68,6.18\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            switch stop {
            case "a":
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                    + liveStop("b", planned: "08:10:00", predicted: "08:11:00", arrival: "08:11:00"),
                    realtime: "08:01:00")
            case "b":
                let departure = outcome == "missed" ? "08:23:00" : "08:17:00"
                let arrival = outcome == "missed" ? "08:33:00" : "08:27:00"
                return liveBoard(stops: liveStop("b", planned: "08:15:00", predicted: departure) + ","
                    + liveStop("d", planned: "08:25:00", predicted: arrival, arrival: arrival),
                    time: "08:15:00", realtime: departure, stop: "b",
                    extra: outcome == "cancelled" ? ",\"cancelled\":true" : "")
                    .replacingOccurrences(of: "same-journey", with: "second-journey")
            default:
                return liveBoard(stops: liveStop("d", planned: "08:30:00", predicted: "08:32:00") + ","
                    + liveStop("c", planned: "08:45:00", predicted: "08:47:00", arrival: "08:47:00"),
                    time: "08:30:00", realtime: "08:32:00", stop: "d")
                    .replacingOccurrences(of: "same-journey", with: "third-journey")
            }
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let query = RouteQuery(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 2),
            realtimePolicy: .bestEffort(configuration: .init(maximumRefinementWaves: 1,
                                                            acquisitionBudgetMilliseconds: 1_000)))
        let session = try await router.makeSession(for: query)
        let page = try await session.initial(count: 10, searchHorizon: 3 * 3_600)
        if outcome == "live" {
            let journey = try #require(page.journeys.first)
            let rides = journey.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
            #expect(rides.map(\.tripID) == ["first", "second", "third"])
            #expect(rides.allSatisfy { $0.board.timingSource == .reported && $0.alight.timingSource == .reported })
            #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:47:00"))
            #expect(journey.statusEvidence.coverage == .live)
            #expect(page.metrics.pointRaptorScans == 2)
            // Fresh boards cover the whole itinerary on the next calculation.
            let cached = try await router.makeSession(for: query).initial(count: 10, searchHorizon: 3 * 3_600)
            #expect(cached.journeys.first?.statusEvidence.coverage == .live)
            #expect(RealtimeBoardProtocol.requests(host).count == 3)
            _ = try await session.refreshRealtime()
            #expect(RealtimeBoardProtocol.requests(host).count == 6)
        } else {
            #expect(page.journeys.isEmpty)
        }
        let requested = Set(RealtimeBoardProtocol.requests(host).compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        })
        #expect(requested == ["a", "b", "d"])
    }

    @Test(arguments: [false, true])
    func filteredBoardsRetainIntermediateReportsAndReuseUnrestrictedCache(primeUnrestricted: Bool) async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in
            liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:03:00") + ","
                + liveStop("b", planned: "08:10:00", predicted: "08:13:00", arrival: "08:13:00") + ","
                + liveStop("c", planned: "08:20:00", predicted: "08:23:00", arrival: "08:23:00"), realtime: "08:03:00")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let unrestricted = HafasDepartureBoardRequest(stationID: "a", language: "en",
            date: try GTFSDate(parsing: "20260930"), time: ServiceTime(rawValue: 7 * 3_600 + 30 * 60),
            durationMinutes: 180, maximumJourneys: -1, realtimeMode: .serverDefault, includePasslist: true)
        if primeUnrestricted { _ = try await client.departureBoardSnapshot(unrestricted) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
            .initial(count: 10, searchHorizon: 3 * 3_600)
        let journey = try #require(page.journeys.first)
        let ride = try #require(journey.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }.first)
        let intermediate = try #require(ride.intermediateStops.first)
        #expect(ride.intermediateStops.count == 1)
        #expect(intermediate.stop.id == "b")
        #expect(intermediate.scheduledTime == RealtimeTestFixture.date("08:10:00"))
        #expect(intermediate.effectiveTime == RealtimeTestFixture.date("08:13:00"))
        #expect(intermediate.timingSource == .reported)
        #expect(journey.statusEvidence.coverage == .live)
        let requests = RealtimeBoardProtocol.requests(host)
        #expect(requests.count == 1)
        let lines = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "lines" }?.value
        #expect(lines == (primeUnrestricted ? nil : "201"))
        // A filtered response cannot hide other lines on an unrestricted board.
        _ = try await client.departureBoardSnapshot(unrestricted)
        #expect(RealtimeBoardProtocol.requests(host).count == (primeUnrestricted ? 1 : 2))
    }

}

/// Capture queue priority independently of concurrent URLSession start order.
private actor ItineraryPriorityProvider: RealtimeRoutingProvider {
    let delegate: HafasRealtimeRoutingProvider
    var requests: [RealtimeRoutingRequest] = []
    init(_ delegate: HafasRealtimeRoutingProvider) { self.delegate = delegate }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        return try await delegate.patches(for: request)
    }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
}
