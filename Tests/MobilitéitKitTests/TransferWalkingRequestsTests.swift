import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Suite struct TransferWalkingRequestsTests {
    @Test func listsEveryTransferRequestRaptorIssues() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("fixture.zip")
        let database = folder.appendingPathComponent("fixture.sqlite")
        try Self.writeFixture(to: archive)
        _ = try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database)

        let recorder = RecordingWalking()
        let router = try await TransitRouter(databaseURL: database, walkingProvider: recorder)
        let listed = router.transferWalkingRequests()
        #expect(!listed.isEmpty)
        let snapshot = await router.snapshot
        #expect(listed.count == snapshot.nearbyTransferStopsByStop.joined().count)
        #expect(listed.allSatisfy { $0.departure == nil })
        #expect(Set(listed).count == listed.count)

        let origin = Coordinate(latitude: 49.5990, longitude: 6.0000)
        let destination = Coordinate(latitude: 49.6020, longitude: 6.0250)
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-10T10:00:00+02:00"))
        for transfers in 1...3 {
            for direction in [RouteQueryDirection.departAfter, .arriveBy] {
                let query = RouteQuery(origin: .coordinate(origin, label: nil),
                    destination: .coordinate(destination, label: nil),
                    departureTime: direction == .arriveBy ? anchor.addingTimeInterval(7_200) : anchor,
                    direction: direction, preferences: .init(maxTransfers: transfers), realtimePolicy: .disabled)
                let session = try await router.makeSession(for: query)
                _ = try await session.initial(count: 5, searchHorizon: 7_200)
            }
        }
        let issued = await recorder.requests.filter { $0.source != origin && $0.destination != destination }
        // The list omits departures, which the walking cache ignores as well.
        struct Pair: Hashable { let source: Coordinate; let destination: Coordinate }
        let known = Set(listed.map { Pair(source: $0.source, destination: $0.destination) })
        let transfers = issued.filter { known.contains(Pair(source: $0.source, destination: $0.destination)) }
        #expect(!transfers.isEmpty)
        // Endpoint candidates are stop/coordinate pairs; every stop-to-stop
        // request RAPTOR makes between two stops must be in the list.
        let stopCoordinates = Set(snapshot.stops.map { $0.model.coordinate })
        for request in issued where stopCoordinates.contains(request.source) && stopCoordinates.contains(request.destination) {
            #expect(known.contains(Pair(source: request.source, destination: request.destination)))
        }
    }

    @Test func orderIsDeterministicAcrossRouters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("fixture.zip")
        let database = folder.appendingPathComponent("fixture.sqlite")
        try Self.writeFixture(to: archive)
        _ = try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database)
        let first = try await TransitRouter(databaseURL: database, walkingProvider: RecordingWalking())
        let second = try await TransitRouter(databaseURL: database, walkingProvider: RecordingWalking())
        #expect(first.transferWalkingRequests() == second.transferWalkingRequests())
    }

    /// Two bus lines that cross near three interchange pairs, so transfers need walks.
    private static func writeFixture(to url: URL) throws {
        var stops = "stop_id,stop_name,stop_lat,stop_lon\n"
        var trips = "route_id,service_id,trip_id\n"
        var times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        for index in 0..<6 {
            let longitude = 6.0 + Double(index) * 0.005
            stops += "a-\(index),A \(index),49.6000,\(longitude)\n"
            stops += "b-\(index),B \(index),49.6010,\(longitude)\n"
        }
        for hour in 8..<14 {
            let t = String(format: "%02d", hour)
            trips += "in,daily,in-\(hour)\nout,daily,out-\(hour)\n"
            for index in 0..<6 {
                times += "in-\(hour),\(t):\(String(format: "%02d", index * 4)):00,\(t):\(String(format: "%02d", index * 4)):00,a-\(index),\(index + 1)\n"
                times += "out-\(hour),\(t):\(String(format: "%02d", 30 + index * 4)):00,\(t):\(String(format: "%02d", 30 + index * 4)):00,b-\(index),\(index + 1)\n"
            }
        }
        let files = [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
            "calendar_dates.txt": "service_id,date,exception_type\ndaily,20261010,1\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nin,operator,IN,3\nout,operator,OUT,3\n",
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

private actor RecordingWalking: WalkingRoutingProvider {
    private(set) var requests: [WalkingRequest] = []
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let route = try await route(request)
        return .init(durationSeconds: route.durationSeconds, distanceMeters: route.distanceMeters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        requests.append(request)
        let meters = distance(request.source, request.destination) * 1.2
        return .init(durationSeconds: max(1, Int(meters / 1.3)), distanceMeters: meters,
                     polyline: [request.source, request.destination], evidence: .routedPedestrian)
    }
}
