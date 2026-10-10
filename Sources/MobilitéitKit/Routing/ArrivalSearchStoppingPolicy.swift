import Foundation

/// Older departures rank behind a complete recent arrive-by selection. They
/// cannot change its presentation either when outside the 20-minute comparison
/// range and unable to board any of the same first vehicle occurrences.
enum ArrivalSearchStoppingPolicy {
    static func canStop(_ selected: [Journey], count: Int, lower: Date,
                        snapshot: RoutingSnapshot, patches: [RealtimePatchKey: RealtimeTripPatch],
                        access: [JourneyPlanningSession.Edge]) -> Bool {
        guard count > 0, selected.count >= count else { return false }
        let accessSeconds = Dictionary(access.map { ($0.stop, $0.seconds) }, uniquingKeysWith: min)
        for journey in selected {
            guard journey.effectiveDeparture > lower.addingTimeInterval(20 * 60),
                  let first = journey.firstRide, let instance = first.instance,
                  let index = snapshot.tripByID[first.tripID] else { return false }
            let trip = snapshot.trips[index]
            let key = RealtimePatchKey(tripID: first.tripID, serviceDate: instance.serviceDate)
            let patch = patches[key]
            // Include every pickup reachable by a validated access walk. An older
            // variant of this first vehicle could otherwise change suggestion
            // filtering even though it cannot improve the departure ranking.
            var checkedBoarding = false
            for time in trip.times where time.pickup == 0 {
                guard let departure = time.departure, let walkingSeconds = accessSeconds[time.stop] else { continue }
                checkedBoarding = true
                let scheduled = snapshot.date(serviceDate: instance.serviceDate, serviceSeconds: departure)
                let event = patch?.event(stopID: snapshot.stops[time.stop].id, sequence: time.sequence)
                let effective = event?.effectiveDeparture ?? scheduled
                let deadline = event?.departureSource == .estimated ? min(scheduled, effective) : effective
                if deadline.addingTimeInterval(-Double(walkingSeconds)) < lower { return false }
            }
            if !checkedBoarding { return false }
        }
        return true
    }
}
