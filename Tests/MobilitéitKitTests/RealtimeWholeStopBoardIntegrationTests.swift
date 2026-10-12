import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeWholeStopBoardIntegrationTests {
    @Test(arguments: [false, true])
    func wholeStopBoardsRetainLinesBeyondEightWithinBothConcurrencyLimits(providerIsBound: Bool) async throws {
        let limits = (provider: providerIsBound ? 2 : 5, request: providerIsBound ? 5 : 2)
        let fixture = try await RealtimeTestFixture(stopTimes:
            "trip,08:00:00,08:00:00,a,1\ntrip,08:10:00,08:10:00,b,2\ntrip,08:20:00,08:20:00,c,3\n"
                + "late-trip,08:30:00,08:30:00,a,1\nlate-trip,08:50:00,08:50:00,c,2\n",
            trips: "route,service,trip,Destination\nlate,service,late-trip,Destination\n",
            additionalRoutes: "late,operator,209,Bus 209,3\n")
        defer { fixture.remove() }
        let probe = WholeStopBoardConcurrency()
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in
            probe.started()
            return .milliseconds(50)
        }) { request in
            probe.finished()
            let lines = Self.query(request)["lines"]?.split(separator: ",").map(String.init) ?? []
            return lines.contains("209")
                ? liveBoard(stops: liveStop("a", planned: "08:30:00", predicted: "08:38:00") + ","
                    + liveStop("c", planned: "08:50:00", predicted: "08:58:00", arrival: "08:58:00"),
                    time: "08:30:00", realtime: "08:38:00")
                    .replacingOccurrences(of: "\"201\"", with: "\"209\"")
                : #"{"Departure":[]}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database,
            client: client, maximumConcurrentBoardRequests: limits.provider)
        let from = RealtimeTestFixture.date("08:05:00")
        let through = RealtimeTestFixture.date("09:25:00")
        let request = RealtimeRoutingRequest(stopIDs: ["a", "b", "c"], from: from, through: through,
            maximumConcurrentRequests: limits.request, targets: [
                .init(stopID: "a", from: from, through: through, lines: (201...205).map(String.init)),
                .init(stopID: "a", from: from, through: through, lines: Array((205...209).reversed()).map(String.init)),
                .init(stopID: "b", from: from, through: through, lines: (211...218).map(String.init)),
                .init(stopID: "c", from: from, through: through),
                .init(stopID: "c", from: from, through: through, lines: ["999"])
            ])
        let batch = try await provider.patches(for: request)
        let requests = RealtimeBoardProtocol.requests(host)
        // Extra slots never split one stop's complete line union. Three stops
        // still respect the smaller of the provider and per-operation limits.
        #expect(requests.count == 3)
        #expect(probe.peak == min(limits.provider, limits.request))
        #expect(batch.requestedStopIDs == ["a", "b", "c"])
        #expect(batch.coveredStopIDs == batch.requestedStopIDs)
        #expect(batch.incompleteStopIDs.isEmpty)
        #expect(batch.networkRequests == 3)
        #expect(batch.cacheHits == 0)
        let patch = try #require(batch.patches.first)
        #expect(patch.tripID == "late-trip")
        #expect(patch.events.first?.effectiveDeparture == RealtimeTestFixture.date("08:38:00"))
        #expect(patch.events.last?.effectiveArrival == RealtimeTestFixture.date("08:58:00"))
        let queries = requests.map(Self.query)
        #expect(queries.filter { $0["id"] == "a" }.compactMap { $0["lines"] }.sorted()
            == ["201,202,203,204,205,206,207,208,209"])
        #expect(queries.filter { $0["id"] == "b" }.compactMap { $0["lines"] } == ["211,212,213,214,215,216,217,218"])
        #expect(queries.filter { $0["id"] == "c" }.allSatisfy { $0["lines"] == nil })
        for query in queries {
            #expect(query["date"] == "2026-09-30")
            #expect(query["time"] == "08:00:00")
            #expect(query["duration"] == "90")
            #expect(query["maxJourneys"] == "-1")
            #expect(query["passlist"] == "1")
        }
        let reused = try await provider.patches(for: request)
        #expect(reused.networkRequests == 0)
        #expect(reused.cacheHits == 3)
        #expect(reused.coveredStopIDs == batch.coveredStopIDs)
        #expect(reused.incompleteStopIDs.isEmpty)
        #expect(reused.patches == batch.patches)
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

private final class WholeStopBoardConcurrency: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var active = 0
    private nonisolated(unsafe) var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func started() { lock.withLock { active += 1; maximum = max(maximum, active) } }
    func finished() { lock.withLock { active -= 1 } }
}
