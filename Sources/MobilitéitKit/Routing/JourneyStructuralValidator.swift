import Foundation

/// Includes frequency suffixes in tripID, so two frequency runs remain distinct.
public struct TransitInstanceIdentity: Hashable, Sendable {
    public let feedGeneration: Int
    public let tripID: String
    public let serviceDate: GTFSDate
    public init(feedGeneration: Int, tripID: String, serviceDate: GTFSDate) {
        self.feedGeneration = feedGeneration; self.tripID = tripID; self.serviceDate = serviceDate
    }
    public var stableKey: String { "g\(feedGeneration):\(tripID)@\(serviceDate.compactString)" }
}

/// Invalid static entities are quarantined from the routing snapshot, never repaired.
enum TripTimeline {
    static func isValid(_ times: [SnapshotTime]) -> Bool {
        var previous: Int32?
        var sequence: Int?
        for event in times {
            if let sequence, event.sequence <= sequence { return false }
            sequence = event.sequence
            for time in [event.arrival, event.departure].compactMap({ $0 }) {
                if time < 0 || previous.map({ time < $0 }) == true { return false }
                previous = time
            }
        }
        return true
    }
}

/// Search validation has feed context; presentation timing alone cannot prove these rules.
enum JourneyStructuralValidator {
    static func assess(_ candidate: Raptor.Candidate, snapshot: RoutingSnapshot,
                       query: RouteQuery) -> JourneyInfeasibility? {
        var seen: Set<Raptor.TripInstance> = []
        var at = candidate.firstStop
        var time: Date?
        var incoming: Raptor.TransitLeg?
        var movement = 0
        let rides = candidate.transitLegs
        var rideIndex = 0
        for leg in candidate.legs {
            switch leg {
            case let .transit(ride):
                guard snapshot.trips.indices.contains(ride.trip) else { return .invalidIdentity }
                let trip = snapshot.trips[ride.trip]
                guard trip.times.indices.contains(ride.boardPos), trip.times.indices.contains(ride.alightPos),
                      ride.boardPos < ride.alightPos,
                      trip.times[ride.boardPos].stop == ride.board,
                      trip.times[ride.alightPos].stop == ride.alight else { return .invalidOccurrence }
                guard snapshot.serviceDays.contains(where: {
                    $0.date == ride.day && $0.activeServices.contains(trip.service)
                }) else { return .inactiveService }
                let continuesNext = rideIndex + 1 < rides.count && rides[rideIndex + 1].continuesFromPrevious
                rideIndex += 1
                guard (ride.continuesFromPrevious || trip.times[ride.boardPos].pickup == 0),
                      (continuesNext || trip.times[ride.alightPos].dropoff == 0) else { return .forbiddenAction }
                guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type)
                else { return .constraintViolation }
                guard seen.insert(.init(trip: ride.trip, day: ride.day)).inserted else { return .repeatedTripInstance }
                guard at == ride.board else { return .disconnectedLegs }
                guard ride.alightTime >= ride.boardTime,
                      snapshot.stops[ride.board].model.coordinate == snapshot.stops[ride.alight].model.coordinate || ride.alightTime > ride.boardTime,
                      time.map({ ride.boardTime >= $0 }) != false else { return .overlappingLegs }
                if let incoming, ride.continuesFromPrevious {
                    guard incoming.alightPos == snapshot.trips[incoming.trip].times.count - 1, ride.boardPos == 0,
                          Raptor.permitsContinuation(snapshot: snapshot, incoming: incoming, outgoing: ride.trip,
                              blockTarget: ride.day == incoming.day ? Raptor.blockSuccessor(snapshot: snapshot, incoming: incoming) : nil)
                    else { return .invalidContinuation }
                } else if let incoming {
                    guard let allowance = Raptor.transferDecision(snapshot: snapshot, incoming: incoming,
                        at: ride.board, outgoing: ride.trip, preferences: query.preferences) else { return .forbiddenAction }
                    let required = max(allowance.requiredSeconds, movement + query.preferences.boardingBufferSeconds)
                    guard (ride.boardingDeadline ?? ride.boardTime).timeIntervalSince(incoming.alightTime) >= Double(required) else { return .missedTransfer }
                }
                at = ride.alight; time = ride.alightTime; incoming = ride; movement = 0
            case let .pathway(path):
                guard at == path.from else { return .disconnectedLegs }
                guard path.seconds > 0, path.distance.isFinite, path.distance >= 0,
                      path.arrival.timeIntervalSince(path.departure) == Double(path.seconds) else { return .invalidMovement }
                guard time.map({ path.departure >= $0 }) != false else { return .overlappingLegs }
                at = path.to; time = path.arrival; movement += path.seconds
            case let .walkingTransfer(walk):
                guard at == walk.from else { return .disconnectedLegs }
                guard walk.route.evidence == .routedPedestrian, walk.route.durationSeconds > 0,
                      walk.route.distanceMeters.isFinite, walk.route.distanceMeters >= 0,
                      walk.arrival.timeIntervalSince(walk.departure) == Double(walk.route.durationSeconds)
                else { return .invalidMovement }
                guard time.map({ walk.departure >= $0 }) != false else { return .overlappingLegs }
                at = walk.to; time = walk.arrival; movement += walk.route.durationSeconds
            }
        }
        return at == candidate.lastStop ? nil : .disconnectedLegs
    }
}

/// Runs before dominance and at every session publication, including refinement.
public enum JourneyPublicationValidator {
    public static func assess(_ journey: Journey, query: RouteQuery) -> JourneyFeasibility {
        let context = JourneyValidationContext(anchor: query.departureTime,
            arriveBy: query.direction == .arriveBy, minimumTransferSeconds: query.preferences.minimumTransferSeconds)
        let timing = JourneyItineraryValidator.assess(journey, context: context)
        if timing.isInvalid { return timing }
        if journey.hasCancelledTransitLeg { return .invalid(.forbiddenAction) }
        if let maximum = query.preferences.maxTransfers, journey.transferCount > maximum { return .invalid(.constraintViolation) }
        if let maximum = query.preferences.maximumWalkingSeconds, journey.walkingDuration > Double(maximum) { return .invalid(.constraintViolation) }
        if query.preferences.wheelchair == .required && journey.accessibility != .verified { return .invalid(.constraintViolation) }
        var instances: Set<TransitInstanceIdentity> = []
        var at: Coordinate?
        var stopID: String?
        var movement = 0.0
        var lastArrival: Date?
        var previousRide: TransitLeg?
        var continuation: InSeatContinuationLeg?
        for leg in journey.legs {
            switch leg {
            case let .walk(walk):
                guard walk.duration >= 0, walk.evidence == .routedPedestrian, walk.distanceMeters.isFinite, walk.distanceMeters >= 0,
                      walk.arrival.timeIntervalSince(walk.departure) == walk.duration,
                      walk.from.coordinate == walk.to.coordinate || walk.duration > 0 else { return .invalid(.invalidMovement) }
                if let at, at != walk.from.coordinate { return .invalid(.disconnectedLegs) }
                at = walk.to.coordinate; stopID = walk.to.stop?.id; lastArrival = walk.arrival
                if previousRide != nil { movement += walk.duration }
            case let .transit(ride):
                guard query.preferences.allowedModes.contains(routeType: ride.route.type) else { return .invalid(.constraintViolation) }
                if let identity = ride.instance {
                    guard identity.feedGeneration == journey.feedGeneration, identity.tripID == ride.tripID,
                          instances.insert(identity).inserted else { return .invalid(.invalidIdentity) }
                    guard let board = ride.boardSequence, let alight = ride.alightSequence, board < alight
                    else { return .invalid(.invalidOccurrence) }
                }
                if let at, at != ride.board.stop.coordinate || (stopID != nil && stopID != ride.board.stop.id) {
                    return .invalid(.disconnectedLegs)
                }
                if let deadline = ride.boardingDeadline, lastArrival.map({ $0 > deadline }) == true { return .invalid(.missedTransfer) }
                if continuation == nil, let incoming = previousRide,
                   (ride.boardingDeadline ?? ride.effectiveDeparture).timeIntervalSince(incoming.effectiveArrival) - movement - Double(ride.requiredTransferSecondsAfterWalking) < 0 { return .invalid(.missedTransfer) }
                var time = ride.effectiveDeparture
                for event in ride.intermediateStops {
                    guard event.effectiveTime >= time, event.effectiveTime <= ride.effectiveArrival else { return .invalid(.contradictoryRealtime) }
                    time = event.effectiveTime
                }
                if let continuation {
                    guard continuation.fromTripID == previousRide?.tripID, continuation.toTripID == ride.tripID
                    else { return .invalid(.invalidContinuation) }
                }
                continuation = nil; previousRide = ride; movement = 0
                at = ride.alight.stop.coordinate; stopID = ride.alight.stop.id; lastArrival = ride.effectiveArrival
            case let .inSeatContinuation(link):
                guard previousRide != nil, continuation == nil else { return .invalid(.invalidContinuation) }
                continuation = link
            }
        }
        if continuation != nil { return .invalid(.invalidContinuation) }
        let rideCount = journey.legs.filter { if case .transit = $0 { true } else { false } }.count
        let continuationCount = journey.legs.filter { if case .inSeatContinuation = $0 { true } else { false } }.count
        if journey.transferCount != max(0, rideCount - continuationCount - 1) { return .invalid(.constraintViolation) }
        return timing
    }
}
