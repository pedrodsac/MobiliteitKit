import Foundation

extension Raptor {
    /// Closure within a vehicle-change round for explicit links and consecutive
    /// trips in a GTFS vehicle block. Explicit transfer restrictions take precedence.
    static func relaxContinuations(snapshot: RoutingSnapshot, query: RouteQuery,
        serviceDays: [SnapshotServiceDay], patches: [PatchKey: PatchOverlay], searchStart: Date,
        scheduledLowerBound: Date, upperBound: Date, reachableStops: [Bool]?, preparation: inout PreparationCache,
        labels: inout [Int: LabelProfile], nextLabelID: inout Int) throws {
        var instances: [Int: [ActiveTripInstance]] = [:]
        func activeInstances(_ target: Int, preparation: inout PreparationCache) -> [ActiveTripInstance] {
            if let cached = instances[target] { return cached }
            let trip = snapshot.trips[target]
            guard !trip.isFrequencyTemplate,
                  query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { return [] }
            let active = serviceDays.compactMap { day -> ActiveTripInstance? in
                guard day.activeServices.contains(trip.service),
                      day.start.addingTimeInterval(TimeInterval(trip.firstServiceTime)) <= upperBound,
                      day.start.addingTimeInterval(TimeInterval(trip.lastServiceTime)) >= scheduledLowerBound else { return nil }
                let patch = patches[.init(trip: target, serviceDate: day.date)]
                guard patch?.status != .unreachable, patch?.status != .cancelled else { return nil }
                return preparation.instance(tripIndex: target, trip: trip, day: day, overlay: patch)
            }
            instances[target] = active
            return active
        }
        var queue = labels.keys.sorted().flatMap { labels[$0]?.ordered ?? [] }
        var cursor = 0
        while cursor < queue.count {
            try Task.checkCancellation()
            let source = queue[cursor]; cursor += 1
            guard let incoming = source.lastTransit, incoming.alightPos == snapshot.trips[incoming.trip].times.count - 1,
                  source.transferWalkSeconds == 0, source.time == incoming.alightTime else { continue }
            let blockTarget = blockSuccessor(snapshot: snapshot, incoming: incoming)
            let targets = Set(snapshot.continuations.explicitTargetsByTrip[incoming.trip] + [blockTarget].compactMap { $0 }).sorted()
            for target in targets {
                let trip = snapshot.trips[target]
                let explicitLink = selectedTransferRule(snapshot: snapshot, incoming: incoming, at: incoming.alight, outgoing: target)?.type == 4
                guard trip.times[0].stop == incoming.alight,
                      permitsContinuation(snapshot: snapshot, incoming: incoming, outgoing: target, blockTarget: blockTarget) else { continue }
                for instance in activeInstances(target, preparation: &preparation) {
                    if !explicitLink && instance.serviceDay.date != incoming.day { continue }
                    let day = instance.serviceDay.date
                    guard !source.tripKey.contains(.init(trip: target, day: day)),
                          let departure = instance.effectiveDepartures[0], let scheduled = instance.scheduledDepartures[0],
                          departure >= source.time, departure <= upperBound,
                          instance.boardingAllowed[0] else { continue }
                    for position in trip.times.indices.dropFirst() {
                        let stopTime = trip.times[position]
                        guard reachableStops?[stopTime.stop] != false,
                              transitAllowed(snapshot: snapshot, trip: target, stop: stopTime.stop, preferences: query.preferences, stayingAboard: position == trip.times.count - 1),
                              (stopTime.dropoff == 0 || position == trip.times.count - 1),
                              instance.alightingAllowed[position],
                              let arrival = instance.effectiveArrivals[position],
                              let scheduledArrival = instance.scheduledArrivals[position], arrival <= upperBound else { continue }
                        var leg = TransitLeg(trip: target, board: incoming.alight, alight: stopTime.stop,
                            boardPos: 0, alightPos: position, day: day, scheduledBoard: scheduled,
                            scheduledAlight: scheduledArrival, boardTime: departure, alightTime: arrival,
                            requiredTransferSecondsAfterWalking: 0)
                        leg.continuesFromPrevious = true
                        let label = Label(id: nextLabelID, time: arrival, prior: source, appendedLeg: .transit(leg),
                            firstStop: source.firstStop, firstDeparture: source.firstDeparture,
                            lastTransit: leg, minimumSlack: source.minimumSlack, totalSlack: source.totalSlack,
                            accessSeconds: source.accessSeconds, accessDistance: source.accessDistance,
                            pathwaySeconds: source.pathwaySeconds, pathwayDistance: source.pathwayDistance,
                            transferWalkSeconds: 0,
                            containsPreferredMode: source.containsPreferredMode || (query.preferences.preferredMode?.contains(routeType: snapshot.routes[trip.route].type) ?? false),
                            walkingStopsVisited: .one(stopTime.stop), tripKey: source.tripKey.appending(.init(trip: target, day: day)))
                        nextLabelID += 1
                        if insert(label, at: stopTime.stop, into: &labels) { queue.append(label) }
                    }
                }
            }
        }
    }
}
