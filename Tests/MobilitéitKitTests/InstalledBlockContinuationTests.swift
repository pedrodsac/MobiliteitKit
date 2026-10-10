import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Installed vehicle block replay")
struct InstalledBlockContinuationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] != nil))
    func luxexpoToKonradAdenauer() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"])
        let router = try await TransitRouter(databaseURL: URL(fileURLWithPath: path))
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-10T18:30:00Z"))
        let query = RouteQuery(origin: .stop(id: "000200417050"), destination: .stop(id: "000900000058"),
            departureTime: anchor, preferences: .init(maxTransfers: 0), realtimePolicy: .disabled)
        let session = try await router.makeSession(for: query)
        let page = try await session.boundedPage(count: 10)
        let journey = try #require(page.journeys.first { journey in
            journey.legs.contains { if case .inSeatContinuation = $0 { true } else { false } }
        })
        print("BLOCK REPLAY: \(journey.scheduledDeparture) → \(journey.scheduledArrival), \(journey.transferCount) transfers")
        #expect(journey.transferCount == 0)
        #expect(transitTripInstanceSequence(journey) == ["24369135", "24364998"] || transitTripInstanceSequence(journey) == ["24427999", "24424738"])
    }
}
