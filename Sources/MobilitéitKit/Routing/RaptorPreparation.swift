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
        profileUpperBound: Date
    ) -> [ActiveTripInstance] {
        snapshot.patterns[patternID].trips.flatMap { tripIndex -> [ActiveTripInstance] in
            let trip = snapshot.trips[tripIndex]
            guard query.preferences.allowedModes.contains(
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
                // Access labels start no earlier than searchStart. Even with
                // realtime delays, an instance whose every pickup has passed
                // cannot be boarded during this query.
                guard trip.times.indices.contains(where: { position in
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
        let inTrip = snapshot.trips[incoming.trip], outTrip = snapshot.trips[outgoing]
        func applies(_ rule: SnapshotRule) -> Bool {
            guard rule.fromTrip == nil || rule.fromTrip == incoming.trip, rule.toTrip == nil || rule.toTrip == outgoing else { return false }
            return (rule.fromRoute == nil || rule.fromRoute == inTrip.route) && (rule.toRoute == nil || rule.toRoute == outTrip.route)
        }
        func score(_ rule: SnapshotRule) -> Int { if rule.fromTrip != nil && rule.toTrip != nil { return 60 }; if rule.fromTrip != nil || rule.toTrip != nil { return (rule.fromRoute != nil || rule.toRoute != nil) ? 50 : 40 }; if rule.fromRoute != nil && rule.toRoute != nil { return 30 }; if rule.fromRoute != nil || rule.toRoute != nil { return 20 }; return 10 }
        let fromGroup = snapshot.stationGroupByStop[incoming.alight]
        let toGroup = snapshot.stationGroupByStop[stop]
        let keys = [
            RuleGroupKey(from: fromGroup, to: toGroup),
            RuleGroupKey(from: nil, to: toGroup),
            RuleGroupKey(from: fromGroup, to: nil),
            RuleGroupKey(from: nil, to: nil),
        ]
        let candidates = keys.flatMap { snapshot.rulesByGroup[$0] ?? [] }.sorted { $0.order < $1.order }
        guard let rule = candidates.filter(applies).max(by: { score($0) < score($1) }) else {
            return .init(requiredSeconds: preferences.minimumTransferSeconds, allowedShortfallSeconds: 0)
        }
        switch rule.type {
        case 3: return nil
        case 1, 4: return .init(requiredSeconds: 0, allowedShortfallSeconds: 0)
        case 2:
            let required = max(preferences.minimumTransferSeconds, rule.minimum ?? 0)
            // A broad stop-wide rule can be conservative for two buses serving
            // the exact same platform. Keep trip/route-specific rules strict.
            let genericSameStop = incoming.alight == stop
                && rule.fromTrip == nil && rule.toTrip == nil
                && rule.fromRoute == nil && rule.toRoute == nil
            return .init(requiredSeconds: required,
                         allowedShortfallSeconds: genericSameStop
                            ? min(required, preferences.sameStopTransferShortfallSeconds) : 0)
        default: return .init(requiredSeconds: preferences.minimumTransferSeconds, allowedShortfallSeconds: 0)
        }
    }
}
