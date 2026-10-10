import Foundation

/// Shared by initial, adjacent and walking-replacement searches in the facade.
enum JourneyBatchPolicy {
    static let count = 6
    static let initialHorizon: TimeInterval = 90 * 60

    static func adjacentSuggestions(_ profile: [Journey], axis: JourneyTimeAxis,
                                    earlier: Bool, count: Int, query: RouteQuery) -> [Journey] {
        if axis == .departure && !earlier {
            return JourneyQualityPolicy.primarySuggestions(profile, count: count, query: query)
        }
        let useful = JourneyQualityPolicy.primarySuggestions(profile, count: profile.count, query: query)
        let ordered = useful.sorted {
            let a = axis == .arrival ? $0.effectiveArrival : $0.effectiveDeparture
            let b = axis == .arrival ? $1.effectiveArrival : $1.effectiveDeparture
            return (a, $0.id) < (b, $1.id)
        }
        return earlier ? Array(ordered.suffix(max(0, count))) : Array(ordered.prefix(max(0, count)))
    }
}
