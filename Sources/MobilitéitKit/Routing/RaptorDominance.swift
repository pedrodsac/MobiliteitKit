import Foundation

extension Raptor {
    @inline(__always) static func cannotEnterFullProfile(
        _ profile: LabelProfile?, source: Label,
        tripIndex: Int, day: GTFSDate, candidateID: Int, alightStop: Int, alightPosition: Int = 1,
        departure: Date, arrival: Date,
        minimumSlack: Int, totalSlack: Int,
        containsPreferredMode: Bool
    ) -> Bool {
        guard let profile, profile.ordered.count == profileWidth,
              let lastUnprotected = profile.lastUnprotectedArrival else { return false }
        let firstDeparture = source.firstDeparture ?? departure
        let walk = source.walkingSeconds
        let candidateTrip = TripInstance(trip: tripIndex, day: day)

        func labelBeforeCandidate(_ lhs: Label) -> Bool {
            let lhsDeparture = lhs.firstDeparture ?? .distantPast
            if lhsDeparture != firstDeparture { return lhsDeparture < firstDeparture }
            if lhs.time != arrival { return lhs.time < arrival }
            if lhs.walkingSeconds != walk { return lhs.walkingSeconds < walk }
            let key = source.tripKey.appending(candidateTrip)
            if precedes(lhs.tripKey, key) { return true }
            if precedes(key, lhs.tripKey) { return false }
            return lhs.id < candidateID
        }
        func candidateBeforeLabel(_ rhs: Label) -> Bool {
            let rhsDeparture = rhs.firstDeparture ?? .distantPast
            if firstDeparture != rhsDeparture { return firstDeparture < rhsDeparture }
            if arrival != rhs.time { return arrival < rhs.time }
            if walk != rhs.walkingSeconds { return walk < rhs.walkingSeconds }
            let key = source.tripKey.appending(candidateTrip)
            if precedes(key, rhs.tripKey) { return true }
            if precedes(rhs.tripKey, key) { return false }
            return candidateID < rhs.id
        }
        guard lastUnprotected.time < arrival
            || (lastUnprotected.time == arrival && labelBeforeCandidate(lastUnprotected))
        else { return false }
        let quota = profileWidth / 5
        guard labelBeforeCandidate(profile.ordered[quota - 1]),
              candidateBeforeLabel(profile.ordered[profileWidth - quota]) else { return false }
        let walkBoundary = profile.byWalk[quota - 1]
        let boundaryWalk = walkBoundary.walkingSeconds
        let outsideWalk = boundaryWalk < walk
            || (boundaryWalk == walk && labelBeforeCandidate(walkBoundary))
        let outsidePreferred = !containsPreferredMode
            || profile.lastPreferredArrival.map {
                $0.time < arrival || ($0.time == arrival && labelBeforeCandidate($0))
            } == true
        guard outsideWalk && outsidePreferred else { return false }

        // The full insert first removes dominated peers. If a peer might be
        // removable, let the original check decide rather than risk pruning it.
        let doorDeparture = firstDeparture.addingTimeInterval(-TimeInterval(source.accessSeconds))
        for peer in profile.byIncomingTrip[tripIndex] ?? [] {
            guard peer.tripKey == source.tripKey.appending(candidateTrip),
                  peer.lastTransit?.alightPos == alightPosition,
                  peer.lastTransit?.alight == alightStop,
                  peer.transferWalkSeconds == 0,
                  peer.containsPreferredMode == containsPreferredMode,
                  peer.walkingStopsVisited.count == 1,
                  peer.walkingStopsVisited.contains(alightStop),
                  minimumSlack >= peer.minimumSlack,
                  totalSlack >= peer.totalSlack else { continue }
            if let peerDeparture = peer.doorDeparture,
               doorDeparture >= peerDeparture,
               arrival <= peer.time,
               walk <= peer.walkingSeconds {
                return false
            }
        }
        return true
    }

    @inline(__always) static func transitCandidateIsDominated(
        by profile: LabelProfile?,
        source: Label,
        tripIndex: Int,
        day: GTFSDate,
        alightStop: Int,
        alightPosition: Int = 1,
        departure: Date,
        arrival: Date,
        minimumSlack: Int,
        totalSlack: Int,
        containsPreferredMode: Bool
    ) -> Bool {
        guard let profile else { return false }
        let firstDeparture = source.firstDeparture ?? departure
        let doorDeparture = firstDeparture.addingTimeInterval(-TimeInterval(source.accessSeconds))
        let walk = source.walkingSeconds
        let lastTrip = TripInstance(trip: tripIndex, day: day)
        return (profile.byIncomingTrip[tripIndex] ?? []).contains { existing in
            guard existing.tripKey == source.tripKey.appending(lastTrip),
                  existing.lastTransit?.alightPos == alightPosition,
                  existing.lastTransit?.trip == tripIndex,
                  existing.lastTransit?.alight == alightStop,
                  existing.transferWalkSeconds == 0,
                  existing.containsPreferredMode == containsPreferredMode,
                  existing.walkingStopsVisited.count == 1,
                  existing.walkingStopsVisited.contains(alightStop),
                  existing.minimumSlack >= minimumSlack,
                  existing.totalSlack >= totalSlack,
                  let existingFirstDeparture = existing.firstDeparture
            else { return false }
            let existingDoorDeparture = existing.doorDeparture ?? existingFirstDeparture.addingTimeInterval(
                -TimeInterval(existing.accessSeconds)
            )
            let existingWalk = existing.walkingSeconds
            guard existingDoorDeparture >= doorDeparture,
                  existing.time <= arrival,
                  existingWalk <= walk else { return false }
            if existingDoorDeparture != doorDeparture || existing.time < arrival || existingWalk < walk {
                return true
            }
            return existing.tripKey.count == source.tripKey.count + 1
                && existing.tripKey.last == lastTrip
                && existing.tripKey.hasPrefix(source.tripKey)
        }
    }

    @inline(__always) static func dominates(_ lhs: Label, _ rhs: Label) -> Bool {
        // Transfer rules inspect the incoming trip and the station where it
        // alighted. Walking allowance is also part of future boardability.
        guard lhs.tripKey == rhs.tripKey,
              lhs.lastTransit?.alightPos == rhs.lastTransit?.alightPos,
              lhs.lastTransit?.day == rhs.lastTransit?.day,
              lhs.lastTransit?.trip == rhs.lastTransit?.trip,
              lhs.lastTransit?.alight == rhs.lastTransit?.alight,
              lhs.transferWalkSeconds == rhs.transferWalkSeconds,
              lhs.containsPreferredMode == rhs.containsPreferredMode,
              lhs.walkingStopsVisited == rhs.walkingStopsVisited,
              lhs.minimumSlack >= rhs.minimumSlack,
              lhs.totalSlack >= rhs.totalSlack else { return false }
        let lhsDeparture = lhs.doorDeparture
        let rhsDeparture = rhs.doorDeparture
        let departureNoWorse: Bool
        if let lhsDeparture, let rhsDeparture { departureNoWorse = lhsDeparture >= rhsDeparture }
        else { departureNoWorse = lhsDeparture == rhsDeparture && lhs.accessSeconds <= rhs.accessSeconds }
        let lhsWalk = lhs.walkingSeconds
        let rhsWalk = rhs.walkingSeconds
        return departureNoWorse && lhs.time <= rhs.time && lhsWalk <= rhsWalk
            && (lhsDeparture != rhsDeparture || lhs.time < rhs.time || lhsWalk < rhsWalk
                || lhs.tripKey == rhs.tripKey)
    }

    @inline(__always) static func labelOrder(_ lhs: Label, _ rhs: Label) -> Bool {
        let a = lhs.firstDeparture ?? .distantPast
        let b = rhs.firstDeparture ?? .distantPast
        if a != b { return a < b }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.walkingSeconds != rhs.walkingSeconds {
            return lhs.walkingSeconds < rhs.walkingSeconds
        }
        if precedes(lhs.tripKey, rhs.tripKey) { return true }
        if precedes(rhs.tripKey, lhs.tripKey) { return false }
        return lhs.id < rhs.id
    }

    static func prefers(_ lhs: Label, over rhs: Label) -> Bool {
        if lhs.minimumSlack != rhs.minimumSlack { return lhs.minimumSlack > rhs.minimumSlack }
        if lhs.totalSlack != rhs.totalSlack { return lhs.totalSlack > rhs.totalSlack }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        // A later stop on the same vehicle reaches the same downstream state.
        // Retain the option that takes less time and distance to reach it.
        if lhs.accessSeconds != rhs.accessSeconds { return lhs.accessSeconds < rhs.accessSeconds }
        if lhs.accessDistance != rhs.accessDistance { return lhs.accessDistance < rhs.accessDistance }
        if lhs.pathwaySeconds != rhs.pathwaySeconds { return lhs.pathwaySeconds < rhs.pathwaySeconds }
        if lhs.pathwayDistance != rhs.pathwayDistance { return lhs.pathwayDistance < rhs.pathwayDistance }
        return lhs.legCount < rhs.legCount
    }

    @inline(__always) static func precedes(_ lhs: TripKey, _ rhs: TripKey) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let a = lhs[index], b = rhs[index]
            if a.trip != b.trip { return a.trip < b.trip }
            if a.day != b.day { return a.day < b.day }
        }
        return lhs.count < rhs.count
    }
}
