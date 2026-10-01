import Foundation

/// Presentation thresholds; these never relax feasibility or search dominance.
public struct JourneySuggestionPolicy: Hashable, Sendable, Codable {
    public var materialArrivalBenefitSeconds: Int
    public var maximumSharedFirstVehicle: Int
    public var recommendationSwitchingMarginSeconds: Int
    public init(materialArrivalBenefitSeconds: Int = 120, maximumSharedFirstVehicle: Int = 2,
                recommendationSwitchingMarginSeconds: Int = 60) {
        self.materialArrivalBenefitSeconds = max(0, materialArrivalBenefitSeconds)
        self.maximumSharedFirstVehicle = max(1, maximumSharedFirstVehicle)
        self.recommendationSwitchingMarginSeconds = max(0, recommendationSwitchingMarginSeconds)
    }
}

extension Journey {
    var firstRide: TransitLeg? { legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }.first }
    var firstVehicleKey: String? { firstRide.map { $0.instance?.stableKey ?? "\($0.tripID)@\($0.scheduledDeparture.timeIntervalSince1970)" } }
}

extension JourneyQualityPolicy {
    /// Remove a feeder only when a verified access walk catches the identical
    /// remaining trip occurrences, leaves home no earlier, and adds at most
    /// five minutes of walking. Keep a requested lower-walking choice.
    static func redundantAccessFeeder(_ candidate: Journey, replacedBy other: Journey,
                                      preferences: RoutingPreferences) -> Bool {
        guard other.id != candidate.id, !other.hasCancelledTransitLeg, !candidate.hasCancelledTransitLeg,
              other.origin == candidate.origin, other.destination == candidate.destination,
              other.accessibility == candidate.accessibility,
              other.matchesPreferredMode == candidate.matchesPreferredMode,
              other.transferCount < candidate.transferCount,
              other.effectiveDeparture >= candidate.effectiveDeparture,
              other.effectiveArrival <= candidate.effectiveArrival,
              other.walkingDuration <= candidate.walkingDuration + transferPenaltySeconds,
              preferences.routePreference != .lessWalking || other.walkingDuration <= candidate.walkingDuration
        else { return false }
        let rides = candidate.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
        let replacement = other.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
        guard !replacement.isEmpty, replacement.count < rides.count else { return false }
        // Line numbers/headsigns cannot establish an equivalent connection.
        // Match service day and the actual boarding/alighting occurrences.
        return zip(rides.suffix(replacement.count), replacement).enumerated().allSatisfy { index, pair in
            let (a, b) = pair
            guard a.instance != nil, a.instance == b.instance,
                  a.boardSequence != nil, b.boardSequence != nil,
                  a.alightSequence != nil, a.alightSequence == b.alightSequence,
                  a.alight.stop.id == b.alight.stop.id, a.effectiveArrival == b.effectiveArrival
            else { return false }
            // The first retained vehicle may be boarded at another reachable
            // occurrence. Both full journeys already passed feed/access checks.
            // Thereafter the downstream boarding actions must be identical.
            return index == 0 || (a.boardSequence == b.boardSequence
                && a.board.stop.id == b.board.stop.id && a.effectiveDeparture == b.effectiveDeparture)
        }
    }

    static func materiallyInferior(_ candidate: Journey, among journeys: [Journey],
                                  policy: JourneySuggestionPolicy) -> Bool {
        journeys.contains { other in
            guard other.id != candidate.id, other.accessibility == candidate.accessibility,
                  other.matchesPreferredMode == candidate.matchesPreferredMode,
                  !other.hasCancelledTransitLeg else { return false }
            func vehicles(_ journey: Journey) -> [String] {
                journey.legs.compactMap { if case let .transit(t) = $0 { t.instance?.stableKey ?? t.tripID } else { nil } }
            }
            // Both candidates have already passed physical/access validation.
            // Collapse minor endpoint variants of the SAME vehicle actions.
            let sameVehicles = !vehicles(other).isEmpty && vehicles(other) == vehicles(candidate)
            let nearEndpoints = abs(other.effectiveDeparture.timeIntervalSince(candidate.effectiveDeparture)) <= 120
                && abs(other.effectiveArrival.timeIntervalSince(candidate.effectiveArrival)) <= Double(policy.materialArrivalBenefitSeconds)
                && abs(other.walkingDuration - candidate.walkingDuration) <= 120
                && abs(other.walkingDistance - candidate.walkingDistance) <= 200
                && other.transferCount == candidate.transferCount
            if sameVehicles && nearEndpoints {
                let otherBurden = (other.walkingDuration, other.walkingDistance, other.duration, other.id)
                let candidateBurden = (candidate.walkingDuration, candidate.walkingDistance, candidate.duration, candidate.id)
                if otherBurden < candidateBurden { return true }
            }
            guard other.transferCount <= candidate.transferCount,
                  other.walkingDuration <= candidate.walkingDuration,
                  other.transferCount < candidate.transferCount || other.walkingDuration + 120 <= candidate.walkingDuration
            else { return false }
            // The same first vehicle preserves departure flexibility even when
            // access/entrance variants move the door-to-door departure slightly.
            let sameFirst = other.firstVehicleKey != nil && other.firstVehicleKey == candidate.firstVehicleKey
            let catchableTogether = other.effectiveDeparture >= candidate.effectiveDeparture.addingTimeInterval(-120)
            return (sameFirst || catchableTogether)
                && other.effectiveArrival <= candidate.effectiveArrival.addingTimeInterval(Double(policy.materialArrivalBenefitSeconds))
        }
    }

    static func primarySuggestions(_ all: [Journey], count: Int, query: RouteQuery) -> [Journey] {
        guard count > 0 else { return [] }
        let useful = all.filter {
            !clearlyInferiorInInitialProfile($0, among: all)
                && !materiallyInferior($0, among: all, policy: query.preferences.suggestionPolicy)
        }
        let ordered = useful.sorted { ranksBefore($0, $1, anchor: query.departureTime,
            direction: query.direction, preferences: query.preferences) }
        guard let best = ordered.first else { return [] }
        var selected = [best]
        var counts: [String: Int] = best.firstVehicleKey.map { [$0: 1] } ?? [:]
        let competitive = ordered.filter {
            score($0, anchor: query.departureTime, direction: query.direction, preferences: query.preferences)
                <= score(best, anchor: query.departureTime, direction: query.direction, preferences: query.preferences) + 15 * 60
        }
        // Reserve a useful fallback whose ACCESS can start after the first
        // vehicle leaves. Different downstream permutations do not qualify.
        let fallback = competitive.first { candidate in
            candidate.firstVehicleKey != nil && candidate.firstVehicleKey != best.firstVehicleKey
                && candidate.effectiveDeparture >= (best.firstRide?.effectiveDeparture ?? best.effectiveDeparture)
                && candidate.accessibility == best.accessibility
        }
        if let fallback, count > 1 {
            selected.append(fallback)
            if let key = fallback.firstVehicleKey { counts[key, default: 0] += 1 }
        }
        for journey in ordered where selected.count < count && !selected.contains(where: { $0.id == journey.id }) {
            if let key = journey.firstVehicleKey,
               counts[key, default: 0] >= query.preferences.suggestionPolicy.maximumSharedFirstVehicle,
               fallback != nil { continue }
            selected.append(journey)
            if let key = journey.firstVehicleKey { counts[key, default: 0] += 1 }
        }
        return selected.sorted { chronologicalOrder($0, $1, query: query) }
    }

    static func chronologicalOrder(_ a: Journey, _ b: Journey, query: RouteQuery) -> Bool {
        if a.effectiveDeparture != b.effectiveDeparture { return a.effectiveDeparture < b.effectiveDeparture }
        if a.effectiveArrival != b.effectiveArrival { return a.effectiveArrival < b.effectiveArrival }
        return ranksBefore(a, b, anchor: query.departureTime, direction: query.direction, preferences: query.preferences)
    }
}
