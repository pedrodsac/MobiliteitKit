import Foundation

extension JourneyPlanningSession {
    func freshBoardingReport(_ event: RealtimeStopEventPatch?) -> Bool {
        guard event?.departureSource == .reported else { return false }
        guard let observed = event?.departureObservedAt else { return true }
        return clock().timeIntervalSince(observed) < 60 && observed.timeIntervalSince(clock()) <= 60
    }

    /// Target actual reachable boardings, including late connections outside
    /// the initial ninety minutes. This does not run an extra RAPTOR search.
    func realtimeTargets(stopIDs: [String], arrivalByStop: [Int: Date], from: Date, through: Date,
                         configuration: RealtimeConfiguration, deadline: ContinuousClock.Instant,
                         patches: [RealtimePatchKey: RealtimeTripPatch],
                         reachability: Raptor.DestinationReachability) -> [RealtimeBoardTarget] {
        let days = snapshot.serviceDays.filter {
            $0.start <= through && $0.start.addingTimeInterval(Double(snapshot.info.maximumServiceTime.rawValue))
                >= from.addingTimeInterval(-Double(configuration.scheduledLookbackSeconds))
        }
        let downstreamReachable = reachability.stopsByRemainingRides[reachability.stopsByRemainingRides.count - 2]
        var targets: [RealtimeBoardTarget] = []
        for stopID in stopIDs {
            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            guard let stop = snapshot.stopByID[stopID], let reach = arrivalByStop[stop] else { continue }
            var departures: [Date] = []
            var lines: Set<String> = []
            var hasUnnamedLine = false
            for tripIndex in snapshot.tripIndicesByDepartureStop[stop] {
                if Task.isCancelled || ContinuousClock.now >= deadline { break }
                let trip = snapshot.trips[tripIndex]
                guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
                for day in days where day.activeServices.contains(trip.service) {
                    let patch = patches[.init(tripID: trip.id, serviceDate: day.date)]
                    guard patch?.status != .cancelled, patch?.status != .unreachable else { continue }
                    for position in trip.times.indices where trip.times[position].stop == stop {
                        let time = trip.times[position]
                        guard time.pickup == 0, let scheduled = time.departure,
                              trip.times.dropFirst(position + 1).contains(where: {
                                  $0.dropoff == 0 && downstreamReachable[$0.stop]
                                      && (query.direction != .arriveBy || $0.arrival.map {
                                          day.start.addingTimeInterval(Double($0)) <= through
                                      } == true)
                              }) else { continue }
                        let event = patch?.event(stopID: stopID, sequence: time.sequence)
                        guard event?.boardingAllowed != false, !freshBoardingReport(event) else { continue }
                        let departure = event?.effectiveDeparture ?? day.start.addingTimeInterval(Double(scheduled))
                        guard departure >= reach.addingTimeInterval(-Double(configuration.scheduledLookbackSeconds)),
                              departure <= through else { continue }
                        departures.append(departure)
                        if let name = snapshot.routes[trip.route].shortName, !name.isEmpty { lines.insert(name) }
                        else { hasUnnamedLine = true }
                    }
                }
            }
            let ordered = Array(Set(departures)).sorted {
                query.direction == .arriveBy ? $0 > $1 : $0 < $1
            }
            // Several candidate services fit in a single unrestricted board.
            // Eight temporal seeds leave room for alternatives without fetching
            // every departure in the 24-hour paging/arrival profile.
            for departure in ordered.prefix(8) {
                let start = max(from, departure.addingTimeInterval(-60))
                let end = min(through, start.addingTimeInterval(Double(configuration.minimumForwardHorizonSeconds)))
                if end >= start { targets.append(.init(stopID: stopID, from: start, through: end,
                    lines: hasUnnamedLine ? [] : lines.sorted())) }
            }
        }
        return targets
    }
}
