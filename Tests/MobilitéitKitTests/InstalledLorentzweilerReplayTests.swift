import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct InstalledLorentzweilerReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] != nil))
    func overnightRailConnection() async throws {
        let database = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"]))
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-10T23:33:00+02:00"))
        let router = try await TransitRouter(databaseURL: database, walkingProvider: ReplayWalking())
        for origin: JourneyEndpoint in [.stop(id: "000200417058"), .coordinate(.init(latitude: 49.6541071, longitude: 6.2296443), label: "Gromscheed")] {
            let session = try await router.makeSession(for: .init(origin: origin, destination: .stop(id: "000160807006"), departureTime: anchor, preferences: .init(allowTightSameStopBusTransfers: true), realtimePolicy: .disabled))
            let page = try await session.initial(count: 6, searchHorizon: 7200)
            for journey in page.journeys {
                print("LORENTZWEILER", journey.scheduledArrival, journey.legs.compactMap { if case let .transit(ride) = $0 { ride.route.shortName } else { nil } })
            }
            let overnight = try #require(page.journeys.first { journey in
                journey.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "24455256" } else { false } }
            })
            #expect(overnight.scheduledArrival == ISO8601DateFormatter().date(from: "2026-10-11T01:25:00+02:00"))
        }
    }
}
private struct ReplayWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let meters = distance(request.source, request.destination) * 1.3
        return .init(durationSeconds: Int(ceil(meters / 1.2)), distanceMeters: meters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        let value = try await estimate(request)
        return .init(durationSeconds: value.durationSeconds, distanceMeters: value.distanceMeters,
                     polyline: [request.source, request.destination])
    }
}
