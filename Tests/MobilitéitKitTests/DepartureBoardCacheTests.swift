import Foundation
import Testing
@testable import MobiliteitKit

private actor FetchCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Test func departureBoardCacheReusesCompletedBoardsAndExpiresAfterLifetime() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let clock = BoardCacheClock()
    let cache = DepartureBoardCache(lifetime: 0.2, now: { clock.read() })
    let count = FetchCount()
    let fetch: @Sendable () async throws -> HafasDepartureBoard = {
        await count.increment()
        try await Task.sleep(for: .milliseconds(10))
        return board
    }

    _ = try await cache.value(for: "stop-a", fetch: fetch)
    #expect(await count.value == 1)

    _ = try await cache.value(for: "stop-a", fetch: fetch)
    #expect(await count.value == 1)

    _ = try await cache.value(for: "stop-b", fetch: fetch)
    #expect(await count.value == 2)

    clock.advance(0.25)
    _ = try await cache.value(for: "stop-a", fetch: fetch)
    #expect(await count.value == 3)
}

@Test func departureBoardsAreSharedAcrossAPIClients() async throws {
    BoardProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoardProtocol.self]
    let session = URLSession(configuration: configuration)
    let baseURL = URL(string: "https://board-cache-\(UUID().uuidString).invalid")!
    let firstClient = MobiliteitAPIClient(apiKey: "test", baseURL: baseURL, session: session)
    let secondClient = MobiliteitAPIClient(apiKey: "test", baseURL: baseURL, session: session)
    let request = HafasDepartureBoardRequest(stationID: "stop-a")

    _ = try await firstClient.departureBoard(request)
    _ = try await secondClient.departureBoard(request)
    #expect(BoardProtocol.count == 1)

    _ = try await secondClient.departureBoard(.init(stationID: "stop-b"))
    #expect(BoardProtocol.count == 2)
}

@Test func canceledBoardFetchDoesNotEnterCache() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let cache = DepartureBoardCache()
    let count = FetchCount()
    let pending = Task {
        try await cache.value(for: "cancelled") {
            await count.increment()
            try await Task.sleep(for: .seconds(5))
            return board
        }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await count.value == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await count.value == 1)
    let canceledAt = ContinuousClock.now
    pending.cancel()
    do {
        _ = try await pending.value
        Issue.record("A canceled fetch unexpectedly completed")
    } catch is CancellationError {
        #expect(canceledAt.duration(to: .now) < .seconds(1))
    }

    _ = try await cache.value(for: "cancelled") {
        await count.increment()
        return board
    }
    #expect(await count.value == 2)
}

private final class BoardProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests = 0

    static var count: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasPrefix("board-cache-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"Departure":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func boardCacheCoalescesAndOneWaiterCanCancelWithoutCancelingAnother() async throws {
    let board = try JSONDecoder().decode(HafasDepartureBoard.self, from: Data(#"{"Departure":[]}"#.utf8))
    let cache = DepartureBoardCache()
    let count = FetchCount()
    let fetch: @Sendable () async throws -> HafasDepartureBoard = {
        await count.increment()
        try await Task.sleep(for: .milliseconds(150))
        return board
    }
    let first = Task { try await cache.value(for: "shared", fetch: fetch) }
    while await count.value == 0 { await Task.yield() }
    let second = Task { try await cache.value(for: "shared", fetch: fetch) }
    try await Task.sleep(for: .milliseconds(20))
    first.cancel()
    do { _ = try await first.value; Issue.record("Cancelled waiter completed") }
    catch is CancellationError {}
    #expect(try await second.value.departures.values.isEmpty)
    #expect(await count.value == 1)
}

@Test func forceRefreshCannotBeOverwrittenByAnOlderInflightResponse() async throws {
    let old = HafasDepartureBoard(departures: [], responseBytes: 1)
    let fresh = HafasDepartureBoard(departures: [], responseBytes: 2)
    let cache = DepartureBoardCache()
    let count = FetchCount()
    let first = Task {
        try await cache.value(for: "generation") {
            await count.increment()
            try await Task.sleep(for: .milliseconds(100))
            return old
        }
    }
    while await count.value == 0 { await Task.yield() }
    let latest = try await cache.value(for: "generation", refreshPolicy: .forceRefresh) { fresh }
    _ = try await first.value
    let reused = try await cache.value(for: "generation") { Issue.record("Missed fresh cache"); return old }
    #expect(latest.responseBytes == 2 && reused.responseBytes == 2)
}

@Test func cacheHitsPreserveAcquisitionTimeInsteadOfRenewingFreshness() async throws {
    let board = try JSONDecoder().decode(HafasDepartureBoard.self, from: Data(#"{"Departure":[]}"#.utf8))
    let cache = DepartureBoardCache()
    let first = try await cache.response(for: "freshness") { board }
    let second = try await cache.response(for: "freshness") { board }
    #expect(first.networkRequests == 1)
    #expect(second.cacheHits == 1)
    #expect(first.fetchedAt == second.fetchedAt)
}

private final class BoardCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)
    func read() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}
