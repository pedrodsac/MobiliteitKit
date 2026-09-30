import Foundation
import ZIPFoundation
@testable import MobiliteitKit

/// Small, deterministic timetable shared by live-routing regression tests.
struct RealtimeTestFixture {
    let directory: URL
    let database: URL
    init(stopTimes: String? = nil, trips: String? = nil,
         serviceDates: String = "service,20260930,1\n") async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRouting-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("fixture.sqlite")
        let archiveURL = directory.appendingPathComponent("fixture.zip")
        let files = [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
            "calendar_dates.txt": "service_id,date,exception_type\n" + serviceDates,
            "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nroute,operator,201,Bus 201,3\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\na,Origin,49.60,6.10\nb,Transfer,49.65,6.15\nc,Destination,49.70,6.20\n",
            "trips.txt": "route_id,service_id,trip_id,trip_headsign\n" + (trips ?? "route,service,trip,Destination\n"),
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + (stopTimes ?? "trip,08:00:00,08:00:00,a,1\ntrip,08:10:00,08:10:00,b,2\ntrip,08:20:00,08:20:00,c,3\n"),
        ]
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (path, text) in files {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) {
                position, size in data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: database)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    static func date(_ time: String, day: String = "2026-09-30") -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "\(day)T\(time)+02:00")!
    }
}

/// URLProtocol fixtures never contact the network. Each host owns its response
/// closure and request history, so parallel Swift Testing cases stay isolated.
final class RealtimeBoardProtocol: URLProtocol {
    typealias Response = @Sendable (URLRequest) -> String
    private struct State { let response: Response; var requests: [URLRequest] = [] }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var states: [String: State] = [:]

    static func client(_ response: @escaping Response) -> (MobiliteitAPIClient, String) {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { states[host] = .init(response: response) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RealtimeBoardProtocol.self]
        return (.init(apiKey: "fixture", baseURL: URL(string: "https://\(host)")!,
                      session: URLSession(configuration: config)), host)
    }
    static func requests(_ host: String) -> [URLRequest] { lock.withLock { states[host]?.requests ?? [] } }
    static func remove(_ host: String) { _ = lock.withLock { states.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map { host in lock.withLock { states[host] != nil } } == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host(), let response = Self.lock.withLock({
            Self.states[host]?.requests.append(request)
            return Self.states[host]?.response
        }) else { return }
        let data = Data(response(request).utf8)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func liveBoard(stops: String, time: String = "08:00:00", realtime: String? = "08:08:00",
               stop: String = "a", extra: String = "", day: String = "2026-09-30") -> String {
    let rt = realtime.map { ",\"rtTime\":\"\($0)\",\"rtDate\":\"\(day)\"" } ?? ""
    return """
    {"Departure":[{"JourneyDetailRef":{"ref":"same-journey"},"Product":{"line":"201","cls":"32"},"direction":"Destination","stopExtId":"\(stop)","time":"\(time)","date":"\(day)"\(rt)\(extra),"Stops":{"Stop":[\(stops)]}}]}
    """
}

func liveStop(_ id: String, planned: String, predicted: String? = nil,
              arrival: String? = nil, extra: String = "", day: String = "2026-09-30") -> String {
    let rt = predicted.map { ",\"rtDepTime\":\"\($0)\",\"rtDepDate\":\"\(day)\"" } ?? ""
    let arr = arrival.map { ",\"arrTime\":\"\(planned)\",\"arrDate\":\"\(day)\",\"rtArrTime\":\"\($0)\",\"rtArrDate\":\"\(day)\"" } ?? ""
    return "{\"extId\":\"\(id)\",\"depTime\":\"\(planned)\",\"depDate\":\"\(day)\"\(rt)\(arr)\(extra)}"
}
