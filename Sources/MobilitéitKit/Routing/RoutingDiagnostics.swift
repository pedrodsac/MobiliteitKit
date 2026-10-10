import Foundation

/// Per-operation wall-clock measurements; cumulative work counters remain in RoutingMetrics.
public struct RoutingDiagnostics: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable, Codable {
        case snapshotPreparation, endpoints, realtime, boardFetch, schedulePreparation, http, decode
        case realtimeDiscovery, boardMatching, raptor, walkingTransfers, candidateBuilding, directWalkingWait
        case geometry, resultAssembly, timetableReadiness, graphPreparation, adapterMapping
        case publication, firstRender, validation, ranking, bikeCalculation, refinement, mapRender
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
    public struct SearchPass: Hashable, Sendable {
        public var startMilliseconds: Double
        public let durationMilliseconds: Double
        public let horizonSeconds: Double
        public let realtimeWave: Int
        public let rounds: [RoutingRoundMetrics]
        public let candidates: Int
        public let walkingMilliseconds: Int
    }
    public private(set) var spans: [Span] = []
    public private(set) var searchPasses: [SearchPass] = []
    private var origin: ContinuousClock.Instant
    /// HTTP and decode are aggregate work across concurrent requests.
    public static let cumulativeWorkStages: Set<Stage> = [.http, .decode]
    public var realtimeMatchingRejections: [RealtimeMatchingRejection: Int] = [:]
    public var rejections: [JourneyInfeasibility: Int] = [:]
    public var counters: [Counter: Int] = [:]
    public var rounds: [RoutingRoundMetrics] = []
    public let requestID: UUID
    public var milliseconds: [Stage: Double] = [:]
    public var totalMilliseconds: Double = 0
    public init(requestID: UUID = UUID(), startedAt: ContinuousClock.Instant = .now) { self.requestID = requestID; origin = startedAt }
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
    /// Keep every pass on the receiving operation's timeline. Gauges remain the latest values.
    public mutating func include(_ other: Self) {
        let offset = Self.milliseconds(origin.duration(to: other.origin))
        spans += other.spans.map { var span = $0; span.startMilliseconds += offset; return span }
        searchPasses += other.searchPasses.map { var pass = $0; pass.startMilliseconds += offset; return pass }
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
