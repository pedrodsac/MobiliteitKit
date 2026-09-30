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
    /// Maximum shortfall allowed for a generic, same-stop type-2 transfer.
    /// The published minimum remains attached to the journey for risk display.
    public var sameStopTransferShortfallSeconds: Int
    public var allowedModes: TransitModeMask
    public var preferredMode: TransitModeMask?
    public var wheelchair: WheelchairPreference
    public var preferWheelchairAccessible: Bool
    public var bike: BikePreference
    public var routePreference: JourneyPreference
    public var frequencyPolicy: FrequencyRoutingPolicy
    public init(maxTransfers: Int? = 3, minimumTransferSeconds: Int = 120, sameStopTransferShortfallSeconds: Int = 0, allowedModes: TransitModeMask = .all, preferredMode: TransitModeMask? = nil, wheelchair: WheelchairPreference = .noPreference, preferWheelchairAccessible: Bool = false, bike: BikePreference = .noPreference, routePreference: JourneyPreference = .fastest, frequencyPolicy: FrequencyRoutingPolicy = .conservative) {
        self.maxTransfers = maxTransfers; self.minimumTransferSeconds = minimumTransferSeconds; self.sameStopTransferShortfallSeconds = max(0, sameStopTransferShortfallSeconds); self.allowedModes = allowedModes
        self.preferredMode = preferredMode; self.wheelchair = wheelchair; self.preferWheelchairAccessible = preferWheelchairAccessible
        self.bike = bike; self.routePreference = routePreference; self.frequencyPolicy = frequencyPolicy
    }
    private enum CodingKeys: String, CodingKey {
        case maxTransfers, minimumTransferSeconds, sameStopTransferShortfallSeconds, allowedModes, preferredMode
        case wheelchair, preferWheelchairAccessible, bike, routePreference, frequencyPolicy
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
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
    public init(scheduledLookbackSeconds: Int = 7_200, minimumForwardHorizonSeconds: Int = 5_400, maximumConcurrentBoardRequests: Int = 4, maximumRefinementWaves: Int = 4) {
        self.scheduledLookbackSeconds = scheduledLookbackSeconds; self.minimumForwardHorizonSeconds = minimumForwardHorizonSeconds
        self.maximumConcurrentBoardRequests = maximumConcurrentBoardRequests; self.maximumRefinementWaves = maximumRefinementWaves
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
public struct TransitLeg: Hashable, Sendable { public let tripID: String; public let route: TransitRoute; public let headsign: String?; public let board: JourneyStopEvent; public let alight: JourneyStopEvent; public let intermediateStops: [JourneyStopEvent]; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let status: RealtimeTripStatus; public let requiredTransferSecondsAfterWalking: Int; public var polyline: [Coordinate] = [] }
public struct InSeatContinuationLeg: Hashable, Sendable { public let fromTripID: String; public let toTripID: String }
public enum JourneyLeg: Hashable, Sendable { case walk(WalkingLeg), transit(TransitLeg), inSeatContinuation(InSeatContinuationLeg) }
public struct JourneySignature: Hashable, Sendable, Codable, Comparable, Identifiable { public let value: String; public var id: String { value }; public init(_ value: String) { self.value = value }; public static func < (l: Self, r: Self) -> Bool { l.value < r.value } }
public enum PageRealtimeState: String, Hashable, Sendable, Codable { case disabled, unavailable, partial, live }
public struct Journey: Hashable, Sendable, Identifiable { public let id: JourneySignature; public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let transferCount: Int; public let walkingDuration: TimeInterval; public let walkingDistance: Double; public let waitingDuration: TimeInterval; public let inVehicleDuration: TimeInterval; public let legs: [JourneyLeg]; public let feedGeneration: Int; public let accessibility: AccessibilityAssessment; public let matchesPreferredMode: Bool; public var duration: TimeInterval { effectiveArrival.timeIntervalSince(effectiveDeparture) } }
public struct RoutingMetrics: Hashable, Sendable {
    public var pointRaptorScans = 0; public var profileGenerationMilliseconds = 0
    public var snapshotLoadMilliseconds = 0; public var raptorSearchMilliseconds = 0
    public var raptorCPUMilliseconds = 0; public var walkingTransferMilliseconds = 0
    public var raptorWorkerCount = 1
    public var endpointPreparationMilliseconds = 0; public var realtimePreparationMilliseconds = 0
    public var candidateBuildingMilliseconds = 0; public var scannedPatterns = 0
    public var scannedTripInstances = 0
    public var endpointAccessCandidates = 0; public var endpointEgressCandidates = 0
    public var candidatesGenerated = 0; public var alternativesRetained = 0
    public var walkingRequests = 0; public var walkingCacheHits = 0
    public var walkingTransferPairs = 0
    public var hafasRequests = 0; public var hafasCacheHits = 0
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
public struct JourneyPage: Sendable { public let journeys: [Journey]; public let recommendedJourneyID: JourneySignature?; public let hasEarlier: Bool; public let hasLater: Bool; public let realtimeState: PageRealtimeState; public let revision: UInt64; public let metrics: RoutingMetrics }
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
struct SnapshotTime: Sendable { let stop: Int; let sequence: Int; let arrival: Int32?; let departure: Int32?; let pickup: Int; let dropoff: Int }
struct SnapshotTrip: Sendable {
    let id: String; let route: Int; let service: Int; let times: [SnapshotTime]; let headsign: String?
    let wheelchairAccessible: Int
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
    let patterns: [SnapshotPattern]; let patternOccurrencesByStop: [[PatternOccurrence]]; let loadMilliseconds: Int
}

struct ServiceRoute: Hashable, Sendable {
    let service: Int
    let route: Int
}

private enum SnapshotBuilder {
    static func load(databaseURL: URL) throws -> RoutingSnapshot {
        let loadStarted = Date()
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
                   st.pickup_type,st.dropoff_type,t.wheelchair_accessible
            FROM trip t JOIN stop_time st ON st.trip_id=t.id
            ORDER BY t.id,st.sequence
            """)
        var trips: [SnapshotTrip] = []; var tripIndex: [Int: Int] = [:]
        var currentSQLiteTrip: Int?; var currentID = ""; var currentRoute: Int?; var currentService: Int?
        var currentHeadsign: String?; var currentTimes: [SnapshotTime] = []; var currentWheelchair = 0
        func appendCurrentTrip() {
            guard let sqliteTrip = currentSQLiteTrip, let route = currentRoute,
                  let service = currentService, currentTimes.count >= 2 else { return }
            tripIndex[sqliteTrip] = trips.count
            trips.append(.init(id: currentID, route: route, service: service, times: currentTimes, headsign: currentHeadsign, wheelchairAccessible: currentWheelchair))
        }
        while try tripTimeStmt.step() {
            let sqliteTrip = tripTimeStmt.int(0)
            if currentSQLiteTrip != sqliteTrip {
                appendCurrentTrip()
                currentSQLiteTrip = sqliteTrip; currentID = tripTimeStmt.text(1)!
                currentRoute = routeIndex[tripTimeStmt.int(2)]; currentService = serviceIndex[tripTimeStmt.int(3)]
                currentHeadsign = tripTimeStmt.text(4); currentWheelchair = tripTimeStmt.int(11); currentTimes = []
            }
            guard let stop = sqliteStopIndex[tripTimeStmt.int(5)] else { continue }
            currentTimes.append(.init(stop: stop, sequence: tripTimeStmt.int(6), arrival: tripTimeStmt.isNull(7) ? nil : tripTimeStmt.int32(7), departure: tripTimeStmt.isNull(8) ? nil : tripTimeStmt.int32(8), pickup: tripTimeStmt.int(9), dropoff: tripTimeStmt.int(10)))
        }
        appendCurrentTrip()
        // exact_times=1 is a set of real timetable instances, represented as
        // lightweight shifted trips in the day view rather than a permanent
        // database explosion. Inexact headway services remain a policy choice.
        if let frequency = try? db.prepare("SELECT trip_id,start_sec,end_sec,headway_sec,exact_times FROM frequency") {
            while try frequency.step() {
                guard !frequency.isNull(4), frequency.int(4) == 1, let sourceIndex = tripIndex[frequency.int(0)] else { continue }
                let source = trips[sourceIndex]
                guard let first = source.times.first?.departure ?? source.times.first?.arrival else { continue }
                var departure = frequency.int32(1)
                while departure < frequency.int32(2) {
                    let shift = departure - first
                    let shifted = source.times.map { time in SnapshotTime(stop: time.stop, sequence: time.sequence, arrival: time.arrival.map { $0 + shift }, departure: time.departure.map { $0 + shift }, pickup: time.pickup, dropoff: time.dropoff) }
                    trips.append(.init(id: "\(source.id)#frequency-\(departure)", route: source.route, service: source.service, times: shifted, headsign: source.headsign, wheelchairAccessible: source.wheelchairAccessible))
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
        let rstmt = try db.prepare("SELECT from_stop_id,to_stop_id,transfer_type,min_transfer_sec,from_route_id,to_route_id,from_trip_id,to_trip_id FROM transfer_rule"); var rules: [SnapshotRule] = []; while try rstmt.step() { rules.append(.init(order: rules.count, from: rstmt.isNull(0) ? nil : sqliteStopIndex[rstmt.int(0)], to: rstmt.isNull(1) ? nil : sqliteStopIndex[rstmt.int(1)], type: rstmt.int(2), minimum: rstmt.isNull(3) ? nil : rstmt.int(3), fromRoute: rstmt.isNull(4) ? nil : routeIndex[rstmt.int(4)], toRoute: rstmt.isNull(5) ? nil : routeIndex[rstmt.int(5)], fromTrip: rstmt.isNull(6) ? nil : tripIndex[rstmt.int(6)], toTrip: rstmt.isNull(7) ? nil : tripIndex[rstmt.int(7)])) }
        let stationGroupByStop = stops.indices.map { stop in stops[stop].parent.flatMap { stopByID[$0] } ?? stop }
        let rulesByGroup = Dictionary(grouping: rules) { rule in
            RuleGroupKey(from: rule.from.map { stationGroupByStop[$0] }, to: rule.to.map { stationGroupByStop[$0] })
        }
        var paths: [SnapshotPath] = []; if let pstmt = try? db.prepare("SELECT from_stop_id,to_stop_id,traversal_time,is_bidirectional,length,pathway_mode,stair_count,max_slope,min_width FROM pathway") { while try pstmt.step() { guard !pstmt.isNull(2), let a = sqliteStopIndex[pstmt.int(0)], let b = sqliteStopIndex[pstmt.int(1)] else { continue }; let path = SnapshotPath(from: a, to: b, seconds: pstmt.int(2), distance: pstmt.isNull(4) ? 0 : pstmt.double(4), mode: pstmt.isNull(5) ? 0 : pstmt.int(5), stairCount: pstmt.isNull(6) ? nil : pstmt.int(6), maxSlope: pstmt.isNull(7) ? nil : pstmt.double(7), minWidth: pstmt.isNull(8) ? nil : pstmt.double(8)); paths.append(path); if pstmt.int(3) == 1 { paths.append(.init(from: b, to: a, seconds: path.seconds, distance: path.distance, mode: path.mode, stairCount: path.stairCount.map { -$0 }, maxSlope: path.maxSlope.map { -$0 }, minWidth: path.minWidth)) } } }
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
        return .init(info: info, converter: converter, stops: stops, stopByID: stopByID, routes: routes, trips: trips, tripByID: tripByID, tripIndicesByDepartureStop: tripIndicesByDepartureStop, serviceRoutesByStop: serviceRoutesByStop.map(Array.init), boardableStops: boardableStops, alightableStops: alightableStops, serviceDays: serviceDays, lastActiveDayStartByService: lastActiveDayStartByService, rulesByGroup: rulesByGroup, stationGroupByStop: stationGroupByStop, pathsByFrom: pathsByFrom, pathsByTo: pathsByTo, nearbyTransferStopsByStop: nearbyTransferStopsByStop, patterns: patterns, patternOccurrencesByStop: patternOccurrencesByStop, loadMilliseconds: Int(Date().timeIntervalSince(loadStarted) * 1_000))
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
    private let snapshot: RoutingSnapshot; private let walking: WalkingRouteCache?; private let realtime: (any RealtimeRoutingProvider)?
    public init(databaseURL: URL, walkingProvider: (any WalkingRoutingProvider)? = nil, realtimeProvider: (any RealtimeRoutingProvider)? = nil) async throws { self.snapshot = try await Task.detached(priority: .utility) { try SnapshotBuilder.load(databaseURL: databaseURL) }.value; self.walking = walkingProvider.map { WalkingRouteCache(provider: $0) }; self.realtime = realtimeProvider }
    public func makeSession(for query: RouteQuery) throws -> JourneyPlanningSession { guard query.preferences.minimumTransferSeconds >= 0, query.preferences.maxTransfers.map({ $0 >= 0 }) ?? true else { throw JourneyPlannerError.invalidPreferences }; return try JourneyPlanningSession(snapshot: snapshot, query: query, walking: walking, realtime: realtime) }
    /// Feeds a measured pedestrian route back into the cache before a bounded
    /// replan, so the search cannot repeat its original short estimate.
    public func correctWalkingRoute(_ route: WalkingRoute, for request: WalkingRequest) async {
        await walking?.correct(request, with: route)
    }
}

public actor JourneyPlanningSession {
    let snapshot: RoutingSnapshot; let query: RouteQuery; private let walking: WalkingRouteCache?; let realtimeProvider: (any RealtimeRoutingProvider)?
    private var all: [Journey] = []; private var visibleStart = 0; private var visibleEnd = 0; private var revision: UInt64 = 0; var state: PageRealtimeState; var metrics = RoutingMetrics()
    private var directWalking: Journey?
    private var cachedEndpointEdges: (access: [Edge], egress: [Edge])?
    var cachedRealtimeBatch: RealtimePatchBatch?
    var latestPatchesByInstance: [RealtimePatchKey: RealtimeTripPatch] = [:]
    fileprivate struct BuiltJourney {
        let journey: Journey
        let firstBoard: Date
        let tripInstanceKey: String
        let equivalentTransferKey: String
        let minimumTransferSlack: Int
        let totalTransferSlack: Int
    }
    fileprivate init(snapshot: RoutingSnapshot, query: RouteQuery, walking: WalkingRouteCache?, realtime: (any RealtimeRoutingProvider)?) throws { self.snapshot = snapshot; self.query = query; self.walking = walking; self.realtimeProvider = realtime; self.state = query.realtimePolicy == .disabled ? .disabled : .unavailable; self.metrics.snapshotLoadMilliseconds = snapshot.loadMilliseconds }
    public func initial(count: Int = 5) async throws -> JourneyPage { if all.isEmpty { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0 }; visibleEnd = min(all.count, max(0, count)); return page() }
    public func initial(count: Int = 5, searchHorizon: TimeInterval) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: max(0, searchHorizon)); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func expanded(count: Int = 5) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func later(count: Int = 3) async throws -> JourneyPage { if all.isEmpty { _ = try await initial() }; visibleEnd = min(all.count, visibleEnd + max(0, count)); return page() }
    public func earlier(count: Int = 3) async throws -> JourneyPage { visibleStart = max(0, visibleStart - max(0, count)); return page() }
    public func refreshRealtime() async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon, forceRealtime: true); visibleStart = 0; visibleEnd = min(max(visibleEnd, 5), all.count); revision &+= 1; return page() }
    /// Returns adjacent transit alternatives after applying the boundary to the
    /// complete evaluated profile. A walking comparison is shown only initially.
    public func boundedPage(before: Date? = nil, beforeID: JourneySignature? = nil,
                            after: Date? = nil, afterID: JourneySignature? = nil,
                            count: Int = 5) async throws -> JourneyPage {
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
        let selected = before == nil ? Array(eligible.prefix(max(0, count))) : Array(eligible.suffix(max(0, count)))
        return makePage(journeys: selected, includeWalking: before == nil && after == nil,
                        hasEarlier: before != nil && eligible.count > selected.count,
                        hasLater: after != nil && eligible.count > selected.count)
    }
    private func page() -> JourneyPage {
        let shown = visibleStart == 0
            ? primaryProfile(count: visibleEnd)
            : Array(all[visibleStart..<visibleEnd])
        return makePage(journeys: shown, includeWalking: visibleStart == 0,
                 hasEarlier: visibleStart > 0, hasLater: visibleEnd < all.count)
    }
    private func primaryProfile(count: Int) -> [Journey] {
        guard count > 0 else { return [] }
        var selected: [Journey] = []; var seen: Set<JourneySignature> = []
        func add(_ journey: Journey?) {
            if let journey, seen.insert(journey.id).inserted { selected.append(journey) }
        }
        let useful = all.filter { !JourneyQualityPolicy.clearlyInferiorInInitialProfile($0, among: all) }
        let ordered = useful.sorted { JourneyQualityPolicy.ranksBefore(
            $0, $1, anchor: query.departureTime, direction: query.direction,
            preferences: query.preferences
        ) }
        add(ordered.first)
        if query.preferences.preferredMode != nil { add(ordered.first { $0.matchesPreferredMode }) }
        if query.preferences.preferWheelchairAccessible {
            add(ordered.first { $0.accessibility == .verified })
        }
        for journey in useful where selected.count < count { add(journey) }
        return selected.prefix(count).sorted { a, b in
            if a.effectiveDeparture != b.effectiveDeparture { return a.effectiveDeparture < b.effectiveDeparture }
            return a.id < b.id
        }
    }
    private func makePage(journeys: [Journey], includeWalking: Bool, hasEarlier: Bool, hasLater: Bool) -> JourneyPage {
        let recommendation = journeys.min { JourneyQualityPolicy.ranksBefore(
            $0, $1, anchor: query.departureTime, direction: query.direction,
            preferences: query.preferences
        ) }
        return .init(journeys: journeys + (includeWalking ? directWalking.map { [$0] } ?? [] : []),
                     recommendedJourneyID: recommendation?.id, hasEarlier: hasEarlier,
                     hasLater: hasLater, realtimeState: state, revision: revision, metrics: metrics)
    }
    private func generate(anchor: Date, searchHorizon: TimeInterval, forceRealtime: Bool = false) async throws -> [Journey] {
        let started = Date()
        let walkingStatisticsBefore = await walking?.statistics()
        let edges: (access: [Edge], egress: [Edge])
        if let cachedEndpointEdges {
            edges = cachedEndpointEdges
        } else {
            let endpointStarted = Date()
            async let access = Self.endpointEdges(snapshot: snapshot, walking: walking, endpoint: query.origin, anchor: anchor, purpose: .access)
            async let egress = Self.endpointEdges(snapshot: snapshot, walking: walking, endpoint: query.destination, anchor: anchor, purpose: .egress)
            edges = try await (access, egress)
            metrics.endpointPreparationMilliseconds += Int(Date().timeIntervalSince(endpointStarted) * 1_000)
            cachedEndpointEdges = edges
        }
        let access = edges.access; let egress = edges.egress
        metrics.endpointAccessCandidates = access.count
        metrics.endpointEgressCandidates = egress.count
        let realtimeStarted = ContinuousClock.now
        let patches = try await acquireRealtime(access: access, egress: egress, anchor: anchor,
                                                searchHorizon: searchHorizon, force: forceRealtime)
        metrics.realtimePreparationMilliseconds += HafasRealtimeRoutingProvider.milliseconds(
            realtimeStarted.duration(to: .now))
        metrics.pointRaptorScans += 1
        async let directJourney = Self.directWalk(snapshot: snapshot, query: query, walking: walking, anchor: anchor)
        let raptorStarted = Date()
        let searchResult = try await Raptor.search(snapshot: snapshot, query: query, access: access, egress: egress, patches: patches, walking: walking, profileHorizon: searchHorizon)
        metrics.raptorSearchMilliseconds = Int(Date().timeIntervalSince(raptorStarted) * 1_000)
        metrics.raptorCPUMilliseconds = searchResult.cpuMilliseconds
        metrics.walkingTransferMilliseconds = searchResult.walkingTransferMilliseconds
        metrics.walkingTransferPairs = searchResult.walkingTransferPairs
        metrics.raptorWorkerCount = searchResult.maximumWorkerCount
        metrics.searchRounds = searchResult.roundMetrics
        metrics.scannedPatterns = searchResult.scannedPatterns
        metrics.scannedTripInstances = searchResult.scannedTripInstances
        metrics.candidatesGenerated = searchResult.candidates.count
        let candidateStarted = Date()
        var representatives: [String: BuiltJourney] = [:]
        for candidate in searchResult.candidates {
            guard let journey = buildJourney(candidate, access: access, egress: egress) else { continue }
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
        let journeys = strictEnvelope(transferRepresentatives).sorted(by: journeyOrder).map(\.journey)
        metrics.alternativesRetained = journeys.count
        metrics.candidateBuildingMilliseconds = Int(Date().timeIntervalSince(candidateStarted) * 1_000)
        let direct = await directJourney
        if let before = walkingStatisticsBefore, let after = await walking?.statistics() {
            metrics.walkingRequests += after.requests - before.requests
            metrics.walkingCacheHits += after.hits - before.hits
        }
        directWalking = direct
        metrics.profileGenerationMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        return journeys
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
                if let route, route.durationSeconds <= 30 * 60, route.distanceMeters <= 3_000 {
                    edges.append(.init(stop: candidate.index, seconds: route.durationSeconds, distance: route.distanceMeters, walk: route))
                }
            }
        }
        return edges
    }
    private nonisolated static func directWalk(snapshot: RoutingSnapshot, query: RouteQuery, walking: WalkingRouteCache?, anchor: Date) async -> Journey? {
        guard query.preferences.wheelchair != .required,
              case let .coordinate(a, al) = query.origin,
              case let .coordinate(b, bl) = query.destination,
              let walking, let route = try? await walking.route(.init(source: a, destination: b, departure: anchor)),
              route.durationSeconds >= 0, route.durationSeconds <= 45 * 60,
              route.distanceMeters <= 3_000 else { return nil }
        let departure = query.direction == .arriveBy
            ? anchor.addingTimeInterval(-TimeInterval(route.durationSeconds)) : anchor
        let arrival = departure.addingTimeInterval(TimeInterval(route.durationSeconds))
        let leg = WalkingLeg(from: .init(coordinate: a, label: al), to: .init(coordinate: b, label: bl), departure: departure, arrival: arrival, duration: TimeInterval(route.durationSeconds), distanceMeters: route.distanceMeters, polyline: route.polyline, steps: route.steps, source: .provider, evidence: route.evidence)
        return .init(id: .init("walk:\(a.latitude),\(a.longitude):\(b.latitude),\(b.longitude)"), origin: query.origin, destination: query.destination, scheduledDeparture: departure, scheduledArrival: arrival, effectiveDeparture: departure, effectiveArrival: arrival, transferCount: 0, walkingDuration: TimeInterval(route.durationSeconds), walkingDistance: route.distanceMeters, waitingDuration: 0, inVehicleDuration: 0, legs: [.walk(leg)], feedGeneration: snapshot.info.generation, accessibility: .unknown, matchesPreferredMode: false)
    }
    private func buildJourney(_ candidate: Raptor.Candidate, access: [Edge], egress: [Edge]) -> BuiltJourney? {
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
                let middle = trip.times[(item.boardPos + 1)..<item.alightPos].map { time in
                    let stop = snapshot.stops[time.stop].model
                    let eventPatch = patch?.event(stopID: stop.id, sequence: time.sequence)
                    let scheduled = snapshot.converter.date(
                        serviceDate: item.day,
                        serviceSeconds: time.arrival ?? time.departure ?? 0
                    )
                    return JourneyStopEvent(
                        stop: stop,
                        scheduledTime: scheduled,
                        effectiveTime: eventPatch?.effectiveArrival
                            ?? eventPatch?.effectiveDeparture
                            ?? scheduled,
                        timingSource: eventPatch?.arrivalSource
                            ?? eventPatch?.departureSource
                            ?? .scheduled,
                        platform: eventPatch?.platform ?? stop.platformCode
                    )
                }
                legs.append(.transit(.init(tripID: trip.id, route: snapshot.routes[trip.route], headsign: trip.headsign, board: b, alight: x, intermediateStops: Array(middle), scheduledDeparture: item.scheduledBoard, scheduledArrival: item.scheduledAlight, effectiveDeparture: item.boardTime, effectiveArrival: item.alightTime, status: status, requiredTransferSecondsAfterWalking: item.requiredTransferSecondsAfterWalking)))
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
        let signature = candidate.tripInstanceKey(snapshot: snapshot)
        let inVehicle = candidate.transitLegs.reduce(0) { $0 + $1.alightTime.timeIntervalSince($1.boardTime) }
        let walkingDuration = TimeInterval(a.seconds + e.seconds + candidate.pathwaySeconds)
        let waiting = max(0, arrive.timeIntervalSince(depart) - inVehicle - walkingDuration)
        let matchesPreferredMode = query.preferences.preferredMode.map { preferred in
            candidate.transitLegs.contains { preferred.contains(routeType: snapshot.routes[snapshot.trips[$0.trip].route].type) }
        } ?? true
        let journey = Journey(id: .init(signature), origin: query.origin, destination: query.destination, scheduledDeparture: scheduledDepart, scheduledArrival: scheduledArrive, effectiveDeparture: depart, effectiveArrival: arrive, transferCount: max(0, candidate.transitLegs.count - 1), walkingDuration: walkingDuration, walkingDistance: a.distance + e.distance + candidate.pathwayDistance, waitingDuration: waiting, inVehicleDuration: inVehicle, legs: legs, feedGeneration: snapshot.info.generation, accessibility: accessibility, matchesPreferredMode: matchesPreferredMode)
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
        for leg in candidate.legs {
            switch leg {
            case let .transit(ride):
                let vehicle = snapshot.trips[ride.trip].wheelchairAccessible
                combine(vehicle == 1 ? .verified : vehicle == 2 ? .inaccessible : .unknown)
                combine(stopEvidence(ride.board)); combine(stopEvidence(ride.alight))
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

private enum Raptor {
    // Retain enough non-dominated prefixes to fill a five-result page while
    // keeping regional, full-feed searches bounded.
    private static let profileWidth = 48
    // Walking providers can be backed by a detailed local graph or a network
    // fallback. Bound automatic interchange probes so a broad regional search
    // never turns into one directions request for every alighting stop.
    private static let maximumWalkingTransferRequestsPerRound = 96
    private static let minimumPatternsForParallelScan = 32
    private static let maximumPatternWorkers = 10
    #if DEBUG
    private static let verifyProfile = ProcessInfo.processInfo.environment["ROUTING_VERIFY_PROFILE"] == "1"
    #endif
    static let fullProfileHorizon: TimeInterval = 86_400
    fileprivate struct TripInstance: Hashable, Sendable { let trip: Int; let day: GTFSDate }
    struct TransitLeg: Sendable { let trip: Int; let board: Int; let alight: Int; let boardPos: Int; let alightPos: Int; let day: GTFSDate; let scheduledBoard: Date; let scheduledAlight: Date; let boardTime: Date; let alightTime: Date; let requiredTransferSecondsAfterWalking: Int }
    struct PathwayLeg: Sendable { let from: Int; let to: Int; let seconds: Int; let distance: Double; let mode: Int; let stairCount: Int?; let maxSlope: Double?; let minWidth: Double?; let departure: Date; let arrival: Date }
    struct WalkingTransferLeg: Sendable { let from: Int; let to: Int; let route: WalkingRoute; let departure: Date; let arrival: Date }
    enum Leg: Sendable { case transit(TransitLeg); case pathway(PathwayLeg); case walkingTransfer(WalkingTransferLeg) }
    struct Candidate: Sendable {
        let legs: [Leg]; let firstStop: Int; let lastStop: Int; let firstDeparture: Date; let lastArrival: Date
        let minimumTransferSlack: Int; let totalTransferSlack: Int; let pathwaySeconds: Int; let pathwayDistance: Double
        var transitLegs: [TransitLeg] { legs.compactMap { if case let .transit(leg) = $0 { return leg }; return nil } }
        var firstTransit: TransitLeg? { transitLegs.first }
        var lastTransit: TransitLeg? { transitLegs.last }
        func tripInstanceKey(snapshot: RoutingSnapshot) -> String {
            let rides = transitLegs.map {
                "\(snapshot.trips[$0.trip].id)@\($0.day.compactString):\($0.boardPos)-\($0.alightPos)"
            }.joined(separator: "|")
            return "\(firstStop)>\(lastStop):\(rides)"
        }
        func equivalentTransferKey(snapshot: RoutingSnapshot) -> String {
            let rides = transitLegs
            let vehicles = rides.map { "\(snapshot.trips[$0.trip].id)@\($0.day.compactString)" }
                .joined(separator: "|")
            return "\(firstStop)>\(lastStop):\(rides.first?.boardPos ?? -1)-\(rides.last?.alightPos ?? -1):\(vehicles)"
        }
    }
    struct SearchResult: Sendable {
        let candidates: [Candidate]
        let scannedPatterns: Int
        let scannedTripInstances: Int
        let cpuMilliseconds: Int
        let walkingTransferMilliseconds: Int
        let walkingTransferPairs: Int
        let maximumWorkerCount: Int
        let roundMetrics: [RoutingRoundMetrics]
    }
    private struct PatchKey: Hashable, Sendable { let trip: Int; let serviceDate: GTFSDate }
    private struct PatchOverlay: Sendable {
        let status: RealtimeTripStatus
        let eventsByPosition: [Int: RealtimeStopEventPatch]
    }
    fileprivate enum WalkingVisits: Hashable, Sendable {
        case one(Int)
        case multiple(Set<Int>)

        var count: Int {
            switch self {
            case .one: 1
            case let .multiple(stops): stops.count
            }
        }

        func contains(_ stop: Int) -> Bool {
            switch self {
            case let .one(only): only == stop
            case let .multiple(stops): stops.contains(stop)
            }
        }

        func adding(_ stop: Int) -> Self {
            switch self {
            case let .one(only): return only == stop ? self : .multiple([only, stop])
            case var .multiple(stops):
                stops.insert(stop)
                return .multiple(stops)
            }
        }
    }
    fileprivate struct TripKey: Equatable, Sendable {
        private var first: TripInstance?
        private var second: TripInstance?
        private var third: TripInstance?
        private var fourth: TripInstance?
        private var overflow: [TripInstance] = []
        private(set) var count = 0

        var last: TripInstance? { count == 0 ? nil : self[count - 1] }

        subscript(_ index: Int) -> TripInstance {
            switch index {
            case 0: first!
            case 1: second!
            case 2: third!
            case 3: fourth!
            default: overflow[index - 4]
            }
        }

        func contains(_ value: TripInstance) -> Bool {
            for index in 0..<count where self[index] == value { return true }
            return false
        }

        func appending(_ value: TripInstance) -> Self {
            var result = self
            switch count {
            case 0: result.first = value
            case 1: result.second = value
            case 2: result.third = value
            case 3: result.fourth = value
            default: result.overflow.append(value)
            }
            result.count += 1
            return result
        }

        func hasPrefix(_ other: Self) -> Bool {
            guard count >= other.count else { return false }
            for index in 0..<other.count where self[index] != other[index] { return false }
            return true
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.count == rhs.count && lhs.hasPrefix(rhs)
        }
    }
    fileprivate final class Label: Sendable {
        let id: Int; let time: Date; let prior: Label?; let appendedLeg: Leg?; let legCount: Int
        let firstStop: Int; let firstDeparture: Date?
        let doorDeparture: Date?; let walkingSeconds: Int
        let lastTransit: TransitLeg?; let minimumSlack: Int; let totalSlack: Int; let accessSeconds: Int; let accessDistance: Double; let pathwaySeconds: Int; let pathwayDistance: Double; let transferWalkSeconds: Int
        let containsPreferredMode: Bool
        let walkingStopsVisited: WalkingVisits
        let tripKey: TripKey

        var legs: [Leg] {
            var result: [Leg] = []
            result.reserveCapacity(legCount)
            var cursor: Label? = self
            while let label = cursor {
                if let leg = label.appendedLeg { result.append(leg) }
                cursor = label.prior
            }
            return result.reversed()
        }

        init(id: Int, time: Date, prior: Label? = nil, appendedLeg: Leg? = nil,
             firstStop: Int, firstDeparture: Date?,
             lastTransit: TransitLeg?, minimumSlack: Int, totalSlack: Int,
             accessSeconds: Int, accessDistance: Double, pathwaySeconds: Int,
             pathwayDistance: Double, transferWalkSeconds: Int, containsPreferredMode: Bool,
             walkingStopsVisited: WalkingVisits, tripKey: TripKey) {
            self.id = id; self.time = time; self.prior = prior; self.appendedLeg = appendedLeg
            self.legCount = (prior?.legCount ?? 0) + (appendedLeg == nil ? 0 : 1)
            self.firstStop = firstStop
            self.firstDeparture = firstDeparture; self.lastTransit = lastTransit
            self.doorDeparture = firstDeparture?.addingTimeInterval(-TimeInterval(accessSeconds))
            self.walkingSeconds = accessSeconds + pathwaySeconds
            self.minimumSlack = minimumSlack; self.totalSlack = totalSlack
            self.accessSeconds = accessSeconds; self.accessDistance = accessDistance
            self.pathwaySeconds = pathwaySeconds; self.pathwayDistance = pathwayDistance
            self.transferWalkSeconds = transferWalkSeconds
            self.containsPreferredMode = containsPreferredMode
            self.walkingStopsVisited = walkingStopsVisited; self.tripKey = tripKey
        }
    }
    private struct LabelProfile: Sendable {
        var ordered: [Label] = []
        var byWalk: [Label] = []
        var byArrival: [Label] = []
        var byIncomingTrip: [Int: [Label]] = [:]
        // Boundaries for rejecting a candidate that cannot enter any quota.
        // Recomputed whenever the retained profile changes.
        var lastUnprotectedArrival: Label?
        var lastPreferredArrival: Label?
    }
    private struct PatternScanResult: Sendable {
        let chunkIndex: Int
        let labels: [Int: LabelProfile]
        let scannedPatterns: Int
        let scannedTripInstances: Int
        let boardingChecks: Int
        let feasibleBoardings: Int
        let alightingChecks: Int
        let labelAttempts: Int
        let retainedLabels: Int
        let rejectedBeforeAllocation: Int
        let elapsedMilliseconds: Int
    }
    private struct ActiveTripInstance: Sendable {
        let tripIndex: Int
        let serviceDay: SnapshotServiceDay
        let scheduledDepartures: [Date?]
        let scheduledArrivals: [Date?]
        let effectiveDepartures: [Date?]
        let effectiveArrivals: [Date?]
        let boardingAllowed: [Bool]
        let alightingAllowed: [Bool]
    }

    /// A conservative topology bound. A true bit means that a stop may still
    /// reach an egress stop with the given number of further vehicle rides.
    /// Pedestrian links are included even when the walking provider may later
    /// reject them, so this bound can only remove impossible journeys.
    private struct DestinationReachability {
        let stopsByRemainingRides: [[Bool]]
        let lastAlightPositionByRemainingRides: [[Int]]

        init(snapshot: RoutingSnapshot, egressStops: Set<Int>, maxRides: Int) {
            let stopCount = snapshot.stops.count
            var walkingSources = Array(repeating: [Int](), count: stopCount)
            for from in snapshot.nearbyTransferStopsByStop.indices {
                for to in snapshot.nearbyTransferStopsByStop[from] {
                    walkingSources[to].append(from)
                }
            }
            func walkingClosure(_ seeds: [Bool]) -> [Bool] {
                var result = seeds
                var queue = result.indices.filter { result[$0] }
                var cursor = 0
                while cursor < queue.count {
                    let to = queue[cursor]
                    cursor += 1
                    for from in snapshot.pathsByTo[to].map(\.from) + walkingSources[to] where !result[from] {
                        result[from] = true
                        queue.append(from)
                    }
                }
                return result
            }

            var base = Array(repeating: false, count: stopCount)
            for stop in egressStops { base[stop] = true }
            var reachability = [walkingClosure(base)]
            if maxRides > 1 {
                for rides in 1..<maxRides {
                    var seeds = reachability[rides - 1]
                    for pattern in snapshot.patterns {
                        guard pattern.stops.count > 1 else { continue }
                        var laterIsReachable = false
                        for position in pattern.stops.indices.reversed() {
                            let stop = pattern.stops[position]
                            if laterIsReachable { seeds[stop] = true }
                            if reachability[rides - 1][stop] { laterIsReachable = true }
                        }
                    }
                    reachability.append(walkingClosure(seeds))
                }
            }
            stopsByRemainingRides = reachability
            lastAlightPositionByRemainingRides = reachability.map { reachable in
                snapshot.patterns.map { pattern in
                    pattern.stops.indices.reversed().first { reachable[pattern.stops[$0]] } ?? -1
                }
            }
        }
    }
    private struct TransferDecisionKey: Hashable, Sendable {
        let incomingTrip: Int
        let stop: Int
        let outgoingTrip: Int
    }
    private struct TransferAllowance: Sendable {
        let requiredSeconds: Int
        let allowedShortfallSeconds: Int
    }
    private enum CachedTransferDecision: Sendable {
        case allowed(TransferAllowance)
        case forbidden

        var allowance: TransferAllowance? {
            switch self {
            case let .allowed(value): value
            case .forbidden: nil
            }
        }
    }
    static func search(snapshot: RoutingSnapshot, query: RouteQuery, access: [JourneyPlanningSession.Edge], egress: [JourneyPlanningSession.Edge], patches: [RealtimeTripPatch], walking: WalkingRouteCache?, profileHorizon: TimeInterval) async throws -> SearchResult {
        guard !access.isEmpty, !egress.isEmpty else { return .init(candidates: [], scannedPatterns: 0, scannedTripInstances: 0, cpuMilliseconds: 0, walkingTransferMilliseconds: 0, walkingTransferPairs: 0, maximumWorkerCount: 1, roundMetrics: []) }
        let maxRounds = (query.preferences.maxTransfers ?? max(1, snapshot.trips.count)) + 1
        let searchStart = query.direction == .arriveBy
            ? query.departureTime.addingTimeInterval(-profileHorizon) : query.departureTime
        let profileUpperBound = query.direction == .arriveBy
            ? query.departureTime : query.departureTime.addingTimeInterval(profileHorizon)
        let scheduledLowerBound: Date = switch query.realtimePolicy {
        case .disabled:
            searchStart
        case let .bestEffort(configuration, _):
            searchStart.addingTimeInterval(-TimeInterval(configuration.scheduledLookbackSeconds))
        }
        let relevantServiceDays = snapshot.serviceDays.filter { serviceDay in
            guard serviceDay.start <= profileUpperBound,
                  serviceDay.start.addingTimeInterval(TimeInterval(snapshot.info.maximumServiceTime.rawValue)) >= scheduledLowerBound
            else { return false }
            return true
        }
        let patchesByInstance = Dictionary(
            patches.compactMap { patch -> (PatchKey, PatchOverlay)? in
                guard let trip = snapshot.tripByID[patch.tripID] else { return nil }
                let times = snapshot.trips[trip].times
                let events = times.indices.compactMap { position -> (Int, RealtimeStopEventPatch)? in
                    let time = times[position]
                    guard let event = patch.event(stopID: snapshot.stops[time.stop].id, sequence: time.sequence)
                    else { return nil }
                    return (position, event)
                }
                return (
                    PatchKey(trip: trip, serviceDate: patch.serviceDate),
                    PatchOverlay(
                        status: patch.status,
                        eventsByPosition: Dictionary(events, uniquingKeysWith: { _, latest in latest })
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        var activeInstancesByPattern: [Int: [ActiveTripInstance]] = [:]
        var labels: [Int: LabelProfile] = [:]
        var nextLabelID = 0
        for a in access {
            _ = insert(.init(id: nextLabelID, time: searchStart.addingTimeInterval(TimeInterval(a.seconds)), firstStop: a.stop, firstDeparture: nil, lastTransit: nil, minimumSlack: .max, totalSlack: 0, accessSeconds: a.seconds, accessDistance: a.distance, pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0, containsPreferredMode: query.preferences.preferredMode == nil, walkingStopsVisited: .one(a.stop), tripKey: .init()), at: a.stop, into: &labels)
            nextLabelID += 1
        }
        var destination: [Candidate] = []
        var scannedPatterns = 0
        var scannedTripInstances = 0
        var cpuSeconds: TimeInterval = 0
        var walkingTransferSeconds: TimeInterval = 0
        var walkingTransferPairs = 0
        var maximumWorkerCount = 1
        var roundMetrics: [RoutingRoundMetrics] = []
        let egressStops = Set(egress.map(\.stop))
        let destinationReachability = maxRounds <= 8
            ? DestinationReachability(snapshot: snapshot, egressStops: egressStops, maxRides: maxRounds)
            : nil
        var finalRoundAlightStops = egressStops
        for from in snapshot.nearbyTransferStopsByStop.indices
        where snapshot.nearbyTransferStopsByStop[from].contains(where: { egressStops.contains($0) }) {
            finalRoundAlightStops.insert(from)
        }
        var predecessorQueue = Array(finalRoundAlightStops)
        var predecessorIndex = 0
        while predecessorIndex < predecessorQueue.count {
            let stop = predecessorQueue[predecessorIndex]
            predecessorIndex += 1
            for path in snapshot.pathsByTo[stop] {
                if finalRoundAlightStops.insert(path.from).inserted {
                    predecessorQueue.append(path.from)
                }
            }
        }
        for round in 0..<maxRounds { var next: [Int: LabelProfile] = [:]
            try Task.checkCancellation()
            let cpuStarted = Date()
            let remainingRides = maxRounds - round - 1
            // Patterns are constructed from route + ordered stop occurrences;
            // scanning only families touched by a label avoids walking the full
            // feed on every round.
            var markedFlags = Array(repeating: false, count: snapshot.patterns.count)
            var patternStartPositions = Array(repeating: Int.max, count: snapshot.patterns.count)
            var markedPatternIDs: [Int] = []
            for stop in labels.keys.sorted() {
                for occurrence in snapshot.patternOccurrencesByStop[stop] {
                    patternStartPositions[occurrence.pattern] = min(
                        patternStartPositions[occurrence.pattern],
                        occurrence.position
                    )
                    if !markedFlags[occurrence.pattern] {
                        markedFlags[occurrence.pattern] = true
                        markedPatternIDs.append(occurrence.pattern)
                    }
                }
            }
            if let destinationReachability {
                let lastAlight = destinationReachability.lastAlightPositionByRemainingRides[remainingRides]
                markedPatternIDs.removeAll {
                    lastAlight[$0] <= patternStartPositions[$0]
                }
            }
            markedPatternIDs.sort()
            let preparationStarted = Date()
            for patternID in markedPatternIDs where activeInstancesByPattern[patternID] == nil {
                activeInstancesByPattern[patternID] = activeTripInstances(
                    patternID: patternID,
                    snapshot: snapshot,
                    query: query,
                    relevantServiceDays: relevantServiceDays,
                    patchesByInstance: patchesByInstance,
                    scheduledLowerBound: scheduledLowerBound,
                    searchStart: searchStart,
                    profileUpperBound: profileUpperBound
                )
            }
            let preparationMilliseconds = Int(Date().timeIntervalSince(preparationStarted) * 1_000)
            let availableWorkers = min(maximumPatternWorkers, ProcessInfo.processInfo.activeProcessorCount)
            let workerCount = markedPatternIDs.count >= minimumPatternsForParallelScan
                ? min(availableWorkers, markedPatternIDs.count)
                : 1
            maximumWorkerCount = max(maximumWorkerCount, workerCount)
            let previousLabels = labels
            let chunkSize = max(1, (markedPatternIDs.count + workerCount * 12 - 1) / (workerCount * 12))
            let chunks = stride(from: 0, to: markedPatternIDs.count, by: chunkSize).enumerated().map { chunkIndex, start in
                (index: chunkIndex, patterns: Array(markedPatternIDs[start..<min(start + chunkSize, markedPatternIDs.count)]))
            }
            let currentRound = round
            let finalRoundAlightStopSnapshot = finalRoundAlightStops
            let activeInstanceSnapshot = activeInstancesByPattern
            let patternStartPositionSnapshot = patternStartPositions
            let reachableStops = destinationReachability?.stopsByRemainingRides[remainingRides]
            let scanStarted = Date()
            let scanResults = try await withThrowingTaskGroup(of: PatternScanResult.self) { group in
                for chunk in chunks {
                    group.addTask(priority: .userInitiated) {
                        try scanPatterns(
                            chunkIndex: chunk.index,
                            patternIDs: chunk.patterns,
                            snapshot: snapshot,
                            query: query,
                            previousLabels: previousLabels,
                            patternStartPositions: patternStartPositionSnapshot,
                            activeInstancesByPattern: activeInstanceSnapshot,
                            reachableStops: reachableStops,
                            round: currentRound,
                            maxRounds: maxRounds,
                            finalRoundAlightStops: finalRoundAlightStopSnapshot
                        )
                    }
                }
                var values: [PatternScanResult] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.chunkIndex < $1.chunkIndex }
            }
            let scanMilliseconds = Int(Date().timeIntervalSince(scanStarted) * 1_000)
            let mergeStarted = Date()
            var roundBoardingChecks = 0
            var roundFeasibleBoardings = 0
            var roundAlightingChecks = 0
            var roundLabelAttempts = 0
            var roundRetainedLabels = 0
            var roundRejectedBeforeAllocation = 0
            for result in scanResults {
                scannedPatterns += result.scannedPatterns
                scannedTripInstances += result.scannedTripInstances
                roundBoardingChecks += result.boardingChecks
                roundFeasibleBoardings += result.feasibleBoardings
                roundAlightingChecks += result.alightingChecks
                roundLabelAttempts += result.labelAttempts
                roundRetainedLabels += result.retainedLabels
                roundRejectedBeforeAllocation += result.rejectedBeforeAllocation
                for stop in result.labels.keys.sorted() {
                    for candidate in result.labels[stop]?.ordered ?? [] {
                        let candidate = candidate.replacingID(with: nextLabelID)
                        nextLabelID += 1
                        _ = insert(candidate, at: stop, into: &next)
                    }
                }
            }
            let mergeMilliseconds = Int(Date().timeIntervalSince(mergeStarted) * 1_000)
            roundMetrics.append(.init(
                tripPreparationMilliseconds: preparationMilliseconds,
                patternScanMilliseconds: scanMilliseconds,
                labelMergeMilliseconds: mergeMilliseconds,
                patterns: markedPatternIDs.count,
                tripInstances: scanResults.reduce(0) { $0 + $1.scannedTripInstances },
                boardingChecks: roundBoardingChecks,
                feasibleBoardings: roundFeasibleBoardings,
                alightingChecks: roundAlightingChecks,
                labelAttempts: roundLabelAttempts,
                retainedLabels: roundRetainedLabels,
                rejectedBeforeAllocation: roundRejectedBeforeAllocation,
                slowestChunkMilliseconds: scanResults.map(\.elapsedMilliseconds).max() ?? 0,
                summedChunkMilliseconds: scanResults.reduce(0) { $0 + $1.elapsedMilliseconds }
            ))
            relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID)
            cpuSeconds += Date().timeIntervalSince(cpuStarted)
            let walkingStarted = Date()
            walkingTransferPairs += try await relaxWalkingTransfers(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, walking: walking)
            walkingTransferSeconds += Date().timeIntervalSince(walkingStarted)
            for e in egress { for label in next[e.stop]?.ordered ?? [] where label.firstDeparture != nil { destination.append(.init(legs: label.legs, firstStop: label.firstStop, lastStop: e.stop, firstDeparture: label.firstDeparture!, lastArrival: label.time, minimumTransferSlack: label.minimumSlack, totalTransferSlack: label.totalSlack, pathwaySeconds: label.pathwaySeconds, pathwayDistance: label.pathwayDistance)) } }
            labels = next; if labels.isEmpty { break }
        }
        return .init(candidates: destination, scannedPatterns: scannedPatterns, scannedTripInstances: scannedTripInstances, cpuMilliseconds: Int(cpuSeconds * 1_000), walkingTransferMilliseconds: Int(walkingTransferSeconds * 1_000), walkingTransferPairs: walkingTransferPairs, maximumWorkerCount: maximumWorkerCount, roundMetrics: roundMetrics)
    }


    private static func scanPatterns(
        chunkIndex: Int,
        patternIDs: [Int],
        snapshot: RoutingSnapshot,
        query: RouteQuery,
        previousLabels: [Int: LabelProfile],
        patternStartPositions: [Int],
        activeInstancesByPattern: [Int: [ActiveTripInstance]],
        reachableStops: [Bool]?,
        round: Int,
        maxRounds: Int,
        finalRoundAlightStops: Set<Int>
    ) throws -> PatternScanResult {
        let scanStarted = Date()
        var next = [LabelProfile?](repeating: nil, count: snapshot.stops.count)
        var nextLabelID = (chunkIndex + 1) * 1_000_000_000
        var scannedTripInstances = 0
        var boardingChecks = 0
        var feasibleBoardings = 0
        var alightingChecks = 0
        var labelAttempts = 0
        var retainedLabels = 0
        var rejectedBeforeAllocation = 0
        var transferDecisions: [TransferDecisionKey: CachedTransferDecision] = [:]

        for patternID in patternIDs {
            try Task.checkCancellation()
            let startPosition = patternStartPositions[patternID]
            guard startPosition != Int.max else { continue }
            let instances = activeInstancesByPattern[patternID] ?? []
            scannedTripInstances += instances.count
            for instance in instances {
                try Task.checkCancellation()
                let tripIndex = instance.tripIndex
                let trip = snapshot.trips[tripIndex]
                let serviceDay = instance.serviceDay
                let day = serviceDay.date
                let tripMatchesPreferredMode = query.preferences.preferredMode?.contains(
                    routeType: snapshot.routes[trip.route].type
                ) ?? false
                let scheduledDepartures = instance.scheduledDepartures
                let scheduledArrivals = instance.scheduledArrivals
                let effectiveDepartures = instance.effectiveDepartures
                let effectiveArrivals = instance.effectiveArrivals
                let eligibleAlights = trip.times.indices.filter { position in
                    let stopTime = trip.times[position]
                    return stopTime.dropoff == 0
                        && instance.alightingAllowed[position]
                        && scheduledArrivals[position] != nil
                        && effectiveArrivals[position] != nil
                        && reachableStops?[stopTime.stop] != false
                        && (round + 1 < maxRounds || finalRoundAlightStops.contains(stopTime.stop))
                }

                for boardPos in startPosition..<trip.times.count {
                        try Task.checkCancellation()
                        let boardTime = trip.times[boardPos]
                        guard let scheduled = scheduledDepartures[boardPos],
                              let effective = effectiveDepartures[boardPos],
                              boardTime.pickup == 0,
                              instance.boardingAllowed[boardPos],
                              let sources = previousLabels[boardTime.stop]?.ordered
                        else { continue }
                        let latestPossibleArrival = effective.addingTimeInterval(
                            TimeInterval(max(0, query.preferences.sameStopTransferShortfallSeconds))
                        )

                        for source in sources {
                            boardingChecks += 1
                            guard source.time <= latestPossibleArrival else { continue }
                            guard !source.tripKey.contains(.init(trip: tripIndex, day: day)) else { continue }
                            guard let transfer = cachedTransferDecision(
                                snapshot: snapshot,
                                incoming: source.lastTransit,
                                at: boardTime.stop,
                                outgoing: tripIndex,
                                preferences: query.preferences,
                                cache: &transferDecisions
                            ) else { continue }
                            let additionalTransferSeconds = source.lastTransit == nil
                                ? 0
                                : max(0, transfer.requiredSeconds - source.transferWalkSeconds)
                            let allowedShortfall = source.transferWalkSeconds == 0
                                ? transfer.allowedShortfallSeconds : 0
                            guard effective >= source.time.addingTimeInterval(
                                TimeInterval(additionalTransferSeconds - allowedShortfall)
                            ) else { continue }
                            feasibleBoardings += 1
                            let slack = Int(effective.timeIntervalSince(source.time))
                                - additionalTransferSeconds
                            let minimumSlack = source.lastTransit == nil
                                ? source.minimumSlack
                                : min(source.minimumSlack, slack)
                            let totalSlack = source.lastTransit == nil
                                ? source.totalSlack
                                : source.totalSlack + slack

                            for alightPos in eligibleAlights where alightPos > boardPos {
                                alightingChecks += 1
                                let alightTime = trip.times[alightPos]
                                let scheduledArrival = scheduledArrivals[alightPos]!
                                let effectiveArrival = effectiveArrivals[alightPos]!
                                if transitCandidateIsDominated(
                                    by: next[alightTime.stop],
                                    source: source,
                                    tripIndex: tripIndex,
                                    day: day,
                                    alightStop: alightTime.stop,
                                    departure: effective,
                                    arrival: effectiveArrival,
                                    minimumSlack: minimumSlack,
                                    totalSlack: totalSlack,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode
                                ) { continue }
                                let candidateID = nextLabelID
                                nextLabelID += 1
                                labelAttempts += 1
                                if cannotEnterFullProfile(
                                    next[alightTime.stop], source: source,
                                    tripIndex: tripIndex, day: day, candidateID: candidateID,
                                    alightStop: alightTime.stop,
                                    departure: effective, arrival: effectiveArrival,
                                    minimumSlack: minimumSlack, totalSlack: totalSlack,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode
                                ) {
                                    rejectedBeforeAllocation += 1
                                    continue
                                }
                                let leg = TransitLeg(
                                    trip: tripIndex,
                                    board: boardTime.stop,
                                    alight: alightTime.stop,
                                    boardPos: boardPos,
                                    alightPos: alightPos,
                                    day: day,
                                    scheduledBoard: scheduled,
                                    scheduledAlight: scheduledArrival,
                                    boardTime: effective,
                                    alightTime: effectiveArrival,
                                    requiredTransferSecondsAfterWalking: additionalTransferSeconds
                                )
                                let label = Label(
                                    id: candidateID,
                                    time: effectiveArrival,
                                    prior: source, appendedLeg: .transit(leg),
                                    firstStop: source.firstStop,
                                    firstDeparture: source.firstDeparture ?? effective,
                                    lastTransit: leg,
                                    minimumSlack: minimumSlack,
                                    totalSlack: totalSlack,
                                    accessSeconds: source.accessSeconds,
                                    accessDistance: source.accessDistance,
                                    pathwaySeconds: source.pathwaySeconds,
                                    pathwayDistance: source.pathwayDistance,
                                    transferWalkSeconds: 0,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode,
                                    walkingStopsVisited: .one(alightTime.stop),
                                    tripKey: source.tripKey.appending(.init(trip: tripIndex, day: day))
                                )
                                if next[alightTime.stop] == nil {
                                    next[alightTime.stop] = LabelProfile()
                                }
                                if insert(label, into: &next[alightTime.stop]!) {
                                    retainedLabels += 1
                                }
                            }
                        }
                }
            }
        }
        var labelsByStop: [Int: LabelProfile] = [:]
        for (stop, profile) in next.enumerated() {
            if let profile { labelsByStop[stop] = profile }
        }
        return .init(
            chunkIndex: chunkIndex,
            labels: labelsByStop,
            scannedPatterns: patternIDs.count,
            scannedTripInstances: scannedTripInstances,
            boardingChecks: boardingChecks,
            feasibleBoardings: feasibleBoardings,
            alightingChecks: alightingChecks,
            labelAttempts: labelAttempts,
            retainedLabels: retainedLabels,
            rejectedBeforeAllocation: rejectedBeforeAllocation,
            elapsedMilliseconds: Int(Date().timeIntervalSince(scanStarted) * 1_000)
        )
    }

    private static func activeTripInstances(
        patternID: Int,
        snapshot: RoutingSnapshot,
        query: RouteQuery,
        relevantServiceDays: [SnapshotServiceDay],
        patchesByInstance: [PatchKey: PatchOverlay],
        scheduledLowerBound: Date,
        searchStart: Date,
        profileUpperBound: Date
    ) -> [ActiveTripInstance] {
        snapshot.patterns[patternID].trips.flatMap { tripIndex -> [ActiveTripInstance] in
            let trip = snapshot.trips[tripIndex]
            guard query.preferences.allowedModes.contains(
                routeType: snapshot.routes[trip.route].type
            ) else { return [] }
            return relevantServiceDays.compactMap { serviceDay in
                guard serviceDay.activeServices.contains(trip.service),
                      serviceDay.start.addingTimeInterval(TimeInterval(trip.firstServiceTime)) <= profileUpperBound,
                      serviceDay.start.addingTimeInterval(TimeInterval(trip.lastServiceTime)) >= scheduledLowerBound
                else { return nil }
                let patch = patchesByInstance[.init(trip: tripIndex, serviceDate: serviceDay.date)]
                // A trip cancellation applies to the entire vehicle instance,
                // including every downstream boarding stop. Do not route a
                // passenger onto it from a different stop.
                guard patch?.status != .unreachable,
                      patch?.status != .cancelled else { return nil }
                let scheduledDepartures = trip.times.map { time in
                    time.departure.map { serviceDay.start.addingTimeInterval(TimeInterval($0)) }
                }
                let scheduledArrivals = trip.times.map { time in
                    time.arrival.map { serviceDay.start.addingTimeInterval(TimeInterval($0)) }
                }
                let effectiveDepartures = trip.times.indices.map { position in
                    patchTime(patch, position: position, departure: true)
                        ?? scheduledDepartures[position]
                }
                let effectiveArrivals = trip.times.indices.map { position in
                    patchTime(patch, position: position, departure: false)
                        ?? scheduledArrivals[position]
                }
                // Access labels start no earlier than searchStart. Even with
                // realtime delays, an instance whose every pickup has passed
                // cannot be boarded during this query.
                guard trip.times.indices.contains(where: { position in
                    trip.times[position].pickup == 0
                        && patch?.eventsByPosition[position]?.boardingAllowed != false
                        && effectiveDepartures[position].map { $0 >= searchStart } == true
                }) else { return nil }
                return .init(
                    tripIndex: tripIndex, serviceDay: serviceDay,
                    scheduledDepartures: scheduledDepartures,
                    scheduledArrivals: scheduledArrivals,
                    effectiveDepartures: effectiveDepartures,
                    effectiveArrivals: effectiveArrivals,
                    boardingAllowed: trip.times.indices.map { patch?.eventsByPosition[$0]?.boardingAllowed != false },
                    alightingAllowed: trip.times.indices.map { patch?.eventsByPosition[$0]?.alightingAllowed != false }
                )
            }
        }
    }

    private static func cachedTransferDecision(
        snapshot: RoutingSnapshot,
        incoming: TransitLeg?,
        at stop: Int,
        outgoing: Int,
        preferences: RoutingPreferences,
        cache: inout [TransferDecisionKey: CachedTransferDecision]
    ) -> TransferAllowance? {
        guard let incoming else { return .init(requiredSeconds: 0, allowedShortfallSeconds: 0) }
        let key = TransferDecisionKey(
            incomingTrip: incoming.trip,
            stop: stop,
            outgoingTrip: outgoing
        )
        if let cached = cache[key] { return cached.allowance }
        let value = transferDecision(
            snapshot: snapshot,
            incoming: incoming,
            at: stop,
            outgoing: outgoing,
            preferences: preferences
        )
        cache[key] = value.map(CachedTransferDecision.allowed) ?? .forbidden
        return value
    }

    private static func relaxPathways(snapshot: RoutingSnapshot, labels: inout [Int: LabelProfile], nextLabelID: inout Int) {
        var queue = labels.keys.sorted().flatMap { stop in
            (labels[stop]?.ordered ?? []).sorted { $0.id < $1.id }.map { (stop: stop, label: $0) }
        }
        var queueIndex = 0
        while queueIndex < queue.count {
            let source = queue[queueIndex]
            queueIndex += 1
            for path in snapshot.pathsByFrom[source.stop] {
                guard !source.label.walkingStopsVisited.contains(path.to) else { continue }
                let arrival = source.label.time.addingTimeInterval(TimeInterval(path.seconds))
                let leg = PathwayLeg(from: path.from, to: path.to, seconds: path.seconds, distance: path.distance, mode: path.mode, stairCount: path.stairCount, maxSlope: path.maxSlope, minWidth: path.minWidth, departure: source.label.time, arrival: arrival)
                let label = Label(id: nextLabelID, time: arrival, prior: source.label, appendedLeg: .pathway(leg), firstStop: source.label.firstStop, firstDeparture: source.label.firstDeparture, lastTransit: source.label.lastTransit, minimumSlack: source.label.minimumSlack, totalSlack: source.label.totalSlack, accessSeconds: source.label.accessSeconds, accessDistance: source.label.accessDistance, pathwaySeconds: source.label.pathwaySeconds + path.seconds, pathwayDistance: source.label.pathwayDistance + path.distance, transferWalkSeconds: source.label.transferWalkSeconds + path.seconds, containsPreferredMode: source.label.containsPreferredMode, walkingStopsVisited: source.label.walkingStopsVisited.adding(path.to), tripKey: source.label.tripKey)
                nextLabelID += 1
                if insert(label, at: path.to, into: &labels) {
                    queue.append((stop: path.to, label: label))
                }
            }
        }
    }

    /// Explores only the handful of geographically-close interchanges reached
    /// in this round. The provider decides whether each pair is actually
    /// walkable and supplies the time used by the next boarding decision.
    private static func relaxWalkingTransfers(
        snapshot: RoutingSnapshot,
        labels: inout [Int: LabelProfile],
        nextLabelID: inout Int,
        walking: WalkingRouteCache?
    ) async throws -> Int {
        guard let walking else { return 0 }
        struct Pair: Hashable { let from: Int; let to: Int }
        var requests: [(from: Int, to: Int, source: Label, routeIndex: Int)] = []
        requests.reserveCapacity(maximumWalkingTransferRequestsPerRound * 3)
        var uniqueRequests: [WalkingRequest] = []
        var routeIndexByPair: [Pair: Int] = [:]
        var distinctPairs = 0
        let sourceStops = labels.keys.sorted { lhs, rhs in
            let a = labels[lhs]?.byArrival.first?.time ?? .distantFuture
            let b = labels[rhs]?.byArrival.first?.time ?? .distantFuture
            return a == b ? lhs < rhs : a < b
        }
        for from in sourceStops {
            let targets = snapshot.nearbyTransferStopsByStop[from]
            guard !targets.isEmpty else { continue }
            let eligible = (labels[from]?.ordered ?? []).filter { $0.lastTransit != nil }
                .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
            guard !eligible.isEmpty else { continue }
            for to in targets {
                guard eligible.contains(where: { !$0.walkingStopsVisited.contains(to) }) else { continue }
                guard distinctPairs < maximumWalkingTransferRequestsPerRound else { break }
                distinctPairs += 1
                try Task.checkCancellation()
                let fromCoordinate = snapshot.stops[from].model.coordinate
                let toCoordinate = snapshot.stops[to].model.coordinate
                // The pedestrian route is fetched once per stop pair. Apply it
                // to every retained arrival label: sampling only the first,
                // middle, and last arrival can discard the safer bus.
                for source in eligible {
                    guard !source.walkingStopsVisited.contains(to) else { continue }
                    let pair = Pair(from: from, to: to)
                    let routeIndex: Int
                    if let existing = routeIndexByPair[pair] {
                        routeIndex = existing
                    } else {
                        routeIndex = uniqueRequests.count
                        routeIndexByPair[pair] = routeIndex
                        uniqueRequests.append(.init(
                            source: fromCoordinate,
                            destination: toCoordinate,
                            departure: source.time
                        ))
                    }
                    requests.append((from, to, source, routeIndex))
                }
            }
            if distinctPairs == maximumWalkingTransferRequestsPerRound { break }
        }
        try Task.checkCancellation()
        let routes = await walking.routes(uniqueRequests, maximumConcurrency: 4)
        try Task.checkCancellation()
        for item in requests {
            // A straight-line or unverified fallback cannot prove that a
            // connection between two boarding points is physically catchable.
            guard let route = routes[item.routeIndex], route.evidence == .routedPedestrian,
                  route.durationSeconds <= 15 * 60,
                  route.distanceMeters <= 1_500 else { continue }
            let arrival = item.source.time.addingTimeInterval(TimeInterval(route.durationSeconds))
            let leg = WalkingTransferLeg(
                from: item.from,
                to: item.to,
                route: route,
                departure: item.source.time,
                arrival: arrival
            )
            let label = Label(
                id: nextLabelID,
                time: arrival,
                prior: item.source, appendedLeg: .walkingTransfer(leg),
                firstStop: item.source.firstStop,
                firstDeparture: item.source.firstDeparture,
                lastTransit: item.source.lastTransit,
                minimumSlack: item.source.minimumSlack,
                totalSlack: item.source.totalSlack,
                accessSeconds: item.source.accessSeconds,
                accessDistance: item.source.accessDistance,
                pathwaySeconds: item.source.pathwaySeconds + route.durationSeconds,
                pathwayDistance: item.source.pathwayDistance + route.distanceMeters,
                transferWalkSeconds: item.source.transferWalkSeconds + route.durationSeconds,
                containsPreferredMode: item.source.containsPreferredMode,
                walkingStopsVisited: item.source.walkingStopsVisited.adding(item.to),
                tripKey: item.source.tripKey
            )
            nextLabelID += 1
            _ = insert(label, at: item.to, into: &labels)
        }
        return uniqueRequests.count
    }

    private static func insert(_ candidate: Label, at stop: Int, into labels: inout [Int: LabelProfile]) -> Bool {
        insert(candidate, into: &labels[stop, default: LabelProfile()])
    }

    @inline(__always) private static func insert(_ candidate: Label, into profile: inout LabelProfile) -> Bool {
        #if DEBUG
        let referenceInput = verifyProfile ? profile.ordered : nil
        #endif
        let incomingTrip = candidate.lastTransit?.trip ?? -1
        let peers = profile.byIncomingTrip[incomingTrip] ?? []
        if peers.contains(where: { dominates($0, candidate) }) { return false }
        let removed = peers.compactMap { dominates(candidate, $0) ? $0.id : nil }
        if !removed.isEmpty {
            profile.ordered.removeAll { removed.contains($0.id) }
            profile.byWalk.removeAll { removed.contains($0.id) }
            profile.byArrival.removeAll { removed.contains($0.id) }
            profile.byIncomingTrip[incomingTrip]?.removeAll { removed.contains($0.id) }
        }
        if removed.isEmpty, profile.ordered.count == profileWidth {
            // A candidate later than the last unprotected arrival is evicted
            // immediately if it also falls outside every protected quota.
            let quota = profileWidth / 5
            let candidateIsLastUnprotected = profile.lastUnprotectedArrival.map {
                arrivalOrder($0, candidate)
            } ?? false
            let candidateIsInOrderedMiddle = labelOrder(profile.ordered[quota - 1], candidate)
                && labelOrder(candidate, profile.ordered[profileWidth - quota])
            let walk = candidate.walkingSeconds
            let walkBoundary = profile.byWalk[quota - 1]
            let boundaryWalk = walkBoundary.walkingSeconds
            let candidateOutsideWalkQuota = boundaryWalk < walk
                || (boundaryWalk == walk && labelOrder(walkBoundary, candidate))
            let candidateOutsidePreferredQuota = !candidate.containsPreferredMode
                || profile.lastPreferredArrival.map { arrivalOrder($0, candidate) } == true
            if candidateIsLastUnprotected, candidateIsInOrderedMiddle,
               candidateOutsideWalkQuota, candidateOutsidePreferredQuota {
                #if DEBUG
                if let referenceInput {
                    let expected = referenceInsert(candidate, into: referenceInput)
                    precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
                }
                #endif
                return false
            }
        }
        insertSorted(candidate, into: &profile.ordered, by: labelOrder)
        insertSorted(candidate, into: &profile.byWalk) { lhs, rhs in
            let a = lhs.walkingSeconds
            let b = rhs.walkingSeconds
            return a == b ? labelOrder(lhs, rhs) : a < b
        }
        insertSorted(candidate, into: &profile.byArrival) { lhs, rhs in
            arrivalOrder(lhs, rhs)
        }
        profile.byIncomingTrip[incomingTrip, default: []].append(candidate)
        var candidateRetained = true
        var membership: (ids: [Int], lastPreferred: Label?)?
        if profile.ordered.count > profileWidth {
            // With 49 labels and 48 slots, the reference quotas plus
            // arrival-order fill exclude the last arrival outside every quota.
            // Build the quota membership once instead of rescanning four
            // sorted profiles for every possible victim.
            let protected = quotaMembership(in: profile)
            membership = protected
            let protectedIDs = protected.ids
            if let victim = profile.byArrival.reversed().first(where: {
                !protectedIDs.contains($0.id)
            }) {
                candidateRetained = victim.id != candidate.id
                profile.ordered.remove(at: profile.ordered.firstIndex { $0.id == victim.id }!)
                profile.byWalk.remove(at: profile.byWalk.firstIndex { $0.id == victim.id }!)
                profile.byArrival.remove(at: profile.byArrival.firstIndex { $0.id == victim.id }!)
                let victimTrip = victim.lastTransit?.trip ?? -1
                profile.byIncomingTrip[victimTrip]?.removeAll { $0.id == victim.id }
            }
        }
        if !candidateRetained && removed.isEmpty {
            #if DEBUG
            if let referenceInput {
                let expected = referenceInsert(candidate, into: referenceInput)
                precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
            }
            #endif
            return false
        }
        if profile.ordered.count == profileWidth {
            let protected = membership ?? quotaMembership(in: profile)
            profile.lastUnprotectedArrival = profile.byArrival.reversed().first {
                !protected.ids.contains($0.id)
            }
            profile.lastPreferredArrival = protected.lastPreferred
        } else {
            profile.lastUnprotectedArrival = nil
            profile.lastPreferredArrival = nil
        }
        #if DEBUG
        if let referenceInput {
            let expected = referenceInsert(candidate, into: referenceInput)
            precondition(expected.map(\.id) == profile.ordered.map(\.id), "profile mismatch")
        }
        #endif
        return candidateRetained
    }

    @inline(__always) private static func quotaMembership(in profile: LabelProfile) -> (ids: [Int], lastPreferred: Label?) {
        let quota = profileWidth / 5
        var ids: [Int] = []
        ids.reserveCapacity(quota * 5)
        var preferredCount = 0
        var lastPreferred: Label?
        for label in profile.byArrival where label.containsPreferredMode {
            if preferredCount == quota { break }
            ids.append(label.id)
            lastPreferred = label
            preferredCount += 1
        }
        for label in profile.ordered.prefix(quota) { ids.append(label.id) }
        for label in profile.ordered.suffix(quota) { ids.append(label.id) }
        for label in profile.byWalk.prefix(quota) { ids.append(label.id) }
        for label in profile.byArrival.prefix(quota) { ids.append(label.id) }
        return (ids, preferredCount == quota ? lastPreferred : nil)
    }

    @inline(__always) private static func arrivalOrder(_ lhs: Label, _ rhs: Label) -> Bool {
        lhs.time == rhs.time ? labelOrder(lhs, rhs) : lhs.time < rhs.time
    }

    #if DEBUG
    private static func referenceInsert(_ candidate: Label, into original: [Label]) -> [Label] {
        var profile = original
        if profile.contains(where: { dominates($0, candidate) }) { return profile }
        profile.removeAll { dominates(candidate, $0) }
        profile.append(candidate)
        if profile.count > profileWidth {
            let earliest = profile.sorted { labelOrder($0, $1) }
            let latest = profile.sorted { labelOrder($1, $0) }
            let lowWalk = profile.sorted {
                let a = $0.walkingSeconds
                let b = $1.walkingSeconds
                return a == b ? labelOrder($0, $1) : a < b
            }
            let earlyArrival = profile.sorted {
                $0.time == $1.time ? labelOrder($0, $1) : $0.time < $1.time
            }
            var selected: [Label] = []; var seen: Set<Int> = []
            let preferred = earlyArrival.filter(\.containsPreferredMode)
            for group in [preferred, earliest, latest, lowWalk, earlyArrival] {
                for label in group.prefix(profileWidth / 5) where seen.insert(label.id).inserted {
                    selected.append(label)
                }
            }
            for label in earlyArrival where selected.count < profileWidth && seen.insert(label.id).inserted {
                selected.append(label)
            }
            profile = selected
        }
        profile.sort(by: labelOrder)
        return profile
    }
    #endif

    @inline(__always) private static func insertSorted(
        _ candidate: Label,
        into values: inout [Label],
        by precedes: (Label, Label) -> Bool
    ) {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if precedes(values[middle], candidate) { lower = middle + 1 }
            else { upper = middle }
        }
        values.insert(candidate, at: lower)
    }

    /// Avoid allocating a complete leg/path for a candidate that the existing
    /// exact dominance rule will immediately reject.
    @inline(__always) private static func cannotEnterFullProfile(
        _ profile: LabelProfile?, source: Label,
        tripIndex: Int, day: GTFSDate, candidateID: Int, alightStop: Int,
        departure: Date, arrival: Date,
        minimumSlack: Int, totalSlack: Int,
        containsPreferredMode: Bool
    ) -> Bool {
        guard let profile, profile.ordered.count == profileWidth,
              let lastUnprotected = profile.lastUnprotectedArrival else { return false }
        let firstDeparture = source.firstDeparture ?? departure
        let walk = source.walkingSeconds
        let candidateTrip = TripInstance(trip: tripIndex, day: day)

        func labelBeforeCandidate(_ lhs: Label) -> Bool {
            let lhsDeparture = lhs.firstDeparture ?? .distantPast
            if lhsDeparture != firstDeparture { return lhsDeparture < firstDeparture }
            if lhs.time != arrival { return lhs.time < arrival }
            if lhs.walkingSeconds != walk { return lhs.walkingSeconds < walk }
            let key = source.tripKey.appending(candidateTrip)
            if precedes(lhs.tripKey, key) { return true }
            if precedes(key, lhs.tripKey) { return false }
            return lhs.id < candidateID
        }
        func candidateBeforeLabel(_ rhs: Label) -> Bool {
            let rhsDeparture = rhs.firstDeparture ?? .distantPast
            if firstDeparture != rhsDeparture { return firstDeparture < rhsDeparture }
            if arrival != rhs.time { return arrival < rhs.time }
            if walk != rhs.walkingSeconds { return walk < rhs.walkingSeconds }
            let key = source.tripKey.appending(candidateTrip)
            if precedes(key, rhs.tripKey) { return true }
            if precedes(rhs.tripKey, key) { return false }
            return candidateID < rhs.id
        }
        guard lastUnprotected.time < arrival
            || (lastUnprotected.time == arrival && labelBeforeCandidate(lastUnprotected))
        else { return false }
        let quota = profileWidth / 5
        guard labelBeforeCandidate(profile.ordered[quota - 1]),
              candidateBeforeLabel(profile.ordered[profileWidth - quota]) else { return false }
        let walkBoundary = profile.byWalk[quota - 1]
        let boundaryWalk = walkBoundary.walkingSeconds
        let outsideWalk = boundaryWalk < walk
            || (boundaryWalk == walk && labelBeforeCandidate(walkBoundary))
        let outsidePreferred = !containsPreferredMode
            || profile.lastPreferredArrival.map {
                $0.time < arrival || ($0.time == arrival && labelBeforeCandidate($0))
            } == true
        guard outsideWalk && outsidePreferred else { return false }

        // The full insert first removes dominated peers. If a peer might be
        // removable, let the original check decide rather than risk pruning it.
        let doorDeparture = firstDeparture.addingTimeInterval(-TimeInterval(source.accessSeconds))
        for peer in profile.byIncomingTrip[tripIndex] ?? [] {
            guard peer.lastTransit?.alight == alightStop,
                  peer.transferWalkSeconds == 0,
                  peer.containsPreferredMode == containsPreferredMode,
                  peer.walkingStopsVisited.count == 1,
                  peer.walkingStopsVisited.contains(alightStop),
                  minimumSlack >= peer.minimumSlack,
                  totalSlack >= peer.totalSlack else { continue }
            if let peerDeparture = peer.doorDeparture,
               doorDeparture >= peerDeparture,
               arrival <= peer.time,
               walk <= peer.walkingSeconds {
                return false
            }
        }
        return true
    }

    @inline(__always) private static func transitCandidateIsDominated(
        by profile: LabelProfile?,
        source: Label,
        tripIndex: Int,
        day: GTFSDate,
        alightStop: Int,
        departure: Date,
        arrival: Date,
        minimumSlack: Int,
        totalSlack: Int,
        containsPreferredMode: Bool
    ) -> Bool {
        guard let profile else { return false }
        let firstDeparture = source.firstDeparture ?? departure
        let doorDeparture = firstDeparture.addingTimeInterval(-TimeInterval(source.accessSeconds))
        let walk = source.walkingSeconds
        let lastTrip = TripInstance(trip: tripIndex, day: day)
        return (profile.byIncomingTrip[tripIndex] ?? []).contains { existing in
            guard existing.lastTransit?.trip == tripIndex,
                  existing.lastTransit?.alight == alightStop,
                  existing.transferWalkSeconds == 0,
                  existing.containsPreferredMode == containsPreferredMode,
                  existing.walkingStopsVisited.count == 1,
                  existing.walkingStopsVisited.contains(alightStop),
                  existing.minimumSlack >= minimumSlack,
                  existing.totalSlack >= totalSlack,
                  let existingFirstDeparture = existing.firstDeparture
            else { return false }
            let existingDoorDeparture = existing.doorDeparture ?? existingFirstDeparture.addingTimeInterval(
                -TimeInterval(existing.accessSeconds)
            )
            let existingWalk = existing.walkingSeconds
            guard existingDoorDeparture >= doorDeparture,
                  existing.time <= arrival,
                  existingWalk <= walk else { return false }
            if existingDoorDeparture != doorDeparture || existing.time < arrival || existingWalk < walk {
                return true
            }
            return existing.tripKey.count == source.tripKey.count + 1
                && existing.tripKey.last == lastTrip
                && existing.tripKey.hasPrefix(source.tripKey)
        }
    }

    @inline(__always) private static func dominates(_ lhs: Label, _ rhs: Label) -> Bool {
        // Transfer rules inspect the incoming trip and the station where it
        // alighted. Walking allowance is also part of future boardability.
        guard lhs.lastTransit?.trip == rhs.lastTransit?.trip,
              lhs.lastTransit?.alight == rhs.lastTransit?.alight,
              lhs.transferWalkSeconds == rhs.transferWalkSeconds,
              lhs.containsPreferredMode == rhs.containsPreferredMode,
              lhs.walkingStopsVisited == rhs.walkingStopsVisited,
              lhs.minimumSlack >= rhs.minimumSlack,
              lhs.totalSlack >= rhs.totalSlack else { return false }
        let lhsDeparture = lhs.doorDeparture
        let rhsDeparture = rhs.doorDeparture
        let departureNoWorse: Bool
        if let lhsDeparture, let rhsDeparture { departureNoWorse = lhsDeparture >= rhsDeparture }
        else { departureNoWorse = lhsDeparture == rhsDeparture && lhs.accessSeconds <= rhs.accessSeconds }
        let lhsWalk = lhs.walkingSeconds
        let rhsWalk = rhs.walkingSeconds
        return departureNoWorse && lhs.time <= rhs.time && lhsWalk <= rhsWalk
            && (lhsDeparture != rhsDeparture || lhs.time < rhs.time || lhsWalk < rhsWalk
                || lhs.tripKey == rhs.tripKey)
    }

    @inline(__always) private static func labelOrder(_ lhs: Label, _ rhs: Label) -> Bool {
        let a = lhs.firstDeparture ?? .distantPast
        let b = rhs.firstDeparture ?? .distantPast
        if a != b { return a < b }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.walkingSeconds != rhs.walkingSeconds {
            return lhs.walkingSeconds < rhs.walkingSeconds
        }
        if precedes(lhs.tripKey, rhs.tripKey) { return true }
        if precedes(rhs.tripKey, lhs.tripKey) { return false }
        return lhs.id < rhs.id
    }

    private static func prefers(_ lhs: Label, over rhs: Label) -> Bool {
        if lhs.minimumSlack != rhs.minimumSlack { return lhs.minimumSlack > rhs.minimumSlack }
        if lhs.totalSlack != rhs.totalSlack { return lhs.totalSlack > rhs.totalSlack }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        // A later stop on the same vehicle reaches the same downstream state.
        // Retain the option that takes less time and distance to reach it.
        if lhs.accessSeconds != rhs.accessSeconds { return lhs.accessSeconds < rhs.accessSeconds }
        if lhs.accessDistance != rhs.accessDistance { return lhs.accessDistance < rhs.accessDistance }
        if lhs.pathwaySeconds != rhs.pathwaySeconds { return lhs.pathwaySeconds < rhs.pathwaySeconds }
        if lhs.pathwayDistance != rhs.pathwayDistance { return lhs.pathwayDistance < rhs.pathwayDistance }
        return lhs.legCount < rhs.legCount
    }

    @inline(__always) private static func precedes(_ lhs: TripKey, _ rhs: TripKey) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let a = lhs[index], b = rhs[index]
            if a.trip != b.trip { return a.trip < b.trip }
            if a.day != b.day { return a.day < b.day }
        }
        return lhs.count < rhs.count
    }

    private static func patchTime(_ patch: PatchOverlay?, position: Int, departure: Bool) -> Date? { guard let event = patch?.eventsByPosition[position] else { return nil }; return departure ? event.effectiveDeparture : event.effectiveArrival }
    /// Resolves the single maximally-specific GTFS transfer rule. Returning nil
    /// means type 3 forbids the operation. This is intentionally centralised so
    /// numerical scan code cannot accidentally apply several conflicting rules.
    private static func transferDecision(snapshot: RoutingSnapshot, incoming: TransitLeg?, at stop: Int, outgoing: Int, preferences: RoutingPreferences) -> TransferAllowance? {
        guard let incoming else { return .init(requiredSeconds: 0, allowedShortfallSeconds: 0) }
        let inTrip = snapshot.trips[incoming.trip], outTrip = snapshot.trips[outgoing]
        func applies(_ rule: SnapshotRule) -> Bool {
            guard rule.fromTrip == nil || rule.fromTrip == incoming.trip, rule.toTrip == nil || rule.toTrip == outgoing else { return false }
            return (rule.fromRoute == nil || rule.fromRoute == inTrip.route) && (rule.toRoute == nil || rule.toRoute == outTrip.route)
        }
        func score(_ rule: SnapshotRule) -> Int { if rule.fromTrip != nil && rule.toTrip != nil { return 60 }; if rule.fromTrip != nil || rule.toTrip != nil { return (rule.fromRoute != nil || rule.toRoute != nil) ? 50 : 40 }; if rule.fromRoute != nil && rule.toRoute != nil { return 30 }; if rule.fromRoute != nil || rule.toRoute != nil { return 20 }; return 10 }
        let fromGroup = snapshot.stationGroupByStop[incoming.alight]
        let toGroup = snapshot.stationGroupByStop[stop]
        let keys = [
            RuleGroupKey(from: fromGroup, to: toGroup),
            RuleGroupKey(from: nil, to: toGroup),
            RuleGroupKey(from: fromGroup, to: nil),
            RuleGroupKey(from: nil, to: nil),
        ]
        let candidates = keys.flatMap { snapshot.rulesByGroup[$0] ?? [] }.sorted { $0.order < $1.order }
        guard let rule = candidates.filter(applies).max(by: { score($0) < score($1) }) else {
            return .init(requiredSeconds: preferences.minimumTransferSeconds, allowedShortfallSeconds: 0)
        }
        switch rule.type {
        case 3: return nil
        case 1, 4: return .init(requiredSeconds: 0, allowedShortfallSeconds: 0)
        case 2:
            let required = max(preferences.minimumTransferSeconds, rule.minimum ?? 0)
            // A broad stop-wide rule can be conservative for two buses serving
            // the exact same platform. Keep trip/route-specific rules strict.
            let genericSameStop = incoming.alight == stop
                && rule.fromTrip == nil && rule.toTrip == nil
                && rule.fromRoute == nil && rule.toRoute == nil
            return .init(requiredSeconds: required,
                         allowedShortfallSeconds: genericSameStop
                            ? min(required, preferences.sameStopTransferShortfallSeconds) : 0)
        default: return .init(requiredSeconds: preferences.minimumTransferSeconds, allowedShortfallSeconds: 0)
        }
    }
}

private extension Raptor.Label {
    func replacingID(with id: Int) -> Self {
        .init(
            id: id,
            time: time,
            prior: prior,
            appendedLeg: appendedLeg,
            firstStop: firstStop,
            firstDeparture: firstDeparture,
            lastTransit: lastTransit,
            minimumSlack: minimumSlack,
            totalSlack: totalSlack,
            accessSeconds: accessSeconds,
            accessDistance: accessDistance,
            pathwaySeconds: pathwaySeconds,
            pathwayDistance: pathwayDistance,
            transferWalkSeconds: transferWalkSeconds,
            containsPreferredMode: containsPreferredMode,
            walkingStopsVisited: walkingStopsVisited,
            tripKey: tripKey
        )
    }
}

private func strictEnvelope(_ journeys: [JourneyPlanningSession.BuiltJourney]) -> [JourneyPlanningSession.BuiltJourney] {
    journeys.filter { candidate in
        !journeys.contains { other in
            other.tripInstanceKey != candidate.tripInstanceKey
                && JourneyQualityPolicy.dominates(other.journey, candidate.journey)
        }
    }
}
private func journeyOrder(_ a: JourneyPlanningSession.BuiltJourney, _ b: JourneyPlanningSession.BuiltJourney) -> Bool { (a.journey.effectiveDeparture, a.journey.effectiveArrival, a.journey.transferCount, a.journey.walkingDuration, a.journey.duration, a.tripInstanceKey) < (b.journey.effectiveDeparture, b.journey.effectiveArrival, b.journey.transferCount, b.journey.walkingDuration, b.journey.duration, b.tripInstanceKey) }
func distance(_ a: Coordinate, _ b: Coordinate) -> Double { let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180, dp = q-p, dl = (b.longitude-a.longitude) * .pi / 180; let x = sin(dp/2)*sin(dp/2)+cos(p)*cos(q)*sin(dl/2)*sin(dl/2); return 6_371_000 * 2 * atan2(sqrt(x),sqrt(1-x)) }
