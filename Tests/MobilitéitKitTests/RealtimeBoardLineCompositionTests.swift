import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardLineCompositionTests {
    @Test(arguments: [0, 1, 2])
    func differentlyPartitionedLinesReuseCachedAndPendingBoards(mode: Int) async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { request in
            Self.payload(lines: Self.lines(in: request))
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let firstRequest = try request(lines: ["201", "202"])
        let secondRequest = try request(lines: ["203", "204"])
        let first = Task { try await client.departureBoardSnapshot(firstRequest) }
        if mode != 1 { _ = try await first.value }
        let second = Task { try await client.departureBoardSnapshot(secondRequest) }
        while RealtimeBoardProtocol.requests(host).count < 2 { await Task.yield() }
        if mode == 0 { _ = try await second.value }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let result = try await provider.patches(for: routingRequest())
        _ = try await first.value; _ = try await second.value
        #expect(Set(result.patches.map(\.tripID)) == ["trip", "other"])
        #expect(result.networkRequests == 0 && result.cacheHits == 2)
        #expect(result.responseBytes == 0 && result.incompleteStopIDs.isEmpty)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }

    @Test func unknownPendingPartitionRetriesOnlyItsAssignedLines() async throws {
        let fixture = try await fixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { request in
            let selected = Self.lines(in: request)
            let value = Self.payload(lines: selected)
            return selected == ["201", "202"]
                ? value.replacingOccurrences(of: "\"line\":\"201\",", with: "") : value
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let firstRequest = try request(lines: ["201", "202"])
        let secondRequest = try request(lines: ["203", "204"])
        let first = Task { try await client.departureBoardSnapshot(firstRequest) }
        let second = Task { try await client.departureBoardSnapshot(secondRequest) }
        while RealtimeBoardProtocol.requests(host).count < 2 { await Task.yield() }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let result = try await provider.patches(for: routingRequest())
        _ = try await first.value; _ = try await second.value
        #expect(Set(result.patches.map(\.tripID)) == ["trip", "other"])
        #expect(result.networkRequests == 1 && result.cacheHits == 2)
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
        #expect(Self.lines(in: try #require(RealtimeBoardProtocol.requests(host).last)) == ["201"])
    }

    private func fixture() async throws -> RealtimeTestFixture {
        try await RealtimeTestFixture(
            stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:20:00,08:20:00,c,2\n"
                + "other,08:00:00,08:00:00,a,1\nother,08:20:00,08:20:00,c,2\n",
            trips: "route,service,trip,Destination\nother-route,service,other,Destination\n",
            additionalRoutes: "other-route,operator,203,Bus 203,3\n")
    }

    private func request(lines: [String]) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: "en", date: try GTFSDate(parsing: "20260930"),
            time: try ServiceTime(parsing: "08:00:00"), durationMinutes: 90,
            maximumJourneys: -1, lines: lines, realtimeMode: .serverDefault, includePasslist: true)
    }

    private func routingRequest() -> RealtimeRoutingRequest {
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("09:30:00")
        return .init(stopIDs: ["a"], from: from, through: through,
            targets: [.init(stopID: "a", from: from, through: through, lines: ["201", "203"])])
    }

    private static func lines(in request: URLRequest) -> [String] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "lines" }?.value?.split(separator: ",").map(String.init) ?? []
    }

    private static func payload(lines: [String]) -> String {
        let first = liveBoard(stops: "")
        let second = first.replacingOccurrences(of: "201", with: "203")
            .replacingOccurrences(of: "same-journey", with: "other-journey")
        let prefix = "{\"Departure\":["
        let values = [("201", first), ("203", second)].filter { lines.isEmpty || lines.contains($0.0) }
        return prefix + values.map { String($0.1.dropFirst(prefix.count).dropLast(2)) }.joined(separator: ",") + "]}"
    }
}
