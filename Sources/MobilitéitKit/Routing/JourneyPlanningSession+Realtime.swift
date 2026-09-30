import Foundation

extension JourneyPlanningSession {
    func acquireRealtime(access: [Edge], egress: [Edge], anchor: Date,
                                 searchHorizon: TimeInterval, force: Bool) async throws -> [RealtimeTripPatch] {
        guard case let .bestEffort(configuration, requestedRefresh) = query.realtimePolicy,
              let realtimeProvider else { return [] }
        let from = query.direction == .arriveBy
            ? anchor.addingTimeInterval(-min(searchHorizon, Double(configuration.minimumForwardHorizonSeconds)))
            : anchor
        let through = query.direction == .arriveBy ? anchor
            : anchor.addingTimeInterval(min(searchHorizon, Double(configuration.minimumForwardHorizonSeconds)))
        if !force, let cachedRealtimeBatch, let fetchedAt = cachedRealtimeBatch.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 60 {
            metrics.hafasCacheHits += 1
            return cachedRealtimeBatch.patches
        }
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(max(0, configuration.acquisitionBudgetMilliseconds)))
        var queried: Set<String> = []
        var covered: Set<String> = []
        var incomplete: Set<String> = []
        var patches: [RealtimePatchKey: RealtimeTripPatch] = [:]
        var fetchedAt: Date?
        var frontier = access.sorted { $0.seconds < $1.seconds }
            .prefix(8).map { snapshot.stops[$0.stop].id }
        var discoveryArrivals = Dictionary(access.map { ($0.stop, from.addingTimeInterval(Double($0.seconds))) },
                                           uniquingKeysWith: min)
        let omittedAccess = access.count > frontier.count
        let limitedHorizon = searchHorizon > through.timeIntervalSince(from)
        for _ in 0..<min(4, max(1, configuration.maximumRefinementWaves)) {
            try Task.checkCancellation()
            guard !frontier.isEmpty, ContinuousClock.now < deadline, queried.count < 24 else { break }
            frontier = Array(frontier.prefix(24 - queried.count))
            queried.formUnion(frontier)
            do {
                let batch = try await realtimeProvider.patches(for: .init(
                    stopIDs: frontier, from: from, through: through,
                    scheduledLookbackSeconds: configuration.scheduledLookbackSeconds,
                    refreshPolicy: force ? .forceRefresh : requestedRefresh,
                    maximumConcurrentRequests: min(4, configuration.maximumConcurrentBoardRequests),
                    timeout: ContinuousClock.now.duration(to: deadline), deadline: deadline))
                covered.formUnion(batch.coveredStopIDs)
                incomplete.formUnion(batch.incompleteStopIDs)
                if let date = batch.fetchedAt { fetchedAt = min(fetchedAt ?? date, date) }
                metrics.realtimeHTTPMilliseconds += batch.httpMilliseconds
                metrics.realtimeDecodeMilliseconds += batch.decodeMilliseconds
                metrics.hafasRequests += batch.networkRequests
                metrics.hafasCacheHits += batch.cacheHits
                metrics.realtimeResponseBytes += batch.responseBytes
                metrics.realtimeBoardFetchMilliseconds += batch.boardFetchMilliseconds
                metrics.realtimeScheduledPreparationMilliseconds += batch.scheduledPreparationMilliseconds
                metrics.realtimeBoardMatchingMilliseconds += batch.boardMatchingMilliseconds
                for patch in batch.patches {
                    let key = RealtimePatchKey(tripID: patch.tripID, serviceDate: patch.serviceDate)
                    patches[key] = patches[key].map { $0.merging(patch) } ?? patch
                }
            } catch is CancellationError { throw CancellationError() }
            catch { break }
            frontier = realtimeFrontier(arrivalByStop: &discoveryArrivals, egress: egress, from: from, through: through,
                                         lookback: configuration.scheduledLookbackSeconds,
                                         deadline: deadline, patches: patches, excluding: queried)
        }
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
        state = covered.isEmpty ? .unavailable
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
                                  excluding: Set<String>) -> [String] {
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
                              departure >= reach.addingTimeInterval(patch == nil ? -Double(lookback) : 0), departure <= through
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
        let target = egress.first.map { snapshot.stops[$0.stop].model.coordinate }
        return arrivalByStop.keys.filter { stop in
            !excluding.contains(snapshot.stops[stop].id) && snapshot.boardableStops.contains(stop)
                && snapshot.tripIndicesByDepartureStop[stop].contains { tripIndex in
                    let trip = snapshot.trips[tripIndex]
                    guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type)
                    else { return false }
                    return serviceDays.contains { day in
                        guard day.activeServices.contains(trip.service),
                              patches[.init(tripID: trip.id, serviceDate: day.date)] == nil else { return false }
                        return trip.times.contains { time in
                            guard time.stop == stop, time.pickup == 0, let departure = time.departure else { return false }
                            let date = day.start.addingTimeInterval(Double(departure))
                            return date >= arrivalByStop[stop]!.addingTimeInterval(-Double(lookback)) && date <= through
                        }
                    }
                }
        }.sorted { left, right in
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
