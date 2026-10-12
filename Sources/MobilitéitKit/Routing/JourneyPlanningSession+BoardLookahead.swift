import Foundation

extension JourneyPlanningSession {
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
