import Foundation

extension JourneyPlanningSession {
    /// Long cross-country profiles commonly expand beyond two hours. Acquire
    /// reusable coverage up front instead of waiting for a new board at every
    /// expansion. This changes transport lookahead only, never routing horizons,
    /// the discovery frontier, matching bounds or the number of results.
    func boardLookaheadMinutes(includeDiscovery: Bool, reusingRealtime: Bool) -> Int {
        // Later horizons consume the initial prefetched coverage and acquire
        // their actual gaps. Padding a shifted start again can turn an already
        // covered window into another overlapping four-hour request.
        guard includeDiscovery, !reusingRealtime, shouldPrepareLongDistanceHorizon else { return 0 }
        return 240
    }

    /// A cheap scheduled profile can choose the starting horizon for sparse,
    /// long-distance services before any acquisition budget is spent. The live
    /// profile still evaluates every candidate and expands further if needed.
    var shouldPrepareLongDistanceHorizon: Bool {
        func coordinate(_ endpoint: JourneyEndpoint) -> Coordinate? {
            switch endpoint {
            case let .coordinate(value, _): value
            case let .stop(id): snapshot.stopByID[id].map { snapshot.stops[$0].model.coordinate }
            }
        }
        guard query.direction == .departAfter,
              case let .bestEffort(configuration, _) = query.realtimePolicy,
              configuration.acquisitionBudgetMilliseconds > 0, configuration.searchWorkBudgetMilliseconds != 0,
              let origin = coordinate(query.origin), let destination = coordinate(query.destination)
        else { return false }
        return distance(origin, destination) >= 40_000
    }
}
