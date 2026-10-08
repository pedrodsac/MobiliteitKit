import Foundation

extension Raptor {
    static func activeTripInstances(
        patternID: Int,
        snapshot: RoutingSnapshot,
        query: RouteQuery,
        relevantServiceDays: [SnapshotServiceDay],
        patchesByInstance: [PatchKey: PatchOverlay],
        scheduledLowerBound: Date,
        searchStart: Date,
        profileUpperBound: Date, includeUnboardable: Bool = false
    ) -> [ActiveTripInstance] {
        snapshot.patterns[patternID].trips.flatMap { tripIndex -> [ActiveTripInstance] in
            let trip = snapshot.trips[tripIndex]
            guard !trip.isFrequencyTemplate, query.preferences.allowedModes.contains(
                routeType: snapshot.routes[trip.route].type
            ) else { return [] }
            return relevantServiceDays.compactMap { serviceDay in
                guard serviceDay.activeServices.contains(trip.service),
                      serviceDay.start.addingTimeInterval(TimeInterval(trip.firstServiceTime)) <= profileUpperBound,
                      serviceDay.start.addingTimeInterval(TimeInterval(trip.lastServiceTime)) >= scheduledLowerBound
                else { return nil }
                let patch = patchesByInstance[.init(trip: tripIndex, serviceDate: serviceDay.date)]
                // A trip cancellation applies to the entire vehicle instance,
                // including every downstream boarding stop. Do not route a
                // passenger onto it from a different stop.
                guard patch?.status != .unreachable,
                      patch?.status != .cancelled else { return nil }
                let scheduledDepartures = trip.times.map { time in
                    time.departure.map { serviceDay.start.addingTimeInterval(TimeInterval($0)) }
                }
                let scheduledArrivals = trip.times.map { time in
                    time.arrival.map { serviceDay.start.addingTimeInterval(TimeInterval($0)) }
                }
                let effectiveDepartures = trip.times.indices.map { position in
                    patchTime(patch, position: position, departure: true)
                        ?? scheduledDepartures[position]
                }
                let effectiveArrivals = trip.times.indices.map { position in
                    patchTime(patch, position: position, departure: false)
                        ?? scheduledArrivals[position]
                }
                var previous: Date?
                for position in trip.times.indices {
                    for instant in [effectiveArrivals[position], effectiveDepartures[position]].compactMap({ $0 }) {
                        if previous.map({ instant < $0 }) == true { return nil }
                        previous = instant
                    }
                }
                // Access labels start no earlier than searchStart. Even with
                // realtime delays, an instance whose every pickup has passed
                // cannot be boarded during this query.
                guard includeUnboardable || trip.times.indices.contains(where: { position in
                    trip.times[position].pickup == 0
                        && patch?.eventsByPosition[position]?.boardingAllowed != false
                        && effectiveDepartures[position].map { $0 >= searchStart } == true
                }) else { return nil }
                return .init(
                    tripIndex: tripIndex, serviceDay: serviceDay,
                    scheduledDepartures: scheduledDepartures,
                    scheduledArrivals: scheduledArrivals,
                    effectiveDepartures: effectiveDepartures,
                    effectiveArrivals: effectiveArrivals,
                    conservativeDepartures: trip.times.indices.map { position in
                        let event = patch?.eventsByPosition[position]
                        if event?.departureSource == .estimated, let scheduled = scheduledDepartures[position], let effective = effectiveDepartures[position] { return min(scheduled, effective) }
                        return effectiveDepartures[position]
                    },
                    boardingAllowed: trip.times.indices.map { patch?.eventsByPosition[$0]?.boardingAllowed != false },
                    alightingAllowed: trip.times.indices.map { patch?.eventsByPosition[$0]?.alightingAllowed != false }
                )
            }
        }
    }

    static func cachedTransferDecision(
        snapshot: RoutingSnapshot,
        incoming: TransitLeg?,
        at stop: Int,
        outgoing: Int,
        preferences: RoutingPreferences,
        cache: inout [TransferDecisionKey: CachedTransferDecision]
    ) -> TransferAllowance? {
        guard let incoming else { return .init(requiredSeconds: 0, allowedShortfallSeconds: 0) }
        let key = TransferDecisionKey(
            incomingTrip: incoming.trip,
            incomingStop: incoming.alight,
            stop: stop,
            outgoingTrip: outgoing
        )
        if let cached = cache[key] { return cached.allowance }
        let value = transferDecision(
            snapshot: snapshot,
            incoming: incoming,
            at: stop,
            outgoing: outgoing,
            preferences: preferences
        )
        cache[key] = value.map(CachedTransferDecision.allowed) ?? .forbidden
        return value
    }

    static func patchTime(_ patch: PatchOverlay?, position: Int, departure: Bool) -> Date? { guard let event = patch?.eventsByPosition[position] else { return nil }; return departure ? event.effectiveDeparture : event.effectiveArrival }

    static func transferDecision(snapshot: RoutingSnapshot, incoming: TransitLeg?, at stop: Int, outgoing: Int, preferences: RoutingPreferences) -> TransferAllowance? {
        guard let incoming else { return .init(requiredSeconds: 0, allowedShortfallSeconds: 0) }
        guard let rule = selectedTransferRule(snapshot: snapshot, incoming: incoming, at: stop, outgoing: outgoing) else {
            return .init(requiredSeconds: preferences.minimumTransferSeconds, allowedShortfallSeconds: 0)
        }
        switch rule.type {
        case 3: return nil
        default:
            if permitsTightSameStopBusTransfer(rule, snapshot: snapshot, incoming: incoming,
                                              at: stop, outgoing: outgoing, preferences: preferences) {
                return .init(requiredSeconds: max(120, preferences.minimumTransferSeconds), allowedShortfallSeconds: 0)
            }
            // Feed minima describe total interchange time, including walking.
            return .init(requiredSeconds: max(preferences.minimumTransferSeconds, rule.minimum ?? 0),
                         allowedShortfallSeconds: 0)
        }
    }

    /// An explicit rider choice can use the normal boarding buffer at an
    /// aggregate bus stop. The larger feed buffer remains recommendation
    /// evidence, so these connections are published with a tight-transfer risk.
    /// Specific rules, different stops and rail/platform changes stay strict.
    private static func permitsTightSameStopBusTransfer(_ rule: SnapshotRule,
        snapshot: RoutingSnapshot, incoming: TransitLeg, at stop: Int, outgoing: Int,
        preferences: RoutingPreferences) -> Bool {
        func bus(_ type: Int) -> Bool { type == 3 || (700...799).contains(type) }
        let model = snapshot.stops[stop].model
        return preferences.allowTightSameStopBusTransfers && preferences.wheelchair != .required
            && incoming.alight == stop && rule.type == 2 && rule.from == stop && rule.to == stop
            && rule.fromRoute == nil && rule.toRoute == nil && rule.fromTrip == nil && rule.toTrip == nil
            && model.locationType == 0 && model.parentStationID == nil && model.platformCode == nil
            && bus(snapshot.routes[snapshot.trips[incoming.trip].route].type)
            && bus(snapshot.routes[snapshot.trips[outgoing].route].type)
    }
    static func selectedTransferRule(snapshot: RoutingSnapshot, incoming: TransitLeg,
                                     at stop: Int, outgoing: Int) -> SnapshotRule? {
        let inTrip = snapshot.trips[incoming.trip], outTrip = snapshot.trips[outgoing]
        func endpoint(_ endpoint: Int?, matches actual: Int) -> Bool {
            guard let endpoint else { return true }
            return endpoint == actual || (snapshot.stops[endpoint].model.locationType == 1 && snapshot.stationGroupByStop[actual] == endpoint)
        }
        func applies(_ rule: SnapshotRule) -> Bool {
            guard endpoint(rule.from, matches: incoming.alight), endpoint(rule.to, matches: stop) else { return false }
            guard rule.fromTrip == nil || rule.fromTrip == incoming.trip, rule.toTrip == nil || rule.toTrip == outgoing else { return false }
            return (rule.fromRoute == nil || rule.fromRoute == inTrip.route) && (rule.toRoute == nil || rule.toRoute == outTrip.route)
        }
        func score(_ rule: SnapshotRule) -> Int { if rule.fromTrip != nil && rule.toTrip != nil { return 60 }; if rule.fromTrip != nil || rule.toTrip != nil { return (rule.fromRoute != nil || rule.toRoute != nil) ? 50 : 40 }; if rule.fromRoute != nil && rule.toRoute != nil { return 30 }; if rule.fromRoute != nil || rule.toRoute != nil { return 20 }; return 10 }
        func endpointScore(_ rule: SnapshotRule) -> Int {
            [rule.from, rule.to].compactMap { $0 }.reduce(0) { $0 + (snapshot.stops[$1].model.locationType == 1 ? 1 : 2) }
        }
        let fromGroup = snapshot.stationGroupByStop[incoming.alight]
        let toGroup = snapshot.stationGroupByStop[stop]
        let keys = [
            RuleGroupKey(from: fromGroup, to: toGroup),
            RuleGroupKey(from: nil, to: toGroup),
            RuleGroupKey(from: fromGroup, to: nil),
            RuleGroupKey(from: nil, to: nil),
        ]
        let candidates = keys.flatMap { snapshot.rulesByGroup[$0] ?? [] }.sorted { $0.order < $1.order }
        return candidates.filter(applies).max(by: {
            if score($0) != score($1) { return score($0) < score($1) }
            if endpointScore($0) != endpointScore($1) { return endpointScore($0) < endpointScore($1) }
            // For conflicting equally scoped links, requiring a change is safer.
            if $0.type != $1.type {
                func restriction(_ type: Int) -> Int { type == 3 ? 3 : type == 5 ? 2 : 1 }
                return restriction($0.type) < restriction($1.type)
            }
            return $0.order > $1.order
        })
    }

}
