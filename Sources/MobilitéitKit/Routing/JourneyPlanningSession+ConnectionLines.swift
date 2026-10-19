import Foundation

extension JourneyPlanningSession {
    /// What a rider who reaches a stop by another ride can board for the rest of the way.
    struct ConnectionLines: Equatable, Sendable {
        /// Named lines with a qualifying departure.
        var lines: Set<String> = []
        /// A qualifying departure has no line name, so only an unrestricted board covers it.
        var unrestricted = false
        /// Every trip behind those departures, so the board's rows for them are matched.
        var tripIDs: Set<String> = []
    }

    struct ConnectionKey: Hashable {
        let stopID: String
        let arrival: Date
    }

    var maximumRealtimeRides: Int { min(8, max(1, (query.preferences.maxTransfers ?? 7) + 1)) }

    /// Discovery keeps its optimistic walking envelope; the executable rounds prove each trip later.
    func optimisticDestinationReachability(egress: [Edge]) -> Raptor.DestinationReachability {
        Raptor.DestinationReachability(snapshot: snapshot, egressStops: Set(egress.map(\.stop)),
            maxRides: maximumRealtimeRides + 1, allowWalkingChains: true)
    }

    /// A selected ride that boards after another ride is checked on its own line only. Its
    /// passlist starts at the board stop, so a connecting line that the schedule did not pick can
    /// be learned from this board alone. Discovery's own rule (`realtimeTargets`) names those
    /// lines: every line with a departure the rider could still take and whose later stops reach
    /// the destination. Asking for them here keeps a late live pick from needing another board
    /// and another routing pass.
    func connectionLines(atStop stopID: String, arrival: Date, from: Date, through: Date,
                         configuration: RealtimeConfiguration, deadline: ContinuousClock.Instant,
                         reachability: Raptor.DestinationReachability) -> ConnectionLines {
        guard let stop = snapshot.stopByID[stopID] else { return .init() }
        var plannedInstances: Set<RealtimePatchKey> = []
        var tripIDs: Set<String> = []
        let targets = realtimeTargets(stopIDs: [stopID], arrivalByStop: [stop: arrival], from: from,
            through: through, configuration: configuration, deadline: deadline,
            patches: latestPatchesByInstance, reachability: reachability,
            plannedInstances: &plannedInstances, matchingTripIDs: &tripIDs)
        guard !targets.isEmpty else { return .init() }
        // The rule gives one line set per stop: an empty set means an unnamed line qualifies.
        return .init(lines: Set(targets.flatMap(\.lines)), unrestricted: targets.contains { $0.lines.isEmpty },
                     tripIDs: tripIDs)
    }
}
