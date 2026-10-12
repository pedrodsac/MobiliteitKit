import Foundation

extension Raptor {
    /// Projects the walking label's insertion fields without allocating its
    /// linked label or visited-stop set. Rejection follows `insert` exactly;
    /// anything that can remove a peer still goes through the full insertion.
    static func walkingCandidateCannotEnterProfile(
        _ profile: LabelProfile?, source: Label, to: Int,
        durationSeconds: Int, arrival: Date, candidateID: Int
    ) -> Bool {
        guard let profile else { return false }
        let walk = source.walkingSeconds + durationSeconds
        let transferWalk = source.transferWalkSeconds + durationSeconds
        var removesPeer = false
        for peer in profile.byIncomingTrip[source.lastTransit?.trip ?? -1] ?? [] {
            guard peer.tripKey == source.tripKey,
                  peer.lastTransit?.alightPos == source.lastTransit?.alightPos,
                  peer.lastTransit?.day == source.lastTransit?.day,
                  peer.lastTransit?.trip == source.lastTransit?.trip,
                  peer.lastTransit?.alight == source.lastTransit?.alight,
                  peer.transferWalkSeconds == transferWalk,
                  peer.containsPreferredMode == source.containsPreferredMode,
                  walkingVisits(peer.walkingStopsVisited, equalTo: source.walkingStopsVisited, adding: to)
            else { continue }
            func departureNoWorse(_ lhs: Date?, _ rhs: Date?, lhsAccess: Int, rhsAccess: Int) -> Bool {
                if let lhs, let rhs { return lhs >= rhs }
                return lhs == rhs && lhsAccess <= rhsAccess
            }
            // The final strictness clause in `dominates` also admits equal
            // trip keys, already established by the identity guard above.
            if peer.minimumSlack >= source.minimumSlack, peer.totalSlack >= source.totalSlack,
               departureNoWorse(peer.doorDeparture, source.doorDeparture,
                   lhsAccess: peer.accessSeconds, rhsAccess: source.accessSeconds),
               peer.time <= arrival, peer.walkingSeconds <= walk { return true }
            if source.minimumSlack >= peer.minimumSlack, source.totalSlack >= peer.totalSlack,
               departureNoWorse(source.doorDeparture, peer.doorDeparture,
                   lhsAccess: source.accessSeconds, rhsAccess: peer.accessSeconds),
               arrival <= peer.time, walk <= peer.walkingSeconds { removesPeer = true }
        }
        guard !removesPeer, profile.ordered.count == profileWidth,
              let lastUnprotected = profile.lastUnprotectedArrival else { return false }

        func labelBeforeCandidate(_ label: Label) -> Bool {
            let lhsDeparture = label.firstDeparture ?? .distantPast
            let rhsDeparture = source.firstDeparture ?? .distantPast
            if lhsDeparture != rhsDeparture { return lhsDeparture < rhsDeparture }
            if label.time != arrival { return label.time < arrival }
            if label.walkingSeconds != walk { return label.walkingSeconds < walk }
            if precedes(label.tripKey, source.tripKey) { return true }
            if precedes(source.tripKey, label.tripKey) { return false }
            return label.id < candidateID
        }
        func candidateBeforeLabel(_ label: Label) -> Bool {
            let lhsDeparture = source.firstDeparture ?? .distantPast
            let rhsDeparture = label.firstDeparture ?? .distantPast
            if lhsDeparture != rhsDeparture { return lhsDeparture < rhsDeparture }
            if arrival != label.time { return arrival < label.time }
            if walk != label.walkingSeconds { return walk < label.walkingSeconds }
            if precedes(source.tripKey, label.tripKey) { return true }
            if precedes(label.tripKey, source.tripKey) { return false }
            return candidateID < label.id
        }
        func arrivalBeforeCandidate(_ label: Label) -> Bool {
            label.time == arrival ? labelBeforeCandidate(label) : label.time < arrival
        }
        let quota = profileWidth / 5
        let walkBoundary = profile.byWalk[quota - 1]
        return arrivalBeforeCandidate(lastUnprotected)
            && labelBeforeCandidate(profile.ordered[quota - 1])
            && candidateBeforeLabel(profile.ordered[profileWidth - quota])
            && (walkBoundary.walkingSeconds < walk
                || (walkBoundary.walkingSeconds == walk && labelBeforeCandidate(walkBoundary)))
            && (!source.containsPreferredMode
                || profile.lastPreferredArrival.map(arrivalBeforeCandidate) == true)
    }

    /// Preserve the enum representation as well as set membership: `.one(x)`
    /// and `.multiple([x])` are distinct states in the original label identity.
    private static func walkingVisits(_ actual: WalkingVisits, equalTo source: WalkingVisits, adding stop: Int) -> Bool {
        switch (source, actual) {
        case let (.one(only), .one(value)):
            return only == stop && value == only
        case let (.one(only), .multiple(values)):
            return only != stop && values.count == 2 && values.contains(only) && values.contains(stop)
        case let (.multiple(original), .multiple(values)):
            return values.count == original.count + (original.contains(stop) ? 0 : 1)
                && values.contains(stop) && original.allSatisfy { values.contains($0) }
        default:
            return false
        }
    }
}
