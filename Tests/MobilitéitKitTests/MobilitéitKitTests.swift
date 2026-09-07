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
