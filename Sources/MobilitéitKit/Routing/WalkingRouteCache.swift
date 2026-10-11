import Foundation

/// A small shared cache around walking providers. It coalesces identical
/// in-flight work, which matters because the same interchange can be reached by
/// several RAPTOR labels and in several rounds.
actor WalkingRouteCache: WalkingRoutingProvider {
    private enum CacheError: Error { case noRoute }

    struct Statistics: Sendable {
        let requests: Int
        let hits: Int
    }

    private enum PendingRoute: Sendable {
        case single(Task<WalkingRoute, Error>)
        case batch(Task<[WalkingRoute?], Never>, Int)
        var value: WalkingRoute {
            get async throws {
                switch self {
                case .single(let task): return try await task.value
                case .batch(let task, let index):
                    let values = await task.value
                    guard values.indices.contains(index), let value = values[index] else { throw CacheError.noRoute }
                    return value
                }
            }
        }
        func cancelSingle() { if case .single(let task) = self { task.cancel() } }
    }
    private struct RouteFlight: Sendable {
        let id: UInt64
        let pending: PendingRoute
    }
    private var nextFlightID: UInt64 = 0

    private struct Key: Hashable, Sendable {
        let source: Coordinate
        let destination: Coordinate
        let departureBucket: Int64?
        let revision: String?
    }

    private struct Cached<Value: Sendable>: Sendable {
        let value: Value
        let generation: UInt64
    }

    private struct Access: Sendable {
        let key: Key
        let isRoute: Bool
        let generation: UInt64
    }

    private var accesses: [Access] = []
    private var accessCursor = 0
    private let provider: any WalkingRoutingProvider
    private let capacity: Int
    private let departureBucketSeconds: TimeInterval?
    private var generation: UInt64 = 0
    private var routesByKey: [Key: Cached<WalkingRoute>] = [:]
    private var estimatesByKey: [Key: Cached<WalkingEstimate>] = [:]
    private var routeTasks: [Key: RouteFlight] = [:]
    private var estimateTasks: [Key: Task<WalkingEstimate, Error>] = [:]
    private var requestCount = 0
    private var hitCount = 0

    init(
        provider: any WalkingRoutingProvider,
        capacity: Int = 8_192,
        departureBucketSeconds: TimeInterval? = nil
    ) {
        self.provider = provider
        self.capacity = max(64, capacity)
        self.departureBucketSeconds = departureBucketSeconds
    }

    func statistics() -> Statistics {
        .init(requests: requestCount, hits: hitCount)
    }

    func correct(_ request: WalkingRequest, with route: WalkingRoute) async {
        let revision = await provider.cacheRevision()
        let key = key(for: request, revision: revision)
        routeTasks[key]?.pending.cancelSingle()
        estimateTasks[key]?.cancel()
        routeTasks[key] = nil
        estimateTasks[key] = nil
        storeRoute(route, for: key)
        storeEstimate(.init(durationSeconds: route.durationSeconds,
                            distanceMeters: route.distanceMeters), for: key)
    }

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let revision = await provider.cacheRevision()
        let key = key(for: request, revision: revision)
        requestCount += 1
        if let cached = estimatesByKey[key] {
            hitCount += 1
            touchEstimate(cached.value, for: key)
            return cached.value
        }
        if let task = estimateTasks[key] {
            hitCount += 1
            return try await task.value
        }

        let provider = self.provider
        let task = Task { try await provider.estimate(request) }
        estimateTasks[key] = task
        do {
            let value = try await task.value
            estimateTasks[key] = nil
            storeEstimate(value, for: key)
            return value
        } catch {
            estimateTasks[key] = nil
            throw error
        }
    }

    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        let revision = await provider.cacheRevision()
        let key = key(for: request, revision: revision)
        requestCount += 1
        if let cached = routesByKey[key] {
            hitCount += 1
            touchRoute(cached.value, for: key)
            return cached.value
        }
        if let flight = routeTasks[key] {
            hitCount += 1
            return try await resolve(flight, for: key)
        }
        let provider = self.provider
        let flight = makeFlight(.single(Task { try await provider.route(request) }))
        routeTasks[key] = flight
        return try await resolve(flight, for: key)
    }

    private func makeFlight(_ pending: PendingRoute) -> RouteFlight {
        nextFlightID &+= 1
        return .init(id: nextFlightID, pending: pending)
    }

    private func resolve(_ flight: RouteFlight, for key: Key) async throws -> WalkingRoute {
        do {
            let value = try await flight.pending.value
            if routeTasks[key]?.id == flight.id {
                routeTasks[key] = nil
                storeRoute(value, for: key)
                return value
            }
            // A refinement may have replaced this route while its shared batch
            // was running. Late work must not overwrite the corrected path.
            return routesByKey[key]?.value ?? value
        } catch {
            if routeTasks[key]?.id == flight.id { routeTasks[key] = nil }
            if let corrected = routesByKey[key]?.value { return corrected }
            throw error
        }
    }

    func routes(
        _ requests: [WalkingRequest],
        maximumConcurrency: Int
    ) async -> [WalkingRoute?] {
        guard !requests.isEmpty else { return [] }
        guard !Task.isCancelled else { return Array(repeating: nil, count: requests.count) }
        let revision = await provider.cacheRevision()
        var results = Array<WalkingRoute?>(repeating: nil, count: requests.count)
        var tasks = Array<RouteFlight?>(repeating: nil, count: requests.count)
        var missingRequests: [WalkingRequest] = []
        var missingKeys: [Key] = []
        var positionsByMissingKey: [Key: [Int]] = [:]

        for (index, request) in requests.enumerated() {
            requestCount += 1
            let key = key(for: request, revision: revision)
            if let cached = routesByKey[key] {
                hitCount += 1
                touchRoute(cached.value, for: key)
                results[index] = cached.value
            } else if let task = routeTasks[key] {
                hitCount += 1
                tasks[index] = task
            } else if positionsByMissingKey[key] != nil {
                hitCount += 1
                positionsByMissingKey[key, default: []].append(index)
            } else {
                missingKeys.append(key)
                missingRequests.append(request)
                positionsByMissingKey[key] = [index]
            }
        }

        let provider = self.provider
        let batchTask: Task<[WalkingRoute?], Never>? = !missingRequests.isEmpty && !Task.isCancelled
            ? Task { await provider.routes(missingRequests, maximumConcurrency: maximumConcurrency) }
            : nil
        if let batchTask {
            for (batchIndex, key) in missingKeys.enumerated() {
                // One shared batch future, indexed directly. A forwarding Task
                // for each pair only wakes thousands of redundant continuations.
                let flight = makeFlight(.batch(batchTask, batchIndex))
                routeTasks[key] = flight
                for position in positionsByMissingKey[key] ?? [] { tasks[position] = flight }
            }
        }

        await withTaskCancellationHandler {
            for index in requests.indices where results[index] == nil {
                guard !Task.isCancelled else { break }
                guard let task = tasks[index] else { continue }
                let key = key(for: requests[index], revision: revision)
                do {
                    let value = try await resolve(task, for: key)
                    guard !Task.isCancelled else { break }
                    results[index] = value
                } catch { }
            }
        } onCancel: {
            batchTask?.cancel()
        }
        if Task.isCancelled {
            for key in missingKeys {
                if let index = positionsByMissingKey[key]?.first, let flight = tasks[index],
                   routeTasks[key]?.id == flight.id { routeTasks[key] = nil }
            }
        }
        return results
    }

    private func key(for request: WalkingRequest, revision: String?) -> Key {
        let bucket = departureBucketSeconds.flatMap { width -> Int64? in
            guard width > 0, let departure = request.departure else { return nil }
            return Int64((departure.timeIntervalSinceReferenceDate / width).rounded(.down))
        }
        return .init(
            source: request.source,
            destination: request.destination,
            departureBucket: bucket, revision: revision
        )
    }

    private func touchRoute(_ value: WalkingRoute, for key: Key) {
        generation &+= 1
        routesByKey[key] = .init(value: value, generation: generation)
        recordAccess(key, isRoute: true)
    }

    private func touchEstimate(_ value: WalkingEstimate, for key: Key) {
        generation &+= 1
        estimatesByKey[key] = .init(value: value, generation: generation)
        recordAccess(key, isRoute: false)
    }

    private func storeRoute(_ value: WalkingRoute, for key: Key) {
        touchRoute(value, for: key)
        trimIfNeeded()
    }

    private func storeEstimate(_ value: WalkingEstimate, for key: Key) {
        touchEstimate(value, for: key)
        trimIfNeeded()
    }

    private func isCurrent(_ access: Access) -> Bool {
        (access.isRoute ? routesByKey[access.key]?.generation
            : estimatesByKey[access.key]?.generation) == access.generation
    }

    private func recordAccess(_ key: Key, isRoute: Bool) {
        accesses.append(.init(key: key, isRoute: isRoute, generation: generation))
        // Lazy LRU records avoid sorting the full cache on every overflow.
        // Compact on hits too, keeping repeated access to a hot key bounded.
        if accesses.count >= capacity * 4 {
            accesses = accesses[accessCursor...].filter { isCurrent($0) }
            accessCursor = 0
        }
    }

    private func trimIfNeeded() {
        while routesByKey.count + estimatesByKey.count > capacity {
            let access = accesses[accessCursor]
            accessCursor += 1
            guard isCurrent(access) else { continue }
            if access.isRoute { routesByKey[access.key] = nil }
            else { estimatesByKey[access.key] = nil }
        }
    }
}
