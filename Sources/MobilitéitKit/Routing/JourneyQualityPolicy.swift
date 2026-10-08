import Foundation

/// Timetable-independent decisions shared by search and the public profile.
/// Walking is already part of elapsed time; its weight is an additional burden.
public enum JourneyQualityPolicy {
    public static let transferPenaltySeconds = 300.0
    public static let walkingBurdenPerSecond = 1.0

    public static func dominates(_ a: Journey, _ b: Journey) -> Bool {
        // A cancelled itinerary must not suppress a running service when this
        // policy is applied to retained or historical journey results.
        guard !a.hasCancelledTransitLeg, !b.hasCancelledTransitLeg else { return false }
        // Accessibility and preferred-mode participation are material choices.
        guard a.accessibility == b.accessibility,
              a.matchesPreferredMode == b.matchesPreferredMode else { return false }
        let noWorse = a.effectiveDeparture >= b.effectiveDeparture
            && a.effectiveArrival <= b.effectiveArrival
            && a.transferCount <= b.transferCount
            && a.walkingDuration <= b.walkingDuration
        let better = a.effectiveDeparture > b.effectiveDeparture
            || a.effectiveArrival < b.effectiveArrival
            || a.transferCount < b.transferCount
            || a.walkingDuration < b.walkingDuration
        return noWorse && better
            && (!a.statusEvidence.tightTransfer || b.statusEvidence.tightTransfer)
    }

    /// Keep the initial list useful when a nearby earlier departure is better
    /// on arrival, transfers, and walking. Later paging still exposes the full
    /// chronological profile for riders who cannot catch that departure.
    static func clearlyInferiorInInitialProfile(_ candidate: Journey, among journeys: [Journey]) -> Bool {
        journeys.contains { other in
            guard other.id != candidate.id,
                  !other.hasCancelledTransitLeg,
                  other.accessibility == candidate.accessibility,
                  other.matchesPreferredMode == candidate.matchesPreferredMode,
                  !other.statusEvidence.tightTransfer || candidate.statusEvidence.tightTransfer else { return false }
            let departureGap = candidate.effectiveDeparture.timeIntervalSince(other.effectiveDeparture)
            return departureGap >= 0 && departureGap <= 20 * 60
                && candidate.effectiveArrival.timeIntervalSince(other.effectiveArrival) >= 10 * 60
                && candidate.duration >= other.duration + 10 * 60
                && candidate.transferCount >= other.transferCount
                && candidate.walkingDuration >= other.walkingDuration
        }
    }

    public static func ranksBefore(_ a: Journey, _ b: Journey,
                                   anchor: Date, direction: RouteQueryDirection,
                                   preferences: RoutingPreferences) -> Bool {
        if a.hasCancelledTransitLeg != b.hasCancelledTransitLeg {
            return !a.hasCancelledTransitLeg
        }
        // An arrival deadline promises the latest feasible departure. Quality
        // costs distinguish journeys only at the same departure instant.
        if direction == .arriveBy, a.effectiveDeparture != b.effectiveDeparture {
            return a.effectiveDeparture > b.effectiveDeparture
        }
        if preferences.preferredMode != nil,
           a.matchesPreferredMode != b.matchesPreferredMode {
            return a.matchesPreferredMode
        }
        if preferences.preferWheelchairAccessible,
           a.accessibility != b.accessibility {
            func rank(_ evidence: AccessibilityAssessment) -> Int {
                switch evidence {
                case .verified: 0
                case .unknown: 1
                case .inaccessible: 2
                }
            }
            return rank(a.accessibility) < rank(b.accessibility)
        }
        let aScore = score(a, anchor: anchor, direction: direction, preferences: preferences)
        let bScore = score(b, anchor: anchor, direction: direction, preferences: preferences)
        if aScore != bScore { return aScore < bScore }
        if a.effectiveDeparture != b.effectiveDeparture {
            return direction == .arriveBy
                ? a.effectiveDeparture > b.effectiveDeparture
                : a.effectiveDeparture < b.effectiveDeparture
        }
        if a.effectiveArrival != b.effectiveArrival { return a.effectiveArrival < b.effectiveArrival }
        return a.id < b.id
    }

    static func recommendation(_ journeys: [Journey], query: RouteQuery) -> Journey? {
        let best = journeys.min { ranksBefore($0, $1, anchor: query.departureTime,
            direction: query.direction, preferences: query.preferences) }
        guard query.preferences.routePreference == .fastest, query.preferences.preferredMode == nil,
              !query.preferences.preferWheelchairAccessible,
              let walk = journeys.filter({ $0.firstRide == nil }).min(by: { $0.effectiveArrival < $1.effectiveArrival }),
              let best else { return best }
        if query.direction == .arriveBy { return walk.effectiveDeparture > best.effectiveDeparture ? walk : best }
        return walk.effectiveArrival < best.effectiveArrival ? walk : best
    }

    public static func score(_ journey: Journey, anchor: Date,
                              direction: RouteQueryDirection,
                              preferences: RoutingPreferences) -> Double {
        let time = direction == .arriveBy
            ? max(0, anchor.timeIntervalSince(journey.effectiveDeparture))
            : max(0, journey.effectiveArrival.timeIntervalSince(anchor))
        let transfers = Double(journey.transferCount)
        let walking = journey.walkingDuration
        let transferWeight: Double
        let walkWeight: Double
        switch preferences.routePreference {
        case .fastest: transferWeight = transferPenaltySeconds; walkWeight = walkingBurdenPerSecond
        case .fewerTransfers: transferWeight = 900; walkWeight = walkingBurdenPerSecond
        case .lessWalking: transferWeight = transferPenaltySeconds; walkWeight = 3
        case .preferDirect: transferWeight = 1_200; walkWeight = walkingBurdenPerSecond
        }
        return time + transfers * transferWeight + walking * walkWeight
    }
}

extension Journey {
    var hasCancelledTransitLeg: Bool {
        legs.contains { leg in
            if case let .transit(transit) = leg { return transit.status == .cancelled }
            return false
        }
    }
}
