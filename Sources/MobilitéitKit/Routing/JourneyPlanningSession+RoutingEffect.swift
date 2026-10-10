import Foundation

extension JourneyPlanningSession {
    /// Freshness, platforms and on-time reports still update the result. A full
    /// feasibility scan is needed only when its actual routing inputs change.
    func routingEffectChanged(from previous: [RealtimePatchKey: RealtimeTripPatch]) -> Bool {
        for (key, patch) in latestPatchesByInstance where patch != previous[key] {
            guard let tripIndex = snapshot.tripByID[key.tripID] else { continue }
            let old = previous[key]
            if patch.status != (old?.status ?? .active) { return true }
            guard patch.status == .active else { continue }
            for time in snapshot.trips[tripIndex].times {
                let stopID = snapshot.stops[time.stop].id
                let before = old?.event(stopID: stopID, sequence: time.sequence)
                let after = patch.event(stopID: stopID, sequence: time.sequence)
                let scheduledDeparture = time.departure.map {
                    snapshot.date(serviceDate: key.serviceDate, serviceSeconds: $0)
                }
                let scheduledArrival = time.arrival.map {
                    snapshot.date(serviceDate: key.serviceDate, serviceSeconds: $0)
                }
                let oldDeparture = before?.effectiveDeparture ?? scheduledDeparture
                let newDeparture = after?.effectiveDeparture ?? scheduledDeparture
                let oldArrival = before?.effectiveArrival ?? scheduledArrival
                let newArrival = after?.effectiveArrival ?? scheduledArrival
                if oldDeparture != newDeparture || oldArrival != newArrival
                    || (before?.boardingAllowed != false) != (after?.boardingAllowed != false)
                    || (before?.alightingAllowed != false) != (after?.alightingAllowed != false) { return true }
                func deadline(_ event: RealtimeStopEventPatch?, effective: Date?) -> Date? {
                    if event?.departureSource == .estimated, let scheduledDeparture, let effective {
                        return min(scheduledDeparture, effective)
                    }
                    return effective
                }
                if deadline(before, effective: oldDeparture) != deadline(after, effective: newDeparture) { return true }
            }
        }
        return false
    }
}
