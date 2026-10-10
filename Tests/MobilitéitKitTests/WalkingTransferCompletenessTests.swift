import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Suite struct WalkingTransferCompletenessTests {
    @Test func laterInterchangeSurvivesMoreThanNinetySixEarlierPairs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("fixture.zip")
        let database = folder.appendingPathComponent("fixture.sqlite")
        try writeFixture(to: archive)
        _ = try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database)
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-10T23:30:00+02:00"))
        let router = try await TransitRouter(databaseURL: database, walkingProvider: InterchangeWalking())
        let session = try await router.makeSession(for: .init(origin: .stop(id: "origin"),
            destination: .stop(id: "destination"), departureTime: anchor,
            preferences: .init(maxTransfers: 1), realtimePolicy: .disabled))
        let page = try await session.initial(count: 1, searchHorizon: 7200)
        let journey = try #require(page.journeys.first)
        let trips = journey.legs.compactMap { if case let .transit(ride) = $0 { ride.tripID } else { nil } }
        #expect(trips == ["in-110", "out-110"])
        let walk = try #require(journey.legs.compactMap { if case let .walk(w) = $0 { w } else { nil } }.first)
        #expect(walk.segments.map(\.mode) == [.walking, .funicular, .walking])
        #expect(journey.walkingDuration == 177)
        #expect(journey.walkingDistance == 125)
        let refreshed = try #require(journey.applyingRealtime([:]))
        #expect(refreshed.legs == journey.legs)
        #expect(refreshed.walkingDuration == 177)
        #expect(refreshed.inVehicleDuration == journey.inVehicleDuration)
        #expect(journey.scheduledArrival == ISO8601DateFormatter().date(from: "2026-10-11T01:25:00+02:00"))
    }

    private func writeFixture(to url: URL) throws {
        var stops = "stop_id,stop_name,stop_lat,stop_lon\norigin,Origin,49.5,5.5\ndestination,Destination,49.8,7.8\n"
        var trips = "route_id,service_id,trip_id\n"
        var times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        // The first 110 interchanges are topologically useful but their
        // departures lie outside this search window. The last one is the
        // only catchable midnight connection. Every pedestrian pair must be
        // considered, independent of the order of earlier arrival labels.
        for index in 0...110 {
            let longitude = 6.0 + Double(index) * 0.02
            stops += "a-\(index),Alight \(index),49.6,\(longitude)\n"
            stops += "b-\(index),Board \(index),49.601,\(longitude)\n"
            trips += "in,saturday,in-\(index)\nout,sunday,out-\(index)\n"
            let inboundArrival = index == 110 ? "23:50:00" : "23:40:00"
            let outboundDeparture = index == 110 ? "01:14:00" : "12:00:00"
            let outboundArrival = index == 110 ? "01:25:00" : "12:30:00"
            times += "in-\(index),23:35:00,23:35:00,origin,1\nin-\(index),\(inboundArrival),\(inboundArrival),a-\(index),2\n"
            times += "out-\(index),\(outboundDeparture),\(outboundDeparture),b-\(index),1\nout-\(index),\(outboundArrival),\(outboundArrival),destination,2\n"
        }
        let files = [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
            "calendar_dates.txt": "service_id,date,exception_type\nsaturday,20261010,1\nsunday,20261011,1\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nin,operator,IN,3\nout,operator,OUT,2\n",
            "stops.txt": stops, "trips.txt": trips, "stop_times.txt": times
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, content) in files {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }
}

private struct InterchangeWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(durationSeconds: route.durationSeconds, distanceMeters: route.distanceMeters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        guard request.source.latitude == 49.6, request.destination.latitude == 49.601,
              request.source.longitude == request.destination.longitude else { throw NoRoute.unavailable }
        let middle = Coordinate(latitude: 49.6005, longitude: request.source.longitude)
        let end = Coordinate(latitude: 49.6008, longitude: request.source.longitude)
        return .init(durationSeconds: 300, distanceMeters: 350,
            polyline: [request.source, middle, end, request.destination], segments: [
                .init(mode: .walking, durationSeconds: 120, distanceMeters: 100, polyline: [request.source, middle]),
                .init(mode: .funicular, name: "Funicular", durationSeconds: 123, distanceMeters: 225, polyline: [middle, end]),
                .init(mode: .walking, durationSeconds: 57, distanceMeters: 25, polyline: [end, request.destination])
            ])
    }
    private enum NoRoute: Error { case unavailable }
}
