import Foundation

extension JourneyPlanningSession {
    /// Discovery owns most request slots. A small reserved set can complete
    /// preliminary selected vehicles while discovery is waiting on HTTP.
    /// Both overlays are acquired before the authoritative feasibility scan.
    func acquireInitialRealtime(access: [Edge], egress: [Edge], anchor: Date,
                                searchHorizon: TimeInterval, force: Bool,
                                budgetMilliseconds: Int, reusingRealtime: Bool,
                                maximumConcurrentRequests: Int?) async throws {
        var attempts: Set<ItineraryBoarding> = []
        _ = try await completeItineraryRealtime([], access: access, egress: egress,
            anchor: anchor, searchHorizon: searchHorizon, force: force,
            budgetMilliseconds: budgetMilliseconds, includeDiscovery: true,
            reusingRealtime: reusingRealtime, attempted: &attempts,
            maximumConcurrentRequests: maximumConcurrentRequests)
    }
}
