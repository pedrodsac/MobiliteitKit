import Foundation

/// An independent operation; it never changes the accumulated result session.
struct AdjacentJourneySearch {
    let router: TransitRouter
    let request: JourneyPlanningRequest
    let boundary: JourneyPageBoundary
    let earlier: Bool
    let excludingIDs: Set<JourneySignature>
    let patches: [RealtimeTripPatch]?
    let now: Date

    struct Result {
        let page: JourneyPage
        let query: RouteQuery
        let patches: [RealtimeTripPatch]
        let window: JourneyBrowsingWindow
    }

    func calculate(refresh: JourneyRefreshPolicy) async throws -> Result {
        let arrival = if case .arriveBy = request.time { true } else { false }
        let started = ContinuousClock.now
        var horizon: TimeInterval = 3 * 60 * 60
        while true {
            try Task.checkCancellation()
            let start = earlier ? boundary.departure.addingTimeInterval(-horizon) : boundary.departure
            let end = earlier ? boundary.departure : boundary.departure.addingTimeInterval(horizon)
            let historical = end < now.addingTimeInterval(-60)
            let remainingBudget = max(0, request.realtimeAcquisitionBudgetMilliseconds
                - Int(RoutingDiagnostics.elapsed(since: started)))
            let query = RouteQuery(origin: request.origin, destination: request.destination,
                departureTime: arrival ? end : start,
                direction: arrival ? .arriveBy : .departAfter,
                preferences: request.preferences,
                realtimePolicy: JourneyPlanningPage.initial.realtimePolicy(
                    historical ? .scheduleOnly : refresh,
                    acquisitionBudgetMilliseconds: remainingBudget))
            let session = try await router.makeSession(for: query)
            if let patches, !historical { await session.setFrozenPatches(patches) }
            // A later arrival can belong to a journey which started before the
            // previous arrival boundary. Keep the normal arrive-by lookback.
            let page = try await session.adjacentTimePage(axis: arrival ? .arrival : .departure,
                boundary: boundary, earlier: earlier, count: 10, excludingIDs: excludingIDs,
                searchHorizon: arrival && !earlier ? Raptor.fullProfileHorizon : horizon)
            if !page.journeys.isEmpty || horizon == Raptor.fullProfileHorizon {
                return Result(page: page, query: query, patches: await session.currentPatches(),
                    window: .init(axis: arrival ? .arrival : .departure,
                                  range: .init(start: start, end: end)))
            }
            horizon = min(Raptor.fullProfileHorizon, horizon * 2)
        }
    }
}
