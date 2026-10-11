import Foundation
import Testing
@testable import MobiliteitKit

struct WalkingBatchCacheTests {
    @Test func batchCoalescesDuplicatesAndSingleRequestsAndPreservesCorrection() async throws {
        let provider = BatchCacheProvider()
        let cache = WalkingRouteCache(provider: provider)
        let a = request(1), b = request(2)
        let batch = Task { await cache.routes([a, a, b], maximumConcurrency: 4) }
        await provider.waitUntilStarted()
        let single = Task { try await cache.route(a) }
        let correction = WalkingRoute(durationSeconds: 120, distanceMeters: 200, polyline: [b.source, b.destination])
        await cache.correct(b, with: correction)
        await provider.release()
        let routes = await batch.value
        #expect(routes[0]?.durationSeconds == 60 && routes[1] == routes[0])
        #expect(routes[2] == correction)
        #expect(try await single.value == routes[0])
        #expect(try await cache.route(b) == correction)
        #expect(await provider.batchCalls == 1)
        #expect(await provider.singleCalls == 0)
    }

    @Test func cancelledBatchCanRetryMissingPairs() async {
        let provider = BatchCacheProvider()
        let cache = WalkingRouteCache(provider: provider)
        let batch = Task { await cache.routes([request(1), request(2)], maximumConcurrency: 2) }
        await provider.waitUntilStarted()
        batch.cancel()
        await provider.release()
        #expect(await batch.value == [nil, nil])
        let retried = await cache.routes([request(1), request(2)], maximumConcurrency: 2)
        #expect(retried.allSatisfy { $0?.durationSeconds == 60 })
        #expect(await provider.batchCalls == 2)
    }

    @Test func cancelledSubscriberDoesNotRemoveAnotherBatchFlight() async throws {
        let provider = BatchCacheProvider()
        let cache = WalkingRouteCache(provider: provider)
        let a = request(1), b = request(2)
        let owner = Task { await cache.routes([a, b], maximumConcurrency: 2) }
        await provider.waitUntilStarted()
        let subscriber = Task { await cache.routes([a], maximumConcurrency: 2) }
        for _ in 0..<1_000 {
            if await cache.statistics().requests == 3 { break }
            await Task.yield()
        }
        #expect(await cache.statistics().requests == 3)
        subscriber.cancel()
        await provider.release()
        #expect(await subscriber.value == [nil])
        #expect(await owner.value.allSatisfy { $0?.durationSeconds == 60 })
        #expect(try await cache.route(a).durationSeconds == 60)
        #expect(await provider.singleCalls == 0)
        #expect(await provider.batchCalls == 1)
    }

    private func request(_ index: Int) -> WalkingRequest {
        .init(source: .init(latitude: 49.6, longitude: 6.1),
              destination: .init(latitude: 49.61, longitude: 6.1 + Double(index) / 100))
    }
}

private actor BatchCacheProvider: WalkingRoutingProvider {
    var batchCalls = 0, singleCalls = 0
    var startWaiter: CheckedContinuation<Void, Never>?
    var blocker: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if batchCalls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { blocker?.resume(); blocker = nil }
    func estimate(_ request: WalkingRequest) -> WalkingEstimate { .init(durationSeconds: 60, distanceMeters: 100) }
    func route(_ request: WalkingRequest) -> WalkingRoute {
        singleCalls += 1
        return .init(durationSeconds: 60, distanceMeters: 100, polyline: [request.source, request.destination])
    }
    func routes(_ requests: [WalkingRequest], maximumConcurrency: Int) async -> [WalkingRoute?] {
        batchCalls += 1
        if batchCalls == 1 {
            await withCheckedContinuation { continuation in
                blocker = continuation
                startWaiter?.resume(); startWaiter = nil
            }
        }
        guard !Task.isCancelled else { return Array(repeating: nil, count: requests.count) }
        return requests.map { .init(durationSeconds: 60, distanceMeters: 100, polyline: [$0.source, $0.destination]) }
    }
}
