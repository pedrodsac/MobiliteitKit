import Foundation

/// Advances the optimistic discovery envelope by exactly one vehicle ride.
/// A single trip pass carries the smallest boarding delay to each later stop;
/// final RAPTOR still proves physical walking and transfer feasibility.
enum RealtimeReachability {
    static func advance(_ arrivals: [Int: Date], snapshot: RoutingSnapshot,
                        serviceDays: [SnapshotServiceDay], allowedModes: TransitModeMask,
                        through: Date, lookback: Int, deadline: ContinuousClock.Instant,
                        patches: [RealtimePatchKey: RealtimeTripPatch],
                        freshBoardingReport: (RealtimeStopEventPatch?) -> Bool) -> [Int: Date]? {
        var marked = [Bool](repeating: false, count: snapshot.trips.count)
        for stop in arrivals.keys {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            for trip in snapshot.tripIndicesByDepartureStop[stop] { marked[trip] = true }
        }
        var improved = arrivals
        for tripIndex in snapshot.trips.indices where marked[tripIndex] {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let trip = snapshot.trips[tripIndex]
            guard allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
            for day in serviceDays where day.activeServices.contains(trip.service) {
                let patch = patches[.init(tripID: trip.id, serviceDate: day.date)]
                guard patch?.status != .cancelled, patch?.status != .unreachable else { continue }
                var minimumRescue: TimeInterval?
                for time in trip.times {
                    let event = patch?.event(stopID: snapshot.stops[time.stop].id, sequence: time.sequence)
                    // Alighting precedes boarding at this occurrence, so a
                    // vehicle ride always spans at least one stop interval.
                    if let rescue = minimumRescue, time.dropoff == 0, event?.alightingAllowed != false,
                       let scheduled = time.arrival {
                        let arrival = (event?.effectiveArrival ?? day.start.addingTimeInterval(Double(scheduled)))
                            .addingTimeInterval(rescue)
                        if arrival <= through {
                            improved[time.stop] = min(improved[time.stop] ?? .distantFuture, arrival)
                            for neighbor in snapshot.nearbyTransferStopsByStop[time.stop] {
                                improved[neighbor] = min(improved[neighbor] ?? .distantFuture, arrival)
                            }
                        }
                    }
                    guard let reach = arrivals[time.stop], time.pickup == 0,
                          event?.boardingAllowed != false, let scheduled = time.departure else { continue }
                    let departure = event?.effectiveDeparture ?? day.start.addingTimeInterval(Double(scheduled))
                    guard departure >= reach.addingTimeInterval(freshBoardingReport(event) ? 0 : -Double(lookback)),
                          departure <= through else { continue }
                    let rescue = max(0, reach.timeIntervalSince(departure))
                    minimumRescue = min(minimumRescue ?? .infinity, rescue)
                }
            }
        }
        return improved
    }
}
