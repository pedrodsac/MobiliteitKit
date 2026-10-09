import Foundation

/// Refreshes the accumulated itineraries independently of the search deadline.
/// Each boarding stop gets an acquisition opportunity, including later pages.
enum DisplayedJourneyRealtime {
    static func targets(for journeys: [Journey], now: Date) -> [RealtimeBoardTarget] {
        var targets: Set<RealtimeBoardTarget> = []
        for journey in journeys {
            for leg in journey.legs {
                guard case let .transit(ride) = leg,
                      ride.effectiveArrival >= now.addingTimeInterval(-60) else { continue }
                let start = min(ride.scheduledDeparture, ride.effectiveDeparture).addingTimeInterval(-90)
                let end = max(ride.effectiveDeparture.addingTimeInterval(90),
                              ride.scheduledDeparture.addingTimeInterval(RealtimeTimeline.maximumDelay + 90))
                targets.insert(.init(stopID: ride.board.stop.id, from: start, through: end,
                    lines: ride.route.shortName.flatMap { $0.isEmpty ? nil : [$0] } ?? []))
            }
        }
        return targets.sorted {
            ($0.from, $0.stopID, $0.lines.joined(separator: ","))
                < ($1.from, $1.stopID, $1.lines.joined(separator: ","))
        }
    }

    static func acquire(targets: [RealtimeBoardTarget], router: TransitRouter,
                        refresh: RealtimeRefreshPolicy, timeout: Duration,
                        tripIDs: Set<String> = []) async throws -> [RealtimePatchBatch] {
        var seen: Set<String> = []
        let stopIDs = targets.map(\.stopID).filter { seen.insert($0).inserted }
        var batches: [RealtimePatchBatch] = []
        // Bound concurrency, not total coverage. A slow first group must not
        // spend the allowance of the next group's connecting vehicles.
        for offset in stride(from: 0, to: stopIDs.count, by: 8) {
            try Task.checkCancellation()
            let ids = Array(stopIDs[offset..<min(offset + 8, stopIDs.count)])
            let selected = targets.filter { ids.contains($0.stopID) }
            guard let from = selected.map(\.from).min(),
                  let through = selected.map(\.through).max() else { continue }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            do {
                if let batch = try await router.realtimePatches(for: .init(stopIDs: ids,
                    from: from, through: through, refreshPolicy: refresh,
                    maximumConcurrentRequests: 8, timeout: timeout, deadline: deadline, targets: selected,
                    tripIDs: tripIDs)) {
                    batches.append(batch)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Keep useful reports from other groups and retry failed stops
                // on the next refresh. Missing evidence remains scheduled.
            }
        }
        try Task.checkCancellation()
        return batches
    }
}
