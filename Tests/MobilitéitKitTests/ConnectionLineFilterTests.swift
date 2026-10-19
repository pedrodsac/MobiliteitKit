import Foundation
import Testing
@testable import MobiliteitKit

/// A selected ride that boards after another ride is checked on the whole way on from its stop,
/// not only on its own line. The fixture follows a real search: the schedule picks line 203 at
/// the transfer stop `b`, but a delayed line 202, scheduled before the feeder arrives, is the live
/// winner. Its departure exists only on `b`'s board, which discovery did not fetch.
@Suite struct ConnectionLineFilterTests {
    private static let stopTimes = "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
        + "connection,08:08:00,08:08:00,b,1\nconnection,08:23:00,08:23:00,c,2\n"
        + "picked,08:20:00,08:20:00,b,1\npicked,08:50:00,08:50:00,c,2\n"
        // Line 204 leaves `b` for a stop that cannot reach the destination.
        + "away,08:15:00,08:15:00,b,1\naway,08:40:00,08:40:00,d,2\n"
    private static let trips = "route,service,first,Transfer\nconnecting,service,connection,Destination\n"
        + "slow,service,picked,Destination\nelsewhere,service,away,Elsewhere\n"
    private static let routes = "connecting,operator,202,Connection,3\nslow,operator,203,Picked,3\n"
        + "elsewhere,operator,204,Away,3\n"
    private static let stops = "d,Dead end,49.55,6.05\n"

    private func fixture() async throws -> RealtimeTestFixture {
        try await RealtimeTestFixture(stopTimes: Self.stopTimes, trips: Self.trips,
            additionalStops: Self.stops, additionalRoutes: Self.routes)
    }

    @Test func theRuleNamesEveryLineThatCanStillReachTheDestination() async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
        let destination = try #require(await router.snapshot.stopByID["c"])
        let reachability = await session.optimisticDestinationReachability(
            egress: [.init(stop: destination, seconds: 0, distance: 0, walk: nil)])
        let found = await session.connectionLines(atStop: "b", arrival: RealtimeTestFixture.date("08:11:00"),
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("10:55:00"),
            configuration: .default, deadline: .now.advanced(by: .seconds(5)), reachability: reachability)
        // 202 left before the feeder arrives, which a delay can still make catchable; 204 is a dead end;
        // 201 only arrives at `b`.
        #expect(found.lines == ["202", "203"])
        #expect(found.tripIDs == ["connection", "picked"])
        #expect(!found.unrestricted)
        let none = await session.connectionLines(atStop: "a", arrival: RealtimeTestFixture.date("08:11:00"),
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("10:55:00"),
            configuration: .default, deadline: .now.advanced(by: .seconds(5)), reachability: reachability)
        #expect(none.lines == ["201"] && none.tripIDs == ["first"])
        let late = await session.connectionLines(atStop: "b", arrival: RealtimeTestFixture.date("12:00:00"),
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("13:00:00"),
            configuration: .default, deadline: .now.advanced(by: .seconds(5)), reachability: reachability)
        #expect(late == .init())
    }

    @Test func anUnnamedLineNeedsAnUnrestrictedBoard() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: Self.stopTimes, trips: Self.trips, additionalStops: Self.stops,
            additionalRoutes: Self.routes.replacingOccurrences(of: "slow,operator,203,Picked,3",
                                                              with: "slow,operator,,Picked,3"))
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
        let destination = try #require(await router.snapshot.stopByID["c"])
        let reachability = await session.optimisticDestinationReachability(
            egress: [.init(stop: destination, seconds: 0, distance: 0, walk: nil)])
        let found = await session.connectionLines(atStop: "b", arrival: RealtimeTestFixture.date("08:11:00"),
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("10:55:00"),
            configuration: .default, deadline: .now.advanced(by: .seconds(5)), reachability: reachability)
        #expect(found.unrestricted)
        #expect(found.tripIDs == ["connection", "picked"])
    }

    @Test(arguments: [RouteQueryDirection.departAfter, .arriveBy])
    func theSelectedTransferStopsBoardCoversTheConnectingLineAndNeedsNoSecondBoard(
        direction: RouteQueryDirection
    ) async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .zero }, Self.response)
        defer { RealtimeBoardProtocol.remove(host) }
        let hafas = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let provider = DiscoveryWithoutTransferStop(hafas: hafas, hidden: "b")
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date(direction == .arriveBy ? "09:30:00" : "07:55:00"),
            direction: direction, preferences: .init(maxTransfers: 1),
            realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 2_500))))
            .initial(count: 10, searchHorizon: 10_800)
        let live = try #require(page.journeys.first { Self.tripIDs($0) == ["first", "connection"] })
        #expect(live.effectiveArrival == RealtimeTestFixture.date("08:29:00"))
        #expect(live.statusEvidence.coverage == .live)
        #expect(page.recommendedJourneyID == live.id)
        let requests = await provider.requests
        let selected = try #require(requests.dropFirst().first { $0.stopIDs.contains("b") })
        let transfer = selected.targets.filter { $0.stopID == "b" }
        #expect(transfer.count == 1 && transfer[0].lines == ["202", "203"])
        #expect(selected.tripIDs.isSuperset(of: ["connection", "picked"]))
        // The first ride boards at the origin: its board keeps its own line.
        #expect(selected.targets.filter { $0.stopID == "a" }.allSatisfy { $0.lines == ["201"] })
        #expect(!selected.tripIDs.contains("away"))
    }

    @Test func theSpeculativeCompletionFindsTheLateLinePassOneThenAlreadyUses() async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .zero }, Self.response)
        defer { RealtimeBoardProtocol.remove(host) }
        let hafas = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        // Discovery runs with 28 request slots and the speculative completion with 4.
        let provider = DiscoveryWithoutTransferStop(hafas: hafas, hidden: "b", hidingSlots: 28)
        let router = try await TransitRouter(databaseURL: fixture.database,
            walkingProvider: UnavailableWalking(), realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 1),
            realtimePolicy: .bestEffort(configuration: .init(maximumConcurrentBoardRequests: 32,
                acquisitionBudgetMilliseconds: 2_500)))).initial(count: 10, searchHorizon: 10_800)
        let live = try #require(page.journeys.first { Self.tripIDs($0) == ["first", "connection"] })
        #expect(live.effectiveArrival == RealtimeTestFixture.date("08:29:00"))
        let requests = await provider.requests
        let speculative = try #require(requests.first { $0.maximumConcurrentRequests == 4 })
        #expect(speculative.targets.filter { $0.stopID == "b" }.map(\.lines) == [["202", "203"]])
        #expect(speculative.tripIDs.isSuperset(of: ["connection", "picked"]))
        // The warm-up scan and one authoritative pass: the connecting line is already in pass one.
        #expect(page.metrics.pointRaptorScans == 2)
        #expect(page.metrics.hafasRequests == RealtimeBoardProtocol.requests(host).count)
        // `b` is fetched once, with both lines. A board for line 203 alone would be a second request.
        let transferBoards = RealtimeBoardProtocol.requests(host).compactMap { request -> String? in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "id" }?.value == "b" ? items.first { $0.name == "lines" }?.value : nil
        }
        #expect(transferBoards == ["202,203"])
    }

    /// A trip that continues the same vehicle is not a transfer: its board keeps its own line.
    @Test func stayingAboardAContinuingTripDoesNotWidenItsBoard() async throws {
        var files = preventionFiles(
            trips: "bus,service,seven,Poutty Stein,,,vehicle\nother,service,twentyfive,Dommeldange,,,vehicle\n"
                + "alt,service,altride,Alt,,,\n",
            times: "seven,20:33:20,20:33:20,a,1\nseven,20:34:40,20:34:40,b,2\n"
                + "twentyfive,20:35:10,20:35:10,b,1\ntwentyfive,20:39:00,20:39:00,d,2\n"
                + "altride,20:50:00,20:50:00,b,1\naltride,20:58:00,20:58:00,d,2\n")
        files["routes.txt"] = "route_id,agency_id,route_short_name,route_long_name,route_type\n"
            + "bus,operator,7,Seven,3\nother,operator,25,Twenty five,3\nalt,operator,99,Alt,3\n"
        files["transfers.txt"] = "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nb,b,2,450\n"
        let provider = RecordingEmptyProvider()
        let fixture = try await RoutingPreventionFixture(files: files, realtime: provider)
        defer { fixture.remove() }
        let page = try await fixture.router.makeSession(for: fixture.query(
            preferences: .init(maxTransfers: 0), anchor: date(hour: 20), live: true))
            .initial(count: 10, searchHorizon: 10_800)
        let journey = try #require(page.journeys.first)
        #expect(Self.tripIDs(journey) == ["seven", "twentyfive"])
        #expect(journey.legs.contains { if case .inSeatContinuation = $0 { true } else { false } })
        // Discovery makes the first request; the selected itinerary's vehicles are the later ones.
        let selected = await provider.requests.dropFirst().flatMap(\.targets).filter { $0.stopID == "b" }
        #expect(!selected.isEmpty)
        #expect(selected.allSatisfy { $0.lines == ["25"] })
        #expect(await provider.requests.dropFirst().allSatisfy { !$0.tripIDs.contains("altride") })
    }

    private static func tripIDs(_ journey: Journey) -> [String] {
        journey.legs.compactMap { if case let .transit(ride) = $0 { ride.tripID } else { nil } }
    }

    private static func response(for request: URLRequest) -> String {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let stop = items.first { $0.name == "id" }?.value
        let lines = items.first { $0.name == "lines" }?.value?.split(separator: ",").map(String.init) ?? []
        if stop == "a" {
            return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                + liveStop("b", planned: "08:10:00", predicted: "08:11:00", arrival: "08:11:00"), realtime: "08:01:00")
        }
        guard stop == "b" else { return #"{"Departure":[]}"# }
        var rows: [String] = []
        // The delayed 202 leaves at 08:14 instead of 08:08; 203 runs on time.
        if lines.isEmpty || lines.contains("202") {
            rows.append(row(line: "202", trip: "connection", departure: "08:08:00", arrival: "08:23:00",
                            predictedDeparture: "08:14:00", predictedArrival: "08:29:00"))
        }
        if lines.isEmpty || lines.contains("203") {
            rows.append(row(line: "203", trip: "picked", departure: "08:20:00", arrival: "08:50:00",
                            predictedDeparture: "08:20:00", predictedArrival: "08:50:00"))
        }
        return "{\"Departure\":[\(rows.joined(separator: ","))]}"
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

/// The first batch (discovery, or only the batch with `hidingSlots` request slots) never asks for
/// `hidden`, so the transfer stop's board can only come from the selected itinerary.
private actor DiscoveryWithoutTransferStop: RealtimeRoutingProvider {
    let hafas: HafasRealtimeRoutingProvider
    let hidden: String
    let hidingSlots: Int?
    private(set) var requests: [RealtimeRoutingRequest] = []
    init(hafas: HafasRealtimeRoutingProvider, hidden: String, hidingSlots: Int? = nil) {
        self.hafas = hafas; self.hidden = hidden; self.hidingSlots = hidingSlots
    }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        let hides = hidingSlots.map { request.maximumConcurrentRequests == $0 } ?? (requests.count == 1)
        guard hides else { return try await hafas.patches(for: request) }
        return try await hafas.patches(for: .init(stopIDs: request.stopIDs.filter { $0 != hidden },
            from: request.from, through: request.through, scheduledLookbackSeconds: request.scheduledLookbackSeconds,
            refreshPolicy: request.refreshPolicy, maximumConcurrentRequests: request.maximumConcurrentRequests,
            timeout: request.timeout, deadline: request.deadline,
            targets: request.targets.filter { $0.stopID != hidden }, tripIDs: request.tripIDs))
    }
}

/// Records every request and reports no live data.
private actor RecordingEmptyProvider: RealtimeRoutingProvider {
    private(set) var requests: [RealtimeRoutingRequest] = []
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        return .init(patches: [], requestedStopIDs: Set(request.stopIDs), coveredStopIDs: Set(request.stopIDs))
    }
}

/// Pedestrian routing exists, so the speculative search runs; no walk is ever needed.
private struct UnavailableWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate { throw Unavailable.route }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute { throw Unavailable.route }
    private enum Unavailable: Error { case route }
}
