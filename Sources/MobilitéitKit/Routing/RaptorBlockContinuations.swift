import Foundation

extension Raptor {
    /// GTFS block IDs identify a vehicle's consecutive trips on a service day.
    /// Reject ambiguous blocks instead of guessing which vehicle a rider remains on.
    static func blockSuccessor(snapshot: RoutingSnapshot, incoming: TransitLeg, members: [Int]? = nil) -> Int? {
        let trip = snapshot.trips[incoming.trip]
        guard let block = trip.blockID, !block.isEmpty, !trip.isFrequencyTemplate,
              let day = snapshot.serviceDayByDate[incoming.day] else { return nil }
        let candidates = (members ?? snapshot.continuations.blockTripsByID[block] ?? []).filter {
            $0 != incoming.trip && !snapshot.trips[$0].isFrequencyTemplate && day.activeServices.contains(snapshot.trips[$0].service)
        }
        // Scheduled order remains authoritative under delays and cancellations.
        // An intervening trip cannot be skipped to reach a convenient stop.
        guard !candidates.contains(where: {
            let other = snapshot.trips[$0]
            return other.firstServiceTime < trip.lastServiceTime && other.lastServiceTime > trip.firstServiceTime
        }) else { return nil }
        let following = candidates.filter { snapshot.trips[$0].firstServiceTime >= trip.lastServiceTime }
        guard let nextTime = following.map({ snapshot.trips[$0].firstServiceTime }).min() else { return nil }
        let next = following.filter { snapshot.trips[$0].firstServiceTime == nextTime }
        guard next.count == 1, let target = next.first,
              snapshot.trips[target].times.first?.stop == trip.times.last?.stop,
              snapshot.routes[snapshot.trips[target].route].type == snapshot.routes[trip.route].type else { return nil }
        return target
    }

    static func permitsContinuation(snapshot: RoutingSnapshot, incoming: TransitLeg, outgoing: Int, blockTarget: Int?) -> Bool {
        let rule = selectedTransferRule(snapshot: snapshot, incoming: incoming, at: incoming.alight, outgoing: outgoing)
        if rule?.type == 4 { return true }
        // Generic boarding buffers apply to changes, not a continuing vehicle.
        // Explicit must-alight links and scoped restrictions still take precedence.
        if let rule, rule.type == 3 || rule.type == 5 || rule.fromTrip != nil || rule.toTrip != nil || rule.fromRoute != nil || rule.toRoute != nil {
            return false
        }
        return outgoing == blockTarget
    }
}
