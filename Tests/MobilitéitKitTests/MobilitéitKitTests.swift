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
    let batchedShapes = try await store.shapes(forTripIDs: ["trip-1", "trip-1", "missing"])
    #expect(batchedShapes == ["trip-1": shape?.coordinates ?? []])

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
        routes: "bus,operator,10,Bus,3\nbus-2,operator,2,Bus 2,3\ntram,operator,T1,Tram,0\ntrain,operator,RE,Train,2\n",
        stops: scenarioStops([
            ("bus-stop", "Bus stop", 49.600000),
            ("tram-stop", "Tram stop", 49.601000),
            ("train-stop", "Train stop", 49.602000),
        ]),
        trips: "bus,service,bus-run,,,,\nbus-2,service,bus-2-run,,,,\ntram,service,tram-run,,,,\ntrain,service,train-run,,,,\n",
        stopTimes: "bus-run,08:00:00,08:00:00,bus-stop,1\n"
            + "bus-run,08:05:00,08:05:00,bus-stop,2\n"
            + "bus-2-run,08:10:00,08:10:00,bus-stop,1\n"
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
    #expect(routes["bus-stop"]?.map(\.id) == ["bus", "bus-2"])
    #expect(routes["tram-stop"]?.map(\.type) == [0])
    #expect(routes["train-stop"]?.map(\.type) == [2])

    let overLimit = (0..<500).map { "missing-\($0)" } + ["bus-stop"]
    #expect(try await store.routes(servingStopIDs: overLimit)["bus-stop"] == nil)
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
    print("Routing timings (ms): endpoint=\(page.metrics.endpointPreparationMilliseconds), live=\(page.metrics.realtimePreparationMilliseconds), RAPTOR=\(page.metrics.raptorSearchMilliseconds), RAPTOR CPU=\(page.metrics.raptorCPUMilliseconds), transfer walks=\(page.metrics.walkingTransferMilliseconds), candidates=\(page.metrics.candidateBuildingMilliseconds)")
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

/// Run explicitly with ROUTING_BENCHMARK_DATABASE pointing to an installed,
/// current GTFS database. CI fixtures stay deterministic and offline.
@Test func installedFeedRouteBenchmarkWhenConfigured() async throws {
    guard let path = ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] else { return }
    let databaseURL = URL(fileURLWithPath: path)
    let store = try GTFSStore(databaseAt: databaseURL)
    let feed = await store.feedInfo()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
    let anchor = try #require(nextWeekday(at: 8, onOrAfter: feed.firstServiceDate, calendar: calendar))
    let router = try await TransitRouter(databaseURL: databaseURL, walkingProvider: BenchmarkWalkingProvider())
    let query = RouteQuery(
        origin: .coordinate(.init(latitude: 49.6541071, longitude: 6.2296443), label: "Gromscheed"),
        destination: .coordinate(.init(latitude: 49.629435, longitude: 6.156983), label: "Kirchberg"),
        departureTime: anchor,
        preferences: .init(maxTransfers: 3, minimumTransferSeconds: 120)
    )
    for run in 1...2 {
        let session = try await router.makeSession(for: query)
        let page = try await session.initial(count: 5, searchHorizon: 3 * 60 * 60)
        print("Full-feed run \(run): profile=\(page.metrics.profileGenerationMilliseconds)ms endpoint=\(page.metrics.endpointPreparationMilliseconds)ms RAPTOR=\(page.metrics.raptorSearchMilliseconds)ms CPU=\(page.metrics.raptorCPUMilliseconds)ms walks=\(page.metrics.walkingTransferMilliseconds)ms pairs=\(page.metrics.walkingTransferPairs) requests=\(page.metrics.walkingRequests) hits=\(page.metrics.walkingCacheHits) journeys=\(page.journeys.map(\.id.value))")
        #expect(!page.journeys.isEmpty)
    }
}

@Test func routePlannerReturnsFiveSequentialNonDominatedTripInstances() async throws {
    let page = try await routePage(using: profileFixtureFiles())
    #expect(page.journeys.count == 5)
    #expect(page.journeys.map(transitTripInstanceSequence) == [["run-1"], ["run-2"], ["run-3"], ["run-4"], ["run-5"]])
    #expect(page.journeys.allSatisfy { $0.effectiveArrival < date(hour: 9) })
}

@Test func routePlannerCanExpandAStableInitialProfile() async throws {
    let fixture = try await installedRouter(
        using: profileFixtureFiles(),
        walking: FixtureWalkingProvider(routes: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"),
        destination: .stop(id: "destination"),
        departureTime: date(hour: 8)
    ))

    let initial = try await session.initial(count: 5, searchHorizon: 12 * 60)
    #expect(initial.journeys.map(transitTripInstanceSequence) == [["run-1"], ["run-2"]])

    let expanded = try await session.expanded(count: 5)
    #expect(expanded.journeys.map(transitTripInstanceSequence) == [["run-1"], ["run-2"], ["run-3"], ["run-4"], ["run-5"]])
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

@Test func parallelPatternScanningIsDeterministic() async throws {
    let routeCount = 40
    let routes = (0..<routeCount).map { "route-\($0),operator,R\($0),Route \($0),3" }.joined(separator: "\n") + "\n"
    let trips = (0..<routeCount).map { "route-\($0),service,run-\($0),,,," }.joined(separator: "\n") + "\n"
    let stopTimes = (0..<routeCount).map { index in
        let departureMinute = index
        let arrivalMinute = index + 20
        let departure = String(format: "08:%02d:00", departureMinute)
        let arrivalHour = 8 + arrivalMinute / 60
        let arrival = String(format: "%02d:%02d:00", arrivalHour, arrivalMinute % 60)
        return "run-\(index),\(departure),\(departure),origin,1\nrun-\(index),\(arrival),\(arrival),destination,2"
    }.joined(separator: "\n") + "\n"
    let fixture = try await installedRouter(
        using: scenarioFiles(
            routes: routes,
            stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
            trips: trips,
            stopTimes: stopTimes
        ),
        walking: FixtureWalkingProvider(routes: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.folder) }

    var expected: [[String]]?
    for _ in 0..<5 {
        let session = try await fixture.router.makeSession(for: .init(
            origin: .stop(id: "origin"),
            destination: .stop(id: "destination"),
            departureTime: date(hour: 8)
        ))
        let page = try await session.initial()
        let sequences = page.journeys.map(transitTripInstanceSequence)
        if let expected { #expect(sequences == expected) }
        else { expected = sequences }
        #expect(page.metrics.raptorWorkerCount == min(8, ProcessInfo.processInfo.activeProcessorCount))
    }
}

@Test func walkingRoutesAreCachedAcrossSessions() async throws {
    let provider = CountingWalkingProvider()
    let fixture = try await installedRouter(using: walkingChoiceFixtureFiles(), walking: provider)
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)

    func page() async throws -> JourneyPage {
        let session = try await fixture.router.makeSession(for: .init(
            origin: .coordinate(origin, label: "Home"),
            destination: .stop(id: "destination"),
            departureTime: date(hour: 8)
        ))
        return try await session.initial()
    }

    _ = try await page()
    let firstRequestCount = await provider.requestCount
    let cachedPage = try await page()
    #expect(await provider.requestCount == firstRequestCount)
    #expect(cachedPage.metrics.walkingCacheHits > 0)
}

@Test func timeOnlyDominanceDoesNotEraseDirectAlternative() async throws {
    let files = scenarioFiles(
        routes: "direct,operator,D,Direct,3\nfirst,operator,F,First,3\nsecond,operator,S,Second,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("transfer", "Transfer", 49.605000), ("destination", "Destination", 49.610000)]),
        trips: "direct,service,direct-run,,,,\nfirst,service,first-run,,,,\nsecond,service,second-run,,,,\n",
        stopTimes: "direct-run,08:00:00,08:00:00,origin,1\ndirect-run,08:30:00,08:30:00,destination,2\n"
            + "first-run,08:01:00,08:01:00,origin,1\nfirst-run,08:10:00,08:10:00,transfer,2\n"
            + "second-run,08:13:00,08:13:00,transfer,1\nsecond-run,08:29:00,08:29:00,destination,2\n"
    )
    let page = try await routePage(using: files)
    let direct = try #require(page.journeys.first { transitTripInstanceSequence($0) == ["direct-run"] })
    #expect(page.journeys.contains { transitTripInstanceSequence($0) == ["first-run", "second-run"] })
    #expect(page.recommendedJourneyID == direct.id)
}

@Test func arrivalDeadlineKeepsLatestDepartureBeyondEightEarlyTrips() async throws {
    let departures = stride(from: 0, through: 56, by: 4).map { minute in
        let id = "run-\(minute)"
        let departure = String(format: "08:%02d:00", minute)
        let arrivalMinute = minute + 20
        let arrival = String(format: "%02d:%02d:00", 8 + arrivalMinute / 60, arrivalMinute % 60)
        return (id, departure, arrival)
    }
    let files = scenarioFiles(
        routes: "bus,operator,B,Bus,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: departures.map { "bus,service,\($0.0),,,," }.joined(separator: "\n") + "\n",
        stopTimes: departures.map {
            "\($0.0),\($0.1),\($0.1),origin,1\n\($0.0),\($0.2),\($0.2),destination,2"
        }.joined(separator: "\n") + "\n"
    )
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 9), direction: .arriveBy
    ))
    let page = try await session.expanded()
    #expect(page.journeys.allSatisfy { $0.effectiveArrival <= date(hour: 9) })
    #expect(page.journeys.contains { firstTransitTripID($0) == "run-40" })
    #expect(page.recommendedJourneyID == page.journeys.first { firstTransitTripID($0) == "run-40" }?.id)
}

@Test func defaultTransferDepthFindsThreeVehicleJourney() async throws {
    let files = scenarioFiles(
        routes: "bus-a,operator,A,Bus A,3\ntrain,operator,T,Train,2\nbus-b,operator,B,Bus B,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("first", "First", 49.603000), ("second", "Second", 49.607000), ("destination", "Destination", 49.610000)]),
        trips: "bus-a,service,run-a,,,,\ntrain,service,run-t,,,,\nbus-b,service,run-b,,,,\n",
        stopTimes: "run-a,08:00:00,08:00:00,origin,1\nrun-a,08:10:00,08:10:00,first,2\n"
            + "run-t,08:13:00,08:13:00,first,1\nrun-t,08:25:00,08:25:00,second,2\n"
            + "run-b,08:28:00,08:28:00,second,1\nrun-b,08:35:00,08:35:00,destination,2\n"
    )
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    func journeys(maxTransfers: Int) async throws -> [Journey] {
        let session = try await fixture.router.makeSession(for: .init(
            origin: .stop(id: "origin"), destination: .stop(id: "destination"),
            departureTime: date(hour: 8), preferences: .init(maxTransfers: maxTransfers)
        ))
        return try await session.initial().journeys
    }
    #expect(try await journeys(maxTransfers: 3).contains { transitTripInstanceSequence($0) == ["run-a", "run-t", "run-b"] })
    #expect(try await journeys(maxTransfers: 1).isEmpty)
}

@Test func usefulInterchangeBeyondOldRadiusUsesVerifiedWalkingBudget() async throws {
    let from = Coordinate(latitude: 49.605000, longitude: 6.100000)
    let to = Coordinate(latitude: 49.611000, longitude: 6.100000)
    let files = scenarioFiles(
        routes: "in,operator,I,Inbound,3\nout,operator,O,Outbound,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000),
                              ("transfer-a", "Transfer A", 49.605000),
                              ("transfer-b", "Transfer B", 49.611000),
                              ("destination", "Destination", 49.616000)]),
        trips: "in,service,incoming,,,,\nout,service,outgoing,,,,\n",
        stopTimes: "incoming,08:00:00,08:00:00,origin,1\nincoming,08:10:00,08:10:00,transfer-a,2\n"
            + "outgoing,08:23:00,08:23:00,transfer-b,1\noutgoing,08:35:00,08:35:00,destination,2\n"
    )
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: [
        .init(from: from, to: to, seconds: 600),
    ]))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8)
    ))
    #expect(try await session.initial().journeys.contains {
        transitTripInstanceSequence($0) == ["incoming", "outgoing"]
    })
    let estimated = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: [
        .init(from: from, to: to, seconds: 600, evidence: .estimate),
    ]))
    defer { try? FileManager.default.removeItem(at: estimated.folder) }
    let estimatedSession = try await estimated.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8)
    ))
    #expect(try await estimatedSession.initial().journeys.isEmpty)
}

@Test func preferredExtendedTramSurvivesFiveEarlierBuses() async throws {
    let mask = TransitModeMask(rawValue: 1 << 0)
    #expect(mask.contains(routeType: 900))
    #expect(!mask.contains(routeType: 700))
    #expect(!TransitModeMask(rawValue: 1 << 2).contains(routeType: 200))
    #expect(TransitModeMask(rawValue: 1 << 3).contains(routeType: 200))
    #expect(TransitModeMask(rawValue: 1 << 1).contains(routeType: 401))
    #expect(!TransitModeMask(rawValue: 1 << 2).contains(routeType: 401))
    let buses = (0..<6).map { minute in ("bus-\(minute)", String(format: "08:%02d:00", minute * 5), String(format: "08:%02d:00", minute * 5 + 20)) }
    let files = scenarioFiles(
        routes: "bus,operator,B,Bus,3\ntram,operator,T,Tram,900\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: buses.map { "bus,service,\($0.0),,,," }.joined(separator: "\n") + "\ntram,service,tram-run,,,,\n",
        stopTimes: buses.map { "\($0.0),\($0.1),\($0.1),origin,1\n\($0.0),\($0.2),\($0.2),destination,2" }.joined(separator: "\n")
            + "\ntram-run,08:30:00,08:30:00,origin,1\ntram-run,08:50:00,08:50:00,destination,2\n"
    )
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8), preferences: .init(preferredMode: mask)
    ))
    let page = try await session.initial()
    #expect(page.journeys.count == 5)
    #expect(page.journeys.contains { firstTransitTripID($0) == "tram-run" })
    #expect(page.recommendedJourneyID == page.journeys.first { firstTransitTripID($0) == "tram-run" }?.id)
}

@Test func sameDeparturePagingUsesStableJourneyCursor() async throws {
    let files = scenarioFiles(
        routes: "bus,operator,B,Bus,3\ntram,operator,T,Tram,900\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: "bus,service,bus-run,,,,\ntram,service,tram-run,,,,\n",
        stopTimes: "bus-run,08:00:00,08:00:00,origin,1\nbus-run,08:20:00,08:20:00,destination,2\n"
            + "tram-run,08:00:00,08:00:00,origin,1\ntram-run,08:20:00,08:20:00,destination,2\n"
    )
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8),
        preferences: .init(preferredMode: .init(rawValue: 1 << 0))
    ))
    let first = try await session.boundedPage(count: 1)
    let firstJourney = try #require(first.journeys.first)
    let next = try await session.boundedPage(after: firstJourney.effectiveDeparture,
                                             afterID: firstJourney.id, count: 1)
    #expect(next.journeys.count == 1)
    #expect(next.journeys.first?.effectiveDeparture == firstJourney.effectiveDeparture)
    #expect(next.journeys.first?.id != firstJourney.id)
}

@Test func olderEncodedPreferencesReceiveNewSoftPreferenceDefaults() throws {
    let legacy = """
    {"maxTransfers":1,"minimumTransferSeconds":120,"allowedModes":8,
     "wheelchair":"noPreference","bike":"noPreference","routePreference":"fastest",
     "frequencyPolicy":"conservative"}
    """.data(using: .utf8)!
    let preferences = try JSONDecoder().decode(RoutingPreferences.self, from: legacy)
    #expect(preferences.maxTransfers == 1)
    #expect(preferences.preferredMode == nil)
    #expect(!preferences.preferWheelchairAccessible)
    #expect(preferences.allowedModes.contains(routeType: 3))
}

@Test func requiredWheelchairEvidenceRejectsUnknownOrInaccessibleVehicles() async throws {
    var files = scenarioFiles(
        routes: "bus,operator,B,Bus,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600000), ("destination", "Destination", 49.610000)]),
        trips: "bus,service,accessible,,,,,1\nbus,service,inaccessible,,,,,2\nbus,service,unknown,,,,,0\n",
        stopTimes: "accessible,08:10:00,08:10:00,origin,1\naccessible,08:30:00,08:30:00,destination,2\n"
            + "inaccessible,08:00:00,08:00:00,origin,1\ninaccessible,08:20:00,08:20:00,destination,2\n"
            + "unknown,08:05:00,08:05:00,origin,1\nunknown,08:25:00,08:25:00,destination,2\n"
    )
    files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\norigin,Origin,49.600000,6.100000,1\ndestination,Destination,49.610000,6.100000,1\n"
    files["trips.txt"] = "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,wheelchair_accessible\n"
        + (files["trips.txt"] ?? "")
    // Replace the duplicated basic header from scenarioFiles.
    files["trips.txt"] = files["trips.txt"]?.replacingOccurrences(
        of: "\nroute_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id\n", with: "\n")
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8), preferences: .init(wheelchair: .required)
    ))
    let page = try await session.initial()
    #expect(page.journeys.map(firstTransitTripID) == ["accessible"])
    #expect(page.journeys.first?.accessibility == .verified)
    let softSession = try await fixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8),
        preferences: .init(preferWheelchairAccessible: true)
    ))
    let softPage = try await softSession.initial()
    #expect(softPage.recommendedJourneyID == softPage.journeys.first {
        firstTransitTripID($0) == "accessible"
    }?.id)
}

@Test func fasterDirectWalkRemainsAComparisonBesideFiveTransitTrips() async throws {
    let trips = (0..<6).map { "run-\($0)" }
    let departures = (0..<6).map { String(format: "08:%02d:00", 5 + $0 * 5) }
    let arrivals = (0..<6).map { String(format: "08:%02d:00", 25 + $0 * 5) }
    let files = scenarioFiles(
        routes: "bus,operator,B,Bus,3\n",
        stops: scenarioStops([("origin-stop", "Origin stop", 49.600100), ("destination-stop", "Destination stop", 49.610100)]),
        trips: trips.map { "bus,service,\($0),,,," }.joined(separator: "\n") + "\n",
        stopTimes: trips.indices.map { index in
            "\(trips[index]),\(departures[index]),\(departures[index]),origin-stop,1\n"
                + "\(trips[index]),\(arrivals[index]),\(arrivals[index]),destination-stop,2"
        }.joined(separator: "\n") + "\n"
    )
    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let destination = Coordinate(latitude: 49.610000, longitude: 6.100000)
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: [
        .init(from: origin, to: Coordinate(latitude: 49.600100, longitude: 6.100000), seconds: 60),
        .init(from: Coordinate(latitude: 49.610100, longitude: 6.100000), to: destination, seconds: 60),
        .init(from: origin, to: destination, seconds: 600),
    ]))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .coordinate(origin, label: "Home"),
        destination: .coordinate(destination, label: "Work"),
        departureTime: date(hour: 8)
    ))
    let page = try await session.initial()
    #expect(page.journeys.filter { !$0.legs.allSatisfy { if case .walk = $0 { return true }; return false } }.count == 5)
    #expect(page.journeys.contains { $0.legs.allSatisfy { if case .walk = $0 { return true }; return false } })
}

@Test func usefulStopBeyondTwentyFourRedundantPlatformsIsMeasured() async throws {
    let placeholders = (1...25).map { index in
        ("placeholder-\(index)", "Placeholder \(index)", 49.600000 + Double(index) / 1_000_000)
    }
    let stops = placeholders + [("useful", "Useful", 49.600100), ("dummy", "Dummy", 49.605000), ("destination", "Destination", 49.610000)]
    let files = scenarioFiles(
        routes: "short,operator,S,Short,3\nuseful-route,operator,U,Useful,3\n",
        stops: scenarioStops(stops),
        trips: placeholders.map { "short,service,trip-\($0.0),,,," }.joined(separator: "\n")
            + "\nuseful-route,service,useful-run,,,,\n",
        stopTimes: placeholders.map {
            "trip-\($0.0),08:10:00,08:10:00,\($0.0),1\ntrip-\($0.0),08:15:00,08:15:00,dummy,2"
        }.joined(separator: "\n")
            + "\nuseful-run,08:05:00,08:05:00,useful,1\nuseful-run,08:25:00,08:25:00,destination,2\n"
    )
    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let useful = Coordinate(latitude: 49.600100, longitude: 6.100000)
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: [
        .init(from: origin, to: useful, seconds: 60),
    ]))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let session = try await fixture.router.makeSession(for: .init(
        origin: .coordinate(origin, label: "Home"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8)
    ))
    let page = try await session.initial()
    let journey = try #require(page.journeys.first)
    #expect(firstTransitTripID(journey) == "useful-run")
    #expect(page.metrics.endpointAccessCandidates <= 40)
    #expect(page.metrics.walkingRequests <= 80)
    #expect(page.metrics.candidatesGenerated >= page.metrics.alternativesRetained)
}

@Test func stairsOnlyStationConnectionFailsRequiredWheelchairQuery() async throws {
    var files = scenarioFiles(
        routes: "in,operator,I,Inbound,3\nout,operator,O,Outbound,3\n",
        stops: "origin,Origin,49.600000,6.100000\nplatform-a,Platform A,49.605000,6.100000\nplatform-b,Platform B,49.605100,6.100000\ndestination,Destination,49.610000,6.100000\n",
        trips: "in,service,incoming,,,,,1\nout,service,outgoing,,,,,1\n",
        stopTimes: "incoming,08:00:00,08:00:00,origin,1\nincoming,08:10:00,08:10:00,platform-a,2\n"
            + "outgoing,08:15:00,08:15:00,platform-b,1\noutgoing,08:25:00,08:25:00,destination,2\n"
    )
    files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station,wheelchair_boarding\n"
        + "origin,Origin,49.600000,6.100000,0,,1\n"
        + "station,Station,49.605000,6.100000,1,,1\n"
        + "platform-a,Platform A,49.605000,6.100000,0,station,1\n"
        + "platform-b,Platform B,49.605100,6.100000,0,station,1\n"
        + "destination,Destination,49.610000,6.100000,0,,1\n"
    files["trips.txt"] = "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,wheelchair_accessible\n"
        + "in,service,incoming,,,,,1\nout,service,outgoing,,,,,1\n"
    files["pathways.txt"] = "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length,traversal_time,stair_count,max_slope,min_width,signposted_as,reversed_signposted_as\n"
        + "stairs,platform-a,platform-b,2,1,100,120,12,0,1.2,,\n"
    let fixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    func page(wheelchair: WheelchairPreference) async throws -> JourneyPage {
        let session = try await fixture.router.makeSession(for: .init(
            origin: .stop(id: "origin"), destination: .stop(id: "destination"),
            departureTime: date(hour: 8), preferences: .init(wheelchair: wheelchair)
        ))
        return try await session.initial()
    }
    let unrestricted = try await page(wheelchair: .noPreference)
    #expect(unrestricted.journeys.first?.accessibility == .inaccessible)
    #expect(try await page(wheelchair: .required).journeys.isEmpty)

    files["pathways.txt"] = files["pathways.txt"]?.replacingOccurrences(
        of: "stairs,platform-a,platform-b,2,1,100,120,12,0,1.2,,",
        with: "lift,platform-a,platform-b,5,1,100,120,0,0,1.2,,")
    let liftFixture = try await installedRouter(using: files, walking: FixtureWalkingProvider(routes: []))
    defer { try? FileManager.default.removeItem(at: liftFixture.folder) }
    let liftSession = try await liftFixture.router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8), preferences: .init(wheelchair: .required)
    ))
    #expect(try await liftSession.initial().journeys.first?.accessibility == .verified)
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

@Test func cancelledRealtimeTripIsNotOfferedAsAJourney() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeArchive(to: archiveURL, files: profileFixtureFiles())
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)

    let live = FixtureRealtime(patches: [.init(
        tripID: "run-1",
        serviceDate: try GTFSDate(parsing: "20260904"),
        status: .cancelled,
        events: []
    )])
    let router = try await TransitRouter(databaseURL: databaseURL, realtimeProvider: live)
    let session = try await router.makeSession(for: .init(
        origin: .stop(id: "origin"), destination: .stop(id: "destination"),
        departureTime: date(hour: 8), realtimePolicy: .bestEffort()
    ))
    let page = try await session.initial()
    #expect(!page.journeys.isEmpty)
    #expect(page.journeys.allSatisfy { !transitTripInstanceSequence($0).contains("run-1") })
}

@Test func realtimeDelayCanCreateAnOtherwiseImpossibleTransfer() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeArchive(to: archiveURL, files: liveTransferFixtureFiles())
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)

    let serviceDate = try GTFSDate(parsing: "20260904")
    let live = FixtureRealtime(patches: [.init(
        tripID: "outgoing",
        serviceDate: serviceDate,
        events: [
            .init(
                stopID: "transfer",
                scheduledDeparture: date(hour: 8, minute: 5),
                effectiveDeparture: date(hour: 8, minute: 15),
                departureSource: .reported
            ),
            .init(
                stopID: "destination",
                scheduledArrival: date(hour: 8, minute: 20),
                effectiveArrival: date(hour: 8, minute: 30),
                arrivalSource: .estimated
            ),
        ]
    )])
    let router = try await TransitRouter(databaseURL: databaseURL, realtimeProvider: live)
    let session = try await router.makeSession(for: .init(
        origin: .stop(id: "origin"),
        destination: .stop(id: "destination"),
        departureTime: date(hour: 7, minute: 55),
        preferences: .init(maxTransfers: 1, minimumTransferSeconds: 120),
        realtimePolicy: .bestEffort()
    ))

    let journey = try #require(try await session.initial().journeys.first)
    #expect(transitTripInstanceSequence(journey) == ["incoming", "outgoing"])
    let transit = journey.legs.compactMap { if case let .transit(value) = $0 { value } else { nil } }
    #expect(transit[0].effectiveArrival == date(hour: 8, minute: 10))
    #expect(transit[1].effectiveDeparture == date(hour: 8, minute: 15))
    #expect(transit[1].board.timingSource == .reported)
    #expect(transit[1].alight.timingSource == .estimated)
}

@Test func realtimeDelayMakesABusCatchableAfterWalkingToTheStop() async throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    let files = scenarioFiles(
        routes: "route,operator,10,Bus,3\n",
        stops: scenarioStops([("origin", "Origin", 49.600100), ("destination", "Destination", 49.610000)]),
        trips: "route,service,bus-run,Destination,,,\n",
        stopTimes: "bus-run,08:05:00,08:05:00,origin,1\nbus-run,08:20:00,08:20:00,destination,2\n"
    )
    try writeArchive(to: archiveURL, files: files)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)

    let home = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let walking = FixtureWalkingProvider(routes: [
        .init(from: home, to: Coordinate(latitude: 49.600100, longitude: 6.100000), seconds: 600),
    ])
    let live = FixtureRealtime(patches: [.init(
        tripID: "bus-run",
        serviceDate: try GTFSDate(parsing: "20260904"),
        events: [
            .init(
                stopID: "origin",
                scheduledDeparture: date(hour: 8, minute: 5),
                effectiveDeparture: date(hour: 8, minute: 15),
                departureSource: .reported
            ),
            .init(
                stopID: "destination",
                scheduledArrival: date(hour: 8, minute: 20),
                effectiveArrival: date(hour: 8, minute: 30),
                arrivalSource: .estimated
            ),
        ]
    )])
    let router = try await TransitRouter(
        databaseURL: databaseURL,
        walkingProvider: walking,
        realtimeProvider: live
    )
    let session = try await router.makeSession(for: .init(
        origin: .coordinate(home, label: "Home"),
        destination: .stop(id: "destination"),
        departureTime: date(hour: 8),
        realtimePolicy: .bestEffort()
    ))

    let journey = try #require(try await session.initial().journeys.first)
    #expect(transitTripInstanceSequence(journey) == ["bus-run"])
    #expect(journey.effectiveDeparture == date(hour: 8, minute: 5))
    #expect(journey.legs.first?.walkingDestinationStopID == "origin")
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct FixtureRealtime: RealtimeRoutingProvider {
    let patches: [RealtimeTripPatch]
    func patches(
        for stopIDs: [String],
        from: Date,
        through: Date,
        refreshPolicy: RealtimeRefreshPolicy
    ) async throws -> RealtimePatchBatch {
        RealtimePatchBatch(
            patches: patches,
            requestedStopIDs: Set(stopIDs),
            coveredStopIDs: Set(stopIDs)
        )
    }
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
        if isNear(request.source, hamiliusStop) && isNear(request.destination, hamilius) {
            return .init(durationSeconds: 60, distanceMeters: 85, polyline: [request.source, request.destination])
        }
        throw WalkingProviderError.noRoute
    }

    private func isNear(_ lhs: Coordinate, _ rhs: Coordinate) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.00002 && abs(lhs.longitude - rhs.longitude) < 0.00002
    }
}

/// A deterministic walking cost for stressing full-feed search on macOS.
/// Real OSM walking is benchmarked in the hosted app.
private struct BenchmarkWalkingProvider: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(durationSeconds: route.durationSeconds, distanceMeters: route.distanceMeters)
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        let north = (request.source.latitude - request.destination.latitude) * 111_000
        let east = (request.source.longitude - request.destination.longitude) * 72_000
        let meters = hypot(north, east) * 1.25
        guard meters <= 3_500 else { throw WalkingProviderError.noRoute }
        return .init(durationSeconds: max(1, Int((meters / 1.25).rounded())),
                     distanceMeters: meters,
                     polyline: [request.source, request.destination])
    }
}

private enum WalkingProviderError: Error {
    case noRoute
}

private struct FixtureWalk: Hashable {
    let from: Coordinate
    let to: Coordinate
    let seconds: Int
    let evidence: WalkingEvidence
    init(from: Coordinate, to: Coordinate, seconds: Int,
         evidence: WalkingEvidence = .routedPedestrian) {
        self.from = from; self.to = to; self.seconds = seconds; self.evidence = evidence
    }
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
        return .init(durationSeconds: match.seconds, distanceMeters: Double(match.seconds),
                     polyline: [match.from, match.to], evidence: match.evidence)
    }
}

private actor CountingWalkingProvider: WalkingRoutingProvider {
    private(set) var requestCount = 0

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        requestCount += 1
        return .init(durationSeconds: 60, distanceMeters: 75)
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        requestCount += 1
        return .init(
            durationSeconds: 60,
            distanceMeters: 75,
            polyline: [request.source, request.destination]
        )
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

private func liveTransferFixtureFiles() -> [String: String] {
    scenarioFiles(
        routes: "in,operator,IN,Incoming,3\nout,operator,OUT,Outgoing,3\n",
        stops: scenarioStops([
            ("origin", "Origin", 49.600000),
            ("transfer", "Transfer", 49.601000),
            ("destination", "Destination", 49.610000),
        ]),
        trips: "in,service,incoming,Transfer,,,\nout,service,outgoing,Destination,,,\n",
        stopTimes: "incoming,08:00:00,08:00:00,origin,1\n"
            + "incoming,08:10:00,08:10:00,transfer,2\n"
            + "outgoing,08:05:00,08:05:00,transfer,1\n"
            + "outgoing,08:20:00,08:20:00,destination,2\n"
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
