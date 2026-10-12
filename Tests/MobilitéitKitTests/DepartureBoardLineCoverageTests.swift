import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DepartureBoardLineCoverageTests {
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
