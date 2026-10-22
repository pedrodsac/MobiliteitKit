import Foundation
import Testing
@testable import MobiliteitKit

/// Asks for the same board twice in one calculation, the way the planner can,
/// and counts what actually reaches the network.
@Suite struct RepeatedBoardRequestTests {
    @Test(arguments: [false, true])
    func repeatedIdenticalRequestIsServedOnce(inFlight: Bool) async throws {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { _ in Self.payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let board = try request(minutes: 90)
        let first = Task { try await client.departureBoardResponse(board, refreshPolicy: .useCache) }
        if inFlight {
            while RealtimeBoardProtocol.requests(host).isEmpty { await Task.yield() }
        } else {
            _ = try await first.value
        }
        let second = try await client.departureBoardResponse(board, refreshPolicy: .useCache)
        let original = try await first.value
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
        #expect(second.fetchedAt == original.fetchedAt)
    }

    @Test func narrowerRequestIsServedFromACachedWiderBoard() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in Self.payload }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardResponse(try request(minutes: 150), refreshPolicy: .useCache)
        let narrow = try await client.departureBoardResponse(try request(minutes: 60), refreshPolicy: .useCache)
        #expect(narrow.cacheHits >= 1)
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }

    @Test func widerRequestIsNotServedFromANarrowerBoard() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in Self.payload }
        defer { RealtimeBoardProtocol.remove(host) }
        _ = try await client.departureBoardResponse(try request(minutes: 60), refreshPolicy: .useCache)
        _ = try await client.departureBoardResponse(try request(minutes: 150), refreshPolicy: .useCache)
        #expect(RealtimeBoardProtocol.requests(host).count >= 2)
    }

    @Test func forceRefreshBypassesAFreshCachedBoard() async throws {
        let (client, host) = RealtimeBoardProtocol.client { _ in Self.payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let board = try request(minutes: 90)
        _ = try await client.departureBoardResponse(board, refreshPolicy: .useCache)
        _ = try await client.departureBoardResponse(board, refreshPolicy: .forceRefresh)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
    }

    private static var payload: String { liveBoard(stops: "") }

    private func request(minutes: Int) throws -> HafasDepartureBoardRequest {
        .init(stationID: "a", language: "en", date: try GTFSDate(parsing: "20260930"),
            time: try ServiceTime(parsing: "08:00:00"), durationMinutes: minutes,
            maximumJourneys: -1, lines: [], realtimeMode: .serverDefault, includePasslist: true)
    }
}
