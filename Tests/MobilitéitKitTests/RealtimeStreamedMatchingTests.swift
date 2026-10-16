import Foundation
import Testing
@testable import MobiliteitKit

/// A batch resolves each board as it arrives and merges stops in request order (CAND-26).
@Suite(.serialized) struct RealtimeStreamedMatchingTests {
    /// The events of the test vehicle, without observation times, which differ between runs.
    private static func events(in batch: RealtimePatchBatch) -> [String] {
        (batch.patches.first { $0.tripID == "trip" }?.events ?? []).map {
            "\($0.stopID) dep \($0.effectiveDeparture?.timeIntervalSince1970 ?? 0) \($0.departureSource.rawValue) "
                + "arr \($0.effectiveArrival?.timeIntervalSince1970 ?? 0) \($0.arrivalSource.rawValue)"
        }
    }

    @Test func requestOrderIsKeptWhicheverBoardArrivesFirst() async throws {
        var results: [[String]] = []
        for delays in [[String: Duration](), ["a": .milliseconds(300)], ["b": .milliseconds(300)]] {
            let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
            let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: delays)
            defer { RealtimeBoardProtocol.remove(host) }
            let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
                through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
            #expect(batch.timings.boards.map(\.stopID) == ["a", "b"])
            // Merged one stop after the other, in request order.
            let first = try #require(batch.timings.boards.first), last = try #require(batch.timings.boards.last)
            #expect(try #require(first.matchingFinished) <= (try #require(last.matchingFinished)))
            results.append(Self.events(in: batch))
        }
        #expect(!results[0].isEmpty)
        #expect(results[1] == results[0], "b arrived first")
        #expect(results[2] == results[0], "a arrived first")
    }

    @Test func matchingStartsBeforeALaterBoardArrives() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: ["b": .milliseconds(600)])
        defer { RealtimeBoardProtocol.remove(host) }
        let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
            through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
        let boards = Dictionary(uniqueKeysWithValues: batch.timings.boards.map { ($0.stopID, $0) })
        let first = try #require(boards["a"]), second = try #require(boards["b"])
        let matchedFirst = try #require(first.matchingFinished), arrivedSecond = try #require(second.arrived)
        #expect(matchedFirst < arrivedSecond, "stop a is matched while stop b is still being fetched")
        #expect(try #require(second.matchingStarted) >= arrivedSecond)
        #expect(try #require(batch.timings.fetchFinished) >= arrivedSecond)
        #expect(!batch.patches.isEmpty)
    }

    @Test func aLaterStopIsResolvedEarlyButMergedAfterTheStopAheadOfIt() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: ["a": .milliseconds(400)])
        defer { RealtimeBoardProtocol.remove(host) }
        let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
            through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
        let boards = Dictionary(uniqueKeysWithValues: batch.timings.boards.map { ($0.stopID, $0) })
        let first = try #require(boards["a"]), second = try #require(boards["b"])
        #expect(try #require(second.arrived) < (try #require(first.arrived)), "b arrives first")
        #expect(try #require(second.matchingStarted) < (try #require(first.arrived)), "b is resolved while a is in flight")
        // Request order is preserved: b is merged only after a.
        #expect(try #require(second.matchingFinished) >= (try #require(first.matchingFinished)))
    }

    /// Stop "b" prefers trip "other" on its own (a matching headsign), but the journey was already
    /// matched to "trip" at stop "a", which comes first in request order and decides.
    @Test(arguments: [[String: Duration](), ["a": .milliseconds(300)]])
    func theReusedCandidateOfAnEarlierStopOverridesAnEarlyResolution(delays: [String: Duration]) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:10:00,08:10:00,b,2\ntrip,08:20:00,08:20:00,c,3\n"
                + "other,08:10:00,08:10:00,b,1\nother,08:20:00,08:20:00,c,2\n",
            trips: "route,service,trip,Elsewhere\nroute,service,other,Destination\n")
        defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: delays)
        defer { RealtimeBoardProtocol.remove(host) }
        let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
            through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh))
        #expect(batch.patches.map(\.tripID) == ["trip"])
        #expect(batch.matchingRejections.isEmpty)
        #expect(Self.events(in: batch).count == 3)
    }

    @Test func aBoardThatMissesTheAcquisitionDeadlineLeavesOnlyItsStopIncomplete() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: ["b": .seconds(3)])
        defer { RealtimeBoardProtocol.remove(host) }
        let started = ContinuousClock.now
        let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
            through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh, timeout: .milliseconds(800)))
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(batch.incompleteStopIDs == ["b"])
        #expect(batch.coveredStopIDs == ["a"])
        #expect(!batch.patches.isEmpty, "the board that arrived was matched")
        #expect(batch.timings.boards.map(\.stopID) == ["a", "b"])
        #expect(batch.timings.boards.last?.arrived == nil || batch.timings.boards.last?.matchingStarted != nil)
    }

    @Test func cancellingABatchWhileABoardIsInFlightEndsItAndReleasesTheMemoization() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (provider, host) = try await RealtimeBatchFixture.provider(fixture, delays: ["b": .seconds(5)])
        defer { RealtimeBoardProtocol.remove(host) }
        let task = Task {
            try await provider.patches(for: .init(stopIDs: ["a", "b"], from: RealtimeBatchFixture.from,
                through: RealtimeBatchFixture.through, refreshPolicy: .forceRefresh, timeout: .seconds(20)))
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(started.duration(to: .now) < .seconds(1))
        if case .success = result { Issue.record("a cancelled batch must not return a result") }
        #expect(await provider.activeMatchingBatches == 0)
        #expect(await provider.timestampCache.isEmpty)
    }
}
