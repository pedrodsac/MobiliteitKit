import Foundation

extension Raptor {
    /// Conservative upper bound on a useful walking transfer's arrival. Use
    /// the same service/window eligibility as trip preparation, but allow
    /// false positives (including nonchronological realtime instances).
    static func walkingBoardingDeadlines(snapshot: RoutingSnapshot, query: RouteQuery,
        serviceDays: [SnapshotServiceDay], patches: [PatchKey: PatchOverlay],
        scheduledLowerBound: Date, profileUpperBound: Date) throws -> [Date] {
        var latest = Array(repeating: Date.distantPast, count: snapshot.stops.count)
        for (tripIndex, trip) in snapshot.trips.enumerated() {
            try Task.checkCancellation()
            guard !trip.isFrequencyTemplate,
                  query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
            for day in serviceDays {
                guard day.activeServices.contains(trip.service),
                      day.start.addingTimeInterval(Double(trip.firstServiceTime)) <= profileUpperBound,
                      day.start.addingTimeInterval(Double(trip.lastServiceTime)) >= scheduledLowerBound else { continue }
                let patch = patches[.init(trip: tripIndex, serviceDate: day.date)]
                guard patch?.status != .cancelled, patch?.status != .unreachable else { continue }
                for (position, time) in trip.times.enumerated() where time.pickup == 0 {
                    guard patch?.eventsByPosition[position]?.boardingAllowed != false,
                          let seconds = time.departure else { continue }
                    let scheduled = day.start.addingTimeInterval(Double(seconds))
                    let effective = patchTime(patch, position: position, departure: true) ?? scheduled
                    let deadline = patch?.eventsByPosition[position]?.departureSource == .estimated
                        ? min(scheduled, effective) : effective
                    // Downstream departures may exceed the profile's upper
                    // bound, just as they can in the actual pattern scan.
                    latest[time.stop] = max(latest[time.stop], deadline)
                }
            }
        }
        return latest
    }
}
