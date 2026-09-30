import Foundation

/// Owns one request's accumulated profile and all route quality decisions.
public actor JourneyResultSession {
    private let router: TransitRouter
    private let store: GTFSStore
    private var request: JourneyPlanningRequest
    private var anchor: Date
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var operation: UInt64 = 0
    private var journeys: [Journey] = []
    private var contexts: [JourneySignature: JourneyValidationContext] = [:]
    private var invalidated: Set<JourneySignature> = []
    private var hasEarlier = true
    private var hasLater = true
    private var metrics = RoutingMetrics()
    private var didReplan = false
    private var replacementSearches = 0

    public var replacementSearchCount: Int { replacementSearches }

    init(router: TransitRouter, databaseURL: URL, request: JourneyPlanningRequest, now: Date) throws {
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
                          refresh: JourneyRefreshPolicy = .useCache) async throws -> JourneyPlanningResult {
        operation &+= 1
        let currentOperation = operation
        let effectivePage = resolved(page)
        let query = makeQuery(page: effectivePage, refresh: refresh)
        if page == .initial {
            generation = UUID(); didReplan = false; replacementSearches = 0
            invalidated = []; journeys = []; contexts = [:]; hasEarlier = true; hasLater = true
        }
        let session = try await router.makeSession(for: query)
        let raw: JourneyPage
        switch effectivePage {
        case let .before(date, id, count):
            raw = try await session.boundedPage(before: date, beforeID: id, count: count)
        case let .after(date, id, count):
            raw = try await session.boundedPage(after: date, afterID: id, count: count)
        default:
            raw = direction == .arriveBy
                ? try await session.expanded(count: 5)
                : try await session.initial(count: 5, searchHorizon: 3 * 60 * 60)
        }
        try Task.checkCancellation()
        let enriched = await JourneyGeometry.enrich(raw.journeys, store: store)
        try Task.checkCancellation()
        guard operation == currentOperation else { throw JourneyPlanningError.supersededRequest }
        metrics = raw.metrics
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
        let result = snapshot()
        if page == .initial && result.journeys.isEmpty { throw JourneyPlanningError.noRouteFound }
        return result
    }

    public func refreshRealtime(now: Date = .now) async throws -> JourneyPlanningResult {
        if case .now = request.time { anchor = now }
        return try await calculate(refresh: .forceRefresh)
    }

    public func updatePreferences(_ preferences: RoutingPreferences) async throws -> JourneyPlanningResult {
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
            legs[position] = .walk(.init(from: last.to, to: last.to, departure: update.arrival,
                arrival: update.arrival, duration: 0, distanceMeters: 0, polyline: [], steps: [],
                source: .pathway, evidence: .routedPedestrian))
        }
        let corrected = journey.replacing(legs: legs)
        journeys[index] = corrected
        await router.correctWalkingRoute(update.route, for: .init(
            source: first.from.coordinate, destination: last.to.coordinate))
        guard update.token.generation == generation else { throw JourneyPlanningError.staleRefinement }
        if JourneyItineraryValidator.assess(corrected, context: contexts[corrected.id] ?? context).isInvalid {
            invalidated.insert(corrected.id)
            journeys.removeAll { $0.id == corrected.id }
            if !didReplan, corrected.legs.contains(where: { if case .transit = $0 { true } else { false } }) {
                didReplan = true; replacementSearches += 1
                let expectedGeneration = generation
                let session = try await router.makeSession(for: makeQuery(page: .initial, refresh: .useCache))
                let raw = direction == .arriveBy
                    ? try await session.expanded(count: 5)
                    : try await session.initial(count: 5, searchHorizon: 3 * 60 * 60)
                let replacements = await JourneyGeometry.enrich(raw.journeys, store: store)
                guard expectedGeneration == generation else { throw JourneyPlanningError.staleRefinement }
                merge(replacements)
                metrics = raw.metrics
            }
        }
        revision &+= 1
        return snapshot()
    }

    private func resolved(_ page: JourneyPlanningPage) -> JourneyPlanningPage {
        let transit = journeys.filter { $0.legs.contains { if case .transit = $0 { true } else { false } } }
            .sorted { ($0.effectiveDeparture, $0.id) < ($1.effectiveDeparture, $1.id) }
        switch page {
        case .earlier:
            if let first = transit.first { return .before(first.effectiveDeparture, first.id, 3) }
            return .before(anchor, nil, 3)
        case .later:
            if let last = transit.last { return .after(last.effectiveDeparture, last.id, 3) }
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
                     realtimePolicy: page.realtimePolicy(refresh))
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
    private func snapshot() -> JourneyPlanningResult {
        var assessments: [JourneySignature: JourneyFeasibility] = [:]
        let valid = journeys.filter { journey in
            let assessment = JourneyItineraryValidator.assess(journey, context: contexts[journey.id] ?? context)
            assessments[journey.id] = assessment
            return !invalidated.contains(journey.id) && !assessment.isInvalid && !journey.hasCancelledTransitLeg
        }
        let retained = valid.filter { candidate in
            !valid.contains { $0.id != candidate.id && JourneyQualityPolicy.dominates($0, candidate) }
        }.sorted { ($0.effectiveDeparture, $0.id) < ($1.effectiveDeparture, $1.id) }
        let transit = retained.filter { $0.legs.contains { if case .transit = $0 { true } else { false } } }
        let recommended = transit.min {
            JourneyQualityPolicy.ranksBefore($0, $1, anchor: anchor, direction: direction,
                                            preferences: request.preferences)
        } ?? retained.first
        let tokens = Dictionary(uniqueKeysWithValues: retained.map {
            ($0.id, JourneyRefinementToken(generation: generation, journeyID: $0.id,
                                          transitFingerprint: $0.transitFingerprint))
        })
        return .init(journeys: retained, recommendedJourneyID: recommended?.id,
            invalidatedIDs: invalidated, feasibility: assessments, refinementTokens: tokens,
            hasEarlier: hasEarlier, hasLater: hasLater, revision: revision, metrics: metrics,
            validationContext: context)
    }
}
