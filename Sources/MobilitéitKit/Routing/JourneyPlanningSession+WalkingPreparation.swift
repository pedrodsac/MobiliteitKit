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

    /// A short unpublished profile can start selected-vehicle HTTP before the
    /// broader pedestrian warm-up finishes. The final scan retains the original
    /// preferences, and completion still checks every selected final vehicle.
    nonisolated static func prepareEarlyVehicles(
        enabled: Bool, snapshot: RoutingSnapshot, query: RouteQuery,
        access: [Edge], egress: [Edge], patches: [RealtimeTripPatch],
        walking: WalkingRouteCache?, horizon: TimeInterval
    ) async throws -> WalkingPreparation? {
        guard enabled, (query.preferences.maxTransfers ?? 2) > 1 else { return nil }
        var preferences = query.preferences
        preferences.maxTransfers = 1
        let preliminaryQuery = RouteQuery(origin: query.origin, destination: query.destination,
            departureTime: query.departureTime, direction: query.direction,
            preferences: preferences, realtimePolicy: query.realtimePolicy)
        return try await prepareWalkingWhileAcquiring(enabled: true, snapshot: snapshot,
            query: preliminaryQuery, access: access, egress: egress, patches: patches,
            walking: walking, horizon: horizon)
    }

}
