import Foundation

/// Post-process completed search routes; never infer a shortcut from a line
/// number. The very same trip instance must legally serve the walked-to stop.
enum RaptorWalkingShortcut {
    static func normalize(_ candidate: Raptor.Candidate, snapshot: RoutingSnapshot,
                          query: RouteQuery, egress: [JourneyPlanningSession.Edge],
                          patches: [RealtimePatchKey: RealtimeTripPatch]) -> Raptor.Candidate {
        var legs = candidate.legs
        var lastStop = candidate.lastStop
        var changed = false
        var index = 0
        while index < legs.count {
            guard case let .transit(ride) = legs[index] else { index += 1; continue }
            var end = index + 1
            var target: Int?
            var walkingArrival: Date?
            while end < legs.count {
                switch legs[end] {
                case let .walkingTransfer(walk): target = walk.to; walkingArrival = walk.arrival
                case let .pathway(walk): target = walk.to; walkingArrival = walk.arrival
                case .transit: break
                }
                if case .transit = legs[end] { break }
                end += 1
            }
            // Egress is outside the native legs. A selected destination stop
            // has an explicit zero-walk edge that can replace the final walk.
            var replacesEgress = false
            if end == legs.count, case let .stop(id) = query.destination,
               let destination = snapshot.stopByID[id],
               let edge = egress.first(where: { $0.stop == lastStop }), edge.walk != nil,
               egress.contains(where: { $0.stop == destination && $0.walk == nil }) {
                target = destination
                let lastArrival = walkingArrival ?? ride.alightTime
                walkingArrival = lastArrival.addingTimeInterval(Double(edge.seconds))
                replacesEgress = true
            }
            if let target, let walkingArrival,
               let shortcut = alighting(ride, at: target, noLaterThan: walkingArrival,
                                        snapshot: snapshot, preferences: query.preferences, patches: patches) {
                legs[index] = .transit(shortcut)
                if end > index + 1 { legs.removeSubrange((index + 1)..<end) }
                if replacesEgress { lastStop = target }
                changed = true
            }
            index += 1
        }
        guard changed else { return candidate }
        // Recompute the connection requirement at the actual alighting stop.
        // A shortcut that misses a scoped transfer minimum is rejected by the
        // ordinary validators, never repaired by retaining the pointless walk.
        var incoming: Raptor.TransitLeg?
        var movement = 0
        var walkingSeconds = 0
        var walkingDistance = 0.0
        var minimumSlack = Int.max
        var totalSlack = 0
        for index in legs.indices {
            switch legs[index] {
            case let .pathway(walk):
                movement += walk.seconds; walkingSeconds += walk.seconds; walkingDistance += walk.distance
            case let .walkingTransfer(walk):
                movement += walk.route.durationSeconds
                walkingSeconds += walk.route.durationSeconds; walkingDistance += walk.route.distanceMeters
            case let .transit(ride):
                if let incoming, !ride.continuesFromPrevious,
                   let allowance = Raptor.transferDecision(snapshot: snapshot, incoming: incoming,
                        at: ride.board, outgoing: ride.trip, preferences: query.preferences) {
                    let required = JourneyTransferArithmetic.requiredAfterWalking(totalMinimum: allowance.requiredSeconds,
                        walkingSeconds: Double(movement), boardingBufferSeconds: query.preferences.boardingBufferSeconds)
                    legs[index] = .transit(copy(ride, requiredTransferSeconds: required))
                    let slack = Int((ride.boardingDeadline ?? ride.boardTime).timeIntervalSince(incoming.alightTime)) - movement - required
                    minimumSlack = min(minimumSlack, slack); totalSlack += slack
                }
                incoming = ride; movement = 0
            }
        }
        let lastArrival: Date = switch legs.last! {
        case let .transit(ride): ride.alightTime
        case let .pathway(walk): walk.arrival
        case let .walkingTransfer(walk): walk.arrival
        }
        return .init(legs: legs, firstStop: candidate.firstStop, lastStop: lastStop,
            firstDeparture: candidate.firstDeparture, lastArrival: lastArrival,
            minimumTransferSlack: minimumSlack, totalTransferSlack: totalSlack,
            pathwaySeconds: walkingSeconds, pathwayDistance: walkingDistance)
    }

    /// Walking refinement can change which side of the arrival comparison
    /// wins. Publication must apply the same rule to accumulated domain routes.
    static func hasRedundantWalk(_ journey: Journey, snapshot: RoutingSnapshot,
                                 preferences: RoutingPreferences,
                                 patches: [RealtimePatchKey: RealtimeTripPatch]) -> Bool {
        for index in journey.legs.indices {
            guard case let .transit(ride) = journey.legs[index], let instance = ride.instance,
                  let tripIndex = snapshot.tripByID[ride.tripID],
                  let board = snapshot.trips[tripIndex].times.firstIndex(where: { $0.sequence == ride.boardSequence }),
                  let alight = snapshot.trips[tripIndex].times.firstIndex(where: { $0.sequence == ride.alightSequence })
            else { continue }
            var lastWalk: WalkingLeg?
            for leg in journey.legs.dropFirst(index + 1) {
                guard case let .walk(walk) = leg else { break }
                if walk.duration > 0 { lastWalk = walk }
            }
            guard let walk = lastWalk, let id = walk.to.stop?.id,
                  let target = snapshot.stopByID[id] else { continue }
            let native = Raptor.TransitLeg(trip: tripIndex, board: snapshot.trips[tripIndex].times[board].stop,
                alight: snapshot.trips[tripIndex].times[alight].stop, boardPos: board, alightPos: alight,
                day: instance.serviceDate, scheduledBoard: ride.scheduledDeparture,
                scheduledAlight: ride.scheduledArrival, boardTime: ride.effectiveDeparture,
                alightTime: ride.effectiveArrival, requiredTransferSecondsAfterWalking: ride.requiredTransferSecondsAfterWalking)
            if alighting(native, at: target, noLaterThan: walk.arrival, snapshot: snapshot,
                         preferences: preferences, patches: patches) != nil { return true }
        }
        return false
    }

    private static func alighting(_ ride: Raptor.TransitLeg, at stop: Int, noLaterThan arrival: Date,
                                  snapshot: RoutingSnapshot, preferences: RoutingPreferences,
                                  patches: [RealtimePatchKey: RealtimeTripPatch]) -> Raptor.TransitLeg? {
        let trip = snapshot.trips[ride.trip]
        let patch = patches[.init(tripID: trip.id, serviceDate: ride.day)]
        guard patch?.status ?? .active == .active,
              Raptor.transitAllowed(snapshot: snapshot, trip: ride.trip, stop: stop, preferences: preferences)
        else { return nil }
        for position in trip.times.indices where position > ride.boardPos {
            let time = trip.times[position]
            guard time.stop == stop, time.dropoff == 0, let seconds = time.arrival else { continue }
            let event = patch?.event(stopID: snapshot.stops[stop].id, sequence: time.sequence)
            guard event?.alightingAllowed != false else { continue }
            let scheduled = snapshot.converter.date(serviceDate: ride.day, serviceSeconds: seconds)
            let effective = event?.effectiveArrival ?? scheduled
            guard effective >= ride.boardTime, effective <= arrival else { continue }
            return .init(trip: ride.trip, board: ride.board, alight: stop, boardPos: ride.boardPos,
                alightPos: position, day: ride.day, scheduledBoard: ride.scheduledBoard,
                scheduledAlight: scheduled, boardTime: ride.boardTime, alightTime: effective,
                requiredTransferSecondsAfterWalking: ride.requiredTransferSecondsAfterWalking,
                continuesFromPrevious: ride.continuesFromPrevious, boardingDeadline: ride.boardingDeadline)
        }
        return nil
    }

    private static func copy(_ ride: Raptor.TransitLeg, requiredTransferSeconds: Int) -> Raptor.TransitLeg {
        .init(trip: ride.trip, board: ride.board, alight: ride.alight, boardPos: ride.boardPos,
            alightPos: ride.alightPos, day: ride.day, scheduledBoard: ride.scheduledBoard,
            scheduledAlight: ride.scheduledAlight, boardTime: ride.boardTime, alightTime: ride.alightTime,
            requiredTransferSecondsAfterWalking: requiredTransferSeconds,
            continuesFromPrevious: ride.continuesFromPrevious, boardingDeadline: ride.boardingDeadline)
    }
}
