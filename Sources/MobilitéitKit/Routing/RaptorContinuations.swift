import Foundation

extension Raptor {
    /// Closure within a vehicle-change round for explicit links and consecutive
    /// trips in a GTFS vehicle block. Explicit transfer restrictions take precedence.
    static func relaxContinuations(snapshot: RoutingSnapshot, query: RouteQuery,
        serviceDays: [SnapshotServiceDay], patches: [PatchKey: PatchOverlay], searchStart: Date,
        scheduledLowerBound: Date, upperBound: Date,
        labels: inout [Int: LabelProfile], nextLabelID: inout Int) throws {
        let links = Dictionary(grouping: snapshot.rulesByGroup.values.joined().filter {
            $0.type == 4 && $0.fromTrip != nil && $0.toTrip != nil
        }, by: { $0.fromTrip! })
        let patternByTrip = Dictionary(uniqueKeysWithValues: snapshot.patterns.enumerated().flatMap { index, pattern in
            pattern.trips.map { ($0, index) }
        })
        let blocks = Dictionary(grouping: snapshot.trips.indices.filter {
            snapshot.trips[$0].blockID?.isEmpty == false && !snapshot.trips[$0].isFrequencyTemplate
        }, by: { snapshot.trips[$0].blockID! })
        var instances: [Int: [ActiveTripInstance]] = [:]
        func activeInstances(_ target: Int) -> [ActiveTripInstance] {
            guard let pattern = patternByTrip[target] else { return [] }
            if instances[pattern] == nil {
                instances[pattern] = activeTripInstances(patternID: pattern, snapshot: snapshot, query: query,
                    relevantServiceDays: serviceDays, patchesByInstance: patches,
                    scheduledLowerBound: scheduledLowerBound, searchStart: searchStart,
                    profileUpperBound: upperBound, includeUnboardable: true)
            }
            return (instances[pattern] ?? []).filter { $0.tripIndex == target }
        }
        var queue = labels.keys.sorted().flatMap { labels[$0]?.ordered ?? [] }
        var cursor = 0
        while cursor < queue.count {
            try Task.checkCancellation()
            let source = queue[cursor]; cursor += 1
            guard let incoming = source.lastTransit, incoming.alightPos == snapshot.trips[incoming.trip].times.count - 1,
                  source.transferWalkSeconds == 0, source.time == incoming.alightTime else { continue }
            let blockTarget = blockSuccessor(snapshot: snapshot, incoming: incoming, members: snapshot.trips[incoming.trip].blockID.flatMap { blocks[$0] } ?? [])
            let targets = Set((links[incoming.trip] ?? []).compactMap(\.toTrip) + [blockTarget].compactMap { $0 }).sorted()
            for target in targets {
                let trip = snapshot.trips[target]
                let explicitLink = selectedTransferRule(snapshot: snapshot, incoming: incoming, at: incoming.alight, outgoing: target)?.type == 4
                guard trip.times[0].stop == incoming.alight,
                      permitsContinuation(snapshot: snapshot, incoming: incoming, outgoing: target, blockTarget: blockTarget) else { continue }
                for instance in activeInstances(target) {
                    if !explicitLink && instance.serviceDay.date != incoming.day { continue }
                    let day = instance.serviceDay.date
                    guard !source.tripKey.contains(.init(trip: target, day: day)),
                          let departure = instance.effectiveDepartures[0], let scheduled = instance.scheduledDepartures[0],
                          departure >= source.time, departure <= upperBound,
                          instance.boardingAllowed[0] else { continue }
                    for position in trip.times.indices.dropFirst() {
                        let stopTime = trip.times[position]
                        guard transitAllowed(snapshot: snapshot, trip: target, stop: stopTime.stop, preferences: query.preferences, stayingAboard: position == trip.times.count - 1),
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
