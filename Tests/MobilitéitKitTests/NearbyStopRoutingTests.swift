import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Test func coordinateRoutingChoosesTheNearbyStopWithTheQuickestJourney() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("NearbyStopRoutingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeNearbyStopFixture(to: archiveURL)
    _ = try await GTFSArchiveInstaller.install(
        archiveAt: archiveURL,
        databaseAt: databaseURL
    )

    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let nearbyStop = Coordinate(latitude: 49.600100, longitude: 6.100000)
    let fasterStop = Coordinate(latitude: 49.601000, longitude: 6.100000)
    let walking = FixtureWalkingProvider(routes: [
        .init(from: origin, to: nearbyStop, seconds: 60),
        .init(from: origin, to: fasterStop, seconds: 120),
    ])
    let router = try await TransitRouter(
        databaseURL: databaseURL,
        walkingProvider: walking
    )
    let session = try await router.makeSession(for: .init(
        origin: .coordinate(origin, label: "Home"),
        destination: .stop(id: "destination"),
        departureTime: routeTestDate(hour: 8)
    ))

    let journey = try #require(try await session.initial().journeys.first)
    let firstTransit = try #require(journey.legs.compactMap { leg in
        if case let .transit(transit) = leg { return transit }
        return nil
    }.first)
    let accessWalk = try #require(journey.legs.compactMap { leg in
        if case let .walk(walk) = leg, walk.source == .provider { return walk }
        return nil
    }.first)

    #expect(firstTransit.tripID == "fast-run")
    #expect(firstTransit.board.stop.id == "fast-stop")
    #expect(accessWalk.to.stop?.id == "fast-stop")
    #expect(accessWalk.duration == 120)
}

@Test func coordinateRoutingKeepsALaterBoardingStopWhenNearbyRecordsAreUnboardable() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaterBoardingStopTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeCrowdedAccessFixture(to: archiveURL)
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)

    let origin = Coordinate(latitude: 49.600000, longitude: 6.100000)
    let earlierStop = Coordinate(latitude: 49.600024, longitude: 6.100000)
    let laterStop = Coordinate(latitude: 49.600025, longitude: 6.100000)
    let router = try await TransitRouter(
        databaseURL: databaseURL,
        walkingProvider: FixtureWalkingProvider(routes: [
            .init(from: origin, to: earlierStop, seconds: 660),
            .init(from: origin, to: laterStop, seconds: 60),
        ])
    )
    let session = try await router.makeSession(for: .init(
        origin: .coordinate(origin, label: "Home"),
        destination: .stop(id: "destination"),
        departureTime: routeTestDate(hour: 8)
    ))

    let journey = try #require(try await session.initial().journeys.first)
    let transit = try #require(journey.legs.compactMap { leg in
        if case let .transit(transit) = leg { return transit }
        return nil
    }.first)
    let accessWalk = try #require(journey.legs.compactMap { leg in
        if case let .walk(walk) = leg, walk.source == .provider { return walk }
        return nil
    }.first)

    #expect(transit.tripID == "same-run")
    #expect(transit.board.stop.id == "later-stop")
    #expect(accessWalk.to.stop?.id == "later-stop")
    #expect(accessWalk.duration == 60)
}

@Test func scheduledDepartureBoardsExcludeATripsFinalStop() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("TerminalDepartureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("transit.sqlite")
    try writeNearbyStopFixture(to: archiveURL)
    _ = try await GTFSArchiveInstaller.install(
        archiveAt: archiveURL,
        databaseAt: databaseURL
    )

    let store = try GTFSStore(databaseAt: databaseURL)
    let originDepartures = try await store.nextScheduledDepartures(
        fromStopID: "fast-stop",
        at: routeTestDate(hour: 8)
    )
    let terminalDepartures = try await store.nextScheduledDepartures(
        fromStopID: "destination",
        at: routeTestDate(hour: 8)
    )

    #expect(originDepartures.map(\.tripID) == ["fast-run"])
    #expect(originDepartures.first?.platformCode == "3")
    #expect(terminalDepartures.isEmpty)
}

private struct FixtureWalk: Sendable {
    let from: Coordinate
    let to: Coordinate
    let seconds: Int
}

private struct FixtureWalkingProvider: WalkingRoutingProvider {
    let routes: [FixtureWalk]

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(
            durationSeconds: route.durationSeconds,
            distanceMeters: route.distanceMeters
        )
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        guard let match = routes.first(where: {
            $0.from == request.source && $0.to == request.destination
        }) else {
            throw FixtureWalkingError.noRoute
        }
        return .init(
            durationSeconds: match.seconds,
            distanceMeters: Double(match.seconds),
            polyline: [match.from, match.to]
        )
    }
}

private enum FixtureWalkingError: Error {
    case noRoute
}

private func routeTestDate(hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
    return calendar.date(from: DateComponents(
        year: 2026,
        month: 9,
        day: 4,
        hour: hour
    ))!
}

private func writeNearbyStopFixture(to url: URL) throws {
    let files: [String: String] = [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
        "calendar_dates.txt": "service_id,date,exception_type\nservice,20260904,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nslow,operator,SLOW,Slow route,3\nfast,operator,FAST,Fast route,3\n",
        "stops.txt": "stop_id,stop_name,stop_lat,stop_lon,platform_code\nnear-stop,Nearest stop,49.600100,6.100000,A\nfast-stop,Faster stop,49.601000,6.100000,3\ndestination,Destination,49.610000,6.100000,\n",
        "trips.txt": "route_id,service_id,trip_id\nslow,service,slow-run\nfast,service,fast-run\n",
        "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nslow-run,08:05:00,08:05:00,near-stop,1\nslow-run,08:40:00,08:40:00,destination,2\nfast-run,08:03:00,08:03:00,fast-stop,1\nfast-run,08:20:00,08:20:00,destination,2\n",
    ]
    let archive = try Archive(url: url, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }
}

private func writeCrowdedAccessFixture(to url: URL) throws {
    var stops = "stop_id,stop_name,stop_lat,stop_lon\n"
    for index in 1...23 {
        stops += "placeholder-\(index),Placeholder \(index),49.6000\(String(format: "%02d", index)),6.100000\n"
    }
    stops += "early-stop,Earlier stop,49.600024,6.100000\n"
    stops += "later-stop,Later stop,49.600025,6.100000\n"
    stops += "destination,Destination,49.610000,6.100000\n"

    let files: [String: String] = [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
        "calendar_dates.txt": "service_id,date,exception_type\nservice,20260904,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nsame,operator,SAME,Same bus,3\n",
        "stops.txt": stops,
        "trips.txt": "route_id,service_id,trip_id\nsame,service,same-run\n",
        "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nsame-run,08:20:00,08:20:00,early-stop,1\nsame-run,08:22:00,08:22:00,later-stop,2\nsame-run,08:40:00,08:40:00,destination,3\n",
    ]
    let archive = try Archive(url: url, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }
}
