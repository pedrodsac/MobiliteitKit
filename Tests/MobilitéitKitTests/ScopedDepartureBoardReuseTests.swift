import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct ScopedDepartureBoardReuseTests {
    @Test(arguments: [false, true])
    func intervalResponseReusesFreshUnrestrictedOverlap(inFlight: Bool) async throws {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { Self.payload(for: $0) }
        defer { RealtimeBoardProtocol.remove(host) }
        let boundary = Date.now
        let prefixRequest = try request(minutes: 90, lines: [])
        let prefix = Task { try await client.departureBoardSnapshot(prefixRequest) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        if !inFlight { _ = try await prefix.value }
        let result = try await client.departureBoardResponse(try request(minutes: 150, lines: []),
            refreshPolicy: .forceRefresh, refreshStartedAt: boundary)
        let original = try await prefix.value
        #expect(result.networkRequests == 1 && result.cacheHits == 1)
        #expect(result.isComplete && result.board.departures.values.count == 2)
        #expect(result.fetchedAt == original.fetchedAt)
        let requests = RealtimeBoardProtocol.requests(host)
        #expect(requests.count == 2)
        #expect(Self.parameter("time", in: try #require(requests.last)) == "09:30:00")
        #expect(Self.parameter("duration", in: try #require(requests.last)) == "60")
    }

    @Test(arguments: [false, true], [false, true])
    func refreshReusesFreshBroaderOverlapAndAcquiresTheNarrowTail(inFlight: Bool, unknownLines: Bool) async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { request in
            var value = Self.payload(for: request)
            if unknownLines, Self.parameter("lines", in: request) == "201,202" {
                value = value.replacingOccurrences(of: "\"line\":\"201\",", with: "")
            }
            return value
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let boundary = Date.now
        let prefixRequest = try request(minutes: 90, lines: ["201", "202"])
        let prefix = Task { try await client.departureBoardSnapshot(prefixRequest) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        if !inFlight { _ = try await prefix.value }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let result = try await provider.patches(for: routingRequest(since: boundary))
        let original = try await prefix.value
        let fallbackCount = unknownLines && inFlight ? 2 : 1
        #expect(result.networkRequests == fallbackCount)
        #expect(result.cacheHits == (unknownLines && !inFlight ? 0 : 1))
        #expect(Set(result.patches.map(\.tripID)) == ["trip", "later"])
        #expect(result.incompleteStopIDs.isEmpty)
        let queries = RealtimeBoardProtocol.requests(host)
        #expect(queries.count == fallbackCount + 1)
        if !unknownLines {
            #expect(Self.parameter("time", in: try #require(queries.last)) == "09:30:00")
            #expect(Self.parameter("duration", in: try #require(queries.last)) == "60")
            #expect(Self.parameter("lines", in: try #require(queries.last)) == "201")
            let first = try #require(result.patches.first { $0.tripID == "trip" })
            #expect(first.events.first?.observedAt == original.fetchedAt)
        }
    }

    @Test func scopedRefreshRetiresOldBroaderCoverageAndKeepsItsFreshPrefix() async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { Self.payload(for: $0) }
        defer { RealtimeBoardProtocol.remove(host) }
        let old = try request(minutes: 150, lines: ["201", "202"])
        _ = try await client.departureBoardSnapshot(old)
        let boundary = Date.now
        _ = try await client.departureBoardSnapshot(try request(minutes: 90, lines: ["201"]))
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let result = try await provider.patches(for: routingRequest(since: boundary))
        #expect(result.networkRequests == 1 && result.cacheHits == 1)
        #expect(Set(result.patches.map(\.tripID)) == ["trip", "later"])
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
        #expect(await client.departureBoardLineCoverageParts(old, maximumCacheAge: 60).isEmpty)
        #expect(Self.parameter("time", in: try #require(RealtimeBoardProtocol.requests(host).last)) == "09:30:00")
    }

    @Test func strictRefreshWithoutBoundaryStillAcquiresTheWholeInterval() async throws {
        let (client, host) = RealtimeBoardProtocol.client { Self.payload(for: $0) }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(try request(minutes: 90, lines: ["201"]))
        _ = try await client.departureBoardSnapshot(try request(minutes: 150, lines: ["201"]), refreshPolicy: .forceRefresh)
        let requests = RealtimeBoardProtocol.requests(host)
        #expect(requests.count == 2)
        #expect(Self.parameter("time", in: try #require(requests.last)) == "08:00:00")
        #expect(Self.parameter("duration", in: try #require(requests.last)) == "150")
    }

    @Test func scopedRetirementPreservesANewerFlightInTheSameNamespace() async throws {
        let clock = ScopedBoardClock()
        let cache = DepartureBoardCache(now: { clock.read() })
        let oldGate = ScopedBoardGate(), freshGate = ScopedBoardGate()
        let start = RealtimeTestFixture.date("08:00:00")
        let namespace = "https://board.invalid/departureBoard?lines=201,202"
        let full = BoardCacheScope(namespace: namespace, interval: .init(start: start, duration: 9_000), maximumJourneys: -1)
        let prefix = BoardCacheScope(namespace: namespace, interval: .init(start: start, duration: 5_400), maximumJourneys: -1)
        let empty = HafasDepartureBoard(departures: [])
        let old = Task {
            try await cache.measuredResponse(for: "old", refreshPolicy: .useCache, scope: full) {
                await oldGate.wait()
                return .init(board: empty, networkRequests: 1, cacheHits: 0)
            }
        }
        while !(await oldGate.entered) { await Task.yield() }
        clock.advance(1)
        let boundary = clock.read()
        let fresh = Task {
            try await cache.measuredResponse(for: "fresh", refreshPolicy: .useCache, scope: prefix,
                minimumFetchedAt: boundary) {
                await freshGate.wait()
                return .init(board: empty, networkRequests: 1, cacheHits: 0)
            }
        }
        while !(await freshGate.entered) { await Task.yield() }
        await cache.retireCoverage(before: boundary, overlapping: full)
        let requested = BoardCacheScope(namespace: "https://board.invalid/departureBoard?lines=201",
            interval: prefix.interval, maximumJourneys: -1)
        let parts = await cache.lineCoverageParts(for: requested, maximumCacheAge: 60, minimumFetchedAt: boundary)
        #expect(parts.count == 1)
        await freshGate.release()
        #expect(try await fresh.value.fetchedAt == boundary)
        clock.advance(5)
        if let part = parts.first {
            let reused = try await cache.reuseLineCoveragePart(part, maximumCacheAge: 60, minimumFetchedAt: boundary)
            #expect(reused?.cacheHits == 1 && reused?.fetchedAt == boundary)
        }
        await oldGate.release()
        _ = try await old.value
        #expect(await cache.lineCoverageParts(for: full, maximumCacheAge: 60, minimumFetchedAt: boundary).isEmpty)
        let slices = await cache.lineCoverageIntervals(for: full, maximumCacheAge: 60, minimumFetchedAt: boundary)
        #expect(slices == [.init(start: start, duration: 5_400), .init(start: start.addingTimeInterval(5_400), duration: 3_600)])
    }

    private func fixture() async throws -> RealtimeTestFixture {
        try await RealtimeTestFixture(
            stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:20:00,08:20:00,c,2\n"
                + "later,10:00:00,10:00:00,a,1\nlater,10:20:00,10:20:00,c,2\n",
            trips: "route,service,trip,Destination\nroute,service,later,Destination\n")
    }

    private func request(minutes: Int, lines: [String]) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: "en", date: try GTFSDate(parsing: "20260930"),
            time: try ServiceTime(parsing: "08:00:00"), durationMinutes: minutes,
            maximumJourneys: -1, lines: lines, realtimeMode: .serverDefault, includePasslist: true)
    }

    private func routingRequest(since boundary: Date) -> RealtimeRoutingRequest {
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("10:30:00")
        return .init(stopIDs: ["a"], from: from, through: through, refreshPolicy: .forceRefresh,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201"])], refreshStartedAt: boundary)
    }

    private static func parameter(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func payload(for request: URLRequest) -> String {
        let first = liveBoard(stops: "")
        let later = liveBoard(stops: "", time: "10:00:00", realtime: "10:08:00")
            .replacingOccurrences(of: "same-journey", with: "later-journey")
        let values = parameter("time", in: request) == "08:00:00"
            ? (parameter("duration", in: request) == "150" ? [first, later] : [first]) : [later]
        let prefix = "{\"Departure\":["
        return prefix + values.map { String($0.dropFirst(prefix.count).dropLast(2)) }.joined(separator: ",") + "]}"
    }
}

private actor ScopedBoardGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ScopedBoardClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
