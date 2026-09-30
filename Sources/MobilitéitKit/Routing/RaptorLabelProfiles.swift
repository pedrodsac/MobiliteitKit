import Foundation

extension Raptor {
    static func insert(_ candidate: Label, at stop: Int, into labels: inout [Int: LabelProfile]) -> Bool {
        insert(candidate, into: &labels[stop, default: LabelProfile()])
    }

    @inline(__always) static func insert(_ candidate: Label, into profile: inout LabelProfile) -> Bool {
        #if DEBUG
        let referenceInput = verifyProfile ? profile.ordered : nil
        #endif
        let incomingTrip = candidate.lastTransit?.trip ?? -1
        let peers = profile.byIncomingTrip[incomingTrip] ?? []
        if peers.contains(where: { dominates($0, candidate) }) { return false }
        let removed = peers.compactMap { dominates(candidate, $0) ? $0.id : nil }
        if !removed.isEmpty {
            profile.ordered.removeAll { removed.contains($0.id) }
            profile.byWalk.removeAll { removed.contains($0.id) }
            profile.byArrival.removeAll { removed.contains($0.id) }
            profile.byIncomingTrip[incomingTrip]?.removeAll { removed.contains($0.id) }
        }
        if removed.isEmpty, profile.ordered.count == profileWidth {
            // A candidate later than the last unprotected arrival is evicted
            // immediately if it also falls outside every protected quota.
            let quota = profileWidth / 5
            let candidateIsLastUnprotected = profile.lastUnprotectedArrival.map {
                arrivalOrder($0, candidate)
            } ?? false
            let candidateIsInOrderedMiddle = labelOrder(profile.ordered[quota - 1], candidate)
                && labelOrder(candidate, profile.ordered[profileWidth - quota])
            let walk = candidate.walkingSeconds
            let walkBoundary = profile.byWalk[quota - 1]
            let boundaryWalk = walkBoundary.walkingSeconds
            let candidateOutsideWalkQuota = boundaryWalk < walk
                || (boundaryWalk == walk && labelOrder(walkBoundary, candidate))
            let candidateOutsidePreferredQuota = !candidate.containsPreferredMode
                || profile.lastPreferredArrival.map { arrivalOrder($0, candidate) } == true
            if candidateIsLastUnprotected, candidateIsInOrderedMiddle,
               candidateOutsideWalkQuota, candidateOutsidePreferredQuota {
                #if DEBUG
                if let referenceInput {
                    let expected = referenceInsert(candidate, into: referenceInput)
                    precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
                }
                #endif
                return false
            }
        }
        insertSorted(candidate, into: &profile.ordered, by: labelOrder)
        insertSorted(candidate, into: &profile.byWalk) { lhs, rhs in
            let a = lhs.walkingSeconds
            let b = rhs.walkingSeconds
            return a == b ? labelOrder(lhs, rhs) : a < b
        }
        insertSorted(candidate, into: &profile.byArrival) { lhs, rhs in
            arrivalOrder(lhs, rhs)
        }
        profile.byIncomingTrip[incomingTrip, default: []].append(candidate)
        var candidateRetained = true
        var membership: (ids: [Int], lastPreferred: Label?)?
        if profile.ordered.count > profileWidth {
            // With 49 labels and 48 slots, the reference quotas plus
            // arrival-order fill exclude the last arrival outside every quota.
            // Build the quota membership once instead of rescanning four
            // sorted profiles for every possible victim.
            let protected = quotaMembership(in: profile)
            membership = protected
            let protectedIDs = protected.ids
            if let victim = profile.byArrival.reversed().first(where: {
                !protectedIDs.contains($0.id)
            }) {
                candidateRetained = victim.id != candidate.id
                profile.ordered.remove(at: profile.ordered.firstIndex { $0.id == victim.id }!)
                profile.byWalk.remove(at: profile.byWalk.firstIndex { $0.id == victim.id }!)
                profile.byArrival.remove(at: profile.byArrival.firstIndex { $0.id == victim.id }!)
                let victimTrip = victim.lastTransit?.trip ?? -1
                profile.byIncomingTrip[victimTrip]?.removeAll { $0.id == victim.id }
            }
        }
        if !candidateRetained && removed.isEmpty {
            #if DEBUG
            if let referenceInput {
                let expected = referenceInsert(candidate, into: referenceInput)
                precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
            }
            #endif
            return false
        }
        if profile.ordered.count == profileWidth {
            let protected = membership ?? quotaMembership(in: profile)
            profile.lastUnprotectedArrival = profile.byArrival.reversed().first {
                !protected.ids.contains($0.id)
            }
            profile.lastPreferredArrival = protected.lastPreferred
        } else {
            profile.lastUnprotectedArrival = nil
            profile.lastPreferredArrival = nil
        }
        #if DEBUG
        if let referenceInput {
            let expected = referenceInsert(candidate, into: referenceInput)
            precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
        }
        #endif
        return candidateRetained
    }

    @inline(__always) static func quotaMembership(in profile: LabelProfile) -> (ids: [Int], lastPreferred: Label?) {
        let quota = profileWidth / 5
        var ids: [Int] = []
        ids.reserveCapacity(quota * 5)
        var preferredCount = 0
        var lastPreferred: Label?
        for label in profile.byArrival where label.containsPreferredMode {
            if preferredCount == quota { break }
            ids.append(label.id)
            lastPreferred = label
            preferredCount += 1
        }
        for label in profile.ordered.prefix(quota) { ids.append(label.id) }
        for label in profile.ordered.suffix(quota) { ids.append(label.id) }
        for label in profile.byWalk.prefix(quota) { ids.append(label.id) }
        for label in profile.byArrival.prefix(quota) { ids.append(label.id) }
        return (ids, preferredCount == quota ? lastPreferred : nil)
    }

    @inline(__always) static func arrivalOrder(_ lhs: Label, _ rhs: Label) -> Bool {
        lhs.time == rhs.time ? labelOrder(lhs, rhs) : lhs.time < rhs.time
    }

    static func referenceInsert(_ candidate: Label, into original: [Label]) -> [Label] {
        var profile = original
        if profile.contains(where: { dominates($0, candidate) }) { return profile }
        profile.removeAll { dominates(candidate, $0) }
        profile.append(candidate)
        if profile.count > profileWidth {
            let earliest = profile.sorted { labelOrder($0, $1) }
            let latest = profile.sorted { labelOrder($1, $0) }
            let lowWalk = profile.sorted {
                let a = $0.walkingSeconds
                let b = $1.walkingSeconds
                return a == b ? labelOrder($0, $1) : a < b
            }
            let earlyArrival = profile.sorted {
                $0.time == $1.time ? labelOrder($0, $1) : $0.time < $1.time
            }
            var selected: [Label] = []; var seen: Set<Int> = []
            let preferred = earlyArrival.filter(\.containsPreferredMode)
            for group in [preferred, earliest, latest, lowWalk, earlyArrival] {
                for label in group.prefix(profileWidth / 5) where seen.insert(label.id).inserted {
                    selected.append(label)
                }
            }
            for label in earlyArrival where selected.count < profileWidth && seen.insert(label.id).inserted {
                selected.append(label)
            }
            profile = selected
        }
        profile.sort(by: labelOrder)
        return profile
    }

    @inline(__always) static func insertSorted(
        _ candidate: Label,
        into values: inout [Label],
        by precedes: (Label, Label) -> Bool
    ) {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if precedes(values[middle], candidate) { lower = middle + 1 }
            else { upper = middle }
        }
        values.insert(candidate, at: lower)
    }
}
