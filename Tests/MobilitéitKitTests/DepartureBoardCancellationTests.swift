import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DepartureBoardCancellationTests {
    @Test func lastWaiterRetainsItsPermitUntilTheCancelledFetchExits() async throws {
        let cache = DepartureBoardCache()
        let scheduler = RealtimeBoardRequestScheduler(capacity: 1)
        let gate = CancelledBoardFetchGate()
        let first = Task {
            try await scheduler.withPermit {
                try await cache.value(for: "abandoned") {
                    await withTaskCancellationHandler {
                        await gate.pause()
                        return HafasDepartureBoard(departures: [])
                    } onCancel: {
                        Task { await gate.observeCancellation() }
                    }
                }
            }
        }
        await gate.waitUntilEntered()
        let replacement = Task { try await scheduler.withPermit { 2 } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await scheduler.waitingCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await scheduler.waitingCount == 1)
        first.cancel()
        await gate.waitUntilCancelled()
        // Cancellation has reached the fetch, which cannot exit before release.
        #expect(await scheduler.activeCount == 1)
        #expect(await scheduler.waitingCount == 1)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await replacement.value == 2)
        #expect(await scheduler.activeCount == 0)
        #expect(await scheduler.waitingCount == 0)
        let response = try await cache.value(for: "abandoned") {
            HafasDepartureBoard(departures: [], responseBytes: 7)
        }
        #expect(response.responseBytes == 7)
    }
}

private actor CancelledBoardFetchGate {
    private var entered = false
    private var cancelled = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { held = $0 }
    }

    func observeCancellation() {
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() { held?.resume(); held = nil }
}
