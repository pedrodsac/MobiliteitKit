import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DepartureBoardLineCoverageTests {
    @Test func composedCoverageRevalidatesFreshnessAndOverlappingRefreshes() async throws {
        let clock = LineCoverageClock()
        let cache = DepartureBoardCache(now: { clock.read() })
        let start = RealtimeTestFixture.date("08:00:00")
        func scope(_ lines: [String], duration: TimeInterval = 5_400,
                   language: String = "en") -> BoardCacheScope {
            .init(namespace: "https://board.invalid/departureBoard?id=a&lang=\(language)&lines=\(lines.joined(separator: ","))",
                interval: .init(start: start, duration: duration), maximumJourneys: -1)
        }
        let empty = HafasDepartureBoard(departures: [])
        for lines in [["201", "202"], ["203", "204"]] {
            let value = scope(lines)
            _ = try await cache.measuredResponse(for: value.namespace, refreshPolicy: .useCache, scope: value) {
                .init(board: empty, networkRequests: 1, cacheHits: 0)
            }
        }
        let requested = scope(["201", "203"])
        let parts = await cache.lineCoverageParts(for: requested, maximumCacheAge: 60)
        #expect(parts.count == 2)
        #expect(Set(parts.flatMap(\.requestedLines)) == ["201", "203"])
        #expect(await cache.lineCoverageParts(for: scope(["201", "203"], language: "fr"), maximumCacheAge: 60).isEmpty)
        clock.advance(2)
        #expect(await cache.lineCoverageParts(for: requested, maximumCacheAge: 1).isEmpty)
        let expired = try await cache.reuseLineCoveragePart(try #require(parts.first), maximumCacheAge: 1)
        #expect(expired?.cacheHits == nil)
        _ = try await cache.measuredResponse(for: "refresh", refreshPolicy: .forceRefresh,
            scope: scope(["201"], duration: 1_800)) {
            .init(board: empty, networkRequests: 1, cacheHits: 0)
        }
        for part in parts {
            let reused = try await cache.reuseLineCoveragePart(part, maximumCacheAge: 60)
            #expect(reused?.cacheHits == (part.requestedLines == ["203"] ? 1 : nil))
        }
    }

    @Test func invalidatedPendingPartitionCannotBeJoinedFromAnEarlierPlan() async throws {
        let cache = DepartureBoardCache()
        let gate = LineCoverageGate()
        let start = RealtimeTestFixture.date("08:00:00")
        let broad = BoardCacheScope(namespace: "https://board.invalid/departureBoard?lines=201,202",
            interval: .init(start: start, duration: 5_400), maximumJourneys: -1)
        let requested = BoardCacheScope(namespace: "https://board.invalid/departureBoard?lines=201",
            interval: broad.interval, maximumJourneys: -1)
        let empty = HafasDepartureBoard(departures: [])
        let owner = Task {
            try await cache.measuredResponse(for: "broad", refreshPolicy: .useCache, scope: broad) {
                await gate.wait()
                return .init(board: empty, networkRequests: 1, cacheHits: 0)
            }
        }
        while !(await gate.entered) { await Task.yield() }
        let parts = await cache.lineCoverageParts(for: requested, maximumCacheAge: 60)
        _ = try await cache.measuredResponse(for: "refresh", refreshPolicy: .forceRefresh,
            scope: .init(namespace: requested.namespace, interval: .init(start: start, duration: 1_800), maximumJourneys: -1)) {
            .init(board: empty, networkRequests: 1, cacheHits: 0)
        }
        let reused = try await cache.reuseLineCoveragePart(try #require(parts.first), maximumCacheAge: 60)
        #expect(reused?.cacheHits == nil)
        await gate.release()
        _ = try await owner.value
        #expect(await cache.lineCoverageParts(for: requested, maximumCacheAge: 60).isEmpty)
    }

    @Test func cancellingAPartitionWaiterPreservesItsOwner() async throws {
        let cache = DepartureBoardCache()
        let gate = LineCoverageGate()
        let start = RealtimeTestFixture.date("08:00:00")
        let scope = BoardCacheScope(namespace: "https://board.invalid/departureBoard?lines=201,202",
            interval: .init(start: start, duration: 5_400), maximumJourneys: -1)
        let requested = BoardCacheScope(namespace: "https://board.invalid/departureBoard?lines=201",
            interval: scope.interval, maximumJourneys: -1)
        let empty = HafasDepartureBoard(departures: [])
        let owner = Task {
            try await cache.measuredResponse(for: "broad", refreshPolicy: .useCache, scope: scope) {
                await gate.wait()
                return .init(board: empty, networkRequests: 1, cacheHits: 0)
            }
        }
        while !(await gate.entered) { await Task.yield() }
        let parts = await cache.lineCoverageParts(for: requested, maximumCacheAge: 60)
        let part = try #require(parts.first)
        let waiter = Task { try await cache.reuseLineCoveragePart(part, maximumCacheAge: 60) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.release()
        #expect(try await owner.value.networkRequests == 1)
        let reused = try await cache.reuseLineCoveragePart(part, maximumCacheAge: 60)
        #expect(reused?.cacheHits == 1)
    }

    @Test(arguments: [false, true])
    func filteredRefreshInvalidatesOlderBroaderCoverage(inFlight: Bool) async throws {
        let cache = DepartureBoardCache()
        let gate = LineCoverageGate()
        let start = RealtimeTestFixture.date("08:00:00")
        func scope(_ lines: [String], start: Date, duration: TimeInterval,
                   language: String = "en") -> BoardCacheScope {
            .init(namespace: "https://board.invalid/departureBoard?id=a&lang=\(language)&lines=\(lines.joined(separator: ","))",
                interval: .init(start: start, duration: duration), maximumJourneys: -1)
        }
        let broad = scope(["201", "202"], start: start, duration: 5_400)
        let narrow = scope(["201"], start: start, duration: 1_800)
        let requested = scope(["201"], start: start, duration: 5_400)
        let independent = [
            scope(["203"], start: start, duration: 5_400),
            scope(["201"], start: start.addingTimeInterval(7_200), duration: 1_800),
            scope(["201"], start: start, duration: 5_400, language: "fr"),
        ]
        let old = HafasDepartureBoard(departures: [], responseBytes: 1)
        let fresh = HafasDepartureBoard(departures: [], responseBytes: 2)
        for value in independent {
            _ = try await cache.measuredResponse(for: value.namespace + value.interval.start.description,
                refreshPolicy: .useCache, scope: value) {
                .init(board: old, networkRequests: 1, cacheHits: 0)
            }
        }
        let first = Task {
            try await cache.measuredResponse(for: "broad", refreshPolicy: .useCache, scope: broad) {
                if inFlight { await gate.wait() }
                return .init(board: old, networkRequests: 1, cacheHits: 0)
            }
        }
        if inFlight {
            while !(await gate.entered) { await Task.yield() }
        } else { _ = try await first.value }
        _ = try await cache.measuredResponse(for: "narrow", refreshPolicy: .forceRefresh, scope: narrow) {
            .init(board: fresh, networkRequests: 1, cacheHits: 0)
        }
        if inFlight { await gate.release() }
        _ = try await first.value
        #expect(await cache.lineCoverageParts(for: requested, maximumCacheAge: 60).isEmpty)
        let renewed = try await cache.measuredResponse(for: "broad", refreshPolicy: .useCache, scope: broad) {
            .init(board: fresh, networkRequests: 1, cacheHits: 0)
        }
        #expect(renewed.networkRequests == 1 && renewed.board.responseBytes == 2)
        for value in independent {
            #expect(await cache.coverage(of: value) == 1)
        }
    }

    @Test(arguments: [false, true])
    func unknownLineMetadataCannotSupplyFilteredCoverage(missing: Bool) async throws {
        let payload = liveBoard(stops: "").replacingOccurrences(of: "\"line\":\"201\",",
            with: missing ? "" : "\"line\":\"\",")
        let (client, host) = RealtimeBoardProtocol.client { _ in payload }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(try request(lines: ["201", "202"]))
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"]),
            maximumCacheAge: 60).isEmpty)
    }

    @Test func scopeAndFreshnessMustMatch() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(try request(lines: ["201", "202"]))
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"]),
            maximumCacheAge: 60).first?.scope.selectedLines == ["201", "202"])
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"]),
            maximumCacheAge: 0).isEmpty)
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["203"]),
            maximumCacheAge: 60).isEmpty)
        #expect(await client.departureBoardLineCoverageParts(try request(lines: []),
            maximumCacheAge: 60).isEmpty)
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"], language: "fr"),
            maximumCacheAge: 60).isEmpty)
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"], passlist: false),
            maximumCacheAge: 60).isEmpty)
        #expect(await client.departureBoardLineCoverageParts(try request(lines: ["201"], maximum: 1),
            maximumCacheAge: 60).isEmpty)
        let other = MobiliteitAPIClient(apiKey: "other", baseURL: client.baseURL)
        #expect(await other.departureBoardLineCoverageParts(try request(lines: ["201"]),
            maximumCacheAge: 60).isEmpty)
    }

    private func request(lines: [String], language: String = "en", passlist: Bool = true,
                         maximum: Int = -1) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: language, date: try GTFSDate(parsing: "20260930"),
            time: try ServiceTime(parsing: "08:00:00"), durationMinutes: 90,
            maximumJourneys: maximum, lines: lines, realtimeMode: .serverDefault, includePasslist: passlist)
    }
}

private actor LineCoverageGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class LineCoverageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
