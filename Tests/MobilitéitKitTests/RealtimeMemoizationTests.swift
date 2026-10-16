import Foundation
import Testing
@testable import MobiliteitKit

/// Overlapping batches share one matching memoization, cleared when the last one ends (CAND-25).
@Suite(.serialized) struct RealtimeMemoizationTests {
    @Test func memoizationSurvivesAnOverlappingBatch() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: [:])
        defer { RealtimeBoardProtocol.remove(host) }
        await provider.beginMatchingBatch()
        _ = await provider.date(date: "2026-09-30", time: "08:00:00")
        #expect(await provider.timestampCache.count == 1)
        await provider.beginMatchingBatch()
        await provider.endMatchingBatch()
        #expect(await provider.timestampCache.count == 1, "the first batch still runs")
        await provider.endMatchingBatch()
        #expect(await provider.timestampCache.isEmpty, "the last batch clears it")
        #expect(await provider.activeMatchingBatches == 0)
    }

    @Test func aFinishingBatchDoesNotClearTheMemoizationOfOneStillRunning() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: ["b": .milliseconds(800)])
        defer { RealtimeBoardProtocol.remove(host) }
        let slow = Task {
            try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
                through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
        }
        // Stop "a" arrives at once; its pure conversions are prepared while "b" is in flight.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await provider.timestampCache.isEmpty == false)
        _ = try await provider.patches(for: .init(stopIDs: ["c"], from: RealtimeBatchFixture.from,
            through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
        #expect(await provider.timestampCache.isEmpty == false, "the other batch's conversions are kept")
        #expect(await provider.activeMatchingBatches == 1)
        _ = try await slow.value
        #expect(await provider.activeMatchingBatches == 0)
        #expect(await provider.timestampCache.isEmpty)
    }
}
