import Foundation

extension JourneyPlanningSession {
    func acquireRealtime(access: [Edge], egress: [Edge], anchor: Date,
                                 searchHorizon: TimeInterval, force: Bool, budgetMilliseconds: Int? = nil,
                    seedPatches: [RealtimeTripPatch]? = nil) async throws -> [RealtimeTripPatch] {
        guard case let .bestEffort(configuration, requestedRefresh) = query.realtimePolicy,
              let realtimeProvider else { return [] }
        let from = query.direction == .arriveBy
            ? anchor.addingTimeInterval(-searchHorizon)
            : anchor
        let through = query.direction == .arriveBy ? anchor
            : anchor.addingTimeInterval(searchHorizon)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(max(0, budgetMilliseconds ?? configuration.acquisitionBudgetMilliseconds)))
        var queried = seedPatches == nil ? Set<String>() : (cachedRealtimeBatch?.requestedStopIDs ?? [])
        var covered: Set<String> = []
        var incomplete: Set<String> = []
        let previousBatch = seedPatches == nil ? nil : cachedRealtimeBatch
        let seeds = seedPatches ?? (force || requestedRefresh == .forceRefresh ? []
            : (frozenPatches ?? []).map { $0.retainingFreshObservations(at: clock()) })
        var patches = Dictionary(seeds.map { (RealtimePatchKey(tripID: $0.tripID, serviceDate: $0.serviceDate), $0) },
                                 uniquingKeysWith: { old, new in old.merging(new) })
        var fetchedAt: Date?
        var frontier: [String] = []
        var discoveryArrivals = Dictionary(access.map { ($0.stop, from.addingTimeInterval(Double($0.seconds))) },
                                           uniquingKeysWith: min)
        let omittedAccess = access.count > 8
        let limitedHorizon = searchHorizon > Double(configuration.minimumForwardHorizonSeconds)
        // Reserve the bounded board budget for trips that can still lead to the
        // destination. Earliest intermediate stops alone starve later lines.
        let maxRides = min(8, max(1, (query.preferences.maxTransfers ?? 7) + 1))
        let reachability = Raptor.DestinationReachability(snapshot: snapshot,
            egressStops: Set(egress.map(\.stop)), maxRides: maxRides + 1)
        frontier = access.sorted { left, right in
            let a = reachability.stopsByRemainingRides.firstIndex { $0[left.stop] } ?? Int.max
            let b = reachability.stopsByRemainingRides.firstIndex { $0[right.stop] } ?? Int.max
            return a != b ? a < b : (left.seconds != right.seconds ? left.seconds < right.seconds : left.stop < right.stop)
        }.prefix(8).map { snapshot.stops[$0.stop].id }
        for _ in 0..<min(4, max(1, configuration.maximumRefinementWaves)) {
            try Task.checkCancellation()
            guard !frontier.isEmpty, ContinuousClock.now < deadline, queried.count < 24 else { break }
            frontier = Array(frontier.prefix(24 - queried.count))
            let targets = realtimeTargets(stopIDs: frontier, arrivalByStop: discoveryArrivals,
                from: from, through: through, configuration: configuration, deadline: deadline, patches: patches, reachability: reachability)
            let targetedStops = frontier.filter { stopID in targets.contains { $0.stopID == stopID } }
            queried.formUnion(frontier)
            do {
                let batch = targetedStops.isEmpty
                    ? RealtimePatchBatch(patches: [], requestedStopIDs: [], coveredStopIDs: [])
                    : try await realtimeProvider.patches(for: .init(
                    stopIDs: targetedStops, from: from, through: through,
                    scheduledLookbackSeconds: configuration.scheduledLookbackSeconds,
                    refreshPolicy: force ? .forceRefresh : requestedRefresh,
                    maximumConcurrentRequests: min(4, configuration.maximumConcurrentBoardRequests),
                    timeout: ContinuousClock.now.duration(to: deadline), deadline: deadline, targets: targets))
                recordRealtimeBatch(batch)
                covered.formUnion(batch.coveredStopIDs)
                incomplete.formUnion(batch.incompleteStopIDs)
                if let date = batch.fetchedAt { fetchedAt = min(fetchedAt ?? date, date) }
                for patch in batch.patches {
                    let key = RealtimePatchKey(tripID: patch.tripID, serviceDate: patch.serviceDate)
                    patches[key] = patches[key].map { $0.merging(patch) } ?? patch
                }
            } catch is CancellationError { throw CancellationError() }
            catch { break }
            let discoveryStarted = ContinuousClock.now
            frontier = realtimeFrontier(arrivalByStop: &discoveryArrivals, egress: egress, from: from, through: through,
                                         lookback: configuration.scheduledLookbackSeconds,
                                         deadline: deadline, patches: patches, excluding: queried, reachability: reachability)
            diagnostics.record(.realtimeDiscovery, since: discoveryStarted)
        }
        queried.formUnion(previousBatch?.requestedStopIDs ?? [])
        covered.formUnion(previousBatch?.coveredStopIDs ?? [])
        incomplete.formUnion(previousBatch?.incompleteStopIDs ?? [])
        if let date = previousBatch?.fetchedAt { fetchedAt = min(fetchedAt ?? date, date) }
        metrics.realtimeFrontierSize = queried.count
        metrics.realtimeBoardsCovered = covered.count
        metrics.realtimeIncompleteBoards = incomplete.count
        let updates = patches.values.sorted { ($0.serviceDate, $0.tripID) < ($1.serviceDate, $1.tripID) }
        latestPatchesByInstance = patches
        metrics.delayedPastBoardingsInjected += updates.flatMap(\.events).filter {
            ($0.scheduledDeparture ?? .distantFuture) < anchor
                && ($0.effectiveDeparture ?? .distantPast) >= anchor
        }.count
        metrics.realtimePredictedEvents = updates.flatMap(\.events).filter {
            $0.departureSource == .reported || $0.arrivalSource == .reported
        }.count
        state = covered.isEmpty && updates.isEmpty ? .unavailable
            : (covered == queried && incomplete.isEmpty && frontier.isEmpty && !omittedAccess
                && !limitedHorizon && ContinuousClock.now < deadline && !updates.isEmpty ? .live : .partial)
        metrics.realtimeOverlayRevisions += 1
        cachedRealtimeBatch = .init(patches: updates, requestedStopIDs: queried,
                                    coveredStopIDs: covered, incompleteStopIDs: incomplete,
                                    fetchedAt: fetchedAt)
        return updates
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
