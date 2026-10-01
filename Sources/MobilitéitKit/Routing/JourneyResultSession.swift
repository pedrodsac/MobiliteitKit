import Foundation

/// Owns one request's accumulated profile and all route quality decisions.
public actor JourneyResultSession {
    private let router: TransitRouter
    private let store: GTFSStore
    private let feedSnapshot: RoutingSnapshot
    private let clock: @Sendable () -> Date
    private var request: JourneyPlanningRequest
    private var anchor: Date
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var operation: UInt64 = 0
    private var journeys: [Journey] = []
    private var contexts: [JourneySignature: JourneyValidationContext] = [:]
    private var invalidated: Set<JourneySignature> = []
    private var exploredBefore: JourneyPageBoundary?
    private var exploredAfter: JourneyPageBoundary?
    private var frozenPatches: [RealtimeTripPatch]?
    private var previousRecommendation: JourneySignature?
    private var hasEarlier = true
    private var hasLater = true
    private var metrics = RoutingMetrics()
    private var diagnostics = RoutingDiagnostics()
    private var preparationMilliseconds: Double
    private var didReplan = false
    private var replacementSearches = 0

    public var replacementSearchCount: Int { replacementSearches }

    init(router: TransitRouter, snapshot: RoutingSnapshot, databaseURL: URL, request: JourneyPlanningRequest, now: Date, preparationMilliseconds: Double = 0) throws {
        self.feedSnapshot = snapshot
        self.clock = router.clock
        self.preparationMilliseconds = preparationMilliseconds
        self.router = router; self.store = try GTFSStore(databaseAt: databaseURL)
        self.request = request
        self.anchor = switch request.time {
        case .now: now
        case let .departAt(date), let .arriveBy(date): date
        }
    }

    private var context: JourneyValidationContext {
        .init(anchor: anchor, arriveBy: direction == .arriveBy,
              minimumTransferSeconds: request.preferences.minimumTransferSeconds,
              sameStopTransferShortfallSeconds: request.preferences.sameStopTransferShortfallSeconds)
    }
    private var direction: RouteQueryDirection {
        if case .arriveBy = request.time { .arriveBy } else { .departAfter }
    }

    public func calculate(page: JourneyPlanningPage = .initial,
                          refresh: JourneyRefreshPolicy = .useCache, now: Date? = nil) async throws -> JourneyPlanningResult {
        let priorIDs = Set(journeys.map(\.id))
        let operationStarted = ContinuousClock.now
        operation &+= 1
        let currentOperation = operation
        let isInitial = page == .initial || refresh == .forceRefresh
        if isInitial, case .now = request.time, let now { anchor = now }
        let effectivePage = resolved(isInitial ? .initial : page)
        let query = makeQuery(page: effectivePage, refresh: refresh)
        if isInitial {
            generation = UUID(); didReplan = false; replacementSearches = 0
            exploredBefore = nil; exploredAfter = nil; frozenPatches = nil
            invalidated = []; journeys = []; contexts = [:]; hasEarlier = true; hasLater = true
        }
        let session = try await router.makeSession(for: query)
        if let frozenPatches { await session.setFrozenPatches(frozenPatches) }
        let raw: JourneyPage
        switch effectivePage {
        case let .before(date, id, count):
            raw = try await session.boundedPage(before: date, beforeID: id, count: count, excludingIDs: Set(journeys.map(\.id)))
        case let .after(date, id, count):
            raw = try await session.boundedPage(after: date, afterID: id, count: count, excludingIDs: Set(journeys.map(\.id)))
        default:
            raw = direction == .arriveBy
                ? try await session.expanded(count: 5)
                : try await session.initial(count: 5, searchHorizon: 3 * 60 * 60)
        }
        try Task.checkCancellation()
        let geometryStarted = ContinuousClock.now
        let enriched = await JourneyGeometry.enrich(raw.journeys, store: store)
        try Task.checkCancellation()
        guard operation == currentOperation else { throw JourneyPlanningError.supersededRequest }
        frozenPatches = await session.currentPatches()
        switch effectivePage {
        case .before: if let boundary = raw.exploredBefore { exploredBefore = boundary }
        case .after: if let boundary = raw.exploredAfter { exploredAfter = boundary }
        default: exploredBefore = raw.exploredBefore; exploredAfter = raw.exploredAfter
        }
        metrics = raw.metrics
        diagnostics = raw.diagnostics
        diagnostics.milliseconds[.snapshotPreparation] = preparationMilliseconds
        preparationMilliseconds = 0
        diagnostics.record(.geometry, since: geometryStarted)
        let assemblyStarted = ContinuousClock.now
        for journey in enriched where journey.hasCancelledTransitLeg {
            invalidated.insert(journey.id)
        }
        let incoming = enriched.filter { !invalidated.contains($0.id) }
        merge(incoming, validationAnchor: query.departureTime)
        switch effectivePage {
        case .before: hasEarlier = !incoming.isEmpty && raw.hasEarlier
        case .after: hasLater = !incoming.isEmpty && raw.hasLater
        default:
            hasEarlier = journeys.contains { $0.legs.contains { if case .transit = $0 { true } else { false } } }
            // Initial search is deliberately shorter than adjacent-page searches.
            hasLater = hasEarlier
        }
        revision &+= 1
        diagnostics.record(.resultAssembly, since: assemblyStarted)
        diagnostics.totalMilliseconds = RoutingDiagnostics.elapsed(since: operationStarted)
            + (diagnostics.milliseconds[.snapshotPreparation] ?? 0)
        if isInitial { invalidated.formUnion(priorIDs.subtracting(Set(journeys.map(\.id)))) }
        diagnostics.counters[.pageNewJourneys] = Set(journeys.map(\.id)).subtracting(priorIDs).count
        let result = snapshot()
        if page == .initial && result.journeys.isEmpty { throw JourneyPlanningError.noRouteFound }
        return result
    }

    public func calculate(before cursor: JourneyPlanningCursor, count: Int = 3,
                          refresh: JourneyRefreshPolicy = .useCache) async throws -> JourneyPlanningResult {
        try validate(cursor)
        return try await calculate(page: .before(cursor.departure, cursor.journeyID, count), refresh: refresh)
    }
    public func calculate(after cursor: JourneyPlanningCursor, count: Int = 3,
                          refresh: JourneyRefreshPolicy = .useCache) async throws -> JourneyPlanningResult {
        try validate(cursor)
        return try await calculate(page: .after(cursor.departure, cursor.journeyID, count), refresh: refresh)
    }
    private func validate(_ cursor: JourneyPlanningCursor) throws {
        guard cursor.generation == generation, cursor.feedGeneration == feedSnapshot.info.generation
        else { throw JourneyPlanningError.stalePage }
    }

    public func refreshRealtime(now: Date = .now) async throws -> JourneyPlanningResult {
        if case .now = request.time { anchor = now }
        return try await calculate(refresh: .forceRefresh)
    }

    public func updatePreferences(_ preferences: RoutingPreferences) async throws -> JourneyPlanningResult {
        previousRecommendation = nil
        request.preferences = preferences
        return try await calculate(refresh: .useCache)
    }

    public func result() -> JourneyPlanningResult { snapshot() }

    public func submitWalkingRefinement(_ update: JourneyWalkingRefinement) async throws -> JourneyPlanningResult {
        guard update.token.generation == generation,
              let index = journeys.firstIndex(where: { $0.id == update.token.journeyID }),
              journeys[index].transitFingerprint == update.token.transitFingerprint,
              !invalidated.contains(update.token.journeyID) else { throw JourneyPlanningError.staleRefinement }
        let journey = journeys[index]
        guard !update.range.isEmpty, update.range.lowerBound >= 0,
              update.range.upperBound <= journey.legs.count,
              update.route.distanceMeters.isFinite, update.route.distanceMeters >= 0,
              update.route.durationSeconds >= 0, update.arrival >= update.departure,
              abs(update.arrival.timeIntervalSince(update.departure) - Double(update.route.durationSeconds)) <= 1,
              update.route.polyline.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite }),
              journey.legs[update.range].allSatisfy({ if case .walk = $0 { true } else { false } }),
              case let .walk(first) = journey.legs[update.range.lowerBound],
              case let .walk(last) = journey.legs[update.range.upperBound - 1] else {
            throw JourneyPlanningError.invalidRefinement
        }
        var legs = journey.legs
        var replacement = WalkingLeg(from: first.from, to: last.to, departure: update.departure,
            arrival: update.arrival, duration: update.arrival.timeIntervalSince(update.departure),
            distanceMeters: update.route.distanceMeters, polyline: update.route.polyline,
            steps: update.route.steps, source: .provider, evidence: update.route.evidence)
        replacement.nativeRange = update.range
        legs[update.range.lowerBound] = .walk(replacement)
        // Retain native indices for other in-flight span updates. Presentation omits these placeholders.
        for position in update.range.dropFirst() {
            var placeholder = WalkingLeg(from: last.to, to: last.to, departure: update.arrival,
                arrival: update.arrival, duration: 0, distanceMeters: 0, polyline: [], steps: [],
                source: .pathway, evidence: .routedPedestrian)
            placeholder.nativeRange = position..<(position + 1)
            legs[position] = .walk(placeholder)
        }
        legs = JourneyTransferArithmetic.recalculating(legs, boardingBufferSeconds: request.preferences.boardingBufferSeconds)
        let corrected = journey.replacing(legs: legs)
        journeys[index] = corrected
        await router.correctWalkingRoute(update.route, for: .init(
            source: first.from.coordinate, destination: last.to.coordinate))
        guard update.token.generation == generation,
              let current = journeys.first(where: { $0.id == corrected.id }),
              current.transitFingerprint == update.token.transitFingerprint,
              !invalidated.contains(corrected.id) else { throw JourneyPlanningError.staleRefinement }
        // Cache correction suspends this actor; independent spans may have finished
        // meanwhile. Validate their combined current itinerary, never an old copy.
        if assess(current).isInvalid {
            invalidated.insert(corrected.id)
            journeys.removeAll { $0.id == corrected.id }
            if !didReplan, corrected.legs.contains(where: { if case .transit = $0 { true } else { false } }) {
                didReplan = true; replacementSearches += 1
                let expectedGeneration = generation
                do {
                    let session = try await router.makeSession(for: makeQuery(page: .initial, refresh: .useCache))
                    let raw = direction == .arriveBy
                        ? try await session.expanded(count: 5)
                        : try await session.initial(count: 5, searchHorizon: 3 * 60 * 60)
                    let replacements = await JourneyGeometry.enrich(raw.journeys, store: store)
                    guard expectedGeneration == generation else { throw JourneyPlanningError.staleRefinement }
                    merge(replacements)
                    metrics = raw.metrics
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard expectedGeneration == generation else { throw JourneyPlanningError.staleRefinement }
                    // A failed replacement search must still remove the unsafe itinerary.
                }
            }
        }
        revision &+= 1
        return snapshot()
    }

    private func resolved(_ page: JourneyPlanningPage) -> JourneyPlanningPage {
        switch page {
        case .earlier:
            if let first = exploredBefore { return .before(first.departure, first.id, 3) }
            return .before(anchor, nil, 3)
        case .later:
            if let last = exploredAfter { return .after(last.departure, last.id, 3) }
            return .after(anchor, nil, 3)
        default: return page
        }
    }
    private func makeQuery(page: JourneyPlanningPage, refresh: JourneyRefreshPolicy) -> RouteQuery {
        var searchAnchor = anchor
        if direction != .arriveBy {
            switch page {
            case let .before(boundary, _, _): searchAnchor = boundary.addingTimeInterval(-86_400)
            case let .after(boundary, _, _): searchAnchor = boundary
            default: break
            }
        }
        return .init(origin: request.origin, destination: request.destination,
                     departureTime: searchAnchor, direction: direction, preferences: request.preferences,
                     realtimePolicy: page.realtimePolicy(refresh, acquisitionBudgetMilliseconds: request.realtimeAcquisitionBudgetMilliseconds))
    }
    private func merge(_ incoming: [Journey], validationAnchor: Date? = nil) {
        var values = Dictionary(journeys.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for journey in incoming where !journey.hasCancelledTransitLeg && !invalidated.contains(journey.id) {
            if let validationAnchor {
                contexts[journey.id] = .init(anchor: validationAnchor, arriveBy: direction == .arriveBy,
                    minimumTransferSeconds: request.preferences.minimumTransferSeconds,
                    sameStopTransferShortfallSeconds: request.preferences.sameStopTransferShortfallSeconds)
            }
            if let existing = values[journey.id], existing.transitFingerprint == journey.transitFingerprint {
                let legs = journey.legs.enumerated().map { index, leg in
                    if existing.legs.indices.contains(index), case let .walk(w) = existing.legs[index],
                       w.nativeRange != nil { return existing.legs[index] }
                    return leg
                }
                values[journey.id] = journey.replacing(legs: legs)
            } else { values[journey.id] = journey }
        }
        journeys = Array(values.values)
    }
    private func assess(_ journey: Journey) -> JourneyFeasibility {
        if let failure = JourneyFeedValidator.failure(journey, snapshot: feedSnapshot, preferences: request.preferences) { return .invalid(failure) }
        let now = clock()
        for leg in journey.legs {
            guard case let .transit(ride) = leg, let identity = ride.instance,
                  let patch = frozenPatches?.first(where: { $0.tripID == ride.tripID && $0.serviceDate == identity.serviceDate }) else { continue }
            if patch.status != .active { return .invalid(.contradictoryRealtime) }
            for event in patch.events {
                for (source, observed) in [(event.arrivalSource, event.arrivalObservedAt), (event.departureSource, event.departureObservedAt)] {
                    if source != .scheduled, let observed,
                       now.timeIntervalSince(observed) > RealtimeTimeline.maximumObservationAge || observed.timeIntervalSince(now) > 60 {
                        return .invalid(.contradictoryRealtime)
                    }
                }
            }
        }
        let validation = contexts[journey.id] ?? context
        return JourneyPublicationValidator.assess(journey, query: .init(origin: request.origin,
            destination: request.destination, departureTime: validation.anchor,
            direction: direction, preferences: request.preferences))
    }
    private func snapshot() -> JourneyPlanningResult {
        var assessments: [JourneySignature: JourneyFeasibility] = [:]
        let priorInvalidations = invalidated.count
        let valid = journeys.filter { journey in
            let assessment = assess(journey)
            assessments[journey.id] = assessment
            if assessment.isInvalid { invalidated.insert(journey.id) }
            return !invalidated.contains(journey.id) && !assessment.isInvalid && !journey.hasCancelledTransitLeg
        }
        if invalidated.count > priorInvalidations {
            revision &+= 1
            diagnostics.counters[.invalidJourneys, default: 0] += invalidated.count - priorInvalidations
        }
        let transitProfile = valid.filter { $0.legs.contains { if case .transit = $0 { true } else { false } } }
        let retained = valid.filter { candidate in
            // The engine keeps an all-the-way walk as a comparison outside transit slots.
            guard transitProfile.contains(where: { $0.id == candidate.id }) else { return true }
            return !transitProfile.contains {
                $0.id != candidate.id && (JourneyQualityPolicy.dominates($0, candidate)
                    || JourneyQualityPolicy.redundantAccessFeeder(candidate, replacedBy: $0, preferences: request.preferences))
            }
        }.sorted { JourneyQualityPolicy.chronologicalOrder($0, $1, query: .init(origin: request.origin, destination: request.destination, departureTime: anchor, direction: direction, preferences: request.preferences)) }
        let selectionQuery = RouteQuery(origin: request.origin, destination: request.destination,
            departureTime: anchor, direction: direction, preferences: request.preferences)
        var recommended = JourneyQualityPolicy.recommendation(retained, query: selectionQuery)
        if let previousRecommendation, let previous = retained.first(where: { $0.id == previousRecommendation }),
           let proposed = recommended, proposed.id != previous.id {
            let improvement = JourneyQualityPolicy.score(previous, anchor: anchor, direction: direction, preferences: request.preferences)
                - JourneyQualityPolicy.score(proposed, anchor: anchor, direction: direction, preferences: request.preferences)
            if improvement < Double(request.preferences.suggestionPolicy.recommendationSwitchingMarginSeconds) { recommended = previous }
        }
        diagnostics.counters[.recommendationSwitches] = previousRecommendation != nil && previousRecommendation != recommended?.id ? 1 : 0
        diagnostics.counters[.sharedFirstVehicleGroups] = Dictionary(grouping: retained.compactMap(\.firstVehicleKey), by: { $0 }).values.filter { $0.count > 1 }.count
        previousRecommendation = recommended?.id
        let tokens = Dictionary(uniqueKeysWithValues: retained.map {
            ($0.id, JourneyRefinementToken(generation: generation, journeyID: $0.id,
                                          transitFingerprint: $0.transitFingerprint))
        })
        var result = JourneyPlanningResult(journeys: retained, recommendedJourneyID: recommended?.id,
            invalidatedIDs: invalidated, feasibility: assessments,
            transferRisks: Dictionary(uniqueKeysWithValues: retained.map {
                ($0.id, JourneyItineraryValidator.transferRisks($0, context: contexts[$0.id] ?? context))
            }), refinementTokens: tokens,
            hasEarlier: hasEarlier, hasLater: hasLater, revision: revision, metrics: metrics,
            diagnostics: diagnostics, validationContext: context)
        result.earlierCursor = exploredBefore.map { .init(generation: generation, feedGeneration: feedSnapshot.info.generation, departure: $0.departure, journeyID: $0.id) }
        result.laterCursor = exploredAfter.map { .init(generation: generation, feedGeneration: feedSnapshot.info.generation, departure: $0.departure, journeyID: $0.id) }
        return result
    }
}
