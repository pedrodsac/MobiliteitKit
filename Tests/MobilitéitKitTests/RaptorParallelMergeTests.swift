import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RaptorParallelMergeTests {
    @Test func outOfOrderParallelChunksPreserveTheCompleteProfile() async throws {
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
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips, additionalRoutes: routes)
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let query = RouteQuery(origin: .stop(id: "a"), destination: .stop(id: "c"),
                               departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 0))
        var expected: [JourneySignature]?
        for _ in 0..<4 {
            let page = try await router.makeSession(for: query).initial(count: 100, searchHorizon: 10_800)
            #expect(page.metrics.raptorWorkerCount > 1)
            #expect(page.journeys.count > 10)
            let actual = page.journeys.map(\.id)
            if let expected { #expect(actual == expected) }
            else { expected = actual }
        }
    }
}
