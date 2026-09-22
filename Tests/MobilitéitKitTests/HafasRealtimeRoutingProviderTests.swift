import Foundation
import Testing
@testable import MobiliteitKit

@Test func realtimeBoardDeadlineKeepsCompletedResponses() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let started = ContinuousClock.now

    let boards = await HafasRealtimeRoutingProvider.fetchBoardsWithLimitedConcurrency(
        stopIDs: ["fast", "slow"],
        maximumConcurrentRequests: 2,
        timeout: .milliseconds(50)
    ) { stopID in
        if stopID == "slow" {
            try? await Task.sleep(for: .seconds(5))
        }
        return board
    }

    #expect(boards.keys.sorted() == ["fast"])
    #expect(started.duration(to: .now) < .seconds(1))
}

@Test func realtimeBoardFetchFinishesWithoutWaitingForDeadline() async throws {
    let board = try JSONDecoder().decode(
        HafasDepartureBoard.self,
        from: Data(#"{"Departure":[]}"#.utf8)
    )
    let started = ContinuousClock.now

    let boards = await HafasRealtimeRoutingProvider.fetchBoardsWithLimitedConcurrency(
        stopIDs: ["a", "b", "c"],
        maximumConcurrentRequests: 2,
        timeout: .seconds(5)
    ) { _ in board }

    #expect(boards.keys.sorted() == ["a", "b", "c"])
    #expect(started.duration(to: .now) < .seconds(1))
}
