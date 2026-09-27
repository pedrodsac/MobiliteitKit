import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Test func realtimeBoardDeadlineKeepsCompletedResponses() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let started = ContinuousClock.now

    let boards = await HafasRealtimeRoutingProvider.fetchBoardsWithLimitedConcurrency(
        stopIDs: ["fast", "slow"],
        maximumConcurrentRequests: 2,
        timeout: .milliseconds(50)
    ) { stopID in
        if stopID == "slow" {
            try? await Task.sleep(for: .seconds(5))
        }
        return board
    }

    #expect(boards.keys.sorted() == ["fast"])
    #expect(started.duration(to: .now) < .seconds(1))
}

@Test func realtimeBoardFetchFinishesWithoutWaitingForDeadline() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let started = ContinuousClock.now

    let boards = await HafasRealtimeRoutingProvider.fetchBoardsWithLimitedConcurrency(
        stopIDs: ["a", "b", "c"],
        maximumConcurrentRequests: 2,
        timeout: .seconds(5)
    ) { _ in board }

    #expect(boards.keys.sorted() == ["a", "b", "c"])
    #expect(started.duration(to: .now) < .seconds(1))
}

@Test func cancelledJourneyCanMatchAtASecondBoardingStop() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HafasRouting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let archiveURL = folder.appendingPathComponent("fixture.zip")
    let databaseURL = folder.appendingPathComponent("fixture.sqlite")
    let files = [
        "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
        "calendar_dates.txt": "service_id,date,exception_type\nservice,20260924,1\n",
        "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nroute-322,operator,322,Bus 322,3\n",
        "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\na,Other platform,49.650,6.230\nb,Gromscheed,49.651,6.231\nc,Destination,49.630,6.180\n",
        "trips.txt": "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id\nroute-322,service,trip-322,Destination,,,\n",
        "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\ntrip-322,09:20:00,09:20:00,b,1\ntrip-322,09:35:00,09:35:00,c,2\n",
    ]
    let archive = try Archive(url: archiveURL, accessMode: .create)
    for (path, content) in files {
        let data = Data(content.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
    _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: databaseURL)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CancelledJourneyBoardProtocol.self]
    let client = MobiliteitAPIClient(
        apiKey: "test",
        baseURL: URL(string: "https://cancelled-\(UUID().uuidString).invalid")!,
        session: URLSession(configuration: configuration)
    )
    let provider = try HafasRealtimeRoutingProvider(databaseURL: databaseURL, client: client)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
    let from = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 24, hour: 9, minute: 10
    )))
    let batch = try await provider.patches(
        for: ["a", "b"], from: from, through: from.addingTimeInterval(20 * 60),
        refreshPolicy: .forceRefresh
    )

    #expect(batch.coveredStopIDs == ["a", "b"])
    #expect(batch.patches.count == 1)
    #expect(batch.patches.first?.tripID == "trip-322")
    #expect(batch.patches.first?.status == .cancelled)

    let mismatchedClient = MobiliteitAPIClient(
        apiKey: "test",
        baseURL: URL(string: "https://mismatch-\(UUID().uuidString).invalid")!,
        session: URLSession(configuration: configuration)
    )
    let mismatchedProvider = try HafasRealtimeRoutingProvider(
        databaseURL: databaseURL, client: mismatchedClient
    )
    let mismatched = try await mismatchedProvider.patches(
        for: ["b"], from: from, through: from.addingTimeInterval(20 * 60),
        refreshPolicy: .forceRefresh
    )
    #expect(mismatched.patches.isEmpty)
}

private final class CancelledJourneyBoardProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasPrefix("cancelled-") == true
            || request.url?.host()?.hasPrefix("mismatch-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stopID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
        let direction = request.url?.host()?.hasPrefix("mismatch-") == true
            ? "Opposite direction" : "Destination"
        let body = """
        {"Departure":[{"JourneyDetailRef":{"ref":"same-journey"},"Product":{"name":"Bus 322","line":"322","cls":"32"},"direction":"\(direction)","time":"09:20:00","date":"2026-09-24","cancelled":true}]}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((stopID == "a" || stopID == "b" ? body : "{\"Departure\":[]}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
