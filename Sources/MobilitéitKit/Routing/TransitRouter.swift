import Foundation

// MARK: - Public routing surface

public enum JourneyEndpoint: Hashable, Sendable, Codable {
    case stop(id: String)
    case coordinate(Coordinate, label: String?)
}

public struct TransitModeMask: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let all = TransitModeMask(rawValue: .max)
    /// Normalize documented HVT route types to a basic transit mode. Unknown
    /// extended types remain excluded by a restricted mask rather than being
    /// silently classified as rail, bus, or another mode.
    public func contains(routeType: Int) -> Bool {
        if rawValue == Self.all.rawValue { return true }
        let basic: Int = switch routeType {
        case 100...117: 2 // rail
        case 200...209, 700...716: 3 // coach and bus
        case 400...404: 1 // urban rail and metro
        case 405: 12 // monorail
        case 800: 11 // trolleybus
        case 900...906: 0 // tram
        case 1000, 1200: 4 // water transport and ferry
        case 1100: 5 // air
        case 1300...1307: 6 // aerial lift
        case 1400: 7 // funicular
        default: routeType
        }
        guard (0..<64).contains(basic) else { return false }
        return (rawValue & (UInt64(1) << UInt64(basic))) != 0
    }
}

public enum JourneyPreference: String, Hashable, Sendable, Codable { case fastest, fewerTransfers, lessWalking, preferDirect }
public enum FrequencyRoutingPolicy: String, Hashable, Sendable, Codable { case conservative, expected, excludeInexact }
public enum WheelchairPreference: String, Hashable, Sendable, Codable { case noPreference, required }
public enum AccessibilityAssessment: String, Hashable, Sendable, Codable {
    case verified, unknown, inaccessible
}
public enum BikePreference: String, Hashable, Sendable, Codable { case noPreference, required }

public struct RoutingPreferences: Hashable, Sendable, Codable {
    public var maxTransfers: Int?
    public var minimumTransferSeconds: Int
    /// Legacy decoding field. Transfer minima are always strict; this value is ignored.
    public var sameStopTransferShortfallSeconds: Int
    public var suggestionPolicy: JourneySuggestionPolicy = .init()
    public var boardingBufferSeconds: Int = 0
    public var maximumWalkingSeconds: Int? = nil
    public var allowedModes: TransitModeMask
    public var preferredMode: TransitModeMask?
    public var wheelchair: WheelchairPreference
    public var preferWheelchairAccessible: Bool
    public var bike: BikePreference
    public var routePreference: JourneyPreference
    public var frequencyPolicy: FrequencyRoutingPolicy
    public init(maxTransfers: Int? = 3, minimumTransferSeconds: Int = 120, sameStopTransferShortfallSeconds: Int = 0, allowedModes: TransitModeMask = .all, preferredMode: TransitModeMask? = nil, wheelchair: WheelchairPreference = .noPreference, preferWheelchairAccessible: Bool = false, bike: BikePreference = .noPreference, routePreference: JourneyPreference = .fastest, frequencyPolicy: FrequencyRoutingPolicy = .conservative, boardingBufferSeconds: Int = 0, maximumWalkingSeconds: Int? = nil, suggestionPolicy: JourneySuggestionPolicy = .init()) {
        self.suggestionPolicy = suggestionPolicy
        self.boardingBufferSeconds = boardingBufferSeconds; self.maximumWalkingSeconds = maximumWalkingSeconds
        self.maxTransfers = maxTransfers; self.minimumTransferSeconds = minimumTransferSeconds; self.sameStopTransferShortfallSeconds = max(0, sameStopTransferShortfallSeconds); self.allowedModes = allowedModes
        self.preferredMode = preferredMode; self.wheelchair = wheelchair; self.preferWheelchairAccessible = preferWheelchairAccessible
        self.bike = bike; self.routePreference = routePreference; self.frequencyPolicy = frequencyPolicy
    }
    private enum CodingKeys: String, CodingKey {
        case maxTransfers, minimumTransferSeconds, sameStopTransferShortfallSeconds, allowedModes, preferredMode
        case wheelchair, preferWheelchairAccessible, bike, routePreference, frequencyPolicy, boardingBufferSeconds, maximumWalkingSeconds, suggestionPolicy
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        suggestionPolicy = try values.decodeIfPresent(JourneySuggestionPolicy.self, forKey: .suggestionPolicy) ?? .init()
        boardingBufferSeconds = try values.decodeIfPresent(Int.self, forKey: .boardingBufferSeconds) ?? 0
        maximumWalkingSeconds = try values.decodeIfPresent(Int.self, forKey: .maximumWalkingSeconds)
        maxTransfers = values.contains(.maxTransfers)
            ? try values.decodeIfPresent(Int.self, forKey: .maxTransfers) : 3
        minimumTransferSeconds = try values.decodeIfPresent(Int.self, forKey: .minimumTransferSeconds) ?? 120
        sameStopTransferShortfallSeconds = max(0, try values.decodeIfPresent(Int.self, forKey: .sameStopTransferShortfallSeconds) ?? 0)
        allowedModes = try values.decodeIfPresent(TransitModeMask.self, forKey: .allowedModes) ?? .all
        preferredMode = try values.decodeIfPresent(TransitModeMask.self, forKey: .preferredMode)
        wheelchair = try values.decodeIfPresent(WheelchairPreference.self, forKey: .wheelchair) ?? .noPreference
        preferWheelchairAccessible = try values.decodeIfPresent(Bool.self, forKey: .preferWheelchairAccessible) ?? false
        bike = try values.decodeIfPresent(BikePreference.self, forKey: .bike) ?? .noPreference
        routePreference = try values.decodeIfPresent(JourneyPreference.self, forKey: .routePreference) ?? .fastest
        frequencyPolicy = try values.decodeIfPresent(FrequencyRoutingPolicy.self, forKey: .frequencyPolicy) ?? .conservative
    }
}

public struct RealtimeConfiguration: Hashable, Sendable, Codable {
    public var scheduledLookbackSeconds: Int
    public var minimumForwardHorizonSeconds: Int
    public var maximumConcurrentBoardRequests: Int
    public var maximumRefinementWaves: Int
    public var acquisitionBudgetMilliseconds: Int
    /// Legacy work allowance. An explicit zero disables acquisition; positive
    /// values cannot suppress required checks on initially or newly selected
    /// vehicles. Acquisition time and the wave limit bound those checks.
    public var searchWorkBudgetMilliseconds: Int?
    public init(scheduledLookbackSeconds: Int = 7_200, minimumForwardHorizonSeconds: Int = 5_400, maximumConcurrentBoardRequests: Int = 4, maximumRefinementWaves: Int = 4, acquisitionBudgetMilliseconds: Int = 4_000, searchWorkBudgetMilliseconds: Int? = nil) {
        self.scheduledLookbackSeconds = scheduledLookbackSeconds; self.minimumForwardHorizonSeconds = minimumForwardHorizonSeconds
        self.maximumConcurrentBoardRequests = maximumConcurrentBoardRequests; self.maximumRefinementWaves = maximumRefinementWaves
        self.acquisitionBudgetMilliseconds = max(0, acquisitionBudgetMilliseconds)
        self.searchWorkBudgetMilliseconds = searchWorkBudgetMilliseconds.map { max(0, $0) }
    }
    private enum CodingKeys: String, CodingKey {
        case scheduledLookbackSeconds, minimumForwardHorizonSeconds
        case maximumConcurrentBoardRequests, maximumRefinementWaves, acquisitionBudgetMilliseconds, searchWorkBudgetMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scheduledLookbackSeconds: try values.decode(Int.self, forKey: .scheduledLookbackSeconds),
                  minimumForwardHorizonSeconds: try values.decode(Int.self, forKey: .minimumForwardHorizonSeconds),
                  maximumConcurrentBoardRequests: try values.decode(Int.self, forKey: .maximumConcurrentBoardRequests),
                  maximumRefinementWaves: try values.decode(Int.self, forKey: .maximumRefinementWaves),
                  acquisitionBudgetMilliseconds: try values.decodeIfPresent(Int.self, forKey: .acquisitionBudgetMilliseconds) ?? 4_000,
                  searchWorkBudgetMilliseconds: try values.decodeIfPresent(Int.self, forKey: .searchWorkBudgetMilliseconds))
    }
    public static let `default` = RealtimeConfiguration()
}
public enum RealtimeRefreshPolicy: String, Hashable, Sendable, Codable { case useCache, forceRefresh }
public enum RealtimePolicy: Hashable, Sendable, Codable {
    case disabled
    case bestEffort(
        configuration: RealtimeConfiguration = .default,
        refresh: RealtimeRefreshPolicy = .useCache
    )
}

public enum RouteQueryDirection: String, Hashable, Sendable, Codable { case departAfter, arriveBy }
public struct RouteQuery: Hashable, Sendable {
    public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let departureTime: Date
    public let direction: RouteQueryDirection
    public let preferences: RoutingPreferences; public let realtimePolicy: RealtimePolicy
    public init(origin: JourneyEndpoint, destination: JourneyEndpoint, departureTime: Date, direction: RouteQueryDirection = .departAfter, preferences: RoutingPreferences = .init(), realtimePolicy: RealtimePolicy = .disabled) {
        self.origin = origin; self.destination = destination; self.departureTime = departureTime; self.direction = direction; self.preferences = preferences; self.realtimePolicy = realtimePolicy
    }
}

public struct WalkingRequest: Hashable, Sendable { public let source: Coordinate; public let destination: Coordinate; public let departure: Date?; public init(source: Coordinate, destination: Coordinate, departure: Date? = nil) { self.source = source; self.destination = destination; self.departure = departure } }
public struct WalkingEstimate: Hashable, Sendable { public let durationSeconds: Int; public let distanceMeters: Double; public init(durationSeconds: Int, distanceMeters: Double) { self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters } }
public struct WalkingStep: Hashable, Sendable { public let instruction: String; public let coordinate: Coordinate?; public init(instruction: String, coordinate: Coordinate? = nil) { self.instruction = instruction; self.coordinate = coordinate } }
public enum WalkingEvidence: String, Hashable, Sendable, Codable { case routedPedestrian, estimate }
public struct WalkingRoute: Hashable, Sendable { public let durationSeconds: Int; public let distanceMeters: Double; public let polyline: [Coordinate]; public let steps: [WalkingStep]; public let evidence: WalkingEvidence; public init(durationSeconds: Int, distanceMeters: Double, polyline: [Coordinate] = [], steps: [WalkingStep] = [], evidence: WalkingEvidence = .routedPedestrian) { self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters; self.polyline = polyline; self.steps = steps; self.evidence = evidence } }
public protocol WalkingRoutingProvider: Sendable {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate
    func route(_ request: WalkingRequest) async throws -> WalkingRoute

    /// Resolves independent walking requests with bounded concurrency. Providers
    /// backed by a one-to-many router can override this to perform a true batch.
    func routes(
        _ requests: [WalkingRequest],
        maximumConcurrency: Int
    ) async -> [WalkingRoute?]
}

public extension WalkingRoutingProvider {
    func routes(
        _ requests: [WalkingRequest],
        maximumConcurrency: Int = 4
    ) async -> [WalkingRoute?] {
        guard !requests.isEmpty else { return [] }
        guard !Task.isCancelled else { return Array(repeating: nil, count: requests.count) }
        let limit = min(max(1, maximumConcurrency), requests.count)
        return await withTaskGroup(of: (Int, WalkingRoute?).self) { group in
            var nextIndex = 0
            var results = Array<WalkingRoute?>(repeating: nil, count: requests.count)

            func add(_ index: Int) -> Bool {
                let request = requests[index]
                return group.addTaskUnlessCancelled {
                    (index, try? await route(request))
                }
            }

            for _ in 0..<limit {
                guard add(nextIndex) else { break }
                nextIndex += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if nextIndex < requests.count, !Task.isCancelled {
                    guard add(nextIndex) else { break }
                    nextIndex += 1
                }
            }
            return results
        }
    }
}


struct RealtimePatchKey: Hashable, Sendable {
    let tripID: String
    let serviceDate: GTFSDate
}

public enum WalkingSource: String, Hashable, Sendable, Codable { case provider, pathway }
public struct JourneyLocation: Hashable, Sendable { public let stop: TransitStop?; public let coordinate: Coordinate; public let label: String?; public init(stop: TransitStop? = nil, coordinate: Coordinate, label: String? = nil) { self.stop = stop; self.coordinate = coordinate; self.label = label } }
public struct WalkingLeg: Hashable, Sendable { public let from: JourneyLocation; public let to: JourneyLocation; public let departure: Date; public let arrival: Date; public let duration: TimeInterval; public let distanceMeters: Double; public let polyline: [Coordinate]; public let steps: [WalkingStep]; public let source: WalkingSource; public let evidence: WalkingEvidence; public var nativeRange: Range<Int>? = nil }
public struct JourneyStopEvent: Hashable, Sendable {
    public let stop: TransitStop
    public let scheduledTime: Date
    public let effectiveTime: Date
    public let timingSource: RealtimeTimingSource
    public let platform: String?
    public init(
        stop: TransitStop,
        scheduledTime: Date,
        effectiveTime: Date,
        timingSource: RealtimeTimingSource = .scheduled,
        platform: String? = nil
    ) {
        self.stop = stop
        self.scheduledTime = scheduledTime
        self.effectiveTime = effectiveTime
        self.timingSource = timingSource
        self.platform = platform
    }
}
public struct TransitLeg: Hashable, Sendable { public let tripID: String; public let route: TransitRoute; public let headsign: String?; public let board: JourneyStopEvent; public let alight: JourneyStopEvent; public var intermediateStops: [JourneyStopEvent]; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let status: RealtimeTripStatus; public var requiredTransferSecondsAfterWalking: Int; public var boardingDeadline: Date? = nil; public var requiredTotalTransferSeconds: Int? = nil; public var instance: TransitInstanceIdentity? = nil; public var boardSequence: Int? = nil; public var alightSequence: Int? = nil; public var polyline: [Coordinate] = [] }
public struct InSeatContinuationLeg: Hashable, Sendable { public let fromTripID: String; public let toTripID: String }
public enum JourneyLeg: Hashable, Sendable { case walk(WalkingLeg), transit(TransitLeg), inSeatContinuation(InSeatContinuationLeg) }
public struct JourneySignature: Hashable, Sendable, Codable, Comparable, Identifiable { public let value: String; public var id: String { value }; public init(_ value: String) { self.value = value }; public static func < (l: Self, r: Self) -> Bool { l.value < r.value } }
public enum PageRealtimeState: String, Hashable, Sendable, Codable { case disabled, unavailable, partial, live }
public struct Journey: Hashable, Sendable, Identifiable { public let id: JourneySignature; public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let transferCount: Int; public let walkingDuration: TimeInterval; public let walkingDistance: Double; public let waitingDuration: TimeInterval; public let inVehicleDuration: TimeInterval; public let legs: [JourneyLeg]; public let feedGeneration: Int; public let accessibility: AccessibilityAssessment; public let matchesPreferredMode: Bool; public var duration: TimeInterval { effectiveArrival.timeIntervalSince(effectiveDeparture) } }
public struct RoutingMetrics: Hashable, Sendable {
    public var pointRaptorScans = 0; public var profileGenerationMilliseconds = 0
    public var snapshotLoadMilliseconds = 0; public var raptorSearchMilliseconds = 0
    /// Historical name: elapsed round work excluding walking, not process CPU time.
    public var raptorCPUMilliseconds = 0; public var walkingTransferMilliseconds = 0
    public var raptorNonWalkingMilliseconds: Int { raptorCPUMilliseconds }
    public var raptorWorkerCount = 1
    public var endpointPreparationMilliseconds = 0; public var realtimePreparationMilliseconds = 0
    public var candidateBuildingMilliseconds = 0; public var scannedPatterns = 0
    public var scannedTripInstances = 0
    public var endpointAccessCandidates = 0; public var endpointEgressCandidates = 0
    public var candidatesGenerated = 0; public var alternativesRetained = 0
    public var walkingRequests = 0; public var walkingCacheHits = 0
    public var walkingTransferPairs = 0
    public var hafasRequests = 0; public var hafasCacheHits = 0
    public var realtimeHTTPMilliseconds = 0; public var realtimeDecodeMilliseconds = 0
    public var realtimeBoardFetchMilliseconds = 0
    public var realtimeScheduledPreparationMilliseconds = 0
    public var realtimeBoardMatchingMilliseconds = 0
    public var realtimeBoardsCovered = 0
    public var realtimeResponseBytes = 0; public var realtimeIncompleteBoards = 0
    public var realtimePredictedEvents = 0
    public var realtimeFrontierSize = 0; public var delayedPastBoardingsInjected = 0
    public var realtimeOverlayRevisions = 0; public var raptorReruns = 0
    public var searchRounds: [RoutingRoundMetrics] = []
    public init() {}
}
public struct RoutingRoundMetrics: Hashable, Sendable {
    public let tripPreparationMilliseconds: Int
    public let patternScanMilliseconds: Int
    public let labelMergeMilliseconds: Int
    public let patterns: Int
    public let tripInstances: Int
    public let boardingChecks: Int
    public let feasibleBoardings: Int
    public let alightingChecks: Int
    public let labelAttempts: Int
    public let retainedLabels: Int
    public let rejectedBeforeAllocation: Int
    public let slowestChunkMilliseconds: Int
    public let summedChunkMilliseconds: Int
}
public struct JourneyPageBoundary: Sendable {
    public let departure: Date; public let id: JourneySignature?
}
public struct JourneyPage: Sendable { public var exploredBefore: JourneyPageBoundary? = nil; public var exploredAfter: JourneyPageBoundary? = nil; public let journeys: [Journey]; public let recommendedJourneyID: JourneySignature?; public let hasEarlier: Bool; public let hasLater: Bool; public let realtimeState: PageRealtimeState; public let revision: UInt64; public let metrics: RoutingMetrics; public var diagnostics = RoutingDiagnostics() }
public enum JourneyPlannerError: Error, Sendable { case invalidPreferences, endpointNotFound, noInstalledFeed }

/// GTFS's service-day conversion anchored at local noon, as required by the
/// schedule specification. It is intentionally the sole date conversion used
/// by the routing snapshot.
public struct ServiceInstantConverter: Sendable {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone) { self.timeZone = timeZone }
    public func date(serviceDate: GTFSDate, serviceSeconds: Int32) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let noon = calendar.date(from: DateComponents(timeZone: timeZone, year: serviceDate.year, month: serviceDate.month, day: serviceDate.day, hour: 12))!
        return noon.addingTimeInterval(-43_200 + TimeInterval(serviceSeconds))
    }
}

// MARK: - Immutable snapshot

struct SnapshotStop: Sendable { let id: String; let model: TransitStop; let parent: String? }
struct SnapshotTime: Sendable { let stop: Int; let sequence: Int; let arrival: Int32?; let departure: Int32?; let pickup: Int; let dropoff: Int; var headsign: String? = nil }
struct SnapshotTrip: Sendable {
    let id: String; let route: Int; let service: Int; let times: [SnapshotTime]; let headsign: String?
    let wheelchairAccessible: Int
    var blockID: String? = nil
    var bikesAllowed: Int = 0
    var isFrequencyTemplate = false
    let firstServiceTime: Int32; let lastServiceTime: Int32

    init(id: String, route: Int, service: Int, times: [SnapshotTime], headsign: String?, wheelchairAccessible: Int) {
        self.id = id; self.route = route; self.service = service; self.times = times; self.headsign = headsign
        self.wheelchairAccessible = wheelchairAccessible
        firstServiceTime = times.lazy.compactMap { $0.departure ?? $0.arrival }.first ?? 0
        lastServiceTime = times.lazy.reversed().compactMap { $0.departure ?? $0.arrival }.first ?? 0
    }
}
struct SnapshotRule: Sendable { let order: Int; let from: Int?; let to: Int?; let type: Int; let minimum: Int?; let fromRoute: Int?; let toRoute: Int?; let fromTrip: Int?; let toTrip: Int? }
struct RuleGroupKey: Hashable, Sendable { let from: Int?; let to: Int? }
struct SnapshotPath: Sendable {
    let from: Int; let to: Int; let seconds: Int; let distance: Double; let mode: Int
    let stairCount: Int?; let maxSlope: Double?; let minWidth: Double?
}
struct SnapshotPattern: Sendable { let trips: [Int]; let stops: [Int] }
struct PatternOccurrence: Sendable { let pattern: Int; let position: Int }
struct SnapshotServiceDay: Sendable { let offset: Int; let date: GTFSDate; let start: Date; let activeServices: Set<Int> }
private struct StopGridCell: Hashable { let latitude: Int; let longitude: Int }
struct RoutingSnapshot: Sendable {
    let info: FeedInfo; let converter: ServiceInstantConverter; let stops: [SnapshotStop]; let stopByID: [String: Int]; let routes: [TransitRoute]; let trips: [SnapshotTrip]; let tripByID: [String: Int]; let tripIndicesByDepartureStop: [[Int]]; let serviceRoutesByStop: [[ServiceRoute]]; let boardableStops: Set<Int>; let alightableStops: Set<Int>; let serviceDays: [SnapshotServiceDay]; let lastActiveDayStartByService: [Date?]; let rulesByGroup: [RuleGroupKey: [SnapshotRule]]; let stationGroupByStop: [Int]; let pathsByFrom: [[SnapshotPath]]; let pathsByTo: [[SnapshotPath]]; let nearbyTransferStopsByStop: [[Int]]
    let hasContinuations: Bool
    let patterns: [SnapshotPattern]; let patternOccurrencesByStop: [[PatternOccurrence]]; let loadMilliseconds: Int
}

struct ServiceRoute: Hashable, Sendable {
    let service: Int
    let route: Int
}

private enum SnapshotBuilder {
    static func load(databaseURL: URL) throws -> RoutingSnapshot {
        let loadStarted = ContinuousClock.now
        let db = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
        let metadata = try db.prepare("SELECT key,value FROM metadata")
        var m: [String: String] = [:]; while try metadata.step() { m[metadata.text(0)!] = metadata.text(1)! }
        guard let first = m["feed_start"], let last = m["feed_end"], let max = m["maximum_service_time"].flatMap(Int32.init), let generation = m["generation"].flatMap(Int.init) else { throw JourneyPlannerError.noInstalledFeed }
        let info = FeedInfo(firstServiceDate: try GTFSDate(parsing: first), lastServiceDate: try GTFSDate(parsing: last), maximumServiceTime: ServiceTime(rawValue: max), generation: generation)
        let zoneStatement = try db.prepare("SELECT timezone FROM agency ORDER BY id LIMIT 1"); let zone = (try zoneStatement.step() ? zoneStatement.text(0).flatMap(TimeZone.init(identifier:)) : nil) ?? TimeZone(identifier: "Europe/Luxembourg")!
        let stopStmt = try db.prepare("SELECT id,gtfs_id,code,name,stop_description,lat_e6,lon_e6,location_type,parent_station_id,wheelchair_boarding,platform_code FROM stop ORDER BY id")
        var stops: [SnapshotStop] = []; var stopByID: [String: Int] = [:]; var sqliteStopIndex: [Int: Int] = [:]
        while try stopStmt.step() { let id = stopStmt.text(1)!; let s = TransitStop(id: id, code: stopStmt.text(2), name: stopStmt.text(3)!, stopDescription: stopStmt.text(4), coordinate: Coordinate(latitude: Double(stopStmt.int64(5))/1e6, longitude: Double(stopStmt.int64(6))/1e6), locationType: stopStmt.int(7), parentStationID: stopStmt.text(8), wheelchairBoarding: stopStmt.int(9), platformCode: stopStmt.text(10)); stopByID[id] = stops.count; sqliteStopIndex[stopStmt.int(0)] = stops.count; stops.append(.init(id: id, model: s, parent: s.parentStationID)) }
        let routeStmt = try db.prepare("SELECT id,gtfs_id,agency_id,short_name,long_name,route_type,color,text_color,route_description FROM route ORDER BY id")
        var routes: [TransitRoute] = []; var routeIndex: [Int: Int] = [:]; var index = 0
        while try routeStmt.step() { routeIndex[routeStmt.int(0)] = routes.count; routes.append(.init(id: routeStmt.text(1)!, agencyID: nil, shortName: routeStmt.text(3), longName: routeStmt.text(4), type: routeStmt.int(5), color: routeStmt.text(6), textColor: routeStmt.text(7), routeDescription: routeStmt.text(8))); index += 1 }
        let serviceStmt = try db.prepare("SELECT id FROM service ORDER BY id"); var serviceIndex: [Int: Int] = [:]; index = 0; while try serviceStmt.step() { serviceIndex[serviceStmt.int(0)] = index; index += 1 }
        // Load all stop times in one ordered scan. The previous implementation
        // reset and executed one SQLite statement per trip (30k+ statements on
        // the Luxembourg feed), which dominated cold snapshot construction.
        let tripTimeStmt = try db.prepare("""
            SELECT t.id,t.gtfs_id,t.route_id,t.service_id,t.headsign,
                   st.stop_id,st.sequence,st.arrival_sec,st.departure_sec,
                   st.pickup_type,st.dropoff_type,t.wheelchair_accessible,st.stop_headsign,t.block_id,t.bikes_allowed
            FROM trip t JOIN stop_time st ON st.trip_id=t.id
            ORDER BY t.id,st.sequence
            """)
        var trips: [SnapshotTrip] = []; var tripIndex: [Int: Int] = [:]
        var currentSQLiteTrip: Int?; var currentID = ""; var currentRoute: Int?; var currentService: Int?
        var currentBikes = 0; var currentBlock: String?; var currentHeadsign: String?; var currentTimes: [SnapshotTime] = []; var currentWheelchair = 0
        func appendCurrentTrip() {
            guard let sqliteTrip = currentSQLiteTrip, let route = currentRoute,
                  let service = currentService, currentTimes.count >= 2, TripTimeline.isValid(currentTimes) else { return }
            tripIndex[sqliteTrip] = trips.count
            trips.append(.init(id: currentID, route: route, service: service, times: currentTimes, headsign: currentHeadsign, wheelchairAccessible: currentWheelchair))
            trips[trips.count - 1].blockID = currentBlock
            trips[trips.count - 1].bikesAllowed = currentBikes
        }
        while try tripTimeStmt.step() {
            let sqliteTrip = tripTimeStmt.int(0)
            if currentSQLiteTrip != sqliteTrip {
                appendCurrentTrip()
                currentSQLiteTrip = sqliteTrip; currentID = tripTimeStmt.text(1)!
                currentRoute = routeIndex[tripTimeStmt.int(2)]; currentService = serviceIndex[tripTimeStmt.int(3)]
                currentHeadsign = tripTimeStmt.text(4); currentBlock = tripTimeStmt.text(13); currentBikes = tripTimeStmt.int(14); currentWheelchair = tripTimeStmt.int(11); currentTimes = []
            }
            guard let stop = sqliteStopIndex[tripTimeStmt.int(5)] else { continue }
            currentTimes.append(.init(stop: stop, sequence: tripTimeStmt.int(6), arrival: tripTimeStmt.isNull(7) ? nil : tripTimeStmt.int32(7), departure: tripTimeStmt.isNull(8) ? nil : tripTimeStmt.int32(8), pickup: tripTimeStmt.int(9), dropoff: tripTimeStmt.int(10), headsign: tripTimeStmt.text(12)))
        }
        appendCurrentTrip()
        // exact_times=1 is a set of real timetable instances, represented as
        // lightweight shifted trips in the day view rather than a permanent
        // database explosion. Inexact headway services remain a policy choice.
        if let frequency = try? db.prepare("SELECT trip_id,start_sec,end_sec,headway_sec,exact_times FROM frequency") {
            while try frequency.step() {
                guard !frequency.isNull(4), frequency.int(4) == 1, let sourceIndex = tripIndex[frequency.int(0)] else { continue }
                let source = trips[sourceIndex]
                trips[sourceIndex].isFrequencyTemplate = true
                guard let first = source.times.first?.departure ?? source.times.first?.arrival else { continue }
                var departure = frequency.int32(1)
                while departure < frequency.int32(2) {
                    let shift = departure - first
                    let shifted = source.times.map { time in SnapshotTime(stop: time.stop, sequence: time.sequence, arrival: time.arrival.map { $0 + shift }, departure: time.departure.map { $0 + shift }, pickup: time.pickup, dropoff: time.dropoff, headsign: time.headsign) }
                    trips.append(.init(id: "\(source.id)#frequency-\(departure)", route: source.route, service: source.service, times: shifted, headsign: source.headsign, wheelchairAccessible: source.wheelchairAccessible))
                    trips[trips.count - 1].bikesAllowed = source.bikesAllowed
                    trips[trips.count - 1].blockID = source.blockID
                    departure += frequency.int32(3)
                }
            }
        }
        let tripByID = Dictionary(uniqueKeysWithValues: trips.enumerated().map { ($0.element.id, $0.offset) })
        var tripIndicesByDepartureStop = Array(repeating: [Int](), count: stops.count)
        var serviceRoutesByStop = Array(repeating: Set<ServiceRoute>(), count: stops.count)
        for (tripIndex, trip) in trips.enumerated() {
            let serviceRoute = ServiceRoute(service: trip.service, route: trip.route)
            for time in trip.times {
                serviceRoutesByStop[time.stop].insert(serviceRoute)
            }
            for stop in Set(trip.times.compactMap { $0.departure == nil ? nil : $0.stop }) {
                tripIndicesByDepartureStop[stop].append(tripIndex)
            }
        }
        let boardableStops = Set(trips.flatMap { trip in
            trip.times.compactMap { time in
                time.pickup == 0 && time.departure != nil ? time.stop : nil
            }
        })
        let alightableStops = Set(trips.flatMap { trip in
            trip.times.compactMap { time in
                time.dropoff == 0 && time.arrival != nil ? time.stop : nil
            }
        })
        var active = Array(repeating: Set<Int>(), count: info.firstServiceDate.days(until: info.lastServiceDate) + 1); let activeStmt = try db.prepare("SELECT day_index,service_id FROM service_date"); while try activeStmt.step() { let day = activeStmt.int(0); if active.indices.contains(day), let s = serviceIndex[activeStmt.int(1)] { active[day].insert(s) } }
        let rstmt = try db.prepare("SELECT from_stop_id,to_stop_id,transfer_type,min_transfer_sec,from_route_id,to_route_id,from_trip_id,to_trip_id FROM transfer_rule"); var rules: [SnapshotRule] = []; while try rstmt.step() { if (!rstmt.isNull(6) && tripIndex[rstmt.int(6)] == nil) || (!rstmt.isNull(7) && tripIndex[rstmt.int(7)] == nil) { continue }; rules.append(.init(order: rules.count, from: rstmt.isNull(0) ? nil : sqliteStopIndex[rstmt.int(0)], to: rstmt.isNull(1) ? nil : sqliteStopIndex[rstmt.int(1)], type: rstmt.int(2), minimum: rstmt.isNull(3) ? nil : rstmt.int(3), fromRoute: rstmt.isNull(4) ? nil : routeIndex[rstmt.int(4)], toRoute: rstmt.isNull(5) ? nil : routeIndex[rstmt.int(5)], fromTrip: rstmt.isNull(6) ? nil : tripIndex[rstmt.int(6)], toTrip: rstmt.isNull(7) ? nil : tripIndex[rstmt.int(7)])) }
        let stationGroupByStop = stops.indices.map { stop in stops[stop].parent.flatMap { stopByID[$0] } ?? stop }
        let rulesByGroup = Dictionary(grouping: rules) { rule in
            RuleGroupKey(from: rule.from.map { stationGroupByStop[$0] }, to: rule.to.map { stationGroupByStop[$0] })
        }
        var paths: [SnapshotPath] = []; if let pstmt = try? db.prepare("SELECT from_stop_id,to_stop_id,traversal_time,is_bidirectional,length,pathway_mode,stair_count,max_slope,min_width FROM pathway") { while try pstmt.step() { guard !pstmt.isNull(2), pstmt.int(2) > 0, (pstmt.isNull(4) || pstmt.double(4) >= 0), let a = sqliteStopIndex[pstmt.int(0)], let b = sqliteStopIndex[pstmt.int(1)] else { continue }; let path = SnapshotPath(from: a, to: b, seconds: pstmt.int(2), distance: pstmt.isNull(4) ? 0 : pstmt.double(4), mode: pstmt.isNull(5) ? 0 : pstmt.int(5), stairCount: pstmt.isNull(6) ? nil : pstmt.int(6), maxSlope: pstmt.isNull(7) ? nil : pstmt.double(7), minWidth: pstmt.isNull(8) ? nil : pstmt.double(8)); paths.append(path); if pstmt.int(3) == 1 { paths.append(.init(from: b, to: a, seconds: path.seconds, distance: path.distance, mode: path.mode, stairCount: path.stairCount.map { -$0 }, maxSlope: path.maxSlope.map { -$0 }, minWidth: path.minWidth)) } } }
        var pathsByFrom = Array(repeating: [SnapshotPath](), count: stops.count)
        var pathsByTo = Array(repeating: [SnapshotPath](), count: stops.count)
        for path in paths {
            pathsByFrom[path.from].append(path)
            pathsByTo[path.to].append(path)
        }
        let nearbyTransferStopsByStop = nearbyTransferStops(
            stops: stops,
            alightableStops: alightableStops,
            boardableStops: boardableStops,
            stationGroupByStop: stationGroupByStop
        )
        // Grouping by route + ordered occurrence sequence gives RAPTOR patterns,
        // never merely route_id. Families are split conservatively by an
        // overtaking check at search time (small feeds remain inexpensive).
        var grouped: [String: [Int]] = [:]; for (i,t) in trips.enumerated() { grouped["\(t.route)|\(t.times.map(\.stop).map(String.init).joined(separator: ","))", default: []].append(i) }
        let patterns = grouped.keys.sorted().map { key in
            let family = grouped[key] ?? []
            return SnapshotPattern(trips: family, stops: family.first.map { trips[$0].times.map(\.stop) } ?? [])
        }
        var patternOccurrencesByStop = Array(repeating: [PatternOccurrence](), count: stops.count)
        for (patternID, pattern) in patterns.enumerated() {
            var firstPositionByStop: [Int: Int] = [:]
            for (position, stop) in pattern.stops.enumerated() {
                firstPositionByStop[stop] = min(firstPositionByStop[stop] ?? position, position)
            }
            for (stop, position) in firstPositionByStop.sorted(by: { $0.key < $1.key }) {
                patternOccurrencesByStop[stop].append(.init(pattern: patternID, position: position))
            }
        }
        let converter = ServiceInstantConverter(timeZone: zone)
        let serviceDays = active.indices.map { offset in
            let date = info.firstServiceDate.adding(days: offset)
            return SnapshotServiceDay(offset: offset, date: date, start: converter.date(serviceDate: date, serviceSeconds: 0), activeServices: active[offset])
        }
        var lastActiveDayStartByService = Array<Date?>(repeating: nil, count: serviceIndex.count)
        for day in serviceDays {
            for service in day.activeServices {
                lastActiveDayStartByService[service] = day.start
            }
        }
        return .init(info: info, converter: converter, stops: stops, stopByID: stopByID, routes: routes, trips: trips, tripByID: tripByID, tripIndicesByDepartureStop: tripIndicesByDepartureStop, serviceRoutesByStop: serviceRoutesByStop.map(Array.init), boardableStops: boardableStops, alightableStops: alightableStops, serviceDays: serviceDays, lastActiveDayStartByService: lastActiveDayStartByService, rulesByGroup: rulesByGroup, stationGroupByStop: stationGroupByStop, pathsByFrom: pathsByFrom, pathsByTo: pathsByTo, nearbyTransferStopsByStop: nearbyTransferStopsByStop, hasContinuations: rulesByGroup.values.joined().contains { $0.type == 4 && $0.fromTrip != nil && $0.toTrip != nil }, patterns: patterns, patternOccurrencesByStop: patternOccurrencesByStop, loadMilliseconds: Int(RoutingDiagnostics.elapsed(since: loadStarted)))
    }

    /// Precomputes a small geographic interchange frontier for every stop.
    /// Actual pedestrian times are still obtained from the walking provider
    /// once a stop is reached during RAPTOR; this only avoids a quadratic scan
    /// of the complete feed for each journey query.
    private static func nearbyTransferStops(
        stops: [SnapshotStop],
        alightableStops: Set<Int>,
        boardableStops: Set<Int>,
        stationGroupByStop: [Int]
    ) -> [[Int]] {
        let cellSize = 0.005
        let nearDistanceMeters = 450.0
        let expandedDistanceMeters = 900.0
        let candidateLimit = 12
        func cell(for coordinate: Coordinate) -> StopGridCell {
            .init(
                latitude: Int((coordinate.latitude / cellSize).rounded(.down)),
                longitude: Int((coordinate.longitude / cellSize).rounded(.down))
            )
        }

        var boardableByCell: [StopGridCell: [Int]] = [:]
        for stop in boardableStops {
            boardableByCell[cell(for: stops[stop].model.coordinate), default: []].append(stop)
        }

        return stops.indices.map { source in
            guard alightableStops.contains(source) else { return [] }
            let sourceCoordinate = stops[source].model.coordinate
            let sourceCell = cell(for: sourceCoordinate)
            var candidates: [Int] = []
            for latitudeOffset in -3...3 {
                for longitudeOffset in -3...3 {
                    candidates += boardableByCell[.init(
                        latitude: sourceCell.latitude + latitudeOffset,
                        longitude: sourceCell.longitude + longitudeOffset
                    )] ?? []
                }
            }
            let nearby: [(stop: Int, distance: Double)] = candidates.compactMap { target in
                guard target != source else { return nil }
                let meters = distance(sourceCoordinate, stops[target].model.coordinate)
                guard meters <= expandedDistanceMeters else { return nil }
                return (target, meters)
            }
            let ordered = nearby.sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                return a.stop < b.stop
            }
            let near = ordered.filter { $0.distance <= nearDistanceMeters }
            var selected: [Int] = []
            var seenGroups: Set<Int> = []
            for candidate in near {
                if seenGroups.insert(stationGroupByStop[candidate.stop]).inserted {
                    selected.append(candidate.stop)
                }
                if selected.count == 8 { break }
            }
            let selectedSet = Set(selected)
            for candidate in near where selected.count < 8 && !selectedSet.contains(candidate.stop) {
                selected.append(candidate.stop)
            }
            // Expand only when the nearby set offers few distinct onward
            // station groups. The actual pedestrian route still has to fit
            // the walking-time budget before it becomes a transfer.
            if seenGroups.count < 3 {
                for candidate in ordered where candidate.distance > nearDistanceMeters {
                    guard seenGroups.insert(stationGroupByStop[candidate.stop]).inserted else { continue }
                    selected.append(candidate.stop)
                    if selected.count == candidateLimit { break }
                }
            }
            return selected
        }
    }
}

// MARK: - Session / RAPTOR

public actor TransitRouter {
    let snapshot: RoutingSnapshot; private let walking: WalkingRouteCache?; let clock: @Sendable () -> Date; private let realtime: (any RealtimeRoutingProvider)?
    public init(databaseURL: URL, walkingProvider: (any WalkingRoutingProvider)? = nil, realtimeProvider: (any RealtimeRoutingProvider)? = nil, clock: @escaping @Sendable () -> Date = { .now }) async throws { self.clock = clock; self.snapshot = try await Task.detached(priority: .utility) { try SnapshotBuilder.load(databaseURL: databaseURL) }.value; self.walking = walkingProvider.map { WalkingRouteCache(provider: $0) }; self.realtime = realtimeProvider }
    public func makeSession(for query: RouteQuery) throws -> JourneyPlanningSession { guard query.preferences.minimumTransferSeconds >= 0, query.preferences.boardingBufferSeconds >= 0, query.preferences.maximumWalkingSeconds.map({ $0 >= 0 }) ?? true, query.preferences.maxTransfers.map({ $0 >= 0 }) ?? true else { throw JourneyPlannerError.invalidPreferences }; return try JourneyPlanningSession(snapshot: snapshot, query: query, walking: walking, realtime: realtime, clock: clock) }
    /// Feeds a measured pedestrian route back into the cache before a bounded
    /// replan, so the search cannot repeat its original short estimate.
    public func correctWalkingRoute(_ route: WalkingRoute, for request: WalkingRequest) async {
        await walking?.correct(request, with: route)
    }

    func realtimePatches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch? {
        try await realtime?.patches(for: request)
    }
}

public actor JourneyPlanningSession {
    let snapshot: RoutingSnapshot; let query: RouteQuery; let clock: @Sendable () -> Date; private let walking: WalkingRouteCache?; let realtimeProvider: (any RealtimeRoutingProvider)?
    private var all: [Journey] = []; private var visibleStart = 0; private var visibleEnd = 0; private var revision: UInt64 = 0; var state: PageRealtimeState; var metrics = RoutingMetrics(); var diagnostics = RoutingDiagnostics()
    private var directWalking: Journey?
    private var cachedEndpointEdges: (access: [Edge], egress: [Edge])?
    var cachedRealtimeBatch: RealtimePatchBatch?
    var frozenPatches: [RealtimeTripPatch]?
    var latestPatchesByInstance: [RealtimePatchKey: RealtimeTripPatch] = [:]
    var latestRawPatchesByInstance: [RealtimePatchKey: RealtimeTripPatch] = [:]
    fileprivate struct BuiltJourney {
        let journey: Journey
        let firstBoard: Date
        let tripInstanceKey: String
        let equivalentTransferKey: String
        let minimumTransferSlack: Int
        let totalTransferSlack: Int
    }
    fileprivate init(snapshot: RoutingSnapshot, query: RouteQuery, walking: WalkingRouteCache?, realtime: (any RealtimeRoutingProvider)?, clock: @escaping @Sendable () -> Date) throws { self.clock = clock; self.snapshot = snapshot; self.query = query; self.walking = walking; self.realtimeProvider = realtime; self.state = query.realtimePolicy == .disabled ? .disabled : .unavailable; self.metrics.snapshotLoadMilliseconds = snapshot.loadMilliseconds }
    func setFrozenPatches(_ patches: [RealtimeTripPatch]) { frozenPatches = patches }
    func currentPatches() -> [RealtimeTripPatch] { Array(latestPatchesByInstance.values) }
    public func initial(count: Int = 5) async throws -> JourneyPage { if all.isEmpty { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0 }; visibleEnd = min(all.count, max(0, count)); return page() }
    public func initial(count: Int = 5, searchHorizon: TimeInterval) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: max(0, searchHorizon)); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func expanded(count: Int = 5) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func later(count: Int = 3) async throws -> JourneyPage {
        if all.isEmpty {
            all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon)
            visibleStart = 0; visibleEnd = min(all.count, 5)
        }
        visibleEnd = min(all.count, visibleEnd + max(0, count))
        return page()
    }
    public func earlier(count: Int = 3) async throws -> JourneyPage { visibleStart = max(0, visibleStart - max(0, count)); return page() }
    public func refreshRealtime() async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon, forceRealtime: true); visibleStart = 0; visibleEnd = min(max(visibleEnd, 5), all.count); revision &+= 1; return page() }
    /// Returns adjacent transit alternatives after applying the boundary to the
    /// complete evaluated profile. A walking comparison is shown only initially.
    public func boundedPage(before: Date? = nil, beforeID: JourneySignature? = nil,
                            after: Date? = nil, afterID: JourneySignature? = nil,
                            count: Int = 5, excludingIDs: Set<JourneySignature> = []) async throws -> JourneyPage {
        if all.isEmpty { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon) }
        let eligible = all.filter { journey in
            (before.map { boundary in
                journey.effectiveDeparture < boundary ||
                    (journey.effectiveDeparture == boundary && beforeID.map { journey.id < $0 } == true)
            } ?? true)
                && (after.map { boundary in
                    journey.effectiveDeparture > boundary ||
                        (journey.effectiveDeparture == boundary && afterID.map { journey.id > $0 } == true)
                } ?? true)
        }
        let cursorOrdered = eligible.sorted { ($0.effectiveDeparture, $0.id) < ($1.effectiveDeparture, $1.id) }
        let unseen = cursorOrdered.filter { !excludingIDs.contains($0.id) }
        let selected = before == nil ? Array(unseen.prefix(max(0, count))) : Array(unseen.suffix(max(0, count)))
        var result = makePage(journeys: selected, includeWalking: before == nil && after == nil,
                        hasEarlier: before != nil && unseen.count > selected.count,
                        hasLater: after != nil && unseen.count > selected.count)
        result.exploredBefore = selected.first.map { .init(departure: $0.effectiveDeparture, id: $0.id) }
        result.exploredAfter = selected.last.map { .init(departure: $0.effectiveDeparture, id: $0.id) }
        return result
    }
    private func page() -> JourneyPage {
        let shown = visibleStart == 0
            ? primaryProfile(count: visibleEnd)
            : Array(all[visibleStart..<visibleEnd])
        var result = makePage(journeys: shown, includeWalking: visibleStart == 0,
                 hasEarlier: visibleStart > 0, hasLater: visibleEnd < all.count)
        // Selection can be noncontiguous. Advance only through its consumed
        // chronological prefix, so paging can backfill every unseen choice.
        let selectedIDs = Set(shown.map(\.id))
        let cursorOrdered = all.sorted { ($0.effectiveDeparture, $0.id) < ($1.effectiveDeparture, $1.id) }
        let prefix = cursorOrdered.prefix { selectedIDs.contains($0.id) }
        result.exploredBefore = .init(departure: query.direction == .arriveBy ? (all.first?.effectiveDeparture ?? query.departureTime) : query.departureTime, id: nil)
        result.exploredAfter = prefix.last.map { .init(departure: $0.effectiveDeparture, id: $0.id) }
            ?? cursorOrdered.first.map { .init(departure: $0.effectiveDeparture.addingTimeInterval(-0.000001), id: nil) }
        return result
    }
    private func primaryProfile(count: Int) -> [Journey] {
        JourneyQualityPolicy.primarySuggestions(all, count: count, query: query)
    }

    private func makePage(journeys: [Journey], includeWalking: Bool, hasEarlier: Bool, hasLater: Bool) -> JourneyPage {
        let choices = journeys + (includeWalking ? directWalking.map { [$0] } ?? [] : [])
        let recommendation = JourneyQualityPolicy.recommendation(choices, query: query)
        let result = JourneyPage(journeys: choices,
                     recommendedJourneyID: recommendation?.id, hasEarlier: hasEarlier,
                     hasLater: hasLater, realtimeState: state, revision: revision, metrics: metrics, diagnostics: diagnostics)
        // A subsequent cached page has its own operation, with no historical
        // scan or acquisition costs. Cumulative RoutingMetrics remain intact.
        diagnostics = RoutingDiagnostics()
        return result
    }
    private func generate(anchor: Date, searchHorizon: TimeInterval, forceRealtime: Bool = false,
                          accepting: (@Sendable (Journey) -> Bool)? = nil) async throws -> [Journey] {
        let started = ContinuousClock.now
        diagnostics = RoutingDiagnostics()
        let countersBefore = metrics
        let boardFetchBefore = metrics.realtimeBoardFetchMilliseconds
        let scheduleBefore = metrics.realtimeScheduledPreparationMilliseconds
        let matchingBefore = metrics.realtimeBoardMatchingMilliseconds
        let walkingStatisticsBefore = await walking?.statistics()
        let edges: (access: [Edge], egress: [Edge])
        if let cachedEndpointEdges {
            edges = cachedEndpointEdges
        } else {
            let endpointStarted = ContinuousClock.now
            async let access = Self.endpointEdges(snapshot: snapshot, walking: walking, endpoint: query.origin, anchor: anchor, purpose: .access)
            async let egress = Self.endpointEdges(snapshot: snapshot, walking: walking, endpoint: query.destination, anchor: anchor, purpose: .egress)
            edges = try await (access, egress)
            metrics.endpointPreparationMilliseconds += Int(RoutingDiagnostics.elapsed(since: endpointStarted))
            diagnostics.record(.endpoints, since: endpointStarted)
            cachedEndpointEdges = edges
        }
        let access = edges.access; let egress = edges.egress
        metrics.endpointAccessCandidates = access.count
        metrics.endpointEgressCandidates = egress.count
        let realtimeBudget: Int
        let maximumCompletionWaves: Int
        let searchWorkBudget: Int?
        if case let .bestEffort(configuration, _) = query.realtimePolicy {
            realtimeBudget = configuration.acquisitionBudgetMilliseconds
            searchWorkBudget = configuration.searchWorkBudgetMilliseconds
            maximumCompletionWaves = min(2, max(1, configuration.maximumRefinementWaves))
        } else {
            realtimeBudget = 0
            searchWorkBudget = nil
            maximumCompletionWaves = 0
        }
        let refreshing = forceRealtime || {
            if case let .bestEffort(_, refresh) = query.realtimePolicy { return refresh == .forceRefresh }
            return false
        }()
        let acquiring = realtimeProvider != nil && query.realtimePolicy != .disabled
        let seeds = refreshing || !acquiring ? [] : (frozenPatches ?? Array(latestRawPatchesByInstance.values))
            .map { $0.retainingFreshObservations(at: clock()) }
        // Coverage bookkeeping belongs to this calculation. Fresh observations
        // survive in seeds and the shared client cache handles board reuse.
        cachedRealtimeBatch = nil
        latestRawPatchesByInstance = Dictionary(seeds.map {
            (RealtimePatchKey(tripID: $0.tripID, serviceDate: $0.serviceDate), $0)
        }, uniquingKeysWith: { old, new in old.merging(new) })
        latestPatchesByInstance = latestRawPatchesByInstance.mapValues {
            RealtimeTimeline.resolved($0, snapshot: snapshot, now: clock())
        }
        var remainingRealtimeMilliseconds = acquiring ? max(0, realtimeBudget) : 0
        var discovered = false
        async let directJourney = Self.directWalk(snapshot: snapshot, query: query, walking: walking, anchor: anchor)
        var attempted: Set<ItineraryBoarding> = []
        var refinementWaves = 0
        // The optimistic frontier needs only endpoint edges and the timetable.
        // Acquire its observations before the first full profile, so routing
        // does not spend a complete scan discovering schedule-only winners.
        if remainingRealtimeMilliseconds > 0, searchWorkBudget != 0 {
            let acquisitionStarted = ContinuousClock.now
            _ = try await completeItineraryRealtime([], access: access, egress: egress,
                anchor: anchor, searchHorizon: searchHorizon, force: forceRealtime,
                budgetMilliseconds: remainingRealtimeMilliseconds, includeDiscovery: true, attempted: &attempted)
            let elapsed = RoutingDiagnostics.elapsed(since: acquisitionStarted)
            remainingRealtimeMilliseconds = max(0, remainingRealtimeMilliseconds - Int(elapsed.rounded(.up)))
            metrics.realtimePreparationMilliseconds += Int(elapsed)
            diagnostics.record(.realtime, since: acquisitionStarted)
            discovered = true
        }
        var cpuMilliseconds = 0
        var walkingPairs = 0
        var searchResult: Raptor.SearchResult
        var built: (journeys: [Journey], validCandidates: Int, representativeCount: Int)
        let rejectionsBefore = diagnostics.rejections
        while true {
            metrics.pointRaptorScans += 1
            let raptorStarted = ContinuousClock.now
            searchResult = try await Raptor.search(snapshot: snapshot, query: query, access: access, egress: egress,
                patches: Array(latestPatchesByInstance.values), walking: walking, profileHorizon: searchHorizon)
            diagnostics.record(.raptor, since: raptorStarted)
            cpuMilliseconds += searchResult.cpuMilliseconds
            walkingPairs += searchResult.walkingTransferPairs
            diagnostics.milliseconds[.walkingTransfers, default: 0] += Double(searchResult.walkingTransferMilliseconds)
            let candidateStarted = ContinuousClock.now
            diagnostics.rejections = rejectionsBefore
            built = buildJourneys(searchResult.candidates, access: access, egress: egress, accepting: accepting)
            diagnostics.record(.candidateBuilding, since: candidateStarted)
            // Both acquisition passes check selected vehicles. Delays can make
            // a previously unselected connection viable on the second scan;
            // spent CPU time must not suppress that vehicle's live board.
            // The shared acquisition deadline and wave limit bound this work.
            if searchWorkBudget == 0 { remainingRealtimeMilliseconds = 0 }
            guard remainingRealtimeMilliseconds > 0, refinementWaves < maximumCompletionWaves else { break }
            let completionStarted = ContinuousClock.now
            let changed = try await completeItineraryRealtime(
                JourneyQualityPolicy.primarySuggestions(built.journeys, count: 10, query: query),
                access: access, egress: egress, anchor: anchor,
                searchHorizon: searchHorizon, force: forceRealtime,
                budgetMilliseconds: remainingRealtimeMilliseconds, includeDiscovery: !discovered, attempted: &attempted)
            discovered = true
            let elapsed = RoutingDiagnostics.elapsed(since: completionStarted)
            remainingRealtimeMilliseconds = max(0, remainingRealtimeMilliseconds - Int(elapsed.rounded(.up)))
            metrics.realtimePreparationMilliseconds += Int(elapsed)
            diagnostics.record(.realtime, since: completionStarted)
            refinementWaves += 1
            // Re-run feasibility and ranking with the new overlay, including
            // cancellations and delays on connecting vehicles.
            if !changed { break }
        }
        let journeys = built.journeys
        metrics.raptorSearchMilliseconds = Int(diagnostics.milliseconds[.raptor, default: 0])
        metrics.raptorCPUMilliseconds = cpuMilliseconds
        metrics.walkingTransferMilliseconds = Int(diagnostics.milliseconds[.walkingTransfers, default: 0])
        metrics.walkingTransferPairs = walkingPairs
        metrics.raptorWorkerCount = searchResult.maximumWorkerCount
        metrics.searchRounds = searchResult.roundMetrics
        metrics.scannedPatterns = searchResult.scannedPatterns
        metrics.scannedTripInstances = searchResult.scannedTripInstances
        metrics.candidatesGenerated = searchResult.candidates.count
        metrics.alternativesRetained = journeys.count
        metrics.candidateBuildingMilliseconds = Int(diagnostics.milliseconds[.candidateBuilding, default: 0])
        metrics.realtimePredictedEvents = latestPatchesByInstance.values.flatMap(\.events).filter {
            $0.departureSource == .reported || $0.arrivalSource == .reported
        }.count
        metrics.delayedPastBoardingsInjected = countersBefore.delayedPastBoardingsInjected
            + latestPatchesByInstance.values.flatMap(\.events).filter {
                ($0.scheduledDeparture ?? .distantFuture) < anchor && ($0.effectiveDeparture ?? .distantPast) >= anchor
            }.count
        diagnostics.milliseconds[.http] = Double(metrics.realtimeHTTPMilliseconds - countersBefore.realtimeHTTPMilliseconds)
        diagnostics.milliseconds[.decode] = Double(metrics.realtimeDecodeMilliseconds - countersBefore.realtimeDecodeMilliseconds)
        diagnostics.milliseconds[.boardFetch] = Double(metrics.realtimeBoardFetchMilliseconds - boardFetchBefore)
        diagnostics.milliseconds[.schedulePreparation] = Double(metrics.realtimeScheduledPreparationMilliseconds - scheduleBefore)
        diagnostics.milliseconds[.boardMatching] = Double(metrics.realtimeBoardMatchingMilliseconds - matchingBefore)
        let directWaitStarted = ContinuousClock.now
        let direct = await directJourney
        diagnostics.record(.directWalkingWait, since: directWaitStarted)
        if let before = walkingStatisticsBefore, let after = await walking?.statistics() {
            metrics.walkingRequests += after.requests - before.requests
            metrics.walkingCacheHits += after.hits - before.hits
        }
        diagnostics.counters = [.networkRequests: metrics.hafasRequests - countersBefore.hafasRequests,
            .boardCacheHits: metrics.hafasCacheHits - countersBefore.hafasCacheHits,
            .responseBytes: metrics.realtimeResponseBytes - countersBefore.realtimeResponseBytes,
            .predictedEvents: metrics.realtimePredictedEvents,
            .delayedPastBoardings: metrics.delayedPastBoardingsInjected - countersBefore.delayedPastBoardingsInjected,
            .walkingRequests: metrics.walkingRequests - countersBefore.walkingRequests,
            .walkingCacheHits: metrics.walkingCacheHits - countersBefore.walkingCacheHits,
            .boardsCovered: metrics.realtimeBoardsCovered, .incompleteBoards: metrics.realtimeIncompleteBoards,
            .workers: metrics.raptorWorkerCount, .candidates: metrics.candidatesGenerated,
            .retainedAlternatives: metrics.alternativesRetained,
            .invalidJourneys: diagnostics.rejections.values.reduce(0, +),
            .duplicatesSuppressed: built.validCandidates - built.representativeCount]
        diagnostics.rounds = searchResult.roundMetrics
        directWalking = direct
        metrics.profileGenerationMilliseconds = Int(RoutingDiagnostics.elapsed(since: started))
        diagnostics.totalMilliseconds = RoutingDiagnostics.elapsed(since: started)
        return journeys
    }

    private func buildJourneys(_ candidates: [Raptor.Candidate], access: [Edge], egress: [Edge],
                               accepting: (@Sendable (Journey) -> Bool)?)
        -> (journeys: [Journey], validCandidates: Int, representativeCount: Int) {
        var representatives: [String: BuiltJourney] = [:]
        var validCandidates = 0
        for candidate in candidates {
            guard let journey = buildJourney(candidate, access: access, egress: egress) else { continue }
            // Page bounds must apply before representatives and dominance: an
            // itinerary outside an arrival window cannot suppress one inside it.
            if let accepting, !accepting(journey.journey) { continue }
            validCandidates += 1
            if let existing = representatives[journey.tripInstanceKey] {
                if prefers(journey, over: existing) { representatives[journey.tripInstanceKey] = journey }
            } else {
                representatives[journey.tripInstanceKey] = journey
            }
        }
        var transferRepresentatives: [BuiltJourney] = []
        var indicesByVehicle: [String: [Int]] = [:]
        for journey in representatives.values.sorted(by: journeyOrder) {
            if let index = indicesByVehicle[journey.equivalentTransferKey]?.first(where: {
                sameVehicleChoice(transferRepresentatives[$0], journey)
            }) {
                if prefersSaferTransfer(journey, over: transferRepresentatives[index]) {
                    transferRepresentatives[index] = journey
                }
            } else {
                indicesByVehicle[journey.equivalentTransferKey, default: []].append(transferRepresentatives.count)
                transferRepresentatives.append(journey)
            }
        }
        let journeys = strictEnvelope(transferRepresentatives, preferences: query.preferences).sorted(by: journeyOrder)
            .map { addingIntermediateStops(to: $0.journey) }
        return (journeys, validCandidates, transferRepresentatives.count)
    }

    /// Uses the same generation and suggestion policy as an initial search,
    /// restricted to one adjacent door-to-door time window.
    func adjacentTimePage(axis: JourneyTimeAxis, boundary: JourneyPageBoundary,
                          earlier: Bool, count: Int, excludingIDs: Set<JourneySignature>,
                          searchHorizon: TimeInterval) async throws -> JourneyPage {
        let profile = try await generate(anchor: query.departureTime, searchHorizon: searchHorizon) { journey in
            guard !excludingIDs.contains(journey.id) else { return false }
            let time = axis == .arrival ? journey.effectiveArrival : journey.effectiveDeparture
            let edge = boundary.departure
            if time != edge { return earlier ? time < edge : time > edge }
            guard let id = boundary.id else { return false }
            return earlier ? journey.id < id : journey.id > id
        }
        let selected: [Journey]
        if axis == .departure && !earlier {
            selected = JourneyQualityPolicy.primarySuggestions(profile, count: count, query: query)
        } else {
            let useful = JourneyQualityPolicy.primarySuggestions(profile, count: profile.count, query: query)
            let ordered = useful.sorted {
                let a = axis == .arrival ? $0.effectiveArrival : $0.effectiveDeparture
                let b = axis == .arrival ? $1.effectiveArrival : $1.effectiveDeparture
                return (a, $0.id) < (b, $1.id)
            }
            selected = earlier ? Array(ordered.suffix(count)) : Array(ordered.prefix(count))
        }
        return makePage(journeys: selected, includeWalking: false,
                        hasEarlier: true, hasLater: true)
    }
    struct Edge: Sendable { let stop: Int; let seconds: Int; let distance: Double; let walk: WalkingRoute? }
    private enum EndpointEdgePurpose: Equatable { case access, egress }
    private static let endpointCandidateLimit = 40
    private static let initialEndpointCandidateLimit = 24

    private nonisolated static func endpointEdges(
        snapshot: RoutingSnapshot,
        walking: WalkingRouteCache?,
        endpoint: JourneyEndpoint,
        anchor: Date,
        purpose: EndpointEdgePurpose
    ) async throws -> [Edge] {
        let endpointStop: Int?
        let coordinate: Coordinate
        switch endpoint {
        case let .stop(id):
            guard let stop = snapshot.stopByID[id] else { throw JourneyPlannerError.endpointNotFound }
            // Preserve the selected platform as a zero-walk option while also
            // allowing a faster service from another reachable stop. This is
            // useful even when the rider selected a stop rather than an address.
            guard walking != nil else {
                return [.init(stop: stop, seconds: 0, distance: 0, walk: nil)]
            }
            endpointStop = stop
            coordinate = snapshot.stops[stop].model.coordinate
        case let .coordinate(value, _):
            guard walking != nil else { throw JourneyPlannerError.endpointNotFound }
            endpointStop = nil
            coordinate = value
        }
        guard let walking else { throw JourneyPlannerError.endpointNotFound }
        let eligibleStops = switch purpose {
        case .access: snapshot.boardableStops
        case .egress: snapshot.alightableStops
        }
        let activeServices = Set(snapshot.serviceDays.filter {
            abs($0.start.timeIntervalSince(anchor)) <= 2 * 86_400
        }.flatMap(\.activeServices))
        let candidates = snapshot.stops.enumerated().compactMap { index, stop -> (index: Int, stop: SnapshotStop, distance: Double, routes: Set<Int>)? in
            guard eligibleStops.contains(index), index != endpointStop else { return nil }
            let direct = distance(coordinate, stop.model.coordinate)
            guard direct <= 3_000 else { return nil }
            let routes = Set(snapshot.serviceRoutesByStop[index].lazy
                .filter { activeServices.contains($0.service) }
                .map(\.route))
            return (index: index, stop: stop, distance: direct, routes: routes)
        }.sorted {
            if $0.routes.isEmpty != $1.routes.isEmpty { return !$0.routes.isEmpty }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.index < $1.index
        }
        var edges: [Edge] = endpointStop.map { [.init(stop: $0, seconds: 0, distance: 0, walk: nil)] } ?? []
        // Choose one platform per station/service pattern first, then fill the
        // remaining slots by distance. This keeps redundant platform clusters
        // from hiding a useful slightly farther service.
        var candidateList: [(index: Int, stop: SnapshotStop, distance: Double, routes: Set<Int>)] = []
        var seenGroups: Set<String> = []
        for candidate in candidates {
            let group = snapshot.stationGroupByStop[candidate.index]
            let key = "\(group):\(candidate.routes.sorted().map(String.init).joined(separator: ","))"
            if seenGroups.insert(key).inserted { candidateList.append(candidate) }
            if candidateList.count == Self.endpointCandidateLimit { break }
        }
        let selected = Set(candidateList.map(\.index))
        for candidate in candidates where candidateList.count < Self.endpointCandidateLimit && !selected.contains(candidate.index) {
            candidateList.append(candidate)
        }
        // Measure a diverse first stage and use the remaining shortlist only
        // when too few physically reachable stops survived its walking budget.
        let stages = [Array(candidateList.prefix(Self.initialEndpointCandidateLimit)),
                      Array(candidateList.dropFirst(Self.initialEndpointCandidateLimit))]
        for (stageIndex, stage) in stages.enumerated() {
            if stageIndex > 0 && edges.count >= 8 { break }
            let requests = stage.map { candidate in
                switch purpose {
                case .access:
                    WalkingRequest(source: coordinate, destination: candidate.stop.model.coordinate, departure: anchor)
                case .egress:
                    WalkingRequest(source: candidate.stop.model.coordinate, destination: coordinate, departure: anchor)
                }
            }
            let routes = await walking.routes(requests, maximumConcurrency: 4)
            for (candidate, route) in zip(stage, routes) {
                if let route, route.evidence == .routedPedestrian, route.durationSeconds > 0, route.distanceMeters.isFinite, route.distanceMeters >= 0, route.durationSeconds <= 30 * 60, route.distanceMeters <= 3_000 {
                    edges.append(.init(stop: candidate.index, seconds: route.durationSeconds, distance: route.distanceMeters, walk: route))
                }
            }
        }
        return edges
    }
    private nonisolated static func directWalk(snapshot: RoutingSnapshot, query: RouteQuery, walking: WalkingRouteCache?, anchor: Date) async -> Journey? {
        func place(_ endpoint: JourneyEndpoint) -> JourneyLocation? {
            switch endpoint {
            case let .coordinate(coordinate, label): return .init(coordinate: coordinate, label: label)
            case let .stop(id):
                guard let index = snapshot.stopByID[id] else { return nil }
                let stop = snapshot.stops[index].model
                return .init(stop: stop, coordinate: stop.coordinate, label: stop.name)
            }
        }
        guard query.preferences.wheelchair != .required,
              let origin = place(query.origin), let destination = place(query.destination) else { return nil }
        let a = origin.coordinate; let b = destination.coordinate
        guard
              distance(a, b) <= 3_050,
              let walking, let route = try? await walking.route(.init(source: a, destination: b, departure: anchor)),
              route.durationSeconds > 0, route.durationSeconds <= 45 * 60, route.evidence == .routedPedestrian,
              query.preferences.maximumWalkingSeconds.map({ route.durationSeconds <= $0 }) ?? true,
              route.distanceMeters.isFinite, route.distanceMeters >= 0, route.distanceMeters <= 3_000 else { return nil }
        let departure = query.direction == .arriveBy
            ? anchor.addingTimeInterval(-TimeInterval(route.durationSeconds)) : anchor
        let arrival = departure.addingTimeInterval(TimeInterval(route.durationSeconds))
        let leg = WalkingLeg(from: origin, to: destination, departure: departure, arrival: arrival, duration: TimeInterval(route.durationSeconds), distanceMeters: route.distanceMeters, polyline: route.polyline, steps: route.steps, source: .provider, evidence: route.evidence)
        return .init(id: .init("walk:\(a.latitude),\(a.longitude):\(b.latitude),\(b.longitude)"), origin: query.origin, destination: query.destination, scheduledDeparture: departure, scheduledArrival: arrival, effectiveDeparture: departure, effectiveArrival: arrival, transferCount: 0, walkingDuration: TimeInterval(route.durationSeconds), walkingDistance: route.distanceMeters, waitingDuration: 0, inVehicleDuration: 0, legs: [.walk(leg)], feedGeneration: snapshot.info.generation, accessibility: .unknown, matchesPreferredMode: query.preferences.preferredMode == nil)
    }
    private func buildJourney(_ candidate: Raptor.Candidate, access: [Edge], egress: [Edge]) -> BuiltJourney? {
        if let failure = JourneyStructuralValidator.assess(candidate, snapshot: snapshot, query: query) {
            diagnostics.rejections[failure, default: 0] += 1; return nil
        }
        guard let a = access.first(where: { $0.stop == candidate.firstStop }), let e = egress.first(where: { $0.stop == candidate.lastStop }), let firstTransit = candidate.firstTransit, let lastTransit = candidate.lastTransit else { return nil }
        let depart = candidate.firstDeparture.addingTimeInterval(-TimeInterval(a.seconds)); let arrive = candidate.lastArrival.addingTimeInterval(TimeInterval(e.seconds))
        if query.direction == .departAfter && depart < query.departureTime { return nil }
        if query.direction == .arriveBy && arrive > query.departureTime { return nil }
        let accessibility = assessAccessibility(candidate, access: a, egress: e)
        if query.preferences.wheelchair == .required && accessibility != .verified { return nil }
        let scheduledDepart = firstTransit.scheduledBoard.addingTimeInterval(-TimeInterval(a.seconds))
        let scheduledArrive = lastTransit.scheduledAlight.addingTimeInterval(candidate.lastArrival.timeIntervalSince(lastTransit.alightTime) + TimeInterval(e.seconds))
        var legs: [JourneyLeg] = []
        if let walk = a.walk {
            let from = endpointLocation(query.origin)
            let to = JourneyLocation(stop: snapshot.stops[candidate.firstStop].model, coordinate: snapshot.stops[candidate.firstStop].model.coordinate, label: snapshot.stops[candidate.firstStop].model.name)
            legs.append(.walk(.init(from: from, to: to, departure: depart, arrival: candidate.firstDeparture, duration: TimeInterval(walk.durationSeconds), distanceMeters: walk.distanceMeters, polyline: walk.polyline, steps: walk.steps, source: .provider, evidence: walk.evidence)))
        }
        for item in candidate.legs {
            switch item {
            case let .transit(item):
                let trip = snapshot.trips[item.trip]
                let board = snapshot.stops[item.board].model
                let alight = snapshot.stops[item.alight].model
                let patch = latestPatchesByInstance[
                    RealtimePatchKey(tripID: trip.id, serviceDate: item.day)
                ]
                let status = patch?.status ?? .active
                let boardPatch = patch?.event(stopID: board.id, sequence: trip.times[item.boardPos].sequence)
                let alightPatch = patch?.event(stopID: alight.id, sequence: trip.times[item.alightPos].sequence)
                let b = JourneyStopEvent(
                    stop: board,
                    scheduledTime: item.scheduledBoard,
                    effectiveTime: item.boardTime,
                    timingSource: boardPatch?.departureSource ?? .scheduled,
                    platform: boardPatch?.platform ?? board.platformCode
                )
                let x = JourneyStopEvent(
                    stop: alight,
                    scheduledTime: item.scheduledAlight,
                    effectiveTime: item.alightTime,
                    timingSource: alightPatch?.arrivalSource ?? .scheduled,
                    platform: alightPatch?.platform ?? alight.platformCode
                )
                if item.continuesFromPrevious, let previous = legs.last, case let .transit(incoming) = previous {
                    legs.append(.inSeatContinuation(.init(fromTripID: incoming.tripID, toTripID: trip.id)))
                }
                legs.append(.transit(.init(tripID: trip.id, route: snapshot.routes[trip.route], headsign: trip.times[item.boardPos].headsign ?? trip.headsign, board: b, alight: x, intermediateStops: [], scheduledDeparture: item.scheduledBoard, scheduledArrival: item.scheduledAlight, effectiveDeparture: item.boardTime, effectiveArrival: item.alightTime, status: status, requiredTransferSecondsAfterWalking: item.requiredTransferSecondsAfterWalking)))
                if case var .transit(ride) = legs[legs.count - 1] {
                    ride.instance = .init(feedGeneration: snapshot.info.generation, tripID: trip.id, serviceDate: item.day)
                    ride.boardingDeadline = item.continuesFromPrevious ? nil : item.boardingDeadline
                    ride.boardSequence = trip.times[item.boardPos].sequence
                    ride.alightSequence = trip.times[item.alightPos].sequence
                    if !item.continuesFromPrevious, let previous = candidate.transitLegs.last(where: { $0.boardTime < item.boardTime }) {
                        ride.requiredTotalTransferSeconds = Raptor.transferDecision(snapshot: snapshot, incoming: previous, at: item.board, outgoing: item.trip, preferences: query.preferences)?.requiredSeconds
                    }
                    legs[legs.count - 1] = .transit(ride)
                }
            case let .pathway(item):
                let fromStop = snapshot.stops[item.from].model
                let toStop = snapshot.stops[item.to].model
                legs.append(.walk(.init(from: .init(stop: fromStop, coordinate: fromStop.coordinate, label: fromStop.name), to: .init(stop: toStop, coordinate: toStop.coordinate, label: toStop.name), departure: item.departure, arrival: item.arrival, duration: TimeInterval(item.seconds), distanceMeters: item.distance, polyline: [fromStop.coordinate, toStop.coordinate], steps: [], source: .pathway, evidence: .routedPedestrian)))
            case let .walkingTransfer(item):
                let fromStop = snapshot.stops[item.from].model
                let toStop = snapshot.stops[item.to].model
                legs.append(.walk(.init(
                    from: .init(stop: fromStop, coordinate: fromStop.coordinate, label: fromStop.name),
                    to: .init(stop: toStop, coordinate: toStop.coordinate, label: toStop.name),
                    departure: item.departure,
                    arrival: item.arrival,
                    duration: TimeInterval(item.route.durationSeconds),
                    distanceMeters: item.route.distanceMeters,
                    polyline: item.route.polyline,
                    steps: item.route.steps,
                    source: .provider,
                    evidence: item.route.evidence
                )))
            }
        }
        if let walk = e.walk {
            let from = JourneyLocation(stop: snapshot.stops[candidate.lastStop].model, coordinate: snapshot.stops[candidate.lastStop].model.coordinate, label: snapshot.stops[candidate.lastStop].model.name)
            let to = endpointLocation(query.destination)
            let departure = candidate.lastArrival
            legs.append(.walk(.init(from: from, to: to, departure: departure, arrival: departure.addingTimeInterval(TimeInterval(walk.durationSeconds)), duration: TimeInterval(walk.durationSeconds), distanceMeters: walk.distanceMeters, polyline: walk.polyline, steps: walk.steps, source: .provider, evidence: walk.evidence)))
        }
        let signature = "g\(snapshot.info.generation):" + candidate.tripInstanceKey(snapshot: snapshot)
        let inVehicle = candidate.transitLegs.reduce(0) { $0 + $1.alightTime.timeIntervalSince($1.boardTime) }
        let walkingDuration = TimeInterval(a.seconds + e.seconds + candidate.pathwaySeconds)
        let waiting = max(0, arrive.timeIntervalSince(depart) - inVehicle - walkingDuration)
        let matchesPreferredMode = query.preferences.preferredMode.map { preferred in
            candidate.transitLegs.contains { preferred.contains(routeType: snapshot.routes[snapshot.trips[$0.trip].route].type) }
        } ?? true
        let journey = Journey(id: .init(signature), origin: query.origin, destination: query.destination, scheduledDeparture: scheduledDepart, scheduledArrival: scheduledArrive, effectiveDeparture: depart, effectiveArrival: arrive, transferCount: max(0, candidate.transitLegs.filter { !$0.continuesFromPrevious }.count - 1), walkingDuration: walkingDuration, walkingDistance: a.distance + e.distance + candidate.pathwayDistance, waitingDuration: waiting, inVehicleDuration: inVehicle, legs: legs, feedGeneration: snapshot.info.generation, accessibility: accessibility, matchesPreferredMode: matchesPreferredMode)
        if case let .invalid(failure) = JourneyPublicationValidator.assess(journey, query: query) {
            diagnostics.rejections[failure, default: 0] += 1; return nil
        }
        return .init(journey: journey, firstBoard: candidate.firstDeparture, tripInstanceKey: signature, equivalentTransferKey: candidate.equivalentTransferKey(snapshot: snapshot), minimumTransferSlack: candidate.minimumTransferSlack, totalTransferSlack: candidate.totalTransferSlack)
    }
    private func endpointLocation(_ endpoint: JourneyEndpoint) -> JourneyLocation {
        switch endpoint {
        case let .coordinate(coordinate, label):
            return .init(coordinate: coordinate, label: label)
        case let .stop(id):
            let stop = snapshot.stops[snapshot.stopByID[id]!].model
            return .init(stop: stop, coordinate: stop.coordinate, label: stop.name)
        }
    }

    private func assessAccessibility(_ candidate: Raptor.Candidate, access: Edge, egress: Edge) -> AccessibilityAssessment {
        var evidence: AccessibilityAssessment = access.walk == nil && egress.walk == nil ? .verified : .unknown
        func combine(_ next: AccessibilityAssessment) {
            if next == .inaccessible { evidence = .inaccessible }
            else if next == .unknown && evidence == .verified { evidence = .unknown }
        }
        func stopEvidence(_ index: Int) -> AccessibilityAssessment {
            let stop = snapshot.stops[index]
            let code = stop.model.wheelchairBoarding == 0
                ? stop.parent.flatMap { snapshot.stopByID[$0] }.map { snapshot.stops[$0].model.wheelchairBoarding } ?? 0
                : stop.model.wheelchairBoarding
            return switch code { case 1: .verified; case 2: .inaccessible; default: .unknown }
        }
        for (index, leg) in candidate.legs.enumerated() {
            switch leg {
            case let .transit(ride):
                let vehicle = snapshot.trips[ride.trip].wheelchairAccessible
                combine(vehicle == 1 ? .verified : vehicle == 2 ? .inaccessible : .unknown)
                if !ride.continuesFromPrevious { combine(stopEvidence(ride.board)) }
                let continuesNext = index + 1 < candidate.legs.count && {
                    if case let .transit(next) = candidate.legs[index + 1] { return next.continuesFromPrevious }
                    return false
                }()
                if !continuesNext { combine(stopEvidence(ride.alight)) }
            case let .pathway(path):
                let structurallyBlocked = path.mode == 2 || path.mode == 4
                    || path.stairCount.map { $0 != 0 } == true
                    || path.maxSlope.map { abs($0) > 1.0 / 12.0 } == true
                    || path.minWidth.map { $0 < 0.9 } == true
                if structurallyBlocked {
                    combine(.inaccessible)
                } else if path.mode == 5
                    || (path.mode == 1 && path.stairCount == 0
                        && path.maxSlope != nil && path.minWidth != nil) {
                    // Static pathway evidence describes the built connection;
                    // it cannot certify an elevator's current operating state.
                    combine(.verified)
                } else {
                    combine(.unknown)
                }
            case .walkingTransfer:
                combine(.unknown)
            }
        }
        return evidence
    }

    private func prefers(_ lhs: BuiltJourney, over rhs: BuiltJourney) -> Bool {
        JourneyQualityPolicy.ranksBefore(lhs.journey, rhs.journey, anchor: query.departureTime,
                                         direction: query.direction, preferences: query.preferences)
    }

    private func sameVehicleChoice(_ lhs: BuiltJourney, _ rhs: BuiltJourney) -> Bool {
        lhs.equivalentTransferKey == rhs.equivalentTransferKey
            && lhs.journey.effectiveDeparture == rhs.journey.effectiveDeparture
            && lhs.journey.effectiveArrival == rhs.journey.effectiveArrival
            && lhs.journey.accessibility == rhs.journey.accessibility
            && lhs.journey.matchesPreferredMode == rhs.journey.matchesPreferredMode
            && abs(lhs.journey.walkingDuration - rhs.journey.walkingDuration) <= 120
            && abs(lhs.journey.walkingDistance - rhs.journey.walkingDistance) <= 200
    }

    private func prefersSaferTransfer(_ lhs: BuiltJourney, over rhs: BuiltJourney) -> Bool {
        // Extra transfer time is useful up to ten minutes. Beyond that, a
        // longer wait should not outweigh walking or journey time.
        let lhsValue = Double(min(lhs.minimumTransferSlack, 600)) - lhs.journey.walkingDuration
        let rhsValue = Double(min(rhs.minimumTransferSlack, 600)) - rhs.journey.walkingDuration
        if lhsValue != rhsValue { return lhsValue > rhsValue }
        return prefers(lhs, over: rhs)
    }
}


private func strictEnvelope(_ journeys: [JourneyPlanningSession.BuiltJourney], preferences: RoutingPreferences) -> [JourneyPlanningSession.BuiltJourney] {
    let retained = JourneyQualityPolicy.envelopeIDs(journeys.map(\.journey), preferences: preferences)
    return journeys.filter { retained.contains($0.journey.id) }
}

private func journeyOrder(_ a: JourneyPlanningSession.BuiltJourney, _ b: JourneyPlanningSession.BuiltJourney) -> Bool { (a.journey.effectiveDeparture, a.journey.effectiveArrival, a.journey.transferCount, a.journey.walkingDuration, a.journey.duration, a.tripInstanceKey) < (b.journey.effectiveDeparture, b.journey.effectiveArrival, b.journey.transferCount, b.journey.walkingDuration, b.journey.duration, b.tripInstanceKey) }
func distance(_ a: Coordinate, _ b: Coordinate) -> Double { let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180, dp = q-p, dl = (b.longitude-a.longitude) * .pi / 180; let x = sin(dp/2)*sin(dp/2)+cos(p)*cos(q)*sin(dl/2)*sin(dl/2); return 6_371_000 * 2 * atan2(sqrt(x),sqrt(1-x)) }
