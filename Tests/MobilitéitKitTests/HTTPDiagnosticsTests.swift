import Foundation
import Testing
import os
@testable import MobiliteitKit

/// The relay's `Server-Timing` header travels with the request's transport metrics, so a
/// benchmark can split the client's server wait into upstream and relay time.
@Suite struct HTTPDiagnosticsTests {
    @Test(arguments: [#"upstream;dur=812.4;desc="headers", edge;desc="LUX""#, nil])
    func theServerTimingHeaderIsRecordedWithTheTransportMetrics(header: String?) async throws {
        let host = ServerTimingProtocol.register(header: header)
        defer { ServerTimingProtocol.remove(host) }
        let received = OSAllocatedUnfairLock<[HTTPResponseDiagnostics]>(initialState: [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerTimingProtocol.self]
        let client = MobiliteitAPIClient(apiKey: "fixture", baseURL: URL(string: "https://\(host)")!,
            session: URLSession(configuration: configuration),
            diagnostics: .init(didReceive: { response in received.withLock { $0.append(response) } }))
        let response = try await client.departureBoardResponse(.init(stationID: "200405035"), refreshPolicy: .forceRefresh)
        let measurement = try #require(response.transport.first)
        #expect(measurement.metrics.serverTiming == header)
        let observed = try #require(received.withLock { $0 }.first)
        #expect(observed.transport?.serverTiming == header)
    }

    @Test func metricsRecordedBeforeTheHeaderExistedStillDecode() throws {
        let json = #"{"totalMilliseconds":12.5,"transactions":[]}"#
        let metrics = try JSONDecoder().decode(HTTPTransportMetrics.self, from: Data(json.utf8))
        #expect(metrics.serverTiming == nil && metrics.totalMilliseconds == 12.5)
    }
}

/// Answers every request for a registered host with an empty board and the given header.
private final class ServerTimingProtocol: URLProtocol {
    private static let headers = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    static func register(header: String?) -> String {
        let host = "server-timing-\(UUID().uuidString.lowercased()).invalid"
        headers.withLock { $0[host] = .some(header) }
        return host
    }
    static func remove(_ host: String) { _ = headers.withLock { $0.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map { host in headers.withLock { $0[host] != nil } } == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let header = request.url?.host().flatMap { host in Self.headers.withLock { $0[host] ?? nil } }
        var fields = ["Content-Type": "application/json"]
        if let header { fields["Server-Timing"] = header }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"Departure":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
