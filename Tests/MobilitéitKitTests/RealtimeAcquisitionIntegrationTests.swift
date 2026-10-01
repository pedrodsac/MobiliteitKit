import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeAcquisitionIntegrationTests {
    @Test func nextWaveFindsADelayedTransferOutsideStaticWinners() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\nsecond,08:12:00,08:12:00,b,1\nsecond,08:30:00,08:30:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            if stop == "a" {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
                    + liveStop("b", planned: "08:10:00", predicted: "08:18:00", arrival: "08:18:00"))
            }
            return liveBoard(stops: liveStop("b", planned: "08:12:00", predicted: "08:20:00") + ","
                + liveStop("c", planned: "08:30:00", predicted: "08:38:00", arrival: "08:38:00"),
                time: "08:12:00", realtime: "08:20:00", stop: "b")
                .replacingOccurrences(of: "same-journey", with: "second-journey")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:05:00"), realtimePolicy: .bestEffort()))
        let page = try await session.initial()
        let journey = try #require(page.journeys.first)
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:38:00"))
        #expect(page.metrics.hafasRequests == 8)
        #expect(page.metrics.realtimeBoardsCovered == 2)
        let stops = Set(RealtimeBoardProtocol.requests(host).compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        })
        #expect(stops == ["a", "b"])
        #expect(page.realtimeState == .partial) // The full GTFS profile exceeds the live horizon.
        _ = try await session.refreshRealtime()
        #expect(RealtimeBoardProtocol.requests(host).count == 16)
    }

    @Test(arguments: [false, true])
    func busyIntermediateStopsDoNotStarveLaterTransitLegs(branchesReachTransfer: Bool) async throws {
        // Twenty-four early branches can consume the entire acquisition budget
        // before the actual interchange. Test both dead ends and longer detours.
        var times = "first,08:00:00,08:00:00,a,1\n"
        var trips = "route,service,first,Destination\nroute,service,second,Destination\nroute,service,third,Destination\n"
        var stops = "d,Second transfer,49.68,6.18\ndead,Dead end,49.40,5.90\n"
        for index in 1...24 {
            let time = String(format: "08:%02d:00", index)
            stops += "branch-\(index),Branch \(index),49.50,6.00\n"
            trips += "route,service,branch-trip-\(index),Dead end\n"
            times += "first,\(time),\(time),branch-\(index),\(index + 1)\n"
            let alight = branchesReachTransfer ? "b" : "dead"
            times += "branch-trip-\(index),\(time),\(time),branch-\(index),1\nbranch-trip-\(index),08:40:00,08:40:00,\(alight),2\n"
        }
        times += "first,08:30:00,08:30:00,b,26\nsecond,08:35:00,08:35:00,b,1\nsecond,08:45:00,08:45:00,d,2\nthird,08:50:00,08:50:00,d,1\nthird,09:00:00,09:00:00,c,2\n"
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips, additionalStops: stops)
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            switch stop {
            case "a":
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:02:00") + ","
                    + liveStop("b", planned: "08:30:00", predicted: "08:32:00", arrival: "08:32:00"),
                    realtime: "08:02:00")
            case "b":
                return liveBoard(stops: liveStop("b", planned: "08:35:00", predicted: "08:37:00") + ","
                    + liveStop("d", planned: "08:45:00", predicted: "08:47:00", arrival: "08:47:00"),
                    time: "08:35:00", realtime: "08:37:00", stop: "b")
                    .replacingOccurrences(of: "same-journey", with: "second-journey")
            case "d":
                return liveBoard(stops: liveStop("d", planned: "08:50:00", predicted: "08:52:00") + ","
                    + liveStop("c", planned: "09:00:00", predicted: "09:02:00", arrival: "09:02:00"),
                    time: "08:50:00", realtime: "08:52:00", stop: "d")
                    .replacingOccurrences(of: "same-journey", with: "third-journey")
            default: return "{\"Departure\":[]}"
            }
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(maxTransfers: 2), realtimePolicy: .bestEffort()))
        let page = try await session.initial()
        let journey = try #require(page.journeys.first)
        let transit = journey.legs.compactMap { leg -> TransitLeg? in
            if case let .transit(value) = leg { return value }; return nil
        }
        #expect(transit.map(\.tripID) == ["first", "second", "third"])
        #expect(transit.allSatisfy { $0.board.timingSource == .reported && $0.alight.timingSource == .reported })
        #expect(journey.statusEvidence.coverage == .live)
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("09:02:00"))
        let requested = Set(RealtimeBoardProtocol.requests(host).compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        })
        #expect(requested.isSuperset(of: ["a", "b", "d"]))
        #expect(requested.count <= 24)
        if !branchesReachTransfer { #expect(requested == ["a", "b", "d"]) }
    }

    @Test func APIErrorKeepsScheduleOnlyRoutingAvailable() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in
            #"{"errorCode":"API_PARAM","errorText":"Fixture failure"}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
        let page = try await session.initial()
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.first?.effectiveDeparture == RealtimeTestFixture.date("08:00:00"))
        #expect(page.realtimeState == .unavailable)
    }
}
