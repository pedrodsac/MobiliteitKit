import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RaptorParallelMergeTests {
    /// 80 one-leg routes with very different numbers of trips, so chunk costs and completion times differ.
    static func makeFixture() async throws -> RealtimeTestFixture {
        var routes = "", trips = "", times = ""
        // Different family sizes make worker completion order uneven. More
        // than two scheduling windows exercise buffer backpressure and draining.
        for pattern in 0..<80 {
            let route = "parallel-route-\(pattern)"
            routes += "\(route),operator,\(pattern),Parallel,3\n"
            for run in 0..<(1 + (pattern % 15) * 8) {
                let trip = "parallel-trip-\(pattern)-\(run)"
                let minute = (pattern + run) % 120
                let departure = String(format: "%02d:%02d:00", 8 + minute / 60, minute % 60)
                let arrival = String(format: "%02d:%02d:00", 8 + (minute + 10) / 60, (minute + 10) % 60)
                trips += "\(route),service,\(trip),Destination\n"
                times += "\(trip),\(departure),\(departure),a,1\n\(trip),\(arrival),\(arrival),c,2\n"
            }
        }
        return try await RealtimeTestFixture(stopTimes: times, trips: trips, additionalRoutes: routes)
    }

    /// A slow merger must hold the scan back at the outstanding-chunk limit without stalling it for good.
    @Test(.timeLimit(.minutes(1)), arguments: [2, 4, 10])
    func slowMergerLimitsTheChunksOutstanding(workers: Int) async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let snapshot = await router.snapshot
        let query = RouteQuery(origin: .stop(id: "a"), destination: .stop(id: "c"),
                               departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 0))
        // No pattern is marked, so every chunk finishes at once and only the merger sets the pace.
        let chunks = snapshot.patterns.indices.map { (index: $0, patterns: [$0]) }
        let inputs = Raptor.PatternScanInputs(snapshot: snapshot, query: query, previousLabels: [:],
            boardings: .init([:], stopCount: snapshot.stops.count),
            patternStartPositions: Array(repeating: .max, count: snapshot.patterns.count),
            activeInstancesByPattern: [:], reachableStops: nil, round: 0, maxRounds: 1, finalRoundAlightStops: [])
        let outcome = try await Raptor.$mergeDelayForTests.withValue(.milliseconds(2)) {
            try await Raptor.scanAndMerge(chunks: chunks, workerCount: workers, inputs: inputs, nextLabelID: 100)
        }
        #expect(chunks.count >= 80)
        #expect(outcome.merge.patterns == chunks.count)
        #expect(outcome.merge.nextID == 100)
        #expect(outcome.peakOutstandingChunks == 3 * workers)
        #expect(outcome.mergeTailMilliseconds > 0)
    }

    /// Few workers keep the outstanding-chunk limit low, so the scan waits for the merger often.
    @Test(.timeLimit(.minutes(2)), arguments: [2, 3, 6, 10])
    func outOfOrderParallelChunksPreserveTheCompleteProfile(workers: Int) async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let query = RouteQuery(origin: .stop(id: "a"), destination: .stop(id: "c"),
                               departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 0))
        var expected: [JourneySignature]?
        for _ in 0..<4 {
            let page = try await Raptor.$activeProcessorCountOverride.withValue(workers) {
                try await router.makeSession(for: query).initial(count: 100, searchHorizon: 10_800)
            }
            #expect(page.metrics.raptorWorkerCount == workers)
            #expect(page.journeys.count > 10)
            let actual = page.journeys.map(\.id)
            if let expected { #expect(actual == expected) }
            else { expected = actual }
        }
    }
}
