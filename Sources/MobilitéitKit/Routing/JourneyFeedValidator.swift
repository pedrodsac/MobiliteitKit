import Foundation

/// Rechecks immutable feed identity at publication; walking callbacks cannot
/// create an occurrence, activate a service date or grant pickup permission.
enum JourneyFeedValidator {
    static func failure(_ journey: Journey, snapshot: RoutingSnapshot,
                        preferences: RoutingPreferences) -> JourneyInfeasibility? {
        guard journey.feedGeneration == snapshot.info.generation else { return .invalidIdentity }
        let rides = journey.legs.enumerated().compactMap { index, leg -> (Int, TransitLeg)? in
            if case let .transit(t) = leg { (index, t) } else { nil }
        }
        for (index, ride) in rides {
            guard let identity = ride.instance, let tripIndex = snapshot.tripByID[ride.tripID],
                  let boardSequence = ride.boardSequence, let alightSequence = ride.alightSequence else { return .invalidIdentity }
            let trip = snapshot.trips[tripIndex]
            guard let board = trip.position(of: boardSequence),
                  let alight = trip.position(of: alightSequence), board < alight,
                  snapshot.stops[trip.times[board].stop].id == ride.board.stop.id,
                  snapshot.stops[trip.times[alight].stop].id == ride.alight.stop.id else { return .invalidOccurrence }
            guard snapshot.serviceDayByDate[identity.serviceDate]?.activeServices.contains(trip.service) == true else { return .inactiveService }
            let continues = index > 0 && { if case .inSeatContinuation = journey.legs[index - 1] { true } else { false } }()
            let continuesNext = index + 1 < journey.legs.count && { if case .inSeatContinuation = journey.legs[index + 1] { true } else { false } }()
            guard (continues || trip.times[board].pickup == 0), (continuesNext || trip.times[alight].dropoff == 0) else { return .forbiddenAction }
            guard let departure = trip.times[board].departure, let arrival = trip.times[alight].arrival,
                  ride.scheduledDeparture == snapshot.date(serviceDate: identity.serviceDate, serviceSeconds: departure),
                  ride.scheduledArrival == snapshot.date(serviceDate: identity.serviceDate, serviceSeconds: arrival) else { return .invalidOccurrence }
            if preferences.bike == .required && trip.bikesAllowed != 1 { return .constraintViolation }
            if continues {
                guard board == 0, let previous = rides.last(where: { $0.0 < index }),
                      let incomingTrip = snapshot.tripByID[previous.1.tripID],
                      let position = snapshot.trips[incomingTrip].times.firstIndex(where: { $0.sequence == previous.1.alightSequence }),
                      position == snapshot.trips[incomingTrip].times.count - 1 else { return .invalidContinuation }
                let incoming = Raptor.TransitLeg(trip: incomingTrip, board: trip.times[board].stop,
                    alight: trip.times[board].stop, boardPos: 0, alightPos: position,
                    day: previous.1.instance!.serviceDate, scheduledBoard: previous.1.scheduledDeparture,
                    scheduledAlight: previous.1.scheduledArrival, boardTime: previous.1.effectiveDeparture,
                    alightTime: previous.1.effectiveArrival, requiredTransferSecondsAfterWalking: 0)
                guard Raptor.selectedTransferRule(snapshot: snapshot, incoming: incoming, at: trip.times[board].stop,
                    outgoing: tripIndex)?.type == 4 else { return .invalidContinuation }
            }
        }
        return nil
    }
}
