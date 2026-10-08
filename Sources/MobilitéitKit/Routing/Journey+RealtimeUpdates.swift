import Foundation

extension Journey {
    /// Revalidate accumulated pages against newly acquired occurrence evidence.
    /// Pedestrian durations/geometry stay measured; walks after a changed ride
    /// move with its arrival and undergo the normal publication validation.
    func applyingRealtime(_ patches: [RealtimePatchKey: RealtimeTripPatch]) -> Journey? {
        var updated: [JourneyLeg] = []
        var arrivalShift: TimeInterval = 0
        for leg in legs {
            switch leg {
            case let .transit(ride):
                guard let instance = ride.instance,
                      let patch = patches[.init(tripID: ride.tripID, serviceDate: instance.serviceDate)],
                      let boardSequence = ride.boardSequence, let alightSequence = ride.alightSequence else {
                    updated.append(leg); arrivalShift = 0; continue
                }
                let boarding = patch.event(stopID: ride.board.stop.id, sequence: boardSequence)
                let alighting = patch.event(stopID: ride.alight.stop.id, sequence: alightSequence)
                guard patch.status == .active, boarding?.boardingAllowed != false,
                      alighting?.alightingAllowed != false else { return nil }
                let departure = boarding?.effectiveDeparture ?? ride.effectiveDeparture
                let arrival = alighting?.effectiveArrival ?? ride.effectiveArrival
                var remaining = patch.events.filter {
                    $0.stopSequence.map { $0 > boardSequence && $0 < alightSequence } == true
                }.sorted { ($0.stopSequence ?? 0) < ($1.stopSequence ?? 0) }
                let intermediate = ride.intermediateStops.map { old -> JourneyStopEvent in
                    guard let index = remaining.firstIndex(where: { $0.stopID == old.stop.id }) else { return old }
                    let event = remaining[index]
                    remaining.removeSubrange(...index)
                    return .init(stop: old.stop, scheduledTime: old.scheduledTime,
                        effectiveTime: event.effectiveArrival ?? event.effectiveDeparture ?? old.effectiveTime,
                        timingSource: event.effectiveArrival == nil ? event.departureSource : event.arrivalSource,
                        platform: event.platform ?? old.platform)
                }
                var replacement = TransitLeg(tripID: ride.tripID, route: ride.route, headsign: ride.headsign,
                    board: .init(stop: ride.board.stop, scheduledTime: ride.scheduledDeparture,
                                 effectiveTime: departure, timingSource: boarding?.departureSource ?? ride.board.timingSource,
                                 platform: boarding?.platform ?? ride.board.platform),
                    alight: .init(stop: ride.alight.stop, scheduledTime: ride.scheduledArrival,
                                 effectiveTime: arrival, timingSource: alighting?.arrivalSource ?? ride.alight.timingSource,
                                 platform: alighting?.platform ?? ride.alight.platform),
                    intermediateStops: intermediate,
                    scheduledDeparture: ride.scheduledDeparture, scheduledArrival: ride.scheduledArrival,
                    effectiveDeparture: departure, effectiveArrival: arrival, status: patch.status,
                    requiredTransferSecondsAfterWalking: ride.requiredTransferSecondsAfterWalking)
                replacement.boardingDeadline = ride.boardingDeadline.map {
                    $0.addingTimeInterval(departure.timeIntervalSince(ride.effectiveDeparture))
                }
                replacement.requiredTotalTransferSeconds = ride.requiredTotalTransferSeconds
                replacement.recommendedTotalTransferSeconds = ride.recommendedTotalTransferSeconds
                replacement.instance = instance; replacement.boardSequence = boardSequence
                replacement.alightSequence = alightSequence; replacement.polyline = ride.polyline
                updated.append(.transit(replacement))
                arrivalShift = arrival.timeIntervalSince(ride.effectiveArrival)
            case let .walk(walk):
                var replacement = WalkingLeg(from: walk.from, to: walk.to,
                    departure: walk.departure.addingTimeInterval(arrivalShift),
                    arrival: walk.arrival.addingTimeInterval(arrivalShift), duration: walk.duration,
                    distanceMeters: walk.distanceMeters, polyline: walk.polyline, steps: walk.steps,
                    source: walk.source, evidence: walk.evidence)
                replacement.nativeRange = walk.nativeRange
                updated.append(.walk(replacement))
            case .inSeatContinuation: updated.append(leg)
            }
        }
        let revised = replacing(legs: updated)
        let vehicle = updated.reduce(0.0) { total, leg in
            if case let .transit(ride) = leg { total + ride.effectiveArrival.timeIntervalSince(ride.effectiveDeparture) }
            else { total }
        }
        return .init(id: id, origin: origin, destination: destination,
            scheduledDeparture: scheduledDeparture, scheduledArrival: scheduledArrival,
            effectiveDeparture: revised.effectiveDeparture, effectiveArrival: revised.effectiveArrival,
            transferCount: transferCount, walkingDuration: revised.walkingDuration,
            walkingDistance: revised.walkingDistance,
            waitingDuration: max(0, revised.duration - vehicle - revised.walkingDuration),
            inVehicleDuration: vehicle, legs: updated, feedGeneration: feedGeneration,
            accessibility: accessibility, matchesPreferredMode: matchesPreferredMode)
    }
}
