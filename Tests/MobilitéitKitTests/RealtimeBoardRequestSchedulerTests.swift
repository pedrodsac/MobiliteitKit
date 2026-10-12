import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardRequestSchedulerTests {
    @Test func cancellingAQueuedWaiterPreservesFIFOAndTheActivePermit() async throws {
        let scheduler = RealtimeBoardRequestScheduler(capacity: 1)
        let gate = BoardSchedulerGate()
        let order = BoardSchedulerOrder()
        let first = Task { try await scheduler.withPermit { await gate.pause(); return 1 } }
        await gate.waitUntilEntered()
        let cancelled = Task { try await scheduler.withPermit { 0 } }
        try await Self.waitForQueue(1, scheduler: scheduler)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await scheduler.activeCount == 1)
        #expect(await scheduler.waitingCount == 0)

        let second = Task { try await scheduler.withPermit { await order.append(2); return 2 } }
        try await Self.waitForQueue(1, scheduler: scheduler)
        let third = Task { try await scheduler.withPermit { await order.append(3); return 3 } }
        try await Self.waitForQueue(2, scheduler: scheduler)
        await gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(try await third.value == 3)
        #expect(await order.values == [2, 3])
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
    }

    @Test func cancellingAcquiredWorkReleasesItsPermitAfterTheOperationExits() async throws {
        let scheduler = RealtimeBoardRequestScheduler(capacity: 1)
        let gate = BoardSchedulerGate()
        let first = Task {
            try await scheduler.withPermit {
                await gate.notifyEntered()
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        await gate.waitUntilEntered()
        let second = Task { try await scheduler.withPermit { 2 } }
        try await Self.waitForQueue(1, scheduler: scheduler)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == 2)
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
        #expect(try await scheduler.withPermit { 3 } == 3)
    }

    @Test func cancellationKeepsThePermitUntilNonthrowingWorkReturnsItsPartialResult() async throws {
        let scheduler = RealtimeBoardRequestScheduler(capacity: 1)
        let gate = BoardSchedulerGate()
        let first = Task { try await scheduler.withPermit { await gate.pause(); return 7 } }
        await gate.waitUntilEntered()
        let second = Task { try await scheduler.withPermit { 2 } }
        try await Self.waitForQueue(1, scheduler: scheduler)
        first.cancel()
        #expect(await scheduler.activeCount == 1)
        #expect(await scheduler.waitingCount == 1)
        await gate.release()
        #expect(try await first.value == 7)
        #expect(try await second.value == 2)
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
    }

    @Test func overlappingProviderBatchesShareOnePhysicalLimit() async throws {
        let fixture = try await RealtimeTestFixture(additionalStops: "d,Other stop,49.68,6.15\n")
        defer { fixture.remove() }
        let probe = SharedBoardConcurrency()
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in
            probe.started()
            return .milliseconds(150)
        }) { _ in
            probe.finished()
            return #"{"Departure":[]}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database,
            client: client, maximumConcurrentBoardRequests: 2)
        #expect(provider.sharedBoardRequestCapacity == 2)
        let scheduler = await provider.boardRequestScheduler
        let first = Task { try await provider.patches(for: Self.request(["a", "b"])) }
        try await Self.waitForActive(2, scheduler: scheduler)
        let second = Task { try await provider.patches(for: Self.request(["c", "d"])) }
        try await Self.waitForQueue(2, scheduler: scheduler)
        let batches = try await [first.value, second.value]
        #expect(probe.peak == 2)
        #expect(RealtimeBoardProtocol.requests(host).count == 4)
        for batch in batches {
            #expect(batch.coveredStopIDs == batch.requestedStopIDs)
            #expect(batch.incompleteStopIDs.isEmpty)
            #expect(batch.networkRequests == 2)
        }
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
    }

    @Test func anExpiredQueuedBatchStartsNoHTTPAndLeavesNoPermit() async throws {
        let fixture = try await RealtimeTestFixture()
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in #"{"Departure":[]}"# }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database,
            client: client, maximumConcurrentBoardRequests: 1)
        let scheduler = await provider.boardRequestScheduler
        // Hold the provider's only permit until after expiry, without depending
        // on a response delay to keep another work unit active.
        let gate = BoardSchedulerGate()
        let first = Task { try await scheduler.withPermit { await gate.pause(); return 1 } }
        await gate.waitUntilEntered()
        let expired = try await provider.patches(for: Self.request(["b"],
            deadline: .now.advanced(by: .milliseconds(40))))
        #expect(expired.coveredStopIDs.isEmpty)
        #expect(expired.incompleteStopIDs == ["b"])
        #expect(expired.networkRequests == 0)
        #expect(RealtimeBoardProtocol.requests(host).isEmpty)
        #expect(await scheduler.activeCount == 1)
        #expect(await scheduler.waitingCount == 0)
        await gate.release()
        #expect(try await first.value == 1)
        let recovered = try await provider.patches(for: Self.request(["a"]))
        #expect(recovered.coveredStopIDs == ["a"])
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
    }

    private static func request(_ stops: [String], deadline: ContinuousClock.Instant? = nil) -> RealtimeRoutingRequest {
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        return .init(stopIDs: stops, from: from, through: through, maximumConcurrentRequests: 2, deadline: deadline,
            targets: stops.map { .init(stopID: $0, from: from, through: through, lines: ["201"]) })
    }

    private static func waitForQueue(_ count: Int, scheduler: RealtimeBoardRequestScheduler) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await scheduler.waitingCount != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await scheduler.waitingCount == count)
    }

    private static func waitForActive(_ count: Int, scheduler: RealtimeBoardRequestScheduler) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await scheduler.activeCount != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await scheduler.activeCount == count)
    }
}

private actor BoardSchedulerGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?

    func pause() async {
        notifyEntered()
        await withCheckedContinuation { held = $0 }
    }

    func notifyEntered() {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() { held?.resume(); held = nil }
}

private actor BoardSchedulerOrder {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private final class SharedBoardConcurrency: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var active = 0
    private nonisolated(unsafe) var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func started() { lock.withLock { active += 1; maximum = max(maximum, active) } }
    func finished() { lock.withLock { active -= 1 } }
}
