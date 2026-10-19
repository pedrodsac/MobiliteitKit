import Foundation

extension JourneyPlanningSession {
    struct ItineraryBoarding: Hashable {
        let instance: RealtimePatchKey
        let sequence: Int?
    }

    /// Acquire selected vehicles and alternative connecting lines together.
    /// Selected stops retain priority over unrelated discovery branches.
    func completeItineraryRealtime(_ journeys: [Journey], access: [Edge], egress: [Edge],
                                   anchor: Date, searchHorizon: TimeInterval,
                                   force: Bool, budgetMilliseconds: Int, includeDiscovery: Bool, reusingRealtime: Bool = false,
                                   attempted: inout Set<ItineraryBoarding>,
                                   maximumConcurrentRequests: Int? = nil) async throws -> Bool {
        guard case let .bestEffort(configuration, refresh) = query.realtimePolicy,
              let realtimeProvider, budgetMilliseconds > 0 else { return false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budgetMilliseconds))
        let lower = query.direction == .arriveBy ? anchor.addingTimeInterval(-searchHorizon) : anchor
        let upper = query.direction == .arriveBy ? anchor : anchor.addingTimeInterval(searchHorizon)
        var targets: [RealtimeBoardTarget] = []
        var stopIDs: [String] = []
        var seenStops: Set<String> = []
        var requestedInstances: Set<RealtimePatchKey> = []
        var matchingTripIDs: Set<String> = []
        // Planning is bounded like discovery's, so HTTP and matching own most of the batch.
        let connectionPlanningDeadline = min(deadline, ContinuousClock.now.advanced(by:
            .milliseconds(min(250, max(1, budgetMilliseconds / 10)))))
        var reachability: Raptor.DestinationReachability?
        var connections: [ConnectionKey: ConnectionLines] = [:]
        for journey in journeys {
            guard ContinuousClock.now < deadline else { break }
            // Set once a ride is behind the rider: when they reach the next boarding stop.
            var reachedStopAt: Date?
            var staysAboard = false
            for leg in journey.legs {
                if case let .walk(walk) = leg, reachedStopAt != nil { reachedStopAt = walk.arrival }
                if case .inSeatContinuation = leg { staysAboard = true }
                guard case let .transit(ride) = leg else { continue }
                // Staying aboard a continuing trip is not a transfer.
                let transferArrival = staysAboard ? nil : reachedStopAt
                staysAboard = false
                reachedStopAt = ride.effectiveArrival
                guard let instance = ride.instance else { continue }
                let key = RealtimePatchKey(tripID: ride.tripID, serviceDate: instance.serviceDate)
                let boarding = ItineraryBoarding(instance: key, sequence: ride.boardSequence)
                let patch = latestPatchesByInstance[key]
                let board = ride.boardSequence.flatMap { patch?.event(stopID: ride.board.stop.id, sequence: $0) }
                let alight = ride.alightSequence.flatMap { patch?.event(stopID: ride.alight.stop.id, sequence: $0) }
                if freshBoardingReport(board), freshArrivalReport(alight) { continue }
                guard attempted.insert(boarding).inserted else { continue }
                // Include the permitted delay range: an unobserved connecting
                // vehicle may depart much later than its scheduled boarding.
                // The board supplies that vehicle's downstream passlist.
                let start = max(lower, min(ride.scheduledDeparture, ride.effectiveDeparture).addingTimeInterval(-60))
                let end = min(upper, max(ride.effectiveDeparture.addingTimeInterval(60),
                    ride.scheduledDeparture.addingTimeInterval(RealtimeTimeline.maximumDelay + 60)))
                guard end >= start else { continue }
                matchingTripIDs.insert(ride.tripID)
                // A passlist can cover nearby downstream boardings. Long rides
                // need another board before forecast propagation expires.
                if ride.scheduledArrival.timeIntervalSince(ride.scheduledDeparture) <= RealtimeTimeline.maximumPropagation {
                    requestedInstances.insert(key)
                }
                var lines = ride.route.shortName.flatMap { $0.isEmpty ? nil : [$0] } ?? []
                if let transferArrival {
                    // The ride's own line is not the only way on from this stop: ask for every line
                    // discovery would, and match their trips too (see `connectionLines`).
                    let connectionKey = ConnectionKey(stopID: ride.board.stop.id, arrival: transferArrival)
                    if connections[connectionKey] == nil {
                        let planningStarted = ContinuousClock.now
                        if reachability == nil { reachability = optimisticDestinationReachability(egress: egress) }
                        connections[connectionKey] = connectionLines(atStop: connectionKey.stopID,
                            arrival: transferArrival, from: lower, through: upper, configuration: configuration,
                            deadline: connectionPlanningDeadline, reachability: reachability!)
                        diagnostics.record(.connectionLines, since: planningStarted)
                    }
                    let connecting = connections[connectionKey]!
                    matchingTripIDs.formUnion(connecting.tripIDs)
                    if !lines.isEmpty {
                        lines = connecting.unrestricted ? [] : Array(Set(lines).union(connecting.lines)).sorted()
                    }
                }
                targets.append(.init(stopID: ride.board.stop.id, from: start, through: end, lines: lines))
                if seenStops.insert(ride.board.stop.id).inserted { stopIDs.append(ride.board.stop.id) }
            }
        }
        if includeDiscovery {
            // Keep planning bounded so HTTP and matching own most of the batch.
            let discoveryStarted = ContinuousClock.now
            let planningDeadline = min(deadline, discoveryStarted.advanced(by:
                .milliseconds(min(250, max(1, budgetMilliseconds / 10)))))
            let discovered = discoveryRealtimeTargets(access: access, egress: egress, journeys: journeys,
                preferredStops: stopIDs, anchor: anchor, searchHorizon: searchHorizon, deadline: planningDeadline,
                requestedInstances: requestedInstances, reachability: reachability)
            targets += discovered.targets
            matchingTripIDs.formUnion(discovered.tripIDs)
            for target in discovered.targets where seenStops.insert(target.stopID).inserted { stopIDs.append(target.stopID) }
            diagnostics.record(.realtimeDiscovery, since: discoveryStarted)
        }
        guard !targets.isEmpty, ContinuousClock.now < deadline else { return false }
        try Task.checkCancellation()
        let batch: RealtimePatchBatch
        do {
            batch = try await realtimeProvider.patches(for: .init(stopIDs: stopIDs,
                from: targets.map(\.from).min()!, through: targets.map(\.through).max()!,
                scheduledLookbackSeconds: configuration.scheduledLookbackSeconds,
                refreshPolicy: reusingRealtime ? .useCache : (force ? .forceRefresh : refresh),
                maximumConcurrentRequests: min(maximumConcurrentRequests ?? 32, configuration.maximumConcurrentBoardRequests),
                timeout: max(.zero, ContinuousClock.now.duration(to: deadline)), deadline: deadline, targets: targets,
                tripIDs: matchingTripIDs, refreshStartedAt: realtimeRefreshStartedAt))
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
        try Task.checkCancellation()
        recordRealtimeBatch(batch)
        let mergeStarted = ContinuousClock.now
        let before = latestPatchesByInstance
        for incoming in batch.patches {
            let key = RealtimePatchKey(tripID: incoming.tripID, serviceDate: incoming.serviceDate)
            let merged = latestRawPatchesByInstance[key].map { $0.merging(incoming) } ?? incoming
            latestRawPatchesByInstance[key] = merged
            latestPatchesByInstance[key] = RealtimeTimeline.resolved(merged, snapshot: snapshot, now: clock())
        }
        let requested = (cachedRealtimeBatch?.requestedStopIDs ?? []).union(stopIDs)
        let covered = (cachedRealtimeBatch?.coveredStopIDs ?? []).union(batch.coveredStopIDs)
        let incomplete = (cachedRealtimeBatch?.incompleteStopIDs ?? []).union(batch.incompleteStopIDs)
        let fetchedAt = [cachedRealtimeBatch?.fetchedAt, batch.fetchedAt].compactMap { $0 }.min()
        cachedRealtimeBatch = .init(patches: Array(latestRawPatchesByInstance.values), requestedStopIDs: requested,
            coveredStopIDs: covered, incompleteStopIDs: incomplete, fetchedAt: fetchedAt)
        metrics.realtimeFrontierSize = requested.count
        metrics.realtimeBoardsCovered = covered.count
        metrics.realtimeIncompleteBoards = incomplete.count
        diagnostics.record(.providerSessionMerge, since: mergeStarted)
        if before != latestPatchesByInstance {
            metrics.realtimeOverlayRevisions += 1
            if state == .unavailable { state = .partial }
            let effectStarted = ContinuousClock.now
            defer { diagnostics.record(.sessionRoutingEffect, since: effectStarted) }
            return routingEffectChanged(from: before)
        }
        return false
    }

    private func freshArrivalReport(_ event: RealtimeStopEventPatch?) -> Bool {
        guard event?.arrivalSource == .reported else { return false }
        guard let observed = event?.arrivalObservedAt else { return true }
        return clock().timeIntervalSince(observed) < 60 && observed.timeIntervalSince(clock()) <= 60
    }

    func recordRealtimeBatch(_ batch: RealtimePatchBatch) {
        for (reason, count) in batch.matchingRejections {
            diagnostics.realtimeMatchingRejections[reason, default: 0] += count
        }
        diagnostics.transport += batch.transport
        diagnostics.recordBoards(batch.timings)
        metrics.realtimeHTTPMilliseconds += batch.httpMilliseconds
        metrics.realtimeDecodeMilliseconds += batch.decodeMilliseconds
        metrics.hafasRequests += batch.networkRequests
        metrics.hafasCacheHits += batch.cacheHits
        metrics.realtimeResponseBytes += batch.responseBytes
        metrics.realtimeBoardFetchMilliseconds += batch.boardFetchMilliseconds
        metrics.realtimeScheduledPreparationMilliseconds += batch.scheduledPreparationMilliseconds
        metrics.realtimeBoardMatchingMilliseconds += batch.boardMatchingMilliseconds
    }
}
