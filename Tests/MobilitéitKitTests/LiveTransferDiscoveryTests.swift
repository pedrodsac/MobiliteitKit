import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct LiveTransferDiscoveryTests {
    @Test(arguments: [RouteQueryDirection.departAfter, .arriveBy], ["available", "stalled", "absent"])
    func delayedDifferentLineIsDiscoveredBeforeTheFirstResult(direction: RouteQueryDirection,
                                                             fallback: String) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "connection,08:08:00,08:08:00,b,1\nconnection,08:23:00,08:23:00,c,2\n"
                + (fallback == "absent" ? "" : "fallback,08:20:00,08:20:00,b,1\nfallback,08:50:00,08:50:00,c,2\n"),
            trips: "route,service,first,Transfer\nconnecting,service,connection,Destination\n"
                + (fallback == "absent" ? "" : "slow,service,fallback,Destination\n"),
            additionalRoutes: "connecting,operator,202,Connection,3\nslow,operator,203,Fallback,3\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // A stalled static winner must leave time to discover another line.
            return fallback == "stalled" && items.contains { $0.name == "lines" && $0.value == "203" }
                ? .seconds(5) : .zero
        }) { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let stop = items.first { $0.name == "id" }?.value
            let lines = items.first { $0.name == "lines" }?.value?.split(separator: ",").map(String.init) ?? []
            if stop == "a" {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                    + liveStop("b", planned: "08:10:00", predicted: "08:11:00", arrival: "08:11:00"),
                    realtime: "08:01:00")
            }
            guard stop == "b" else { return #"{"Departure":[]}"# }
            var rows: [String] = []
            if lines.isEmpty || lines.contains("202") {
                rows.append(Self.row(line: "202", trip: "connection", departure: "08:08:00", arrival: "08:23:00",
                                     predictedDeparture: "08:14:00", predictedArrival: "08:29:00"))
            }
            if lines.isEmpty || lines.contains("203") {
                rows.append(Self.row(line: "203", trip: "fallback", departure: "08:20:00", arrival: "08:50:00",
                                     predictedDeparture: "08:20:00", predictedArrival: "08:50:00"))
            }
            return "{\"Departure\":[\(rows.joined(separator: ","))]}"
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let anchor = RealtimeTestFixture.date(direction == .arriveBy ? "09:00:00" : "07:55:00")
        let preferences = RoutingPreferences(maxTransfers: 1)
        let scheduled = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: anchor, direction: direction, preferences: preferences)).initial(count: 10, searchHorizon: 10_800)
        #expect(scheduled.journeys.isEmpty == (fallback == "absent"))
        #expect(!scheduled.journeys.contains { Self.tripIDs($0).contains("connection") })
        let live = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: anchor, direction: direction, preferences: preferences,
            realtimePolicy: .bestEffort(configuration: .init(maximumConcurrentBoardRequests: 16,
                acquisitionBudgetMilliseconds: 2_500, searchWorkBudgetMilliseconds: 4_100))))
            .initial(count: 10, searchHorizon: 10_800)
        let rescued = try #require(live.journeys.first { Self.tripIDs($0) == ["first", "connection"] })
        #expect(rescued.effectiveArrival == RealtimeTestFixture.date("08:29:00"))
        #expect(rescued.statusEvidence.coverage == .live)
        #expect(live.recommendedJourneyID == rescued.id)
        let requestedConnection = RealtimeBoardProtocol.requests(host).contains { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "id" }?.value == "b"
                && (items.first { $0.name == "lines" }?.value?.contains("202") ?? true)
        }
        #expect(requestedConnection)
    }

    private static func tripIDs(_ journey: Journey) -> [String] {
        journey.legs.compactMap { if case let .transit(ride) = $0 { ride.tripID } else { nil } }
    }
    private static func row(line: String, trip: String, departure: String, arrival: String,
                            predictedDeparture: String, predictedArrival: String) -> String {
        let stops = liveStop("b", planned: departure, predicted: predictedDeparture) + ","
            + liveStop("c", planned: arrival, predicted: predictedArrival, arrival: predictedArrival)
        let payload = liveBoard(stops: stops, time: departure, realtime: predictedDeparture, stop: "b")
            .replacingOccurrences(of: "\"201\"", with: "\"\(line)\"")
            .replacingOccurrences(of: "same-journey", with: trip)
        let prefix = "{\"Departure\":["
        return String(payload.dropFirst(prefix.count).dropLast(2))
    }
}
