import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DepartureBoardIntervalTests {
    @Test func overlappingFlightsShareTheirIntersectionAndFetchOnlyTheTail() async throws {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { _ in
            liveBoard(stops: "")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let first = Task { try await client.departureBoardSnapshot(request("08:00:00", minutes: 60)) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        let second = Task { try await client.departureBoardSnapshot(request("08:30:00", minutes: 60)) }
        _ = try await first.value; _ = try await second.value
        let queries = RealtimeBoardProtocol.requests(host).map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!
        }
        #expect(queries.count == 2)
        #expect(queries.last?.first { $0.name == "duration" }?.value == "30")
        #expect(queries.last?.first { $0.name == "time" }?.value == "09:00:00")
    }

    @Test func compatibleCoverageExpiresAtItsOriginalAcquisitionTime() async throws {
        let clock = IntervalCacheClock()
        let cache = DepartureBoardCache(now: { clock.read() })
        let interval = DateInterval(start: RealtimeTestFixture.date("08:00:00"), duration: 90 * 60)
        let broad = BoardCacheScope(namespace: "expiration", interval: interval, maximumJourneys: -1)
        let narrow = BoardCacheScope(namespace: "expiration", interval: .init(start: interval.start, duration: 30 * 60), maximumJourneys: -1)
        let board = HafasDepartureBoard(departures: [])
        let first = try await cache.measuredResponse(for: "broad", refreshPolicy: .useCache, scope: broad) {
            .init(board: board, networkRequests: 1, cacheHits: 0)
        }
        clock.advance(59)
        let reused = try await cache.intervalResponse(scope: narrow, refreshPolicy: .useCache) { _ in
            Issue.record("Fresh containing coverage was missed")
            return .init(board: board, networkRequests: 1, cacheHits: 0)
        }
        #expect(reused.fetchedAt == first.fetchedAt && reused.networkRequests == 0)
        clock.advance(1)
        let expired = try await cache.intervalResponse(scope: narrow, refreshPolicy: .useCache) { _ in
            try await cache.measuredResponse(for: "narrow", refreshPolicy: .useCache, scope: narrow) {
                .init(board: board, networkRequests: 1, cacheHits: 0)
            }
        }
        #expect(expired.networkRequests == 1 && expired.cacheHits == 0)
        #expect(expired.fetchedAt == clock.read())
    }

    private func request(_ time: String, minutes: Int, line: String? = nil,
                         language: String = "en", maximum: Int = -1) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: language, date: try GTFSDate(parsing: "20260930"),
              time: try ServiceTime(parsing: time), durationMinutes: minutes, maximumJourneys: maximum,
              lines: line.map { [$0] } ?? [], realtimeMode: .serverDefault, includePasslist: true)
    }

    @Test func stopBoardSuppliesRoutingWithoutAnotherRequest() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let board = try await client.departureBoardSnapshot(request("08:00:00", minutes: 180))
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let batch = try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache)
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
        #expect(batch.networkRequests == 0 && batch.cacheHits == 1)
        let patch = try #require(batch.patches.first)
        #expect(patch.events.first?.effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
        #expect(patch.events.first?.observedAt == board.fetchedAt)
    }

    @Test func movingWindowFetchesOnlyTheUncoveredTail() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let first = try await client.departureBoardSnapshot(request("08:00:00", minutes: 60))
        let shifted = try await client.departureBoardSnapshot(request("08:10:00", minutes: 60))
        let queries = RealtimeBoardProtocol.requests(host).map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!
        }
        #expect(queries.count == 2)
        #expect(queries.last?.contains(.init(name: "time", value: "09:00:00")) == true)
        #expect(queries.last?.contains(.init(name: "duration", value: "10")) == true)
        #expect(shifted.isComplete)
        #expect(shifted.fetchedAt == first.fetchedAt)
    }

    @Test func disjointCachedIntervalsFetchOnlyTheirMiddleGap() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in "{\"Departure\":[]}" }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(request("08:00:00", minutes: 30))
        _ = try await client.departureBoardSnapshot(request("09:00:00", minutes: 30))
        let assembled = try await client.departureBoardSnapshot(request("08:00:00", minutes: 90))
        let query = URLComponents(url: RealtimeBoardProtocol.requests(host).last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
        #expect(query.contains(.init(name: "time", value: "08:30:00")))
        #expect(query.contains(.init(name: "duration", value: "30")))
        #expect(assembled.isComplete && assembled.board.departures.values.isEmpty)
    }

    @Test func filtersLanguageCredentialsAndPasslistsStayIsolated() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(request("08:00:00", minutes: 90, line: "201"))
        _ = try await client.departureBoardSnapshot(request("08:00:00", minutes: 30))
        _ = try await client.departureBoardSnapshot(request("08:00:00", minutes: 30, language: "fr"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RealtimeBoardProtocol.self]
        let other = MobiliteitAPIClient(apiKey: "different", baseURL: client.baseURL, session: URLSession(configuration: config))
        _ = try await other.departureBoardSnapshot(request("08:00:00", minutes: 30))
        _ = try await client.departureBoardSnapshot(.init(stationID: "a", language: "en",
            date: try GTFSDate(parsing: "20260930"), time: try ServiceTime(parsing: "08:00:00"),
            durationMinutes: 30, maximumJourneys: -1, realtimeMode: .serverDefault))
        #expect(RealtimeBoardProtocol.requests(host).count == 5)
    }

    @Test func saturatedCountLimitedBoardCannotSupplyUnrestrictedCoverage() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let capped = try await client.departureBoardSnapshot(request("08:00:00", minutes: 90, maximum: 1))
        #expect(!capped.isComplete)
        let unrestricted = try await client.departureBoardSnapshot(request("08:00:00", minutes: 30))
        #expect(unrestricted.isComplete)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }

    @Test func containingInflightRequestSurvivesOneWaitersCancellation() async throws {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(150) }) { _ in
            liveBoard(stops: "")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let broadRequest = try request("08:00:00", minutes: 90)
        let narrowRequest = try request("08:00:00", minutes: 30)
        let first = Task { try await client.departureBoardSnapshot(broadRequest) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        let second = Task { try await client.departureBoardSnapshot(narrowRequest) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.isComplete)
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }

    @Test func refreshCannotBeReplacedByAnOlderContainingFlight() async throws {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            request.url!.query!.contains("duration=90") ? .milliseconds(150) : .zero
        }) { request in
            liveBoard(stops: "", realtime: request.url!.query!.contains("duration=90") ? "08:01:00" : "08:09:00")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let broad = try request("08:00:00", minutes: 90)
        let narrow = try request("08:00:00", minutes: 30)
        let first = Task { try await client.departureBoardSnapshot(broad) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        _ = try await client.departureBoardSnapshot(narrow, refreshPolicy: .forceRefresh)
        _ = try await first.value
        let reused = try await client.departureBoardSnapshot(narrow)
        #expect(reused.board.departures.values.first?.realtimeTime == "08:09:00")
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }
}

private final class IntervalCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date.now
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
