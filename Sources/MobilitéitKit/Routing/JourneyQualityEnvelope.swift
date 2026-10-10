import Foundation

extension JourneyQualityPolicy {
    /// All replacement policies require a departure no earlier and an arrival
    /// no later. Visit that interval before evaluating vehicle/walking details.
    static func envelopeIDs(_ journeys: [Journey], preferences: RoutingPreferences) -> Set<JourneySignature> {
        let ordered = journeys.sorted { $0.effectiveDeparture > $1.effectiveDeparture }
        let walkingAllowance = preferences.routePreference == .lessWalking ? 0 : transferPenaltySeconds
        var retained: Set<JourneySignature> = []
        for candidate in journeys {
            var replaced = false
            for other in ordered {
                if other.effectiveDeparture < candidate.effectiveDeparture { break }
                guard other.effectiveArrival <= candidate.effectiveArrival,
                      other.accessibility == candidate.accessibility,
                      other.matchesPreferredMode == candidate.matchesPreferredMode,
                      other.transferCount <= candidate.transferCount,
                      other.id != candidate.id else { continue }
                if redundantAccessFeeder(candidate, replacedBy: other, preferences: preferences)
                    || (other.walkingDuration <= candidate.walkingDuration + walkingAllowance
                        && (dominates(other, candidate)
                            || redundantIntermediateTransfer(candidate, replacedBy: other, preferences: preferences))) {
                    replaced = true
                    break
                }
            }
            if !replaced { retained.insert(candidate.id) }
        }
        return retained
    }
}
