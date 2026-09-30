import Foundation

public enum RealtimeTripStatus: String, Hashable, Sendable, Codable { case active, cancelled, unreachable }
public enum RealtimeTimingSource: String, Hashable, Sendable, Codable { case scheduled, reported, estimated }
public struct RealtimeStopEventPatch: Hashable, Sendable {
    public let stopID: String
    /// GTFS sequence identifies repeated visits to the same stop.
    public let stopSequence: Int?
    public let boardingAllowed: Bool?
    public let alightingAllowed: Bool?
    public let observedAt: Date?
    public let scheduledDeparture: Date?
    public let effectiveDeparture: Date?
    public let departureSource: RealtimeTimingSource
    public let scheduledArrival: Date?
    public let effectiveArrival: Date?
    public let arrivalSource: RealtimeTimingSource
    public let platform: String?
    public init(
        stopID: String,
        scheduledDeparture: Date? = nil,
        effectiveDeparture: Date? = nil,
        departureSource: RealtimeTimingSource = .scheduled,
        scheduledArrival: Date? = nil,
        effectiveArrival: Date? = nil,
        arrivalSource: RealtimeTimingSource = .scheduled,
        platform: String? = nil,
        stopSequence: Int? = nil,
        boardingAllowed: Bool? = nil,
        alightingAllowed: Bool? = nil,
        observedAt: Date? = nil
    ) {
        self.stopID = stopID
        self.stopSequence = stopSequence
        self.boardingAllowed = boardingAllowed
        self.alightingAllowed = alightingAllowed
        self.observedAt = observedAt
        self.scheduledDeparture = scheduledDeparture
        self.effectiveDeparture = effectiveDeparture
        self.departureSource = departureSource
        self.scheduledArrival = scheduledArrival
        self.effectiveArrival = effectiveArrival
        self.arrivalSource = arrivalSource
        self.platform = platform
    }
}
/// A high-confidence, already matched GTFS trip-instance update. The mapping
/// layer belongs outside RAPTOR; this compact value is its immutable hand-off.
public struct RealtimeTripPatch: Hashable, Sendable { public let tripID: String; public let serviceDate: GTFSDate; public let status: RealtimeTripStatus; public let events: [RealtimeStopEventPatch]; public init(tripID: String, serviceDate: GTFSDate, status: RealtimeTripStatus = .active, events: [RealtimeStopEventPatch]) { self.tripID = tripID; self.serviceDate = serviceDate; self.status = status; self.events = events } }
public struct RealtimePatchBatch: Hashable, Sendable {
    public let patches: [RealtimeTripPatch]
    public let requestedStopIDs: Set<String>
    public let coveredStopIDs: Set<String>
    public let boardFetchMilliseconds: Int
    public let scheduledPreparationMilliseconds: Int
    public let boardMatchingMilliseconds: Int
    public let networkRequests: Int
    public let cacheHits: Int
    public let responseBytes: Int
    public let incompleteStopIDs: Set<String>
    public let fetchedAt: Date?
    public init(
        patches: [RealtimeTripPatch],
        requestedStopIDs: Set<String>,
        coveredStopIDs: Set<String>,
        boardFetchMilliseconds: Int = 0,
        scheduledPreparationMilliseconds: Int = 0,
        boardMatchingMilliseconds: Int = 0,
        networkRequests: Int = 0,
        cacheHits: Int = 0,
        responseBytes: Int = 0,
        incompleteStopIDs: Set<String> = [],
        fetchedAt: Date? = nil
    ) {
        self.patches = patches
        self.requestedStopIDs = requestedStopIDs
        self.coveredStopIDs = coveredStopIDs
        self.boardFetchMilliseconds = boardFetchMilliseconds
        self.scheduledPreparationMilliseconds = scheduledPreparationMilliseconds
        self.boardMatchingMilliseconds = boardMatchingMilliseconds
        self.networkRequests = networkRequests
        self.cacheHits = cacheHits
        self.responseBytes = responseBytes
        self.incompleteStopIDs = incompleteStopIDs
        self.fetchedAt = fetchedAt
    }
}
public protocol RealtimeRoutingProvider: Sendable {
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch
    func patches(
        for stopIDs: [String],
        from: Date,
        through: Date,
        refreshPolicy: RealtimeRefreshPolicy
    ) async throws -> RealtimePatchBatch
}


/// Network bounds are independent of the GTFS scheduled-time lookback.
public struct RealtimeRoutingRequest: Sendable {
    public let stopIDs: [String]
    public let from: Date
    public let through: Date
    public let scheduledLookbackSeconds: Int
    public let refreshPolicy: RealtimeRefreshPolicy
    public let maximumConcurrentRequests: Int
    public let timeout: Duration
    public init(stopIDs: [String], from: Date, through: Date,
                scheduledLookbackSeconds: Int = 7_200,
                refreshPolicy: RealtimeRefreshPolicy = .useCache,
                maximumConcurrentRequests: Int = 4, timeout: Duration = .seconds(4)) {
        self.stopIDs = stopIDs; self.from = from; self.through = through
        self.scheduledLookbackSeconds = max(0, scheduledLookbackSeconds)
        self.refreshPolicy = refreshPolicy
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.timeout = timeout
    }
}

extension RealtimeRoutingProvider {
    public func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        try await patches(for: request.stopIDs, from: request.from, through: request.through,
                          refreshPolicy: request.refreshPolicy)
    }
}
