import Foundation

extension JourneyQualityPolicy {
    /// Staying aboard can replace an intermediate vehicle when the validated
    /// journey still catches the same downstream services. A modest increase
    /// in interchange walking must not preserve an otherwise pointless change.
    static func redundantIntermediateTransfer(_ candidate: Journey, replacedBy other: Journey,
                                              preferences: RoutingPreferences) -> Bool {
        guard candidate.id != other.id, !candidate.hasCancelledTransitLeg, !other.hasCancelledTransitLeg,
              candidate.origin == other.origin, candidate.destination == other.destination,
              candidate.accessibility == other.accessibility,
              candidate.matchesPreferredMode == other.matchesPreferredMode,
              other.transferCount < candidate.transferCount,
              other.effectiveDeparture >= candidate.effectiveDeparture,
              other.effectiveArrival <= candidate.effectiveArrival,
              other.walkingDuration <= candidate.walkingDuration + transferPenaltySeconds,
              preferences.routePreference != .lessWalking || other.walkingDuration <= candidate.walkingDuration
        else { return false }
        let rides = candidate.legs.compactMap { if case let .transit(ride) = $0 { ride } else { nil } }
        let replacement = other.legs.compactMap { if case let .transit(ride) = $0 { ride } else { nil } }
        guard replacement.count >= 2, replacement.count < rides.count else { return false }
        let removedCount = rides.count - replacement.count
        for split in 0..<(replacement.count - 1) {
            // The common prefix boards the same instances and occurrences.
            // Only its last ride extends to a later alighting occurrence.
            let prefixMatches = (0...split).allSatisfy { index in
                let a = rides[index], b = replacement[index]
                guard sameBoarding(a, b), let oldAlight = a.alightSequence,
                      let newAlight = b.alightSequence else { return false }
                return index == split ? newAlight > oldAlight : sameAlighting(a, b)
            }
            guard prefixMatches else { continue }
            // The first downstream service may be boarded at a different
            // reachable occurrence. Remaining vehicle actions match exactly.
            let suffixMatches = ((split + 1)..<replacement.count).allSatisfy { index in
                let a = rides[index + removedCount], b = replacement[index]
                return sameInstance(a, b) && a.boardSequence != nil && b.boardSequence != nil
                    && sameAlighting(a, b) && (index == split + 1 || sameBoarding(a, b))
            }
            if suffixMatches { return true }
        }
        return false
    }

    private static func sameInstance(_ a: TransitLeg, _ b: TransitLeg) -> Bool {
        a.instance != nil && a.instance == b.instance
    }

    private static func sameBoarding(_ a: TransitLeg, _ b: TransitLeg) -> Bool {
        sameInstance(a, b) && a.boardSequence != nil && a.boardSequence == b.boardSequence
            && a.board.stop.id == b.board.stop.id && a.effectiveDeparture == b.effectiveDeparture
    }

    private static func sameAlighting(_ a: TransitLeg, _ b: TransitLeg) -> Bool {
        a.alightSequence != nil && a.alightSequence == b.alightSequence
            && a.alight.stop.id == b.alight.stop.id && a.effectiveArrival == b.effectiveArrival
    }
}
