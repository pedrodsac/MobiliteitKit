import Foundation
import os

/// Opt-in instrumentation; production requests have no delegate or payload copy by default.
public struct HTTPDiagnosticsObserver: Sendable {
    public let willSend: @Sendable (URL) throws -> Void
    public let didReceive: @Sendable (HTTPResponseDiagnostics) -> Void
    public init(willSend: @escaping @Sendable (URL) throws -> Void = { _ in },
                didReceive: @escaping @Sendable (HTTPResponseDiagnostics) -> Void) {
        self.willSend = willSend; self.didReceive = didReceive
    }
}
public struct HTTPResponseDiagnostics: Sendable {
    /// Access IDs, keys and request IDs are removed from this URL.
    public let request: URL
    public let statusCode: Int
    public let receivedAt: Date
    public let transport: HTTPTransportMetrics?
    /// Error payloads are deliberately omitted: HAFAS can echo access credentials.
    public let successfulBody: Data?
}
public struct HTTPTransportMetrics: Codable, Hashable, Sendable {
    public struct Transaction: Codable, Hashable, Sendable {
        public let protocolName: String?
        public let reusedConnection: Bool
        public let queueMilliseconds: Double?
        public let connectionMilliseconds: Double?
        public let responseWaitMilliseconds: Double?
        public let transferMilliseconds: Double?
        public let encodedResponseBytes: Int64
    }
    public let totalMilliseconds: Double
    public let transactions: [Transaction]
}
final class HTTPTaskMetricsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let metrics = OSAllocatedUnfairLock<HTTPTransportMetrics?>(initialState: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting value: URLSessionTaskMetrics) {
        func elapsed(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1_000)
        }
        let result = HTTPTransportMetrics(totalMilliseconds: value.taskInterval.duration * 1_000,
            transactions: value.transactionMetrics.map { item in
                .init(protocolName: item.networkProtocolName, reusedConnection: item.isReusedConnection,
                    queueMilliseconds: elapsed(value.taskInterval.start, item.fetchStartDate),
                    connectionMilliseconds: elapsed(item.connectStartDate, item.connectEndDate),
                    responseWaitMilliseconds: elapsed(item.requestEndDate, item.responseStartDate),
                    transferMilliseconds: elapsed(item.responseStartDate, item.responseEndDate),
                    encodedResponseBytes: item.countOfResponseBodyBytesReceived)
            })
        metrics.withLock { $0 = result }
    }
    func result() -> HTTPTransportMetrics? { metrics.withLock { $0 } }
    static func sanitized(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let privateNames: Set<String> = ["accessid", "apikey", "key", "token", "requestid"]
        parts.user = nil; parts.password = nil
        parts.queryItems = parts.queryItems?.filter { !privateNames.contains($0.name.lowercased()) }
        return parts.url ?? url
    }
}
