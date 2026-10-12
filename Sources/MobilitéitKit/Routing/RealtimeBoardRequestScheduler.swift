import Foundation

/// Only providers that enforce this capacity across overlapping requests may
/// let discovery borrow the slots otherwise reserved for selected vehicles.
protocol SharedRealtimeBoardScheduling: RealtimeRoutingProvider {
    nonisolated var sharedBoardRequestCapacity: Int { get }
}

extension HafasRealtimeRoutingProvider: SharedRealtimeBoardScheduling {
    nonisolated var sharedBoardRequestCapacity: Int { maximumConcurrentBoardRequests }
}

/// A work unit owns one permit until all of its sequential HTTP/cache slices
/// finish. Queued cancellation never releases a permit held by running work.
actor RealtimeBoardRequestScheduler {
    private let capacity: Int
    private var active: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<UUID, any Error>] = [:]
    private var order: [UUID] = []
    private var cursor = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var activeCount: Int { active.count }
    var waitingCount: Int { waiters.count }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = try await acquire()
        do {
            // Cancellation may race with a queued waiter receiving its permit.
            try Task.checkCancellation()
            let value = try await operation()
            release(id)
            return value
        } catch {
            release(id)
            throw error
        }
    }

    private func acquire() async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if active.count < capacity {
                    active.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiters[id] = continuation
                    order.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if waiters.isEmpty {
            order.removeAll(keepingCapacity: true)
            cursor = 0
        }
    }

    private func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        while cursor < order.count {
            let next = order[cursor]
            cursor += 1
            guard let waiter = waiters.removeValue(forKey: next) else { continue }
            active.insert(next)
            waiter.resume(returning: next)
            break
        }
        if cursor == order.count {
            order.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor >= 256, cursor * 2 >= order.count {
            order.removeFirst(cursor)
            cursor = 0
        }
    }
}
