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

    private struct Key: Hashable, Sendable {
        let source: Coordinate
        let destination: Coordinate
        let departureBucket: Int64?
    }

    private struct Cached<Value: Sendable>: Sendable {
        let value: Value
        let generation: UInt64
    }

    private let provider: any WalkingRoutingProvider
    private let capacity: Int
    private let departureBucketSeconds: TimeInterval?
    private var generation: UInt64 = 0
    private var routesByKey: [Key: Cached<WalkingRoute>] = [:]
    private var estimatesByKey: [Key: Cached<WalkingEstimate>] = [:]
    private var routeTasks: [Key: Task<WalkingRoute, Error>] = [:]
    private var estimateTasks: [Key: Task<WalkingEstimate, Error>] = [:]
    private var requestCount = 0
    private var hitCount = 0

    init(
        provider: any WalkingRoutingProvider,
        capacity: Int = 4_096,
        departureBucketSeconds: TimeInterval? = nil
    ) {
        self.provider = provider
        self.capacity = max(64, capacity)
        self.departureBucketSeconds = departureBucketSeconds
    }

    func statistics() -> Statistics {
        .init(requests: requestCount, hits: hitCount)
    }

    func correct(_ request: WalkingRequest, with route: WalkingRoute) {
        let key = key(for: request)
        routeTasks[key]?.cancel()
        estimateTasks[key]?.cancel()
        routeTasks[key] = nil
        estimateTasks[key] = nil
        storeRoute(route, for: key)
        storeEstimate(.init(durationSeconds: route.durationSeconds,
                            distanceMeters: route.distanceMeters), for: key)
    }

    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let key = key(for: request)
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
        let key = key(for: request)
        requestCount += 1
        if let cached = routesByKey[key] {
            hitCount += 1
            touchRoute(cached.value, for: key)
            return cached.value
        }
        if let task = routeTasks[key] {
            hitCount += 1
            return try await task.value
        }

        let provider = self.provider
        let task = Task { try await provider.route(request) }
        routeTasks[key] = task
        do {
            let value = try await task.value
            routeTasks[key] = nil
            storeRoute(value, for: key)
            return value
        } catch {
            routeTasks[key] = nil
            throw error
        }
    }

    func routes(
        _ requests: [WalkingRequest],
        maximumConcurrency: Int
    ) async -> [WalkingRoute?] {
        guard !requests.isEmpty else { return [] }
        guard !Task.isCancelled else { return Array(repeating: nil, count: requests.count) }
        var results = Array<WalkingRoute?>(repeating: nil, count: requests.count)
        var tasks = Array<Task<WalkingRoute, Error>?>(repeating: nil, count: requests.count)
        var missingRequests: [WalkingRequest] = []
        var missingKeys: [Key] = []
        var positionsByMissingKey: [Key: [Int]] = [:]

        for (index, request) in requests.enumerated() {
            requestCount += 1
            let key = key(for: request)
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
                let task = Task<WalkingRoute, Error> {
                    let values = await batchTask.value
                    guard values.indices.contains(batchIndex), let value = values[batchIndex] else {
                        throw CacheError.noRoute
                    }
                    return value
                }
                routeTasks[key] = task
                for position in positionsByMissingKey[key] ?? [] { tasks[position] = task }
            }
        }

        await withTaskCancellationHandler {
            for index in requests.indices where results[index] == nil {
                guard !Task.isCancelled else { break }
                guard let task = tasks[index] else { continue }
                let key = key(for: requests[index])
                do {
                    let value = try await task.value
                    guard !Task.isCancelled else { break }
                    results[index] = value
                    routeTasks[key] = nil
                    storeRoute(value, for: key)
                } catch {
                    routeTasks[key] = nil
                }
            }
        } onCancel: {
            batchTask?.cancel()
        }
        if Task.isCancelled {
            for key in missingKeys { routeTasks[key] = nil }
        }
        return results
    }

    private func key(for request: WalkingRequest) -> Key {
        let bucket = departureBucketSeconds.flatMap { width -> Int64? in
            guard width > 0, let departure = request.departure else { return nil }
            return Int64((departure.timeIntervalSinceReferenceDate / width).rounded(.down))
        }
        return .init(
            source: request.source,
            destination: request.destination,
            departureBucket: bucket
        )
    }

    private func touchRoute(_ value: WalkingRoute, for key: Key) {
        generation &+= 1
        routesByKey[key] = .init(value: value, generation: generation)
    }

    private func touchEstimate(_ value: WalkingEstimate, for key: Key) {
        generation &+= 1
        estimatesByKey[key] = .init(value: value, generation: generation)
    }

    private func storeRoute(_ value: WalkingRoute, for key: Key) {
        touchRoute(value, for: key)
        trimIfNeeded()
    }

    private func storeEstimate(_ value: WalkingEstimate, for key: Key) {
        touchEstimate(value, for: key)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        let overflow = routesByKey.count + estimatesByKey.count - capacity
        guard overflow > 0 else { return }
        let oldestRoutes = routesByKey.map { (kind: 0, key: $0.key, generation: $0.value.generation) }
        let oldestEstimates = estimatesByKey.map { (kind: 1, key: $0.key, generation: $0.value.generation) }
        for item in (oldestRoutes + oldestEstimates).sorted(by: { $0.generation < $1.generation }).prefix(overflow) {
            if item.kind == 0 { routesByKey[item.key] = nil }
            else { estimatesByKey[item.key] = nil }
        }
    }
}
