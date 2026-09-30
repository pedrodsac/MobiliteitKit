import Foundation

struct CachedBoardResponse: Sendable {
    let board: HafasDepartureBoard
    let networkRequests: Int
    let cacheHits: Int
    var fetchedAt: Date = .now
    var httpMilliseconds: Int = 0
    var decodeMilliseconds: Int = 0
}

/// Shares boards and in-flight requests. Each waiter can cancel independently;
/// the URLSession task is cancelled as soon as its last waiter leaves.
actor DepartureBoardCache {
    private struct Entry {
        let board: HafasDepartureBoard
        let fetchedAt: Date
    }
    private struct Flight {
        let key: String
        let refreshPolicy: RealtimeRefreshPolicy
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CachedBoardResponse, any Error>]
        let initiator: UUID
        let startedAt: Date
    }
    private let lifetime: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var flights: [UUID: Flight] = [:]
    private var latestByKey: [String: UUID] = [:]

    init(lifetime: TimeInterval = 60, capacity: Int = 256,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.lifetime = max(0, lifetime)
        self.capacity = max(1, capacity)
        self.now = now
    }

    func value(for key: String, refreshPolicy: RealtimeRefreshPolicy = .useCache,
               fetch: @escaping @Sendable () async throws -> HafasDepartureBoard
    ) async throws -> HafasDepartureBoard {
        try await response(for: key, refreshPolicy: refreshPolicy, fetch: fetch).board
    }

    func response(for key: String, refreshPolicy: RealtimeRefreshPolicy = .useCache,
                  fetch: @escaping @Sendable () async throws -> HafasDepartureBoard
    ) async throws -> CachedBoardResponse {
        try await measuredResponse(for: key, refreshPolicy: refreshPolicy) {
            .init(board: try await fetch(), networkRequests: 1, cacheHits: 0)
        }
    }

    func measuredResponse(for key: String, refreshPolicy: RealtimeRefreshPolicy,
                          fetch: @escaping @Sendable () async throws -> CachedBoardResponse) async throws -> CachedBoardResponse {
        try Task.checkCancellation()
        if refreshPolicy == .useCache, let entry = entries[key],
           now().timeIntervalSince(entry.fetchedAt) < lifetime {
            return .init(board: entry.board, networkRequests: 0, cacheHits: 1, fetchedAt: entry.fetchedAt)
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let id = latestByKey[key], var flight = flights[id],
                   refreshPolicy == .useCache || flight.refreshPolicy == .forceRefresh {
                    flight.waiters[waiter] = continuation
                    flights[id] = flight
                    return
                }
                entries[key] = nil
                let id = UUID()
                let task = Task {
                    let result: Result<CachedBoardResponse, any Error>
                    do {
                        let board = try await fetch()
                        try Task.checkCancellation()
                        result = .success(board)
                    } catch { result = .failure(error) }
                    complete(id, result: result)
                }
                flights[id] = Flight(key: key, refreshPolicy: refreshPolicy, task: task,
                                     waiters: [waiter: continuation], initiator: waiter, startedAt: now())
                latestByKey[key] = id
            }
        } onCancel: {
            Task { await self.cancel(waiter) }
        }
    }

    private func cancel(_ waiter: UUID) {
        guard let id = flights.first(where: { $0.value.waiters[waiter] != nil })?.key,
              var flight = flights[id], let continuation = flight.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights[id] = nil
            if latestByKey[flight.key] == id { latestByKey[flight.key] = nil }
        } else { flights[id] = flight }
    }

    private func complete(_ id: UUID, result: Result<CachedBoardResponse, any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        if latestByKey[flight.key] == id {
            latestByKey[flight.key] = nil
            if case let .success(board) = result {
                entries[flight.key] = Entry(board: board.board, fetchedAt: flight.startedAt)
                if entries.count > capacity,
                   let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                    entries[oldest] = nil
                }
            }
        }
        let networkOwner = flight.waiters[flight.initiator] != nil
            ? flight.initiator : flight.waiters.keys.first
        for (waiter, continuation) in flight.waiters {
            continuation.resume(with: result.map {
                .init(board: $0.board, networkRequests: waiter == networkOwner ? 1 : 0,
                      cacheHits: waiter == networkOwner ? 0 : 1, fetchedAt: flight.startedAt,
                      httpMilliseconds: waiter == networkOwner ? $0.httpMilliseconds : 0,
                      decodeMilliseconds: waiter == networkOwner ? $0.decodeMilliseconds : 0)
            })
        }
    }
}
