import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardSupersetTests {
    @Test func forcedMissingCoverageInvalidatesAnOlderContainingBoard() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            request.url!.query!.contains("duration=90") ? liveBoard(stops: "") : #"{"Departure":[]}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let broad = try request(lines: ["201"])
        _ = try await client.departureBoardSnapshot(broad)
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("08:30:00")
        _ = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            refreshPolicy: .forceRefresh,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201"])],
            refreshStartedAt: .now))
        // An empty refreshed interval must not resurrect its earlier report
        // by selecting the stale, containing ninety-minute cached board.
        let reused = try await client.departureBoardSnapshot(broad)
        #expect(reused.board.departures.values.isEmpty)
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
    }

    @Test func forcedCalculationReusesOnlyBoardsAcquiredSinceItsStart() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardSnapshot(try request(lines: ["201", "202"]))
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        let boundary = Date.now
        func query(_ lines: [String], since start: Date) -> RealtimeRoutingRequest {
            .init(stopIDs: ["a"], from: from, through: through, refreshPolicy: .forceRefresh,
                targets: [.init(stopID: "a", from: from, through: through, lines: lines)],
                refreshStartedAt: start)
        }
        let fresh = try await provider.patches(for: query(["201", "202"], since: boundary))
        #expect(fresh.networkRequests == 1)
        let completion = try await provider.patches(for: query(["201"], since: boundary))
        #expect(completion.networkRequests == 0 && completion.cacheHits == 1)
        let nextRefresh = try await provider.patches(for: query(["201"], since: .now))
        #expect(nextRefresh.networkRequests == 1)
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
    }

    @Test func aRefreshCannotJoinAFlightFromBeforeItStarted() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(150) }) { _ in
            liveBoard(stops: "")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let broad = try request(lines: ["201", "202"])
        let old = Task { try await client.departureBoardSnapshot(broad) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        let refreshed = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            refreshPolicy: .forceRefresh,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201", "202"])],
            refreshStartedAt: .now))
        _ = try await old.value
        #expect(refreshed.networkRequests == 1)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }

    @Test(arguments: [false, true])
    func narrowerLinesReuseLookaheadWithoutPublishingOtherLines(inFlight: Bool) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,11:00:00,11:00:00,a,1\ntrip,11:20:00,11:20:00,c,2\n"
                + "other,11:00:00,11:00:00,a,1\nother,11:20:00,11:20:00,c,2\n",
            trips: "route,service,trip,Destination\nother-route,service,other,Destination\n",
            additionalRoutes: "other-route,operator,202,Bus 202,3\n")
        defer { fixture.remove() }
        let first = liveBoard(stops: "", time: "11:00:00", realtime: "11:08:00")
        let second = first.replacingOccurrences(of: "201", with: "202")
            .replacingOccurrences(of: "same-journey", with: "other-journey")
        let prefix = "{\"Departure\":["
        let payload = prefix + String(first.dropFirst(prefix.count).dropLast(2)) + ","
            + String(second.dropFirst(prefix.count).dropLast(2)) + "]}"
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in
            inFlight ? .milliseconds(100) : .zero
        }) { _ in payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let early = RealtimeTestFixture.date("08:00:00")
        let earlyEnd = RealtimeTestFixture.date("09:30:00")
        let flight = Task { try await provider.patches(for: .init(stopIDs: ["a"], from: early, through: earlyEnd,
            targets: [.init(stopID: "a", from: early, through: earlyEnd, lines: ["201", "202"])],
            minimumBoardCoverageMinutes: 240)) }
        if inFlight {
            while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        } else { _ = try await flight.value }
        let from = RealtimeTestFixture.date("11:00:00")
        let through = RealtimeTestFixture.date("12:00:00")
        let narrower = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201"])]))
        _ = try await flight.value
        #expect(narrower.networkRequests == 0)
        #expect(narrower.cacheHits == 1)
        #expect(narrower.patches.map(\.tripID) == ["trip"])
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }

    @Test func anInFlightSupersetWithUnknownLinesFallsBackToTheOriginalFilter() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { request in
            let lines = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "lines" }?.value
            return lines == "201,202"
                ? liveBoard(stops: "").replacingOccurrences(of: "\"line\":\"201\",", with: "")
                : liveBoard(stops: "")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let broadRequest = try request(lines: ["201", "202"])
        let first = Task { try await client.departureBoardSnapshot(broadRequest) }
        while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        let result = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201"])]))
        _ = try await first.value
        #expect(result.patches.map(\.tripID) == ["trip"])
        #expect(result.networkRequests == 1)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }

    private func request(lines: [String], language: String = "en", passlist: Bool = true,
                         maximum: Int = -1) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: language, date: try GTFSDate(parsing: "20260930"),
            time: try ServiceTime(parsing: "08:00:00"), durationMinutes: 90,
            maximumJourneys: maximum, lines: lines, realtimeMode: .serverDefault, includePasslist: passlist)
    }
}
