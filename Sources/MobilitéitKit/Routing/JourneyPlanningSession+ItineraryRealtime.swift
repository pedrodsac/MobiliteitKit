import Foundation

extension JourneyPlanningSession {
    struct ItineraryBoarding: Hashable {
        let instance: RealtimePatchKey
        let sequence: Int?
    }

    /// Acquire every vehicle in the candidate page before broad discovery,
    /// including walking and in-seat connections. Unrelated stops must not
    /// consume the deadline before an actual connecting vehicle is checked.
    func completeItineraryRealtime(_ journeys: [Journey], anchor: Date, searchHorizon: TimeInterval,
                                   force: Bool, budgetMilliseconds: Int,
                                   attempted: inout Set<ItineraryBoarding>) async throws -> Bool {
        guard case let .bestEffort(configuration, refresh) = query.realtimePolicy,
              let realtimeProvider, budgetMilliseconds > 0 else { return false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budgetMilliseconds))
        let lower = query.direction == .arriveBy ? anchor.addingTimeInterval(-searchHorizon) : anchor
        let upper = query.direction == .arriveBy ? anchor : anchor.addingTimeInterval(searchHorizon)
        var tripIDs: Set<String> = []
        var targets: [RealtimeBoardTarget] = []
        var stopIDs: [String] = []
        var seenStops: Set<String> = []
        for journey in journeys {
            guard ContinuousClock.now < deadline else { break }
            for leg in journey.legs {
                guard case let .transit(ride) = leg, let instance = ride.instance else { continue }
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
                tripIDs.insert(ride.tripID)
                targets.append(.init(stopID: ride.board.stop.id, from: start, through: end))
                if seenStops.insert(ride.board.stop.id).inserted { stopIDs.append(ride.board.stop.id) }
            }
        }
        guard !targets.isEmpty, ContinuousClock.now < deadline else { return false }
        try Task.checkCancellation()
        let batch: RealtimePatchBatch
        do {
            batch = try await realtimeProvider.patches(for: .init(stopIDs: stopIDs,
                from: targets.map(\.from).min()!, through: targets.map(\.through).max()!,
                scheduledLookbackSeconds: configuration.scheduledLookbackSeconds,
                refreshPolicy: force ? .forceRefresh : refresh,
                maximumConcurrentRequests: min(4, configuration.maximumConcurrentBoardRequests),
                timeout: max(.zero, ContinuousClock.now.duration(to: deadline)), deadline: deadline, targets: targets, tripIDs: tripIDs))
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
        try Task.checkCancellation()
        recordRealtimeBatch(batch)
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
        if before != latestPatchesByInstance {
            metrics.realtimeOverlayRevisions += 1
            if state == .unavailable { state = .partial }
            return true
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
