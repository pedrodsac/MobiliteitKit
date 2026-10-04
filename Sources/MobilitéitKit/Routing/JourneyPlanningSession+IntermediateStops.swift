import Foundation

extension JourneyPlanningSession {
    /// Ranking depends on boarding/alighting occurrences, not intermediate
    /// presentation events. Materialize those only for surviving journeys.
    func addingIntermediateStops(to journey: Journey) -> Journey {
        journey.replacing(legs: journey.legs.map { leg in
            guard case var .transit(ride) = leg, let instance = ride.instance,
                  let tripIndex = snapshot.tripByID[ride.tripID],
                  let boardSequence = ride.boardSequence, let alightSequence = ride.alightSequence else { return leg }
            let trip = snapshot.trips[tripIndex]
            let patch = latestPatchesByInstance[.init(tripID: ride.tripID, serviceDate: instance.serviceDate)]
            ride.intermediateStops = trip.times.filter {
                $0.sequence > boardSequence && $0.sequence < alightSequence
            }.map { time in
                let stop = snapshot.stops[time.stop].model
                let event = patch?.event(stopID: stop.id, sequence: time.sequence)
                let scheduled = snapshot.converter.date(serviceDate: instance.serviceDate,
                    serviceSeconds: time.arrival ?? time.departure ?? 0)
                return JourneyStopEvent(stop: stop, scheduledTime: scheduled,
                    effectiveTime: event?.effectiveArrival ?? event?.effectiveDeparture ?? scheduled,
                    timingSource: event?.arrivalSource ?? event?.departureSource ?? .scheduled,
                    platform: event?.platform ?? stop.platformCode)
            }
            return .transit(ride)
        })
    }
}
