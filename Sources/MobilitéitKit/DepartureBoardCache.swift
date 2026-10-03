import Foundation

struct CachedBoardResponse: Sendable {
    var board: HafasDepartureBoard
    let networkRequests: Int
    let cacheHits: Int
    var fetchedAt: Date = .now
    var httpMilliseconds: Int = 0
    var decodeMilliseconds: Int = 0
    var scope: BoardCacheScope? = nil
    var isComplete: Bool = false
    var observations: [String: Date] = [:]

    func restricted(to requested: BoardCacheScope?) -> Self {
        guard let requested, let scope, scope.contains(requested) else { return self }
        var result = self
        let filter = BoardIntervalFilter()
        result.board = .init(departures: board.departures.values.filter {
            filter.contains($0, in: requested.interval)
        }, responseBytes: board.responseBytes)
        result.scope = requested
        return result
    }
}

/// Shares boards and in-flight requests. Each waiter can cancel independently;
/// the URLSession task is cancelled as soon as its last waiter leaves.
actor DepartureBoardCache {
    private struct Entry { let response: CachedBoardResponse }
    private struct Flight {
        let key: String
        let refreshPolicy: RealtimeRefreshPolicy
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CachedBoardResponse, any Error>]
        let initiator: UUID
        let startedAt: Date
        let scope: BoardCacheScope?
        let scopeRevision: UInt64
    }
    private let lifetime: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var flights: [UUID: Flight] = [:]
    private var latestByKey: [String: UUID] = [:]
    private var scopeRevisions: [String: UInt64] = [:]

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
                          scope: BoardCacheScope? = nil, maximumCacheAge: TimeInterval = 60,
                          fetch: @escaping @Sendable () async throws -> CachedBoardResponse) async throws -> CachedBoardResponse {
        try Task.checkCancellation()
        if refreshPolicy == .useCache, let entry = entries[key],
           now().timeIntervalSince(entry.response.fetchedAt) < min(lifetime, maximumCacheAge) {
            var response = entry.response
            response = response.restricted(to: scope)
            response = cacheHit(response)
            return response
        }
        if refreshPolicy == .useCache, let scope, scope.unlimited,
           let entry = entries.values.filter({
               $0.response.isComplete && $0.response.scope?.contains(scope) == true
                   && now().timeIntervalSince($0.response.fetchedAt) < min(lifetime, maximumCacheAge)
           }).max(by: { $0.response.fetchedAt < $1.response.fetchedAt }) {
            return cacheHit(entry.response.restricted(to: scope))
        }
        let waiter = UUID()
        let response: CachedBoardResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CachedBoardResponse, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let compatibleFlight = scope.flatMap { scope in
                    guard scope.unlimited else { return nil as UUID? }
                    return flights.first {
                        $0.value.scope?.unlimited == true && $0.value.scope?.contains(scope) == true
                            && $0.value.scopeRevision == scopeRevisions[scope.namespace, default: 0]
                            && (refreshPolicy == .useCache || $0.value.refreshPolicy == .forceRefresh)
                    }?.key
                }
                if let id = compatibleFlight ?? latestByKey[key], var flight = flights[id],
                   (refreshPolicy == .useCache || flight.refreshPolicy == .forceRefresh),
                   flight.scope.map({ scopeRevisions[$0.namespace, default: 0] == flight.scopeRevision }) ?? true {
                    flight.waiters[waiter] = continuation
                    flights[id] = flight
                    return
                }
                entries[key] = nil
                if refreshPolicy == .forceRefresh, let scope {
                    scopeRevisions[scope.namespace, default: 0] &+= 1
                    entries = entries.filter { entry in
                        guard let prior = entry.value.response.scope, prior.namespace == scope.namespace else { return true }
                        return prior.interval.end < scope.interval.start || prior.interval.start > scope.interval.end
                    }
                }
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
                                     waiters: [waiter: continuation], initiator: waiter, startedAt: now(),
                                     scope: scope, scopeRevision: scope.map { scopeRevisions[$0.namespace, default: 0] } ?? 0)
                latestByKey[key] = id
            }
        } onCancel: {
            Task { await self.cancel(waiter) }
        }
        return response.restricted(to: scope)
    }

    /// Metadata-only lookup lets acquisition consume fresh boards before
    /// unrelated network waits occupy all of its bounded request slots.
    func coverage(of scope: BoardCacheScope, maximumCacheAge: TimeInterval = 60) -> Double {
        guard scope.unlimited, scope.interval.duration > 0 else { return 0 }
        let intervals = entries.values.compactMap { entry -> DateInterval? in
            guard entry.response.isComplete, let prior = entry.response.scope,
                  prior.namespace == scope.namespace,
                  now().timeIntervalSince(entry.response.fetchedAt) < min(lifetime, maximumCacheAge) else { return nil }
            return prior.interval
        }.sorted { $0.start < $1.start }
        var position = scope.interval.start
        var seconds: TimeInterval = 0
        for interval in intervals {
            let start = max(position, interval.start)
            let end = min(scope.interval.end, interval.end)
            if end > start { seconds += end.timeIntervalSince(start); position = end }
            if position >= scope.interval.end { break }
        }
        return min(1, seconds / scope.interval.duration)
    }

    private func cacheHit(_ response: CachedBoardResponse) -> CachedBoardResponse {
        var value = response
        value = .init(board: value.board, networkRequests: 0, cacheHits: 1,
                      fetchedAt: value.fetchedAt, scope: value.scope, isComplete: value.isComplete,
                      observations: value.observations)
        return value
    }

    /// Reuse proven complete coverage and acquire only its gaps. Flight sharing
    /// remains in measuredResponse, including containing unrestricted requests.
    func intervalResponse(scope: BoardCacheScope, refreshPolicy: RealtimeRefreshPolicy,
                          preservePartialOnFailure: Bool = false, maximumCacheAge: TimeInterval = 60,
                          fetch: @escaping @Sendable (DateInterval) async throws -> CachedBoardResponse) async throws -> CachedBoardResponse {
        try Task.checkCancellation()
        if refreshPolicy == .forceRefresh || !scope.unlimited {
            return try await fetch(scope.interval)
        }
        let cached = entries.values.map(\.response).filter {
            $0.isComplete && $0.scope?.namespace == scope.namespace
                && now().timeIntervalSince($0.fetchedAt) < min(lifetime, maximumCacheAge)
                && $0.scope!.interval.end > scope.interval.start
                && $0.scope!.interval.start < scope.interval.end
        }.sorted { $0.scope!.interval.start < $1.scope!.interval.start }
        var position = scope.interval.start
        var pieces = cached.map(cacheHit)
        var gaps: [DateInterval] = []
        for entry in cached {
            let interval = entry.scope!.interval
            if interval.start > position {
                gaps.append(.init(start: position, end: min(interval.start, scope.interval.end)))
            }
            position = max(position, interval.end)
            if position >= scope.interval.end { break }
        }
        if position < scope.interval.end {
            gaps.append(.init(start: position, end: scope.interval.end))
        }
        var failedRequests = 0
        for gap in coalescedGaps(gaps, namespace: scope.namespace) {
            do { pieces.append(try await fetch(gap)) }
            catch {
                guard preservePartialOnFailure, !pieces.isEmpty else { throw error }
                failedRequests += 1
                break
            }
        }
        let filter = BoardIntervalFilter()
        var departures: [String: HafasDeparture] = [:]
        var observations: [String: Date] = [:]
        for piece in pieces.sorted(by: { $0.fetchedAt < $1.fetchedAt }) {
            for departure in piece.board.departures.values where filter.contains(departure, in: scope.interval) {
                let identity = departure.cacheIdentity
                departures[identity] = departure
                observations[identity] = piece.observations[identity] ?? piece.fetchedAt
            }
        }
        return .init(board: .init(departures: Array(departures.values),
                                 responseBytes: pieces.filter { $0.networkRequests > 0 }.reduce(0) { $0 + $1.board.responseBytes }),
                     networkRequests: pieces.reduce(failedRequests) { $0 + $1.networkRequests },
                     cacheHits: pieces.reduce(0) { $0 + $1.cacheHits },
                     fetchedAt: pieces.map(\.fetchedAt).min() ?? now(),
                     httpMilliseconds: pieces.reduce(0) { $0 + $1.httpMilliseconds },
                     decodeMilliseconds: pieces.reduce(0) { $0 + $1.decodeMilliseconds },
                     scope: scope, isComplete: failedRequests == 0 && pieces.allSatisfy(\.isComplete), observations: observations)
    }

    /// Split an uncovered range at compatible flight boundaries. Its covered
    /// pieces join those flights; only the tails start additional requests.
    private func coalescedGaps(_ gaps: [DateInterval], namespace: String) -> [DateInterval] {
        let pending = flights.values.compactMap { flight -> DateInterval? in
            guard let scope = flight.scope, scope.unlimited, scope.namespace == namespace,
                  flight.scopeRevision == scopeRevisions[namespace, default: 0] else { return nil }
            return scope.interval
        }
        return gaps.flatMap { gap in
            let boundaries = Set([gap.start, gap.end] + pending.flatMap { interval in
                [interval.start, interval.end].filter { $0 > gap.start && $0 < gap.end }
            }).sorted()
            return zip(boundaries, boundaries.dropFirst()).map { DateInterval(start: $0, end: $1) }
        }
    }

    private func pruneRevisions() {
        let active = Set(entries.values.compactMap { $0.response.scope?.namespace })
            .union(flights.values.compactMap { $0.scope?.namespace })
        scopeRevisions = scopeRevisions.filter { active.contains($0.key) }
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
        pruneRevisions()
    }

    private func complete(_ id: UUID, result: Result<CachedBoardResponse, any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        let stamped = result.map { response in
            var value = response
            value.fetchedAt = flight.startedAt
            value.scope = flight.scope
            value.isComplete = flight.scope?.complete(value.board) ?? false
            value.observations = Dictionary(value.board.departures.values.map {
                ($0.cacheIdentity, flight.startedAt)
            }, uniquingKeysWith: min)
            return value
        }
        if latestByKey[flight.key] == id {
            latestByKey[flight.key] = nil
            if case let .success(board) = stamped,
               flight.scope.map({ scopeRevisions[$0.namespace, default: 0] == flight.scopeRevision }) ?? true {
                entries[flight.key] = Entry(response: board)
                if entries.count > capacity,
                   let oldest = entries.min(by: { $0.value.response.fetchedAt < $1.value.response.fetchedAt })?.key {
                    entries[oldest] = nil
                }
            }
        }
        pruneRevisions()
        let networkOwner = flight.waiters[flight.initiator] != nil
            ? flight.initiator : flight.waiters.keys.first
        for (waiter, continuation) in flight.waiters {
            continuation.resume(with: stamped.map {
                .init(board: $0.board, networkRequests: waiter == networkOwner ? 1 : 0,
                      cacheHits: waiter == networkOwner ? 0 : 1, fetchedAt: flight.startedAt,
                      httpMilliseconds: waiter == networkOwner ? $0.httpMilliseconds : 0,
                      decodeMilliseconds: waiter == networkOwner ? $0.decodeMilliseconds : 0,
                      scope: $0.scope, isComplete: $0.isComplete, observations: $0.observations)
            })
        }
    }
}
