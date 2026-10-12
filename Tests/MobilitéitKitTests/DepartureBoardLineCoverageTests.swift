import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DepartureBoardLineCoverageTests {
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
        #expect(await cache.coveringLines(for: requested, maximumCacheAge: 60) == nil)
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
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"]),
            maximumCacheAge: 60) == nil)
    }

    @Test func scopeAndFreshnessMustMatch() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(try request(lines: ["201", "202"]))
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"]),
            maximumCacheAge: 60) == ["201", "202"])
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"]),
            maximumCacheAge: 0) == nil)
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["203"]),
            maximumCacheAge: 60) == nil)
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: []),
            maximumCacheAge: 60) == nil)
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"], language: "fr"),
            maximumCacheAge: 60) == nil)
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"], passlist: false),
            maximumCacheAge: 60) == nil)
        #expect(await client.cachedDepartureBoardSupersetLines(try request(lines: ["201"], maximum: 1),
            maximumCacheAge: 60) == nil)
        let other = MobiliteitAPIClient(apiKey: "other", baseURL: client.baseURL)
        #expect(await other.cachedDepartureBoardSupersetLines(try request(lines: ["201"]),
            maximumCacheAge: 60) == nil)
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
