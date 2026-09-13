import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Test func serviceTimeRetainsServiceDayOverflow() throws {
    let time = try ServiceTime(parsing: "25:03:00")
    #expect(time.rawValue == 90_180)
    #expect(time.gtfsString == "25:03:00")
    #expect(throws: GTFSArchiveError.invalidServiceTime("12:60:00")) {
        _ = try ServiceTime(parsing: "12:60:00")
    }
}

@Test func streamedImportSupportsArchiveTablesAndQueries() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeFixtureArchive(to: archiveURL)

    let info = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL, generation: 7)
    let expectedStart = try GTFSDate(parsing: "20260901")
    let expectedEnd = try GTFSDate(parsing: "20260903")
    let expectedMaximum = try ServiceTime(parsing: "25:20:00")
    #expect(info.firstServiceDate == expectedStart)
    #expect(info.lastServiceDate == expectedEnd)
    #expect(info.maximumServiceTime == expectedMaximum)
    #expect(info.generation == 7)

    let replacement = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL, generation: 8)
    #expect(replacement.generation == 8)

    let store = try GTFSStore(databaseAt: databaseURL)
    #expect(await store.feedInfo().generation == 8)
    #expect((try await store.agencies()).map(\.id) == ["operator"])
    #expect(try await store.route(id: "route-1")?.agencyID == "operator")
    let searched = try await store.searchStops(matching: "eto")
    #expect(searched.map(\.id) == ["stop-a"])

    let nearby = try await store.nearbyStops(to: Coordinate(latitude: 49.611, longitude: 6.131), withinMeters: 500)
    #expect(nearby.map(\.id) == ["stop-a"])

    let date = try GTFSDate(parsing: "20260903")
    #expect(try await store.isServiceActive("weekday", on: date))
    let removedDate = try GTFSDate(parsing: "20260902")
    #expect(!(try await store.isServiceActive("weekday", on: removedDate)))
    #expect(try await store.calendar(forServiceID: "weekday")?.weekdays == [0, 1, 1, 0, 0, 0, 0])
    #expect((try await store.calendarExceptions(forServiceID: "weekday")).count == 2)
    #expect((try await store.trips(forRouteID: "route-1", activeOn: date)).map(\.id) == ["trip-1"])

    let departures = try await store.scheduledDepartures(fromStopID: "stop-a", on: date, notBefore: ServiceTime(rawValue: 80_000))
    #expect(departures.count == 1)
    #expect(departures[0].departure?.gtfsString == "25:10:00")
    #expect(departures[0].route.id == "route-1")
    #expect(departures[0].agency?.id == "operator")

    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let afterMidnight = berlin.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 0))!
    let next = try await store.nextScheduledDepartures(fromStopID: "stop-a", at: afterMidnight, horizon: 60 * 60)
    #expect(next.first?.departure?.gtfsString == "25:10:00")

    let stopTimes = try await store.stopTimes(forTripID: "trip-1")
    #expect(stopTimes.count == 2)
    #expect(stopTimes[1].arrival?.gtfsString == "25:20:00")
    #expect(stopTimes[1].dropOffType == 0)

    let shape = try await store.shape(id: "shape-1")
    #expect(shape?.coordinates.count == 3)
    #expect(shape?.coordinates[1] == Coordinate(latitude: 49.611, longitude: 6.132))

    let rules = try await store.transferRules(fromStopID: "stop-a")
    #expect(rules == [TransferRule(fromStopID: "stop-a", toStopID: "stop-b", transferType: 2, minimumTransferSeconds: 180, fromRouteID: "route-1", toRouteID: nil, fromTripID: nil, toTripID: nil)])

    let frequencies = try await store.frequencies(forTripID: "trip-1")
    #expect(frequencies.count == 1)
    #expect(frequencies[0].headwaySeconds == 600)
}

@Test func batchedRoutesServingStopsAreDistinctBoundedAndDeterministic() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("routes-by-stop.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeArchive(to: archiveURL, files: scenarioFiles(
        routes: "bus,operator,10,Bus,3\ntram,operator,T1,Tram,0\ntrain,operator,RE,Train,2\n",
        stops: scenarioStops([
            ("bus-stop", "Bus stop", 49.600000),
            ("tram-stop", "Tram stop", 49.601000),
            ("train-stop", "Train stop", 49.602000),
        ]),
        trips: "bus,service,bus-run,,,,\ntram,service,tram-run,,,,\ntrain,service,train-run,,,,\n",
        stopTimes: "bus-run,08:00:00,08:00:00,bus-stop,1\n"
            + "bus-run,08:05:00,08:05:00,bus-stop,2\n"
            + "tram-run,08:00:00,08:00:00,tram-stop,1\n"
            + "train-run,08:00:00,08:00:00,train-stop,1\n"
    ))
    _ = try await GTFSArchiveInstaller.install(
        archiveAt: archiveURL,
        databaseAt: databaseURL,
        generation: 1
    )
    let store = try GTFSStore(databaseAt: databaseURL)

    #expect(try await store.routes(servingStopIDs: []).isEmpty)
    let routes = try await store.routes(servingStopIDs: [
        "train-stop", "bus-stop", "tram-stop", "bus-stop", "missing-stop",
    ])

    #expect(routes.keys.sorted() == ["bus-stop", "train-stop", "tram-stop"])
    #expect(routes["bus-stop"]?.map(\.id) == ["bus"])
    #expect(routes["tram-stop"]?.map(\.type) == [0])
    #expect(routes["train-stop"]?.map(\.type) == [2])
}

@Test func hafasModelsHandleSingleAndNestedResponseValues() throws {
    let nearbyJSON = """
    {"StopLocation":{"id":"A=1@L=42@","extId":"42","name":"Gare","lon":6.1,"lat":49.6,"products":"32","productAtStop":{"name":"Bus 10","line":"10","cls":"32"}}}
    """.data(using: .utf8)!
    let nearby = try JSONDecoder().decode(HafasNearbyStopsEnvelope.self, from: nearbyJSON)
    #expect(nearby.stopLocations.values.count == 1)
    #expect(nearby.stopLocations.values[0].productsAtStop.values[0].productClass == 32)

    let boardJSON = """
    {"DepartureBoard":{"Departure":{"JourneyDetailRef":{"ref":"1|2"},"Product":{"name":"Bus 10","cls":"32"},"Notes":{"Note":{"value":"Late","priority":"1"}},"Stops":{"Stop":{"name":"Gare","routeIdx":0}},"time":"12:00:00","date":"2026-09-03","rtTime":"12:02:00","cancelled":false}}}
    """.data(using: .utf8)!
    let board = try JSONDecoder().decode(HafasDepartureBoardEnvelope.self, from: boardJSON)
    let departure = try #require(board.departureBoard.departures.values.first)
    #expect(departure.journeyReference?.reference == "1|2")
    #expect(departure.notes.values.first?.priority == 1)
    #expect(departure.passlist.values.first?.name == "Gare")
}

@Test func hafasDepartureBoardAcceptsTheCurrentTopLevelResponse() throws {
    // ATP currently returns `Departure` at the response root, without a
    // `DepartureBoard` wrapper.
    let boardJSON = """
    {"Departure":{"JourneyDetailRef":{"ref":"1|2"},"Product":{"name":"Bus 10","cls":"32"},"time":"12:00:00","date":"2026-09-03"}}
    """.data(using: .utf8)!

    let board = try JSONDecoder().decode(HafasDepartureBoardEnvelope.self, from: boardJSON)
    let departure = try #require(board.departureBoard.departures.values.first)
    #expect(departure.journeyReference?.reference == "1|2")
    #expect(departure.product?.name == "Bus 10")
}

@Test func hafasModelsAcceptTheCurrentATPNearbyAndDepartureShapes() throws {
    let nearbyJSON = """
    {"stopLocationOrCoordLocation":[{"StopLocation":{"id":"A=1@L=42@","extId":"42","name":"Gare","lon":6.1,"lat":49.6,"dist":59,"products":32}}]}
    """.data(using: .utf8)!

    let nearby = try JSONDecoder().decode(HafasNearbyStopsEnvelope.self, from: nearbyJSON)
    #expect(nearby.stopLocations.values.first?.name == "Gare")
    #expect(nearby.stopLocations.values.first?.products == 32)

    let boardJSON = """
    {"Departure":[{"JourneyDetailRef":{"ref":"1|2"},"Product":[{"name":"Bus 19","line":"19","lineId":"route-19","cls":"32","operator":"AVL"}],"direction":"Luxembourg, Gare","platform":{"type":"ST","text":"1"},"rtPlatform":{"type":"ST","text":"2"},"time":"12:00:00","date":"2026-09-03","rtTime":"12:02:00","rtDate":"2026-09-03","cancelled":false}]}
    """.data(using: .utf8)!

    let board = try JSONDecoder().decode(HafasDepartureBoardEnvelope.self, from: boardJSON)
    let departure = try #require(board.departureBoard.departures.values.first)
    #expect(departure.product?.line == "19")
    #expect(departure.product?.operatorName == "AVL")
    #expect(departure.direction == "Luxembourg, Gare")
    #expect(departure.platform?.text == "1")
    #expect(departure.realtimePlatform?.text == "2")
}

@Test func apiClientAcceptsAnAppEnteredRelayURL() throws {
    let client = try MobiliteitAPIClient(
        apiKey: "relay-key",
        apiURL: "  https://relay.example.com/hafas  "
    )

    #expect(client.baseURL.absoluteString == "https://relay.example.com/hafas")
    #expect(throws: MobiliteitAPIError.invalidRequest("apiURL must be an absolute HTTP(S) URL")) {
        _ = try MobiliteitAPIClient(apiKey: "relay-key", apiURL: "not a URL")
    }
}

@Test func routingSnapshotProvidesOfflineRaptorJourney() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeFixtureArchive(to: archiveURL)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL, generation: 9)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let anchor = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1)))
    let router = try await TransitRouter(databaseURL: databaseURL)
    let session = try await router.makeSession(for: .init(origin: .stop(id: "stop-a"), destination: .stop(id: "stop-b"), departureTime: anchor))
    let page = try await session.initial()
    let journey = try #require(page.journeys.first)
    #expect(journey.legs.count == 1)
    #expect(journey.transferCount == 0)
    #expect(journey.effectiveArrival > anchor)
}

@Test func gromscheedToHamiliusAppRoutePrintsRealGTFSResults() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("gromscheed-hamilius.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try await downloadLiveOpenOVGTFS(to: archiveURL)
    try addLuxexpoInterchange(to: archiveURL)
    let feed = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL, generation: 10)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
    let anchor = try #require(nextWeekday(at: 8, onOrAfter: feed.firstServiceDate, calendar: calendar))
    let origin = Coordinate(latitude: 49.6541071, longitude: 6.2296443)
    let destination = Coordinate(latitude: 49.611409, longitude: 6.126431)
    let router = try await TransitRouter(databaseURL: databaseURL, walkingProvider: RealisticWalkingProvider())
    let session = try await router.makeSession(for: .init(
        origin: .coordinate(origin, label: "18A Gromscheed, Senningerberg"),
        destination: .coordinate(destination, label: "Hamilius"),
        departureTime: anchor,
        preferences: .init(maxTransfers: 1, minimumTransferSeconds: 120)
    ))

    let page = try await session.initial()
    #expect(page.journeys.count == 5)
    #expect(page.journeys.allSatisfy { $0.transferCount >= 1 })
    #expect(page.journeys.allSatisfy { journey in journey.legs.contains { if case let .walk(walk) = $0 { return walk.source == .pathway && walk.duration == 90 }; return false } })
    #expect(page.journeys.allSatisfy { $0.walkingDuration == 390 })
    let tripSequences = page.journeys.map(transitTripInstanceSequence)
    #expect(Set(tripSequences).count == page.journeys.count)
    #expect(Set(page.journeys.compactMap(firstTransitTripID)).count == page.journeys.count)
    for (earlier, later) in zip(page.journeys, page.journeys.dropFirst()) {
        #expect(earlier.effectiveDeparture <= later.effectiveDeparture)
        #expect(!(later.effectiveDeparture >= earlier.effectiveDeparture && later.effectiveArrival <= earlier.effectiveArrival && (later.effectiveDeparture > earlier.effectiveDeparture || later.effectiveArrival < earlier.effectiveArrival)))
    }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "HH:mm:ss"
    print("Gromscheed → Hamilius: \(page.journeys.count) routes")
    for (index, journey) in page.journeys.enumerated() {
        let routes = journey.legs.compactMap { leg in
            if case let .transit(transit) = leg { return transit.route.shortName ?? transit.route.id }
            if case .walk = leg { return "walk" }
            return "in-seat"
        }.joined(separator: " → ")
        print("  \(index + 1). \(formatter.string(from: journey.effectiveDeparture))–\(formatter.string(from: journey.effectiveArrival)) | \(routes) | transfers: \(journey.transferCount)")
    }
}

@Test func routePlannerReturnsFiveSequentialNonDominatedTripInstances() async throws {
    let page = try await routePage(using: profileFixtureFiles())
    #expect(page.journeys.count == 5)
    #expect(page.journeys.map(transitTripInstanceSequence) == [["run-1"], ["run-2"], ["run-3"], ["run-4"], ["run-5"]])
    #expect(page.journeys.allSatisfy { $0.effectiveArrival < date(hour: 9) })
}

@Test func routePlannerWalksToTheNearbyStopWithTheQuickestJourney() async throws {
    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let fixture = try await installedRouter(using: walkingChoiceFixtureFiles(), walking: FixtureWalkingProvider(routes: [
        .init(from: origin, to: Coordinate(latitude: 49.600100, longitude: 6.100000), seconds: 60),
        .init(from: origin, to: Coordinate(latitude: 49.601000, longitude: 6.100000), seconds: 120),
    ]))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(origin: .coordinate(origin, label: "Home"), destination: .stop(id: "destination"), departureTime: date(hour: 8)))
    let journey = try #require(try await session.initial().journeys.first)
    #expect(transitTripInstanceSequence(journey) == ["fast-run"])
    #expect(journey.legs.first?.walkingDestinationStopID == "fast-stop")
}

@Test func routePlannerCollapsesExactTripsAndKeepsTheSafestTransfer() async throws {
    let page = try await routePage(using: transferChoiceFixtureFiles())
    #expect(page.journeys.count == 1)
    let journey = try #require(page.journeys.first)
    #expect(transitTripInstanceSequence(journey) == ["incoming", "outgoing"])
    let transit = journey.legs.compactMap { if case let .transit(leg) = $0 { return leg }; return nil }
    #expect(transit[0].alight.stop.id == "transfer-a")
    #expect(transit[1].board.stop.id == "transfer-a")
}

@Test func routePlannerRetainsDifferentScheduledVehiclesOnTheSameLine() async throws {
    let page = try await routePage(using: sameLineFixtureFiles())
    #expect(page.journeys.map(transitTripInstanceSequence) == [["line-10-run-1"], ["line-10-run-2"]])
}

@Test func realtimeOverlayInjectsDelayedPastBoarding() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeFixtureArchive(to: archiveURL)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let anchor = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 15)))
    let departure = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 20)))
    let arrival = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 30)))
    let serviceDate = try GTFSDate(parsing: "20260903")
    let live = FixtureRealtime(patches: [.init(tripID: "trip-1", serviceDate: serviceDate, events: [
        .init(stopID: "stop-a", effectiveDeparture: departure),
        .init(stopID: "stop-b", effectiveArrival: arrival),
    ])])
    let router = try await TransitRouter(databaseURL: databaseURL, realtimeProvider: live)
    let session = try await router.makeSession(for: .init(origin: .stop(id: "stop-a"), destination: .stop(id: "stop-b"), departureTime: anchor, realtimePolicy: .bestEffort()))
    let page = try await session.initial()
    let journey = try #require(page.journeys.first)
    #expect(journey.effectiveDeparture == departure)
    #expect(journey.effectiveArrival == arrival)
    #expect(journey.scheduledDeparture < anchor)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct FixtureRealtime: RealtimeRoutingProvider {
    let patches: [RealtimeTripPatch]
    func patches(for stopIDs: [String], from: Date, through: Date) async throws -> [RealtimeTripPatch] { patches }
}

private struct RealisticWalkingProvider: WalkingRoutingProvider {
    private let home = Coordinate(latitude: 49.6541071, longitude: 6.2296443)
    private let gromscheedStop = Coordinate(latitude: 49.6516899, longitude: 6.2310641)
    private let hamilius = Coordinate(latitude: 49.611409, longitude: 6.126431)
    private let hamiliusStop = Coordinate(latitude: 49.6109868, longitude: 6.1257988)

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(durationSeconds: route.durationSeconds, distanceMeters: route.distanceMeters)
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        if isNear(request.source, home) && isNear(request.destination, gromscheedStop) {
            return .init(durationSeconds: 240, distanceMeters: 300, polyline: [request.source, request.destination])
        }
        if isNear(request.source, hamilius) && isNear(request.destination, hamiliusStop) {
            return .init(durationSeconds: 60, distanceMeters: 85, polyline: [request.source, request.destination])
        }
        throw WalkingProviderError.noRoute
    }

    private func isNear(_ lhs: Coordinate, _ rhs: Coordinate) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.00002 && abs(lhs.longitude - rhs.longitude) < 0.00002
    }
}

private enum WalkingProviderError: Error {
    case noRoute
}

private struct FixtureWalk: Hashable {
    let from: Coordinate
    let to: Coordinate
    let seconds: Int
}

private struct FixtureWalkingProvider: WalkingRoutingProvider {
    let routes: [FixtureWalk]

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(durationSeconds: route.durationSeconds, distanceMeters: route.distanceMeters)
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        guard let match = routes.first(where: { $0.from == request.source && $0.to == request.destination }) else {
            throw WalkingProviderError.noRoute
        }
        return .init(durationSeconds: match.seconds, distanceMeters: Double(match.seconds), polyline: [match.from, match.to])
    }
}

private func routePage(using files: [String: String]) async throws -> JourneyPage {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeArchive(to: archiveURL, files: files)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)
    let router = try await TransitRouter(databaseURL: databaseURL)
    let session = try await router.makeSession(for: .init(origin: .stop(id: "origin"), destination: .stop(id: "destination"), departureTime: date(hour: 8)))
    return try await session.initial()
}

private struct InstalledFixtureRouter {
    let folder: URL
    let router: TransitRouter
}

private func installedRouter(using files: [String: String], walking: any WalkingRoutingProvider) async throws -> InstalledFixtureRouter {
    let folder = try temporaryDirectory()
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeArchive(to: archiveURL, files: files)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)
    return .init(folder: folder, router: try await TransitRouter(databaseURL: databaseURL, walkingProvider: walking))
}

private func date(hour: Int, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: hour, minute: minute))!
}

private func transitTripInstanceSequence(_ journey: Journey) -> [String] {
    journey.legs.compactMap { if case let .transit(leg) = $0 { return leg.tripID }; return nil }
}

private func firstTransitTripID(_ journey: Journey) -> String? {
    transitTripInstanceSequence(journey).first
}

private extension JourneyLeg {
    var walkingDestinationStopID: String? {
        guard case let .walk(leg) = self else { return nil }
        return leg.to.stop?.id
    }
}

private func profileFixtureFiles() -> [String: String] {
    scenarioFiles(
        routes: "route-10,operator,10,Profile,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: ["run-1", "same-departure-slower", "slow-early", "run-2", "run-3", "run-4", "run-5"].map { "route-10,service,\($0),,,," }.joined(separator: "\n") + "\n",
        stopTimes: [
            ("run-1", "08:05:00", "08:25:00"), ("same-departure-slower", "08:05:00", "08:27:00"), ("slow-early", "08:06:00", "08:50:00"),
            ("run-2", "08:10:00", "08:30:00"), ("run-3", "08:15:00", "08:35:00"),
            ("run-4", "08:20:00", "08:40:00"), ("run-5", "08:25:00", "08:45:00"),
        ].map { "\($0.0),\($0.1),\($0.1),origin,1\n\($0.0),\($0.2),\($0.2),destination,2" }.joined(separator: "\n") + "\n"
    )
}

private func walkingChoiceFixtureFiles() -> [String: String] {
    scenarioFiles(
        routes: "slow,operator,SLOW,Slow,3\nfast,operator,FAST,Fast,3\n",
        stops: scenarioStops([("near-stop", "Near stop", 49.600100), ("fast-stop", "Fast stop", 49.601000), ("destination", "Destination", 49.610000)]),
        trips: "slow,service,slow-run,,,,\nfast,service,fast-run,,,,\n",
        stopTimes: "slow-run,08:05:00,08:05:00,near-stop,1\nslow-run,08:40:00,08:40:00,destination,2\nfast-run,08:03:00,08:03:00,fast-stop,1\nfast-run,08:20:00,08:20:00,destination,2\n"
    )
}

private func transferChoiceFixtureFiles() -> [String: String] {
    scenarioFiles(
        routes: "in,operator,IN,Incoming,3\nout,operator,OUT,Outgoing,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("transfer-a", "Transfer A", 49.601000), ("transfer-b", "Transfer B", 49.602000), ("destination", "Destination", 49.610000)]),
        trips: "in,service,incoming,,,,\nout,service,outgoing,,,,\n",
        stopTimes: "incoming,08:05:00,08:05:00,origin,1\nincoming,08:10:00,08:10:00,transfer-a,2\nincoming,08:12:00,08:12:00,transfer-b,3\noutgoing,08:25:00,08:25:00,transfer-a,1\noutgoing,08:25:00,08:25:00,transfer-b,2\noutgoing,08:40:00,08:40:00,destination,3\n"
    )
}

private func sameLineFixtureFiles() -> [String: String] {
    scenarioFiles(
        routes: "route-10,operator,10,Same line,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: "route-10,service,line-10-run-1,,,,\nroute-10,service,line-10-run-2,,,,\n",
        stopTimes: "line-10-run-1,08:05:00,08:05:00,origin,1\nline-10-run-1,08:30:00,08:30:00,destination,2\nline-10-run-2,08:10:00,08:10:00,origin,1\nline-10-run-2,08:35:00,08:35:00,destination,2\n"
    )
}

private func scenarioFiles(routes: String, stops: String, trips: String, stopTimes: String) -> [String: String] {
    [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Berlin\n",
        "calendar_dates.txt": "service_id,date,exception_type\nservice,20260904,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\n" + routes,
        "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\n" + stops,
        "trips.txt": "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id\n" + trips,
        "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + stopTimes,
    ]
}

private func scenarioStops(_ stops: [(String, String, Double)]) -> String {
    stops.map { "\($0.0),\($0.1),\($0.2),6.100000" }.joined(separator: "\n") + "\n"
}

private func writeArchive(to url: URL, files: [String: String]) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate, provider: { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        })
    }
}

private func downloadLiveOpenOVGTFS(to destination: URL) async throws {
    // OpenOV's HTTPS chain is currently incompatible with the test host's
    // trust store. This is public, unsigned fixture data, so the required live
    // integration test downloads the publisher's HTTP endpoint instead.
    let source = URL(string: "http://www.openov.lu/data/gtfs/gtfs-openov-lu.zip")!
    let (temporaryURL, response) = try await URLSession.shared.download(from: source)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
}

private func addLuxexpoInterchange(to archiveURL: URL) throws {
    let archive = try Archive(url: archiveURL, accessMode: .update)
    let content = "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length,traversal_time,stair_count,max_slope,min_width,signposted_as,reversed_signposted_as\nluxexpo-bus-to-tram,LU::ScheduledStopPoint:18550810_RGTR_::,LU::ScheduledStopPoint:1855805_TRAM_::,2,0,65,90,0,0,1.2,,\n"
    let data = Data(content.utf8)
    try archive.addEntry(with: "pathways.txt", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate, provider: { position, size in
        data.subdata(in: Int(position)..<(Int(position) + size))
    })
}

private func nextWeekday(at hour: Int, onOrAfter date: GTFSDate, calendar: Calendar) -> Date? {
    var candidate = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hour))
    for _ in 0..<14 {
        guard let current = candidate else { return nil }
        if (2...6).contains(calendar.component(.weekday, from: current)) { return current }
        candidate = calendar.date(byAdding: .day, value: 1, to: current)
    }
    return nil
}

private func writeFixtureArchive(to url: URL) throws {
    let files: [String: String] = [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone\noperator,Transit Operator,https://example.com,Europe/Berlin,fr,+352\n",
        "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nweekday,0,1,1,0,0,0,0,20260901,20260903\n",
        "calendar_dates.txt": "service_id,date,exception_type\nweekday,20260902,2\nweekday,20260903,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color,route_desc\nroute-1,operator,10,Central,3,00AAFF,FFFFFF,Test route\n",
        "stops.txt": "stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,location_type,parent_station,wheelchair_boarding,platform_code\nstop-a,,Gare Étoile,,49.611,6.131,0,,0,\nstop-b,,Terminus,,49.620,6.140,0,,0,\n",
        "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nshape-1,49.610000,6.131000,1\nshape-1,49.611000,6.132000,2\nshape-1,49.620000,6.140000,3\n",
        "trips.txt": "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed\nroute-1,weekday,trip-1,Terminus,,0,block-1,shape-1,0,1\n",
        "stop_times.txt": "trip_id,stop_id,stop_sequence,pickup_type,drop_off_type,stop_headsign,arrival_time,departure_time\ntrip-1,stop-a,1,0,0,,25:00:00,25:10:00\ntrip-1,stop-b,2,0,0,,25:20:00,25:20:00\n",
        "frequencies.txt": "trip_id,start_time,end_time,headway_secs,exact_times\ntrip-1,05:00:00,06:00:00,600,1\n",
        "transfers.txt": "from_stop_id,to_stop_id,transfer_type,min_transfer_time,from_route_id,to_route_id,from_trip_id,to_trip_id\nstop-a,stop-b,2,180,route-1,,,,\n",
    ]
    let archive = try Archive(url: url, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate,
            provider: { (position: Int64, size: Int) in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }
}

// Real rows copied from the OpenOV Luxembourg GTFS archive published on
// 2024-10-24: RGTR 322 from Gromscheed to Luxexpo, then tram T1 to Hamilius.
// The source feed did not contain transfers.txt or pathways.txt, so this
// fixture adds the physical Luxexpo interchange needed for the app route.
private func writeRealGromscheedToHamiliusArchive(to url: URL) throws {
    let files: [String: String] = [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone\nLU::Authority:126::,RGTR,http://openov.nl/,Europe/Amsterdam,,\nLU::Authority:141::,Luxtram,http://openov.nl/,Europe/Amsterdam,,\n",
        "calendar_dates.txt": "service_id,date,exception_type\nLU::DayType:1690::,20241025,1\nLU::DayType:1649::,20241025,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_desc,route_type\nLU::Line:2424::,LU::Authority:126::,322,,,3\nLU::Line:2466::,LU::Authority:141::,T1,,,0\n",
        "stops.txt": "stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,location_type,parent_station,wheelchair_boarding,platform_code\nLU::ScheduledStopPoint:24430202_RGTR_::,SEGROM02,\"SENNINGERBERG, Gromscheed\",,49.6516899,6.2310641,,,0,,\nLU::ScheduledStopPoint:24430302_RGTR_::,SEKAPE02,\"SENNINGERBERG, Kapell\",,49.6501880,6.2265770,,,0,,\nLU::ScheduledStopPoint:16380102_RGTR_::,SEGOLF02,\"SENNINGERBERG, Rue du Golf\",,49.6448994,6.2210035,,,0,,\nLU::ScheduledStopPoint:18550810_RGTR_::,LUKGLU10,\"LUX Kirchberg, Gare Luxexpo quai 1A\",,49.6359786,6.1750942,,,0,,\nLU::ScheduledStopPoint:1855805_TRAM_::,KENN805,Luxexpo,,49.6354302,6.1758462,,,0,,\nLU::ScheduledStopPoint:1855807_TRAM_::,KENN807,Alphonse Weicker,,49.6322035,6.1708112,,,0,,\nLU::ScheduledStopPoint:1855809_TRAM_::,KENN809,\"Nationalbibliothéik / Bibliothèque Nationale\",,49.6293073,6.1660624,,,0,,\nLU::ScheduledStopPoint:1855811_TRAM_::,KENN811,Universitéit,,49.6260081,6.1606589,,,0,,\nLU::ScheduledStopPoint:1855813_TRAM_::,KENN813,Coque,,49.6228282,6.1542660,,,0,,\nLU::ScheduledStopPoint:1855815_TRAM_::,KENN815,\"Europaparlament / Parlement Européen\",,49.6208554,6.1483157,,,0,,\nLU::ScheduledStopPoint:1855817_TRAM_::,KENN817,\"Philharmonie / Mudam\",,49.6195485,6.1420223,,,0,,\nLU::ScheduledStopPoint:1855819_TRAM_::,KENN819,Rout Bréck - Pafendall,,49.6186465,6.1364671,,,0,,\nLU::ScheduledStopPoint:1628821_TRAM_::,GLAC821,Theater,,49.6176348,6.1254214,,,0,,\nLU::ScheduledStopPoint:1431823_TRAM_::,RESI823,Faïencerie,,49.6160639,6.1212215,,,0,,\nLU::ScheduledStopPoint:2440825_TRAM_::,ETOI825,\"Stäreplaz / Étoile\",,49.6136051,6.1196635,,,0,,\nLU::ScheduledStopPoint:2449827_TRAM_::,ROYA827,Hamilius,,49.6109868,6.1257988,,,0,,\n",
        "trips.txt": "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed\nLU::Line:2424::,LU::DayType:1690::,LU::ServiceJourney:18813796_0::,,,,,,0,\nLU::Line:2466::,LU::DayType:1649::,LU::ServiceJourney:18556305_0::,,,,,,0,\n",
        "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,continuous_pickup,continuous_drop_off,shape_dist_traveled,timepoint\nLU::ServiceJourney:18813796_0::,08:20:10,08:20:10,LU::ScheduledStopPoint:24430202_RGTR_::,17,,,,,,,1\nLU::ServiceJourney:18813796_0::,08:21:05,08:21:05,LU::ScheduledStopPoint:24430302_RGTR_::,18,,,,,,,1\nLU::ServiceJourney:18813796_0::,08:22:35,08:22:35,LU::ScheduledStopPoint:16380102_RGTR_::,19,,,,,,,1\nLU::ServiceJourney:18813796_0::,08:30:30,08:30:30,LU::ScheduledStopPoint:18550810_RGTR_::,20,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:33:00,08:33:00,LU::ScheduledStopPoint:1855805_TRAM_::,1,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:34:20,08:34:20,LU::ScheduledStopPoint:1855807_TRAM_::,2,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:35:40,08:35:40,LU::ScheduledStopPoint:1855809_TRAM_::,3,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:37:10,08:37:10,LU::ScheduledStopPoint:1855811_TRAM_::,4,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:38:30,08:38:30,LU::ScheduledStopPoint:1855813_TRAM_::,5,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:39:50,08:39:50,LU::ScheduledStopPoint:1855815_TRAM_::,6,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:41:10,08:41:10,LU::ScheduledStopPoint:1855817_TRAM_::,7,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:42:30,08:42:30,LU::ScheduledStopPoint:1855819_TRAM_::,8,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:45:00,08:45:00,LU::ScheduledStopPoint:1628821_TRAM_::,9,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:46:50,08:46:50,LU::ScheduledStopPoint:1431823_TRAM_::,10,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:48:30,08:48:30,LU::ScheduledStopPoint:2440825_TRAM_::,11,,,,,,,1\nLU::ServiceJourney:18556305_0::,08:51:20,08:51:20,LU::ScheduledStopPoint:2449827_TRAM_::,12,,,,,,,1\n",
        "pathways.txt": "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length,traversal_time,stair_count,max_slope,min_width,signposted_as,reversed_signposted_as\nluxexpo-bus-to-tram,LU::ScheduledStopPoint:18550810_RGTR_::,LU::ScheduledStopPoint:1855805_TRAM_::,2,0,0,0,0,0,1.2,,\n"
    ]
    let archive = try Archive(url: url, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate,
            provider: { (position: Int64, size: Int) in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }
}
