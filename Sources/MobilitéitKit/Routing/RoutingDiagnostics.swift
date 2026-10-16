import Foundation

/// Per-operation wall-clock measurements; cumulative work counters remain in RoutingMetrics.
public struct RoutingDiagnostics: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable, Codable {
        case snapshotPreparation, endpoints, realtime, boardFetch, schedulePreparation, http, decode
        case realtimeDiscovery, boardMatching, raptor, walkingPreparation, walkingTransfers, candidateBuilding, directWalkingWait
        case geometry, resultAssembly, timetableReadiness, graphPreparation, adapterMapping
        case publication, firstRender, validation, ranking, bikeCalculation, refinement, mapRender
        // Sub-spans nested inside the stages above. They only add measurements.
        /// Inside a RAPTOR scan.
        case patchOverlay, boardingIndex, walkingBoardingDeadlines, candidateCollection
        /// Phases of one round's walking transfers.
        case walkingTransferRequests, walkingTransferRoutes, walkingTransferWork, walkingTransferApply
        /// `buildJourneys`. The first six alternate per candidate and are therefore summed work,
        /// recorded in `milliseconds` only. The last three are contiguous and recorded as spans.
        case buildNormalisation, buildStructuralValidation, buildAssembly, buildTransferRules
        case buildPublicationValidation, buildDeduplication
        case buildTransferGroups, buildEnvelope, buildIntermediateStops
        /// Inside one provider batch. Preparation is summed work; the rest are spans.
        case providerBoardFetch, providerBoardPreparation, providerStopMatching, providerSessionMerge
        /// The session's check of whether new live data changed any routing input.
        case sessionRoutingEffect
    }
    public enum Counter: String, Hashable, Sendable, Codable {
        case networkRequests, boardCacheHits, responseBytes, walkingRequests, walkingCacheHits
        case predictedEvents, delayedPastBoardings
        case boardsCovered, incompleteBoards, workers, candidates, retainedAlternatives
        case invalidJourneys, duplicatesSuppressed, sharedFirstVehicleGroups, recommendationSwitches, pageNewJourneys
    }
    /// These records describe wall-clock intervals, including nested work.
    public struct Span: Hashable, Sendable, Codable {
        public let stage: Stage
        public var startMilliseconds: Double
        public let durationMilliseconds: Double
    }
    /// One board's life inside a provider batch, relative to the operation start.
    public struct BoardTiming: Hashable, Sendable, Codable {
        public let stopID: String
        public var arrivedMilliseconds: Double?
        public var matchingStartedMilliseconds: Double?
        public var matchingFinishedMilliseconds: Double?
    }
    public struct SearchPass: Hashable, Sendable {
        public var startMilliseconds: Double
        public let durationMilliseconds: Double
        public let horizonSeconds: Double
        public let realtimeWave: Int
        public let rounds: [RoutingRoundMetrics]
        public let candidates: Int
        public let walkingMilliseconds: Int
    }
    public var transport: [HTTPTransportMeasurement] = []
    public private(set) var spans: [Span] = []
    public private(set) var searchPasses: [SearchPass] = []
    /// Schedule-only scans that run while boards are acquired. Never part of `searchPasses`.
    public private(set) var warmUpPasses: [SearchPass] = []
    public private(set) var realtimeBoards: [BoardTiming] = []
    private var origin: ContinuousClock.Instant
    /// Wall-clock time of `origin`, to place absolute transport timestamps on this timeline.
    public private(set) var originDate: Date
    /// HTTP and decode are aggregate work across concurrent requests.
    public static let cumulativeWorkStages: Set<Stage> = [.http, .decode]
    public var realtimeMatchingRejections: [RealtimeMatchingRejection: Int] = [:]
    public var rejections: [JourneyInfeasibility: Int] = [:]
    public var counters: [Counter: Int] = [:]
    public var rounds: [RoutingRoundMetrics] = []
    public let requestID: UUID
    public var milliseconds: [Stage: Double] = [:]
    public var totalMilliseconds: Double = 0
    public init(requestID: UUID = UUID(), startedAt: ContinuousClock.Instant = .now) {
        self.requestID = requestID; origin = startedAt
        originDate = Date.now.addingTimeInterval(-Self.milliseconds(startedAt.duration(to: .now)) / 1_000)
    }
    public mutating func record(_ stage: Stage, since start: ContinuousClock.Instant,
                                through end: ContinuousClock.Instant = .now) {
        let elapsed = Self.milliseconds(start.duration(to: end))
        milliseconds[stage, default: 0] += elapsed
        spans.append(.init(stage: stage, startMilliseconds: Self.milliseconds(origin.duration(to: start)), durationMilliseconds: elapsed))
    }
    public mutating func recordSearch(since start: ContinuousClock.Instant, horizon: Double, wave: Int,
                                      rounds: [RoutingRoundMetrics], candidates: Int, walkingMilliseconds: Int) {
        searchPasses.append(.init(startMilliseconds: Self.milliseconds(origin.duration(to: start)),
            durationMilliseconds: Self.elapsed(since: start), horizonSeconds: horizon, realtimeWave: wave,
            rounds: rounds, candidates: candidates, walkingMilliseconds: walkingMilliseconds))
        self.rounds.append(contentsOf: rounds)
    }
    public mutating func recordWarmUp(since start: ContinuousClock.Instant, through end: ContinuousClock.Instant,
                                      horizon: Double, rounds: [RoutingRoundMetrics], candidates: Int,
                                      walkingMilliseconds: Int) {
        warmUpPasses.append(.init(startMilliseconds: Self.milliseconds(origin.duration(to: start)),
            durationMilliseconds: Self.milliseconds(start.duration(to: end)), horizonSeconds: horizon,
            realtimeWave: 0, rounds: rounds, candidates: candidates, walkingMilliseconds: walkingMilliseconds))
    }
    /// Sums work that alternates with other work, so it has no single start.
    public mutating func addWork(_ stage: Stage, _ duration: Duration) {
        milliseconds[stage, default: 0] += Self.milliseconds(duration)
    }
    public mutating func recordBoards(_ timings: RealtimeBatchTimings) {
        func relative(_ instant: ContinuousClock.Instant?) -> Double? {
            instant.map { Self.milliseconds(origin.duration(to: $0)) }
        }
        realtimeBoards += timings.boards.map {
            .init(stopID: $0.stopID, arrivedMilliseconds: relative($0.arrived),
                  matchingStartedMilliseconds: relative($0.matchingStarted),
                  matchingFinishedMilliseconds: relative($0.matchingFinished))
        }
        if let started = timings.fetchStarted, let finished = timings.fetchFinished {
            record(.providerBoardFetch, since: started, through: finished)
        }
        if let started = timings.matchingStarted, let finished = timings.matchingFinished {
            record(.providerStopMatching, since: started, through: finished)
        }
        milliseconds[.providerBoardPreparation, default: 0] += timings.preparationMilliseconds
    }
    /// Keep every pass on the receiving operation's timeline. Gauges remain the latest values.
    public mutating func include(_ other: Self) {
        let offset = Self.milliseconds(origin.duration(to: other.origin))
        spans += other.spans.map { var span = $0; span.startMilliseconds += offset; return span }
        searchPasses += other.searchPasses.map { var pass = $0; pass.startMilliseconds += offset; return pass }
        warmUpPasses += other.warmUpPasses.map { var pass = $0; pass.startMilliseconds += offset; return pass }
        realtimeBoards += other.realtimeBoards.map {
            var board = $0
            board.arrivedMilliseconds = board.arrivedMilliseconds.map { $0 + offset }
            board.matchingStartedMilliseconds = board.matchingStartedMilliseconds.map { $0 + offset }
            board.matchingFinishedMilliseconds = board.matchingFinishedMilliseconds.map { $0 + offset }
            return board
        }
        transport += other.transport
        rounds += other.rounds
        for (stage, value) in other.milliseconds { milliseconds[stage, default: 0] += value }
        for (reason, value) in other.rejections { rejections[reason, default: 0] += value }
        for (reason, value) in other.realtimeMatchingRejections { realtimeMatchingRejections[reason, default: 0] += value }
        let gauges: Set<Counter> = [.predictedEvents, .boardsCovered, .incompleteBoards, .workers, .candidates, .retainedAlternatives]
        for (counter, value) in other.counters {
            if gauges.contains(counter) { counters[counter] = value }
            else { counters[counter, default: 0] += value }
        }
    }
    public mutating func rebase(to start: ContinuousClock.Instant) {
        let offset = Self.milliseconds(start.duration(to: origin))
        for i in spans.indices { spans[i].startMilliseconds += offset }
        for i in searchPasses.indices { searchPasses[i].startMilliseconds += offset }
        for i in warmUpPasses.indices { warmUpPasses[i].startMilliseconds += offset }
        for i in realtimeBoards.indices {
            realtimeBoards[i].arrivedMilliseconds = realtimeBoards[i].arrivedMilliseconds.map { $0 + offset }
            realtimeBoards[i].matchingStartedMilliseconds = realtimeBoards[i].matchingStartedMilliseconds.map { $0 + offset }
            realtimeBoards[i].matchingFinishedMilliseconds = realtimeBoards[i].matchingFinishedMilliseconds.map { $0 + offset }
        }
        originDate = originDate.addingTimeInterval(-offset / 1_000)
        origin = start
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
    public static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
