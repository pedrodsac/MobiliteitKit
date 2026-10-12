import Foundation

extension JourneyPlanningSession {
    struct WalkingPreparation: Sendable {
        let result: Raptor.SearchResult
        let started: ContinuousClock.Instant
        let finished: ContinuousClock.Instant
    }

    nonisolated static func prepareWalkingWhileAcquiring(
        enabled: Bool, snapshot: RoutingSnapshot, query: RouteQuery,
        access: [Edge], egress: [Edge], patches: [RealtimeTripPatch],
        walking: WalkingRouteCache?, horizon: TimeInterval
    ) async throws -> WalkingPreparation? {
        guard enabled else { return nil }
        let started = ContinuousClock.now
        let result = try await Raptor.search(snapshot: snapshot, query: query, access: access,
            egress: egress, patches: patches, walking: walking, profileHorizon: horizon)
        return .init(result: result, started: started, finished: .now)
    }
}
