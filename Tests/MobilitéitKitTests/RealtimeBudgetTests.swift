import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBudgetTests {
    @Test func oldConfigurationDecodesWithFourSecondBudget() throws {
        let json = Data(#"{"scheduledLookbackSeconds":7200,"minimumForwardHorizonSeconds":5400,"maximumConcurrentBoardRequests":4,"maximumRefinementWaves":4}"#.utf8)
        let old = try JSONDecoder().decode(RealtimeConfiguration.self, from: json)
        #expect(old.acquisitionBudgetMilliseconds == 4_000)
        var changed = old
        changed.acquisitionBudgetMilliseconds = 2_000
        #expect(try JSONDecoder().decode(RealtimeConfiguration.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func shiftedClockReusesSlicesAndFetchesOnlyMissingCoverage() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:05:00")
        let through = RealtimeTestFixture.date("09:35:00")
        let first = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        #expect(first.networkRequests == 4)
        let moved = try await provider.patches(for: ["a"], from: from.addingTimeInterval(10),
                                              through: through.addingTimeInterval(10), refreshPolicy: .useCache)
        #expect(moved.networkRequests == 0)
        #expect(moved.cacheHits == 4)
        let extended = try await provider.patches(for: ["a"], from: from.addingTimeInterval(30 * 60),
                                                 through: through.addingTimeInterval(30 * 60), refreshPolicy: .useCache)
        #expect(extended.networkRequests == 1)
        #expect(extended.cacheHits == 3)
        let refreshed = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .forceRefresh)
        #expect(refreshed.networkRequests == 4)
    }

    @Test func expiredDeadlineDoesNotUseCachedEvidenceAsComplete() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("08:30:00")
        _ = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        do {
            let batch = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
                timeout: .zero, deadline: ContinuousClock.now.advanced(by: .seconds(-1))))
            #expect(batch.patches.isEmpty)
            #expect(batch.incompleteStopIDs == ["a"])
        } catch HafasRealtimeRoutingError.unavailable {
            // No work began before the expired deadline.
        }
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }
}
