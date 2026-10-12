import Foundation

/// Shares boards and in-flight requests. Each waiter can cancel independently;
/// the URLSession task is cancelled as soon as its last waiter leaves.
actor DepartureBoardCache {
    private struct CoverageUnavailable: Error {}
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
        var invalidated = false
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
                          minimumFetchedAt: Date? = nil,
                          fetch: @escaping @Sendable () async throws -> CachedBoardResponse) async throws -> CachedBoardResponse {
        try Task.checkCancellation()
        if refreshPolicy == .useCache, let entry = entries[key],
           fresh(entry.response.fetchedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt) {
            var response = entry.response
            response = response.restricted(to: scope)
            response = cacheHit(response)
            return response
        }
        if refreshPolicy == .useCache, let scope, scope.unlimited,
           let entry = entries.values.filter({
               $0.response.isComplete && $0.response.scope?.contains(scope) == true
                   && fresh($0.response.fetchedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt)
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
                        !$0.value.invalidated && $0.value.scope?.unlimited == true && $0.value.scope?.contains(scope) == true
                            && $0.value.scopeRevision == scopeRevisions[scope.namespace, default: 0]
                            && (refreshPolicy == .useCache || $0.value.refreshPolicy == .forceRefresh)
                            && fresh($0.value.startedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt)
                    }?.key
                }
                if let id = compatibleFlight ?? latestByKey[key], var flight = flights[id],
                   !flight.invalidated,
                   (refreshPolicy == .useCache || flight.refreshPolicy == .forceRefresh),
                   fresh(flight.startedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt),
                   flight.scope.map({ scopeRevisions[$0.namespace, default: 0] == flight.scopeRevision }) ?? true {
                    flight.waiters[waiter] = continuation
                    flights[id] = flight
                    return
                }
                entries[key] = nil
                if refreshPolicy == .forceRefresh, let scope {
                    // A filtered refresh also supersedes older broader filters
                    // that could otherwise reintroduce rows from this interval.
                    let invalidatedNamespaces = (entries.values.compactMap { $0.response.scope }
                        + flights.values.compactMap(\.scope))
                        .filter { scopesOverlap($0, scope) }.map(\.namespace)
                    for namespace in Set(invalidatedNamespaces).union([scope.namespace]) {
                        scopeRevisions[namespace, default: 0] &+= 1
                    }
                    entries = entries.filter { entry in
                        guard let prior = entry.value.response.scope else { return true }
                        return !scopesOverlap(prior, scope)
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

    private func scopesOverlap(_ first: BoardCacheScope, _ second: BoardCacheScope) -> Bool {
        guard first.namespaceWithoutLines == second.namespaceWithoutLines,
              first.interval.end >= second.interval.start, first.interval.start <= second.interval.end else { return false }
        return first.selectedLines.isEmpty || second.selectedLines.isEmpty
            || !Set(first.selectedLines).isDisjoint(with: second.selectedLines)
    }

    private func fresh(_ acquired: Date, maximumCacheAge: TimeInterval, since minimum: Date?) -> Bool {
        now().timeIntervalSince(acquired) < min(lifetime, maximumCacheAge)
            && minimum.map { acquired >= $0 } != false
    }

    /// Retire only evidence that predates this calculation. A namespace revision
    /// would also retire newer flights, so scoped refresh marks old flights alone.
    func retireCoverage(before boundary: Date, overlapping scope: BoardCacheScope) {
        entries = entries.filter { _, entry in
            guard entry.response.fetchedAt < boundary, let prior = entry.response.scope else { return true }
            return !scopesOverlap(prior, scope)
        }
        for (id, var flight) in flights {
            guard flight.startedAt < boundary, let prior = flight.scope, scopesOverlap(prior, scope) else { continue }
            flight.invalidated = true
            flights[id] = flight
        }
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

    /// Different board partitions can together cover a later line filter. Every
    /// selected source must cover the entire interval; temporal gap reuse stays
    /// in intervalResponse. Cached sources take precedence over pending work.
    func lineCoverageParts(for scope: BoardCacheScope,
                           maximumCacheAge: TimeInterval, minimumFetchedAt: Date? = nil) -> [DepartureBoardLineCoveragePart] {
        guard scope.unlimited, !scope.selectedLines.isEmpty else { return [] }
        func compatible(_ prior: BoardCacheScope?, acquired: Date) -> Bool {
            guard let prior, prior.unlimited, prior.namespaceWithoutLines == scope.namespaceWithoutLines,
                  prior.interval.start <= scope.interval.start, prior.interval.end >= scope.interval.end else { return false }
            return fresh(acquired, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt)
        }
        var candidates: [DepartureBoardLineCoveragePart.Candidate] = entries.compactMap { key, entry in
            let value = entry.response
            guard value.isComplete, compatible(value.scope, acquired: value.fetchedAt),
                  value.board.departures.values.allSatisfy({ $0.product?.line?.isEmpty == false }) else { return nil }
            return .init(source: .cached(key), scope: value.scope!, acquired: value.fetchedAt, cached: true)
        }
        candidates += flights.compactMap { id, flight in
            guard !flight.invalidated, compatible(flight.scope, acquired: flight.startedAt), let prior = flight.scope,
                  flight.scopeRevision == scopeRevisions[prior.namespace, default: 0] else { return nil }
            return .init(source: .flight(id), scope: prior, acquired: flight.startedAt, cached: false)
        }
        return DepartureBoardLineCoveragePart.select(candidates, for: scope)
    }

    /// Slice at reusable temporal boundaries before composing line partitions.
    /// A wider line filter can then supply its overlap without fetching its tail.
    func lineCoverageIntervals(for scope: BoardCacheScope, maximumCacheAge: TimeInterval,
                               minimumFetchedAt: Date? = nil) -> [DateInterval] {
        let requested = Set(scope.selectedLines)
        func compatible(_ prior: BoardCacheScope?) -> Bool {
            guard let prior, prior.unlimited, prior.namespaceWithoutLines == scope.namespaceWithoutLines,
                  prior.interval.end > scope.interval.start, prior.interval.start < scope.interval.end else { return false }
            return prior.selectedLines.isEmpty || !requested.isDisjoint(with: prior.selectedLines)
        }
        let cached = entries.values.compactMap { entry -> DateInterval? in
            let response = entry.response
            guard response.isComplete, compatible(response.scope),
                  fresh(response.fetchedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt),
                  response.board.departures.values.allSatisfy({ $0.product?.line?.isEmpty == false }) else { return nil }
            return response.scope!.interval
        }
        let pending = flights.values.compactMap { flight -> DateInterval? in
            guard !flight.invalidated, compatible(flight.scope), let prior = flight.scope,
                  flight.scopeRevision == scopeRevisions[prior.namespace, default: 0],
                  fresh(flight.startedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt) else { return nil }
            return prior.interval
        }
        let boundaries = Set([scope.interval.start, scope.interval.end] + (cached + pending).flatMap {
            [$0.start, $0.end].filter { $0 > scope.interval.start && $0 < scope.interval.end }
        }).sorted()
        return zip(boundaries, boundaries.dropFirst()).map { .init(start: $0, end: $1) }
    }

    /// Takes only existing work. A source lost to cancellation, expiry, or a
    /// refresh returns nil so the caller can acquire its original missing lines.
    func reuseLineCoveragePart(_ part: DepartureBoardLineCoveragePart,
                               maximumCacheAge: TimeInterval, minimumFetchedAt: Date? = nil) async throws -> CachedBoardResponse? {
        try Task.checkCancellation()
        // A selected flight may have completed while an earlier partition was
        // awaited. Its complete cached response is still the same reusable work.
        if let response = entries.values.map(\.response).filter({
            $0.isComplete && $0.scope?.contains(part.scope) == true
                && fresh($0.fetchedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt)
        }).max(by: { $0.fetchedAt < $1.fetchedAt }) {
            return cacheHit(response.restricted(to: part.scope))
        }
        switch part.source {
        case .cached: return nil
        case let .flight(id):
            let waiter = UUID()
            do {
                let response: CachedBoardResponse = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                        guard var flight = flights[id], !flight.invalidated, flight.scope?.contains(part.scope) == true,
                              flight.scopeRevision == scopeRevisions[part.scope.namespace, default: 0],
                              fresh(flight.startedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt) else {
                            continuation.resume(throwing: CoverageUnavailable()); return
                        }
                        flight.waiters[waiter] = continuation
                        flights[id] = flight
                    }
                } onCancel: { Task { await self.cancel(waiter) } }
                return response.restricted(to: part.scope)
            } catch is CoverageUnavailable { return nil }
        }
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
                          minimumFetchedAt: Date? = nil,
                          fetch: @escaping @Sendable (DateInterval) async throws -> CachedBoardResponse) async throws -> CachedBoardResponse {
        try Task.checkCancellation()
        if refreshPolicy == .forceRefresh, let minimumFetchedAt {
            retireCoverage(before: minimumFetchedAt, overlapping: scope)
        }
        if (refreshPolicy == .forceRefresh && minimumFetchedAt == nil) || !scope.unlimited {
            return try await fetch(scope.interval)
        }
        let cached = entries.values.map(\.response).filter {
            $0.isComplete && $0.scope?.namespace == scope.namespace
                && fresh($0.fetchedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt)
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
        for gap in coalescedGaps(gaps, namespace: scope.namespace, maximumCacheAge: maximumCacheAge, minimumFetchedAt: minimumFetchedAt) {
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
                     transport: pieces.flatMap(\.transport),
                     scope: scope, isComplete: failedRequests == 0 && pieces.allSatisfy(\.isComplete), observations: observations)
    }

    /// Split an uncovered range at compatible flight boundaries. Its covered
    /// pieces join those flights; only the tails start additional requests.
    private func coalescedGaps(_ gaps: [DateInterval], namespace: String,
                               maximumCacheAge: TimeInterval, minimumFetchedAt: Date?) -> [DateInterval] {
        let pending = flights.values.compactMap { flight -> DateInterval? in
            guard !flight.invalidated, let scope = flight.scope, scope.unlimited, scope.namespace == namespace,
                  fresh(flight.startedAt, maximumCacheAge: maximumCacheAge, since: minimumFetchedAt),
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

    private func cancel(_ waiter: UUID) async {
        guard let id = flights.first(where: { $0.value.waiters[waiter] != nil })?.key,
              var flight = flights[id], let continuation = flight.waiters.removeValue(forKey: waiter)
        else { return }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights[id] = nil
            if latestByKey[flight.key] == id { latestByKey[flight.key] = nil }
        } else { flights[id] = flight }
        pruneRevisions()
        // The final caller may own a transport permit. Keep that ownership
        // until the cancelled fetch exits; a surviving caller already owns it.
        if flight.waiters.isEmpty { await flight.task.value }
        continuation.resume(throwing: CancellationError())
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
            if !flight.invalidated, case let .success(board) = stamped,
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
                      transport: waiter == networkOwner ? $0.transport : [],
                      scope: $0.scope, isComplete: $0.isComplete, observations: $0.observations)
            })
        }
    }
}
