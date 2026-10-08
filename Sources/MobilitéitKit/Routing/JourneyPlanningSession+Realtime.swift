import Foundation

extension JourneyPlanningSession {
    /// Plan optimistic discovery before fetching. Selected itinerary boards and
    /// other reachable lines share one concurrent batch and one full deadline.
    /// RAPTOR will prove feasibility using the resulting live observations.
    func discoveryRealtimeTargets(access: [Edge], egress: [Edge], journeys: [Journey],
                                  preferredStops: [String], anchor: Date, searchHorizon: TimeInterval,
                                  deadline: ContinuousClock.Instant,
                                  requestedInstances: Set<RealtimePatchKey>)
        -> (targets: [RealtimeBoardTarget], tripIDs: Set<String>) {
        guard case let .bestEffort(configuration, _) = query.realtimePolicy else { return ([], []) }
        let from = query.direction == .arriveBy ? anchor.addingTimeInterval(-searchHorizon) : anchor
        let through = query.direction == .arriveBy ? anchor : anchor.addingTimeInterval(searchHorizon)
        let maxRides = min(8, max(1, (query.preferences.maxTransfers ?? 7) + 1))
        let reachability = Raptor.DestinationReachability(snapshot: snapshot,
            egressStops: Set(egress.map(\.stop)), maxRides: maxRides + 1)
        var arrivals = Dictionary(access.map { ($0.stop, from.addingTimeInterval(Double($0.seconds))) },
                                  uniquingKeysWith: min)
        func reach(_ stopID: String, at date: Date) {
            guard let stop = snapshot.stopByID[stopID] else { return }
            arrivals[stop] = min(arrivals[stop] ?? .distantFuture, date)
        }
        for journey in journeys {
            for leg in journey.legs {
                switch leg {
                case let .transit(ride):
                    reach(ride.board.stop.id, at: ride.effectiveDeparture)
                    reach(ride.alight.stop.id, at: ride.effectiveArrival)
                case let .walk(walk):
                    if let stop = walk.to.stop { reach(stop.id, at: walk.arrival) }
                case .inSeatContinuation: break
                }
            }
        }
        let accessStops = access.sorted { left, right in
            let a = reachability.stopsByRemainingRides.firstIndex { $0[left.stop] } ?? Int.max
            let b = reachability.stopsByRemainingRides.firstIndex { $0[right.stop] } ?? Int.max
            return a != b ? a < b : (left.seconds != right.seconds ? left.seconds < right.seconds : left.stop < right.stop)
        }.prefix(8).map { snapshot.stops[$0.stop].id }
        let preferred = Set(preferredStops)
        var seen: Set<String> = []
        var frontier = (preferredStops + accessStops).filter { seen.insert($0).inserted }
        var queried: Set<String> = []
        var targets: [RealtimeBoardTarget] = []
        var matchingTripIDs: Set<String> = []
        for _ in 0..<min(4, max(1, configuration.maximumRefinementWaves)) {
            guard !Task.isCancelled, !frontier.isEmpty, ContinuousClock.now < deadline else { break }
            // Existing itinerary stops keep priority and can acquire other lines.
            let available = max(0, 24 - queried.union(preferred).count)
            let additional = Set(frontier.filter { !preferred.contains($0) }.prefix(available))
            frontier = frontier.filter { preferred.contains($0) || additional.contains($0) }
            guard !frontier.isEmpty else { break }
            targets += realtimeTargets(stopIDs: frontier, arrivalByStop: arrivals,
                from: from, through: through, configuration: configuration, deadline: deadline,
                patches: latestPatchesByInstance, reachability: reachability, excludingInstances: requestedInstances,
                matchingTripIDs: &matchingTripIDs)
            queried.formUnion(frontier)
            frontier = realtimeFrontier(arrivalByStop: &arrivals, egress: egress, from: from, through: through,
                lookback: configuration.scheduledLookbackSeconds, deadline: deadline,
                patches: latestPatchesByInstance, excluding: queried, reachability: reachability)
        }
        return (targets, matchingTripIDs)
    }

    /// Temporal, destination-aware discovery includes delayed-past candidates,
    /// not just static winners. One board covers that vehicle's downstream events;
    /// another board is useful when its outgoing trips have not been acquired.
    private func realtimeFrontier(arrivalByStop: inout [Int: Date], egress: [Edge], from: Date, through: Date,
                                  lookback: Int, deadline: ContinuousClock.Instant,
                                  patches: [RealtimePatchKey: RealtimeTripPatch],
                                  excluding: Set<String>, reachability: Raptor.DestinationReachability) -> [String] {
        let serviceDays = snapshot.serviceDays.filter {
            $0.start <= through && $0.start.addingTimeInterval(Double(snapshot.info.maximumServiceTime.rawValue))
                >= from.addingTimeInterval(-Double(lookback))
        }
        // Carry an optimistic reachability envelope forward one ride per wave.
        // Recomputing all prior rides would make four waves perform ten scans.
        // Reports can improve the envelope; final RAPTOR alone proves feasibility.
        var improved = arrivalByStop
        for (stop, reach) in arrivalByStop {
            if Task.isCancelled || ContinuousClock.now >= deadline { return [] }
            for tripIndex in snapshot.tripIndicesByDepartureStop[stop] {
                if Task.isCancelled || ContinuousClock.now >= deadline { return [] }
                let trip = snapshot.trips[tripIndex]
                guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type)
                else { continue }
                for day in serviceDays where day.activeServices.contains(trip.service) {
                    let patch = patches[.init(tripID: trip.id, serviceDate: day.date)]
                    guard patch?.status != .cancelled, patch?.status != .unreachable else { continue }
                    for position in trip.times.indices where trip.times[position].stop == stop {
                        let board = trip.times[position]
                        guard board.pickup == 0, let time = board.departure else { continue }
                        let event = patch?.event(stopID: snapshot.stops[stop].id, sequence: board.sequence)
                        let departure = event?.effectiveDeparture ?? day.start.addingTimeInterval(Double(time))
                        guard event?.boardingAllowed != false,
                              departure >= reach.addingTimeInterval(freshBoardingReport(event) ? 0 : -Double(lookback)), departure <= through
                        else { continue }
                        let rescue = max(0, reach.timeIntervalSince(departure))
                        for downstream in trip.times[(position + 1)...] where downstream.dropoff == 0 {
                            guard let scheduled = downstream.arrival else { continue }
                            let report = patch?.event(stopID: snapshot.stops[downstream.stop].id,
                                                      sequence: downstream.sequence)
                            guard report?.alightingAllowed != false else { continue }
                            let arrival = (report?.effectiveArrival ?? day.start.addingTimeInterval(Double(scheduled)))
                                .addingTimeInterval(rescue)
                            guard arrival <= through else { continue }
                            improved[downstream.stop] = min(improved[downstream.stop] ?? .distantFuture, arrival)
                            for neighbor in snapshot.nearbyTransferStopsByStop[downstream.stop] {
                                improved[neighbor] = min(improved[neighbor] ?? .distantFuture, arrival)
                            }
                        }
                    }
                }
            }
        }
        arrivalByStop = improved
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return [] }
        let reachableAfterBoarding = reachability.stopsByRemainingRides[reachability.stopsByRemainingRides.count - 2]
        let remainingRides = snapshot.stops.indices.map { stop in
            reachability.stopsByRemainingRides.firstIndex { $0[stop] } ?? Int.max
        }
        let target = egress.first.map { snapshot.stops[$0.stop].model.coordinate }
        return arrivalByStop.keys.filter { stop in
            !excluding.contains(snapshot.stops[stop].id) && snapshot.boardableStops.contains(stop)
                && snapshot.tripIndicesByDepartureStop[stop].contains { tripIndex in
                    let trip = snapshot.trips[tripIndex]
                    guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type)
                    else { return false }
                    return serviceDays.contains { day in
                        guard day.activeServices.contains(trip.service) else { return false }
                        let patch = patches[.init(tripID: trip.id, serviceDate: day.date)]
                        guard patch?.status != .cancelled, patch?.status != .unreachable else { return false }
                        return trip.times.indices.contains { position in
                            let time = trip.times[position]
                            guard time.stop == stop, time.pickup == 0, let departure = time.departure else { return false }
                            let event = patch?.event(stopID: snapshot.stops[stop].id, sequence: time.sequence)
                            guard !freshBoardingReport(event), event?.boardingAllowed != false else { return false }
                            let date = event?.effectiveDeparture ?? day.start.addingTimeInterval(Double(departure))
                            return date >= arrivalByStop[stop]!.addingTimeInterval(-Double(lookback)) && date <= through
                                && trip.times.dropFirst(position + 1).contains {
                                    $0.dropoff == 0 && reachableAfterBoarding[$0.stop]
                                }
                        }
                    }
                }
        }.sorted { left, right in
            if remainingRides[left] != remainingRides[right] {
                return remainingRides[left] < remainingRides[right]
            }
            let a = arrivalByStop[left]!; let b = arrivalByStop[right]!
            if a != b { return a < b }
            if let target {
                return distance(snapshot.stops[left].model.coordinate, target)
                    < distance(snapshot.stops[right].model.coordinate, target)
            }
            return snapshot.stops[left].id < snapshot.stops[right].id
        }.prefix(8).map { snapshot.stops[$0].id }
    }
}
