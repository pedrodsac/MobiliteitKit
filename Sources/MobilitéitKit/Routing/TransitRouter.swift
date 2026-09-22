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
    public func contains(routeType: Int) -> Bool { contains(.all) || (rawValue & (UInt64(1) << UInt64(clamping: routeType))) != 0 }
}

public enum JourneyPreference: String, Hashable, Sendable, Codable { case fastest, fewerTransfers, lessWalking, preferDirect }
public enum FrequencyRoutingPolicy: String, Hashable, Sendable, Codable { case conservative, expected, excludeInexact }
public enum WheelchairPreference: String, Hashable, Sendable, Codable { case noPreference, required }
public enum BikePreference: String, Hashable, Sendable, Codable { case noPreference, required }

public struct RoutingPreferences: Hashable, Sendable, Codable {
    public var maxTransfers: Int?
    public var minimumTransferSeconds: Int
    public var allowedModes: TransitModeMask
    public var wheelchair: WheelchairPreference
    public var bike: BikePreference
    public var routePreference: JourneyPreference
    public var frequencyPolicy: FrequencyRoutingPolicy
    public init(maxTransfers: Int? = 3, minimumTransferSeconds: Int = 120, allowedModes: TransitModeMask = .all, wheelchair: WheelchairPreference = .noPreference, bike: BikePreference = .noPreference, routePreference: JourneyPreference = .fastest, frequencyPolicy: FrequencyRoutingPolicy = .conservative) {
        self.maxTransfers = maxTransfers; self.minimumTransferSeconds = minimumTransferSeconds; self.allowedModes = allowedModes
        self.wheelchair = wheelchair; self.bike = bike; self.routePreference = routePreference; self.frequencyPolicy = frequencyPolicy
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

public struct RouteQuery: Hashable, Sendable {
    public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let departureTime: Date
    public let preferences: RoutingPreferences; public let realtimePolicy: RealtimePolicy
    public init(origin: JourneyEndpoint, destination: JourneyEndpoint, departureTime: Date, preferences: RoutingPreferences = .init(), realtimePolicy: RealtimePolicy = .disabled) {
        self.origin = origin; self.destination = destination; self.departureTime = departureTime; self.preferences = preferences; self.realtimePolicy = realtimePolicy
    }
}

public struct WalkingRequest: Hashable, Sendable { public let source: Coordinate; public let destination: Coordinate; public let departure: Date?; public init(source: Coordinate, destination: Coordinate, departure: Date? = nil) { self.source = source; self.destination = destination; self.departure = departure } }
public struct WalkingEstimate: Hashable, Sendable { public let durationSeconds: Int; public let distanceMeters: Double; public init(durationSeconds: Int, distanceMeters: Double) { self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters } }
public struct WalkingStep: Hashable, Sendable { public let instruction: String; public let coordinate: Coordinate?; public init(instruction: String, coordinate: Coordinate? = nil) { self.instruction = instruction; self.coordinate = coordinate } }
public struct WalkingRoute: Hashable, Sendable { public let durationSeconds: Int; public let distanceMeters: Double; public let polyline: [Coordinate]; public let steps: [WalkingStep]; public init(durationSeconds: Int, distanceMeters: Double, polyline: [Coordinate] = [], steps: [WalkingStep] = []) { self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters; self.polyline = polyline; self.steps = steps } }
public protocol WalkingRoutingProvider: Sendable { func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate; func route(_ request: WalkingRequest) async throws -> WalkingRoute }

public enum RealtimeTripStatus: String, Hashable, Sendable, Codable { case active, cancelled, unreachable }
public enum RealtimeTimingSource: String, Hashable, Sendable, Codable { case scheduled, reported, estimated }
public struct RealtimeStopEventPatch: Hashable, Sendable {
    public let stopID: String
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
        platform: String? = nil
    ) {
        self.stopID = stopID
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
    public init(patches: [RealtimeTripPatch], requestedStopIDs: Set<String>, coveredStopIDs: Set<String>) {
        self.patches = patches
        self.requestedStopIDs = requestedStopIDs
        self.coveredStopIDs = coveredStopIDs
    }
}
public protocol RealtimeRoutingProvider: Sendable {
    func patches(
        for stopIDs: [String],
        from: Date,
        through: Date,
        refreshPolicy: RealtimeRefreshPolicy
    ) async throws -> RealtimePatchBatch
}

private struct RealtimePatchKey: Hashable, Sendable {
    let tripID: String
    let serviceDate: GTFSDate
}

public enum WalkingSource: String, Hashable, Sendable, Codable { case provider, pathway }
public struct JourneyLocation: Hashable, Sendable { public let stop: TransitStop?; public let coordinate: Coordinate; public let label: String?; public init(stop: TransitStop? = nil, coordinate: Coordinate, label: String? = nil) { self.stop = stop; self.coordinate = coordinate; self.label = label } }
public struct WalkingLeg: Hashable, Sendable { public let from: JourneyLocation; public let to: JourneyLocation; public let departure: Date; public let arrival: Date; public let duration: TimeInterval; public let distanceMeters: Double; public let polyline: [Coordinate]; public let steps: [WalkingStep]; public let source: WalkingSource }
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
public struct TransitLeg: Hashable, Sendable { public let tripID: String; public let route: TransitRoute; public let headsign: String?; public let board: JourneyStopEvent; public let alight: JourneyStopEvent; public let intermediateStops: [JourneyStopEvent]; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date }
public struct InSeatContinuationLeg: Hashable, Sendable { public let fromTripID: String; public let toTripID: String }
public enum JourneyLeg: Hashable, Sendable { case walk(WalkingLeg), transit(TransitLeg), inSeatContinuation(InSeatContinuationLeg) }
public struct JourneySignature: Hashable, Sendable, Codable, Comparable, Identifiable { public let value: String; public var id: String { value }; public init(_ value: String) { self.value = value }; public static func < (l: Self, r: Self) -> Bool { l.value < r.value } }
public enum PageRealtimeState: String, Hashable, Sendable, Codable { case disabled, unavailable, partial, live }
public struct Journey: Hashable, Sendable, Identifiable { public let id: JourneySignature; public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let transferCount: Int; public let walkingDuration: TimeInterval; public let walkingDistance: Double; public let waitingDuration: TimeInterval; public let inVehicleDuration: TimeInterval; public let legs: [JourneyLeg]; public let feedGeneration: Int; public var duration: TimeInterval { effectiveArrival.timeIntervalSince(effectiveDeparture) } }
public struct RoutingMetrics: Hashable, Sendable {
    public var pointRaptorScans = 0; public var profileGenerationMilliseconds = 0
    public var snapshotLoadMilliseconds = 0; public var raptorSearchMilliseconds = 0
    public var candidateBuildingMilliseconds = 0; public var scannedPatterns = 0
    public var scannedTripInstances = 0
    public var walkingRequests = 0; public var hafasRequests = 0; public var hafasCacheHits = 0
    public var realtimeFrontierSize = 0; public var delayedPastBoardingsInjected = 0
    public var realtimeOverlayRevisions = 0; public var raptorReruns = 0
    public init() {}
}
public struct JourneyPage: Sendable { public let journeys: [Journey]; public let hasEarlier: Bool; public let hasLater: Bool; public let realtimeState: PageRealtimeState; public let revision: UInt64; public let metrics: RoutingMetrics }
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

private struct SnapshotStop: Sendable { let id: String; let model: TransitStop; let parent: String? }
private struct SnapshotTime: Sendable { let stop: Int; let sequence: Int; let arrival: Int32?; let departure: Int32?; let pickup: Int; let dropoff: Int }
private struct SnapshotTrip: Sendable {
    let id: String; let route: Int; let service: Int; let times: [SnapshotTime]; let headsign: String?
    let firstServiceTime: Int32; let lastServiceTime: Int32

    init(id: String, route: Int, service: Int, times: [SnapshotTime], headsign: String?) {
        self.id = id; self.route = route; self.service = service; self.times = times; self.headsign = headsign
        firstServiceTime = times.lazy.compactMap { $0.departure ?? $0.arrival }.first ?? 0
        lastServiceTime = times.lazy.reversed().compactMap { $0.departure ?? $0.arrival }.first ?? 0
    }
}
private struct SnapshotRule: Sendable { let order: Int; let from: Int?; let to: Int?; let type: Int; let minimum: Int?; let fromRoute: Int?; let toRoute: Int?; let fromTrip: Int?; let toTrip: Int? }
private struct RuleGroupKey: Hashable, Sendable { let from: Int?; let to: Int? }
private struct SnapshotPath: Sendable { let from: Int; let to: Int; let seconds: Int; let distance: Double }
private struct SnapshotPattern: Sendable { let trips: [Int]; let stops: [Int] }
private struct SnapshotServiceDay: Sendable { let offset: Int; let date: GTFSDate; let start: Date; let activeServices: Set<Int> }
private struct StopGridCell: Hashable { let latitude: Int; let longitude: Int }
private struct RoutingSnapshot: Sendable {
    let info: FeedInfo; let converter: ServiceInstantConverter; let stops: [SnapshotStop]; let stopByID: [String: Int]; let routes: [TransitRoute]; let trips: [SnapshotTrip]; let boardableStops: Set<Int>; let alightableStops: Set<Int>; let serviceDays: [SnapshotServiceDay]; let rulesByGroup: [RuleGroupKey: [SnapshotRule]]; let stationGroupByStop: [Int]; let paths: [SnapshotPath]; let nearbyTransferStopsByStop: [[Int]]
    let patterns: [SnapshotPattern]; let patternIDsByStop: [[Int]]; let loadMilliseconds: Int
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
                   st.pickup_type,st.dropoff_type
            FROM trip t JOIN stop_time st ON st.trip_id=t.id
            ORDER BY t.id,st.sequence
            """)
        var trips: [SnapshotTrip] = []; var tripIndex: [Int: Int] = [:]
        var currentSQLiteTrip: Int?; var currentID = ""; var currentRoute: Int?; var currentService: Int?
        var currentHeadsign: String?; var currentTimes: [SnapshotTime] = []
        func appendCurrentTrip() {
            guard let sqliteTrip = currentSQLiteTrip, let route = currentRoute,
                  let service = currentService, currentTimes.count >= 2 else { return }
            tripIndex[sqliteTrip] = trips.count
            trips.append(.init(id: currentID, route: route, service: service, times: currentTimes, headsign: currentHeadsign))
        }
        while try tripTimeStmt.step() {
            let sqliteTrip = tripTimeStmt.int(0)
            if currentSQLiteTrip != sqliteTrip {
                appendCurrentTrip()
                currentSQLiteTrip = sqliteTrip; currentID = tripTimeStmt.text(1)!
                currentRoute = routeIndex[tripTimeStmt.int(2)]; currentService = serviceIndex[tripTimeStmt.int(3)]
                currentHeadsign = tripTimeStmt.text(4); currentTimes = []
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
                    trips.append(.init(id: "\(source.id)#frequency-\(departure)", route: source.route, service: source.service, times: shifted, headsign: source.headsign))
                    departure += frequency.int32(3)
                }
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
        var paths: [SnapshotPath] = []; if let pstmt = try? db.prepare("SELECT from_stop_id,to_stop_id,traversal_time,is_bidirectional,length FROM pathway") { while try pstmt.step() { guard !pstmt.isNull(2), let a = sqliteStopIndex[pstmt.int(0)], let b = sqliteStopIndex[pstmt.int(1)] else { continue }; let path = SnapshotPath(from: a, to: b, seconds: pstmt.int(2), distance: pstmt.isNull(4) ? 0 : pstmt.double(4)); paths.append(path); if pstmt.int(3) == 1 { paths.append(.init(from: b, to: a, seconds: path.seconds, distance: path.distance)) } } }
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
        let patterns = grouped.values.map { family in SnapshotPattern(trips: family, stops: family.first.map { trips[$0].times.map(\.stop) } ?? []) }
        var patternIDsByStop = Array(repeating: [Int](), count: stops.count)
        for (patternID, pattern) in patterns.enumerated() {
            for stop in Set(pattern.stops) { patternIDsByStop[stop].append(patternID) }
        }
        let converter = ServiceInstantConverter(timeZone: zone)
        let serviceDays = active.indices.map { offset in
            let date = info.firstServiceDate.adding(days: offset)
            return SnapshotServiceDay(offset: offset, date: date, start: converter.date(serviceDate: date, serviceSeconds: 0), activeServices: active[offset])
        }
        return .init(info: info, converter: converter, stops: stops, stopByID: stopByID, routes: routes, trips: trips, boardableStops: boardableStops, alightableStops: alightableStops, serviceDays: serviceDays, rulesByGroup: rulesByGroup, stationGroupByStop: stationGroupByStop, paths: paths, nearbyTransferStopsByStop: nearbyTransferStopsByStop, patterns: patterns, patternIDsByStop: patternIDsByStop, loadMilliseconds: Int(Date().timeIntervalSince(loadStarted) * 1_000))
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
        let maximumDistanceMeters = 450.0
        let candidateLimit = 5
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
            for latitudeOffset in -1...1 {
                for longitudeOffset in -1...1 {
                    candidates += boardableByCell[.init(
                        latitude: sourceCell.latitude + latitudeOffset,
                        longitude: sourceCell.longitude + longitudeOffset
                    )] ?? []
                }
            }
            return candidates
            .filter { target in
                target != source && stationGroupByStop[target] != stationGroupByStop[source]
            }
            .map { target in (stop: target, distance: distance(sourceCoordinate, stops[target].model.coordinate)) }
            .filter { $0.distance <= maximumDistanceMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(candidateLimit)
            .map(\.stop)
        }
    }
}

// MARK: - Session / RAPTOR

public actor TransitRouter {
    private let snapshot: RoutingSnapshot; private let walking: (any WalkingRoutingProvider)?; private let realtime: (any RealtimeRoutingProvider)?
    public init(databaseURL: URL, walkingProvider: (any WalkingRoutingProvider)? = nil, realtimeProvider: (any RealtimeRoutingProvider)? = nil) async throws { self.snapshot = try await Task.detached(priority: .utility) { try SnapshotBuilder.load(databaseURL: databaseURL) }.value; self.walking = walkingProvider; self.realtime = realtimeProvider }
    public func makeSession(for query: RouteQuery) throws -> JourneyPlanningSession { guard query.preferences.minimumTransferSeconds >= 0, query.preferences.maxTransfers.map({ $0 >= 0 }) ?? true else { throw JourneyPlannerError.invalidPreferences }; return try JourneyPlanningSession(snapshot: snapshot, query: query, walking: walking, realtime: realtime) }
}

public actor JourneyPlanningSession {
    private let snapshot: RoutingSnapshot; private let query: RouteQuery; private let walking: (any WalkingRoutingProvider)?; private let realtimeProvider: (any RealtimeRoutingProvider)?
    private var all: [Journey] = []; private var visibleStart = 0; private var visibleEnd = 0; private var revision: UInt64 = 0; private var state: PageRealtimeState; private var metrics = RoutingMetrics()
    private var cachedEndpointEdges: (access: [Edge], egress: [Edge])?
    private var cachedRealtimeBatch: RealtimePatchBatch?
    private var latestPatchesByInstance: [RealtimePatchKey: RealtimeTripPatch] = [:]
    fileprivate struct BuiltJourney {
        let journey: Journey
        let firstBoard: Date
        let tripInstanceKey: String
        let minimumTransferSlack: Int
        let totalTransferSlack: Int
    }
    fileprivate init(snapshot: RoutingSnapshot, query: RouteQuery, walking: (any WalkingRoutingProvider)?, realtime: (any RealtimeRoutingProvider)?) throws { self.snapshot = snapshot; self.query = query; self.walking = walking; self.realtimeProvider = realtime; self.state = query.realtimePolicy == .disabled ? .disabled : .unavailable; self.metrics.snapshotLoadMilliseconds = snapshot.loadMilliseconds }
    public func initial(count: Int = 5) async throws -> JourneyPage { if all.isEmpty { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0 }; visibleEnd = min(all.count, max(0, count)); return page() }
    public func initial(count: Int = 5, searchHorizon: TimeInterval) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: max(0, searchHorizon)); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func expanded(count: Int = 5) async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon); visibleStart = 0; visibleEnd = min(all.count, max(0, count)); revision &+= 1; return page() }
    public func later(count: Int = 3) async throws -> JourneyPage { if all.isEmpty { _ = try await initial() }; visibleEnd = min(all.count, visibleEnd + max(0, count)); return page() }
    public func earlier(count: Int = 3) async throws -> JourneyPage { visibleStart = max(0, visibleStart - max(0, count)); return page() }
    public func refreshRealtime() async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, searchHorizon: Raptor.fullProfileHorizon, forceRealtime: true); visibleStart = 0; visibleEnd = min(max(visibleEnd, 5), all.count); revision &+= 1; return page() }
    private func page() -> JourneyPage { .init(journeys: Array(all[visibleStart..<visibleEnd]), hasEarlier: visibleStart > 0, hasLater: visibleEnd < all.count, realtimeState: state, revision: revision, metrics: metrics) }
    private func generate(anchor: Date, searchHorizon: TimeInterval, forceRealtime: Bool = false) async throws -> [Journey] {
        let started = Date()
        let edges: (access: [Edge], egress: [Edge])
        if let cachedEndpointEdges {
            edges = cachedEndpointEdges
        } else {
            edges = (
                try await endpointEdges(query.origin, anchor: anchor, purpose: .access),
                try await endpointEdges(query.destination, anchor: anchor, purpose: .egress)
            )
            cachedEndpointEdges = edges
        }
        let access = edges.access; let egress = edges.egress
        var patches: [RealtimeTripPatch] = []
        if case let .bestEffort(configuration, requestedRefresh) = query.realtimePolicy,
           let realtimeProvider {
            // Bootstrap with every access stop and the bounded, timetable
            // derived interchange frontier reachable from those first boards.
            // The backwards start is crucial: a 17:50 scheduled departure can
            // be returned and injected when its effective time is 18:05.
            let ids = realtimeFrontier(access: access, anchor: anchor, lookback: configuration.scheduledLookbackSeconds)
            metrics.realtimeFrontierSize = ids.count
            do {
                let batch: RealtimePatchBatch
                if !forceRealtime, let cachedRealtimeBatch {
                    batch = cachedRealtimeBatch
                    metrics.hafasCacheHits += 1
                } else {
                    metrics.hafasRequests += 1
                    batch = try await realtimeProvider.patches(
                        for: ids,
                        from: anchor.addingTimeInterval(-TimeInterval(configuration.scheduledLookbackSeconds)),
                        through: anchor.addingTimeInterval(TimeInterval(configuration.minimumForwardHorizonSeconds)),
                        refreshPolicy: forceRealtime ? .forceRefresh : requestedRefresh
                    )
                    cachedRealtimeBatch = batch
                }
                patches = batch.patches
                latestPatchesByInstance = Dictionary(
                    patches.map { (RealtimePatchKey(tripID: $0.tripID, serviceDate: $0.serviceDate), $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                metrics.delayedPastBoardingsInjected += patches.reduce(0) { partial, patch in
                    partial + patch.events.filter {
                        ($0.scheduledDeparture ?? .distantFuture) < anchor
                            && ($0.effectiveDeparture ?? .distantPast) >= anchor
                    }.count
                }
                metrics.realtimeOverlayRevisions += 1
                if batch.coveredStopIDs.isEmpty {
                    state = .unavailable
                } else if batch.coveredStopIDs == batch.requestedStopIDs, !patches.isEmpty {
                    state = .live
                } else {
                    state = .partial
                }
            } catch {
                state = .unavailable
                latestPatchesByInstance = [:]
            }
        }
        metrics.pointRaptorScans += 1
        let raptorStarted = Date()
        let searchResult = try await Raptor.search(snapshot: snapshot, query: query, access: access, egress: egress, patches: patches, walking: walking, profileHorizon: searchHorizon)
        metrics.raptorSearchMilliseconds = Int(Date().timeIntervalSince(raptorStarted) * 1_000)
        metrics.scannedPatterns = searchResult.scannedPatterns
        metrics.scannedTripInstances = searchResult.scannedTripInstances
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
        var journeys = strictEnvelope(Array(representatives.values)).sorted(by: journeyOrder).map(\.journey)
        metrics.candidateBuildingMilliseconds = Int(Date().timeIntervalSince(candidateStarted) * 1_000)
        let direct = try await directWalk(anchor: anchor)
        if let direct, !journeys.isEmpty { let minDuration = journeys.map(\.duration).min()!; let first = journeys.map(\.effectiveArrival).min()!; if direct.duration < minDuration { return [direct] }; if direct.effectiveArrival < first { journeys.insert(direct, at: 0) } } else if let direct, journeys.isEmpty { return [direct] }
        metrics.profileGenerationMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        return journeys
    }
    private func realtimeFrontier(access: [Edge], anchor: Date, lookback: Int) -> [String] {
        var result = Set(access.map { $0.stop })
        // This is intentionally bounded and purely static. It finds transfer
        // stops before the live overlay exists, without network work in RAPTOR.
        for trip in snapshot.trips {
            for time in trip.times where access.contains(where: { $0.stop == time.stop }) {
                guard let departure = time.departure else { continue }
                let activeDays = snapshot.serviceDays.filter { $0.activeServices.contains(trip.service) }
                if activeDays.contains(where: { $0.start.addingTimeInterval(TimeInterval(departure)) >= anchor.addingTimeInterval(-TimeInterval(lookback)) }) {
                    result.formUnion(trip.times.map(\.stop))
                }
            }
            if result.count >= 64 { break }
        }
        return result.sorted().prefix(64).map { snapshot.stops[$0].id }
    }
    fileprivate struct Edge { let stop: Int; let seconds: Int; let distance: Double; let walk: WalkingRoute? }
    private enum EndpointEdgePurpose: Equatable { case access, egress }
    private static let endpointCandidateLimit = 24

    private func endpointEdges(
        _ endpoint: JourneyEndpoint,
        anchor: Date,
        purpose: EndpointEdgePurpose
    ) async throws -> [Edge] {
        let endpointStop: Int?
        let coordinate: Coordinate
        switch endpoint {
        case let .stop(id):
            guard let stop = snapshot.stopByID[id] else { throw JourneyPlannerError.endpointNotFound }
            // An origin stop must remain exact. At the destination, preserve
            // the exact stop as a zero-walk option but also allow a rider to
            // alight at a nearby stop and walk the final stretch when faster.
            guard purpose == .egress, let walking else {
                return [.init(stop: stop, seconds: 0, distance: 0, walk: nil)]
            }
            endpointStop = stop
            coordinate = snapshot.stops[stop].model.coordinate
            _ = walking
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
        let candidates = snapshot.stops.enumerated().compactMap { index, stop -> (index: Int, stop: SnapshotStop, distance: Double)? in
            guard eligibleStops.contains(index), index != endpointStop else { return nil }
            return (index: index, stop: stop, distance: distance(coordinate, stop.model.coordinate))
        }.sorted { $0.distance < $1.distance }.prefix(Self.endpointCandidateLimit)
        var edges: [Edge] = endpointStop.map { [.init(stop: $0, seconds: 0, distance: 0, walk: nil)] } ?? []
        for candidate in candidates {
            metrics.walkingRequests += 1
            let request = switch purpose {
            case .access:
                WalkingRequest(source: coordinate, destination: candidate.stop.model.coordinate, departure: anchor)
            case .egress:
                WalkingRequest(source: candidate.stop.model.coordinate, destination: coordinate, departure: anchor)
            }
            if let route = try? await walking.route(request) {
                edges.append(.init(stop: candidate.index, seconds: route.durationSeconds, distance: route.distanceMeters, walk: route))
            }
        }
        return edges
    }
    private func directWalk(anchor: Date) async throws -> Journey? { guard case let .coordinate(a,al) = query.origin, case let .coordinate(b,bl) = query.destination, let walking, let route = try? await walking.route(.init(source: a, destination: b, departure: anchor)) else { return nil }; let arrival = anchor.addingTimeInterval(TimeInterval(route.durationSeconds)); let leg = WalkingLeg(from: .init(coordinate: a, label: al), to: .init(coordinate: b, label: bl), departure: anchor, arrival: arrival, duration: TimeInterval(route.durationSeconds), distanceMeters: route.distanceMeters, polyline: route.polyline, steps: route.steps, source: .provider); return .init(id: .init("walk:\(a.latitude),\(a.longitude):\(b.latitude),\(b.longitude)"), origin: query.origin, destination: query.destination, scheduledDeparture: anchor, scheduledArrival: arrival, effectiveDeparture: anchor, effectiveArrival: arrival, transferCount: 0, walkingDuration: TimeInterval(route.durationSeconds), walkingDistance: route.distanceMeters, waitingDuration: 0, inVehicleDuration: 0, legs: [.walk(leg)], feedGeneration: snapshot.info.generation) }
    private func buildJourney(_ candidate: Raptor.Candidate, access: [Edge], egress: [Edge]) -> BuiltJourney? {
        guard let a = access.first(where: { $0.stop == candidate.firstStop }), let e = egress.first(where: { $0.stop == candidate.lastStop }), let firstTransit = candidate.firstTransit, let lastTransit = candidate.lastTransit else { return nil }
        let depart = candidate.firstDeparture.addingTimeInterval(-TimeInterval(a.seconds)); let arrive = candidate.lastArrival.addingTimeInterval(TimeInterval(e.seconds)); guard depart >= query.departureTime else { return nil }
        let scheduledDepart = firstTransit.scheduledBoard.addingTimeInterval(-TimeInterval(a.seconds))
        let scheduledArrive = lastTransit.scheduledAlight.addingTimeInterval(candidate.lastArrival.timeIntervalSince(lastTransit.alightTime) + TimeInterval(e.seconds))
        var legs: [JourneyLeg] = []
        if let walk = a.walk {
            let from = endpointLocation(query.origin)
            let to = JourneyLocation(stop: snapshot.stops[candidate.firstStop].model, coordinate: snapshot.stops[candidate.firstStop].model.coordinate, label: snapshot.stops[candidate.firstStop].model.name)
            legs.append(.walk(.init(from: from, to: to, departure: depart, arrival: candidate.firstDeparture, duration: TimeInterval(walk.durationSeconds), distanceMeters: walk.distanceMeters, polyline: walk.polyline, steps: walk.steps, source: .provider)))
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
                let boardPatch = patch?.events.first { $0.stopID == board.id }
                let alightPatch = patch?.events.first { $0.stopID == alight.id }
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
                    let eventPatch = patch?.events.first { $0.stopID == stop.id }
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
                legs.append(.transit(.init(tripID: trip.id, route: snapshot.routes[trip.route], headsign: trip.headsign, board: b, alight: x, intermediateStops: Array(middle), scheduledDeparture: item.scheduledBoard, scheduledArrival: item.scheduledAlight, effectiveDeparture: item.boardTime, effectiveArrival: item.alightTime)))
            case let .pathway(item):
                let fromStop = snapshot.stops[item.from].model
                let toStop = snapshot.stops[item.to].model
                legs.append(.walk(.init(from: .init(stop: fromStop, coordinate: fromStop.coordinate, label: fromStop.name), to: .init(stop: toStop, coordinate: toStop.coordinate, label: toStop.name), departure: item.departure, arrival: item.arrival, duration: TimeInterval(item.seconds), distanceMeters: item.distance, polyline: [fromStop.coordinate, toStop.coordinate], steps: [], source: .pathway)))
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
                    source: .provider
                )))
            }
        }
        if let walk = e.walk {
            let from = JourneyLocation(stop: snapshot.stops[candidate.lastStop].model, coordinate: snapshot.stops[candidate.lastStop].model.coordinate, label: snapshot.stops[candidate.lastStop].model.name)
            let to = endpointLocation(query.destination)
            let departure = candidate.lastArrival
            legs.append(.walk(.init(from: from, to: to, departure: departure, arrival: departure.addingTimeInterval(TimeInterval(walk.durationSeconds)), duration: TimeInterval(walk.durationSeconds), distanceMeters: walk.distanceMeters, polyline: walk.polyline, steps: walk.steps, source: .provider)))
        }
        let signature = candidate.tripInstanceKey(snapshot: snapshot)
        let inVehicle = candidate.transitLegs.reduce(0) { $0 + $1.alightTime.timeIntervalSince($1.boardTime) }
        let walkingDuration = TimeInterval(a.seconds + e.seconds + candidate.pathwaySeconds)
        let waiting = max(0, arrive.timeIntervalSince(depart) - inVehicle - walkingDuration)
        let journey = Journey(id: .init(signature), origin: query.origin, destination: query.destination, scheduledDeparture: scheduledDepart, scheduledArrival: scheduledArrive, effectiveDeparture: depart, effectiveArrival: arrive, transferCount: max(0, candidate.transitLegs.count - 1), walkingDuration: walkingDuration, walkingDistance: a.distance + e.distance + candidate.pathwayDistance, waitingDuration: waiting, inVehicleDuration: inVehicle, legs: legs, feedGeneration: snapshot.info.generation)
        return .init(journey: journey, firstBoard: candidate.firstDeparture, tripInstanceKey: signature, minimumTransferSlack: candidate.transferSlacks.min() ?? .max, totalTransferSlack: candidate.transferSlacks.reduce(0, +))
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

    private func prefers(_ lhs: BuiltJourney, over rhs: BuiltJourney) -> Bool {
        (lhs.minimumTransferSlack, lhs.totalTransferSlack, -lhs.journey.effectiveArrival.timeIntervalSinceReferenceDate, -lhs.journey.walkingDuration, lhs.journey.id) > (rhs.minimumTransferSlack, rhs.totalTransferSlack, -rhs.journey.effectiveArrival.timeIntervalSinceReferenceDate, -rhs.journey.walkingDuration, rhs.journey.id)
    }
}

private enum Raptor {
    // Retain enough non-dominated prefixes to fill a five-result page while
    // keeping regional, full-feed searches bounded.
    private static let profileWidth = 8
    // Walking providers can be backed by a detailed local graph or a network
    // fallback. Bound automatic interchange probes so a broad regional search
    // never turns into one directions request for every alighting stop.
    private static let maximumWalkingTransferRequestsPerRound = 96
    static let fullProfileHorizon: TimeInterval = 86_400
    fileprivate struct TripInstance: Hashable { let trip: Int; let day: GTFSDate }
    struct TransitLeg { let trip: Int; let board: Int; let alight: Int; let boardPos: Int; let alightPos: Int; let day: GTFSDate; let scheduledBoard: Date; let scheduledAlight: Date; let boardTime: Date; let alightTime: Date }
    struct PathwayLeg { let from: Int; let to: Int; let seconds: Int; let distance: Double; let departure: Date; let arrival: Date }
    struct WalkingTransferLeg { let from: Int; let to: Int; let route: WalkingRoute; let departure: Date; let arrival: Date }
    enum Leg { case transit(TransitLeg); case pathway(PathwayLeg); case walkingTransfer(WalkingTransferLeg) }
    struct Candidate {
        let legs: [Leg]; let firstStop: Int; let lastStop: Int; let firstDeparture: Date; let lastArrival: Date
        let transferSlacks: [Int]; let pathwaySeconds: Int; let pathwayDistance: Double
        var transitLegs: [TransitLeg] { legs.compactMap { if case let .transit(leg) = $0 { return leg }; return nil } }
        var firstTransit: TransitLeg? { transitLegs.first }
        var lastTransit: TransitLeg? { transitLegs.last }
        func tripInstanceKey(snapshot: RoutingSnapshot) -> String { transitLegs.map { "\(snapshot.trips[$0.trip].id)@\($0.day.compactString)" }.joined(separator: "|") }
    }
    struct SearchResult {
        let candidates: [Candidate]
        let scannedPatterns: Int
        let scannedTripInstances: Int
    }
    private struct PatchKey: Hashable { let tripID: String; let serviceDate: GTFSDate }
    private struct PatchOverlay {
        let status: RealtimeTripStatus
        let eventsByStopID: [String: RealtimeStopEventPatch]
    }
    fileprivate struct Label {
        let id: Int; let time: Date; let legs: [Leg]; let firstStop: Int; let firstDeparture: Date?
        let lastTransit: TransitLeg?; let transferSlacks: [Int]; let accessSeconds: Int; let accessDistance: Double; let pathwaySeconds: Int; let pathwayDistance: Double; let transferWalkSeconds: Int
        let tripKey: [TripInstance]
    }
    static func search(snapshot: RoutingSnapshot, query: RouteQuery, access: [JourneyPlanningSession.Edge], egress: [JourneyPlanningSession.Edge], patches: [RealtimeTripPatch], walking: (any WalkingRoutingProvider)?, profileHorizon: TimeInterval) async throws -> SearchResult {
        guard !access.isEmpty, !egress.isEmpty else { return .init(candidates: [], scannedPatterns: 0, scannedTripInstances: 0) }
        let maxRounds = (query.preferences.maxTransfers ?? max(1, snapshot.trips.count)) + 1
        let scheduledLowerBound: Date = switch query.realtimePolicy {
        case .disabled:
            query.departureTime
        case let .bestEffort(configuration, _):
            query.departureTime.addingTimeInterval(-TimeInterval(configuration.scheduledLookbackSeconds))
        }
        let relevantServiceDays = snapshot.serviceDays.filter { serviceDay in
            guard serviceDay.start <= query.departureTime.addingTimeInterval(profileHorizon),
                  serviceDay.start.addingTimeInterval(TimeInterval(snapshot.info.maximumServiceTime.rawValue)) >= scheduledLowerBound
            else { return false }
            return true
        }
        let patchesByInstance = Dictionary(uniqueKeysWithValues: patches.map { patch in
            (PatchKey(tripID: patch.tripID, serviceDate: patch.serviceDate), PatchOverlay(status: patch.status, eventsByStopID: Dictionary(patch.events.map { ($0.stopID, $0) }, uniquingKeysWith: { _, latest in latest })))
        })
        var labels: [Int: [Label]] = [:]
        var nextLabelID = 0
        for a in access {
            _ = insert(.init(id: nextLabelID, time: query.departureTime.addingTimeInterval(TimeInterval(a.seconds)), legs: [], firstStop: a.stop, firstDeparture: nil, lastTransit: nil, transferSlacks: [], accessSeconds: a.seconds, accessDistance: a.distance, pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0, tripKey: []), at: a.stop, into: &labels)
            nextLabelID += 1
        }
        var destination: [Candidate] = []
        var scannedPatterns = 0
        var scannedTripInstances = 0
        let egressStops = Set(egress.map(\.stop))
        var finalRoundAlightStops = egressStops
        var foundPathwayPredecessor = true
        while foundPathwayPredecessor {
            foundPathwayPredecessor = false
            for path in snapshot.paths where finalRoundAlightStops.contains(path.to) {
                if finalRoundAlightStops.insert(path.from).inserted {
                    foundPathwayPredecessor = true
                }
            }
        }
        for round in 0..<maxRounds { var next: [Int: [Label]] = [:]
            try Task.checkCancellation()
            // Patterns are constructed from route + ordered stop occurrences;
            // scanning only families touched by a label avoids walking the full
            // feed on every round.
            let markedPatternIDs = Set(labels.keys.flatMap { snapshot.patternIDsByStop[$0] })
            for patternID in markedPatternIDs.sorted() {
                try Task.checkCancellation()
                scannedPatterns += 1
                let family = snapshot.patterns[patternID].trips
                for tripIndex in family { let trip = snapshot.trips[tripIndex]; guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
                for serviceDay in relevantServiceDays where serviceDay.activeServices.contains(trip.service) {
                    guard serviceDay.start.addingTimeInterval(TimeInterval(trip.firstServiceTime)) <= query.departureTime.addingTimeInterval(profileHorizon),
                          serviceDay.start.addingTimeInterval(TimeInterval(trip.lastServiceTime)) >= scheduledLowerBound
                    else { continue }
                    scannedTripInstances += 1
                    let day = serviceDay.date; let patch = patchesByInstance[.init(tripID: trip.id, serviceDate: day)]; guard patch?.status != .cancelled && patch?.status != .unreachable else { continue }
                    for boardPos in trip.times.indices { let bt = trip.times[boardPos]; guard let depart = bt.departure, bt.pickup == 0, let sources = labels[bt.stop] else { continue }; let scheduled = serviceDay.start.addingTimeInterval(TimeInterval(depart)); let effective = patchTime(patch, stop: snapshot.stops[bt.stop].id, departure: true) ?? scheduled
                        for source in sources {
                            guard let transfer = transferDecision(snapshot: snapshot, incoming: source.lastTransit, at: bt.stop, outgoing: tripIndex, preferences: query.preferences) else { continue }
                            let additionalTransferSeconds = source.lastTransit == nil ? 0 : max(0, transfer - source.transferWalkSeconds)
                            guard effective >= source.time.addingTimeInterval(TimeInterval(additionalTransferSeconds)) else { continue }
                            let slacks = source.lastTransit == nil ? source.transferSlacks : source.transferSlacks + [Int(effective.timeIntervalSince(source.time)) - additionalTransferSeconds]
                            for alightPos in (boardPos + 1)..<trip.times.count { let at = trip.times[alightPos]; guard at.dropoff == 0, let arrival = at.arrival, round + 1 < maxRounds || finalRoundAlightStops.contains(at.stop) else { continue }; let schedArrival = serviceDay.start.addingTimeInterval(TimeInterval(arrival)); let effectiveArrival = patchTime(patch, stop: snapshot.stops[at.stop].id, departure: false) ?? schedArrival; let leg = TransitLeg(trip: tripIndex, board: bt.stop, alight: at.stop, boardPos: boardPos, alightPos: alightPos, day: day, scheduledBoard: scheduled, scheduledAlight: schedArrival, boardTime: effective, alightTime: effectiveArrival); let label = Label(id: nextLabelID, time: effectiveArrival, legs: source.legs + [.transit(leg)], firstStop: source.firstStop, firstDeparture: source.firstDeparture ?? effective, lastTransit: leg, transferSlacks: slacks, accessSeconds: source.accessSeconds, accessDistance: source.accessDistance, pathwaySeconds: source.pathwaySeconds, pathwayDistance: source.pathwayDistance, transferWalkSeconds: 0, tripKey: source.tripKey + [.init(trip: tripIndex, day: day)]); nextLabelID += 1; _ = insert(label, at: at.stop, into: &next) }
                        }
                    }
                }
            } }
            relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID)
            try await relaxWalkingTransfers(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, walking: walking)
            for e in egress { for label in next[e.stop] ?? [] where label.firstDeparture != nil { destination.append(.init(legs: label.legs, firstStop: label.firstStop, lastStop: e.stop, firstDeparture: label.firstDeparture!, lastArrival: label.time, transferSlacks: label.transferSlacks, pathwaySeconds: label.pathwaySeconds, pathwayDistance: label.pathwayDistance)) } }
            labels = next; if labels.isEmpty { break }
        }
        return .init(candidates: destination, scannedPatterns: scannedPatterns, scannedTripInstances: scannedTripInstances)
    }

    private static func relaxPathways(snapshot: RoutingSnapshot, labels: inout [Int: [Label]], nextLabelID: inout Int) {
        var changed = true
        while changed {
            changed = false
            let sources = labels
            for path in snapshot.paths {
                for source in sources[path.from] ?? [] {
                    let arrival = source.time.addingTimeInterval(TimeInterval(path.seconds))
                    let leg = PathwayLeg(from: path.from, to: path.to, seconds: path.seconds, distance: path.distance, departure: source.time, arrival: arrival)
                    let label = Label(id: nextLabelID, time: arrival, legs: source.legs + [.pathway(leg)], firstStop: source.firstStop, firstDeparture: source.firstDeparture, lastTransit: source.lastTransit, transferSlacks: source.transferSlacks, accessSeconds: source.accessSeconds, accessDistance: source.accessDistance, pathwaySeconds: source.pathwaySeconds + path.seconds, pathwayDistance: source.pathwayDistance + path.distance, transferWalkSeconds: source.transferWalkSeconds + path.seconds, tripKey: source.tripKey)
                    nextLabelID += 1
                    if insert(label, at: path.to, into: &labels) { changed = true }
                }
            }
        }
    }

    /// Explores only the handful of geographically-close interchanges reached
    /// in this round. The provider decides whether each pair is actually
    /// walkable and supplies the time used by the next boarding decision.
    private static func relaxWalkingTransfers(
        snapshot: RoutingSnapshot,
        labels: inout [Int: [Label]],
        nextLabelID: inout Int,
        walking: (any WalkingRoutingProvider)?
    ) async throws {
        guard let walking else { return }
        let sources = labels.flatMap { stop, labels in
            labels.map { (stop: stop, label: $0) }
        }.sorted {
            if $0.label.time != $1.label.time { return $0.label.time < $1.label.time }
            if $0.stop != $1.stop { return $0.stop < $1.stop }
            return $0.label.id < $1.label.id
        }
        var requestCount = 0
        for (from, source) in sources where source.lastTransit != nil {
            let targets = snapshot.nearbyTransferStopsByStop[from]
            guard !targets.isEmpty else { continue }
            for to in targets {
                guard requestCount < maximumWalkingTransferRequestsPerRound else { return }
                requestCount += 1
                try Task.checkCancellation()
                let fromCoordinate = snapshot.stops[from].model.coordinate
                let toCoordinate = snapshot.stops[to].model.coordinate
                guard let route = try? await walking.route(.init(
                    source: fromCoordinate,
                    destination: toCoordinate,
                    departure: source.time
                )) else { continue }
                let arrival = source.time.addingTimeInterval(TimeInterval(route.durationSeconds))
                let leg = WalkingTransferLeg(
                    from: from,
                    to: to,
                    route: route,
                    departure: source.time,
                    arrival: arrival
                )
                let label = Label(
                    id: nextLabelID,
                    time: arrival,
                    legs: source.legs + [.walkingTransfer(leg)],
                    firstStop: source.firstStop,
                    firstDeparture: source.firstDeparture,
                    lastTransit: source.lastTransit,
                    transferSlacks: source.transferSlacks,
                    accessSeconds: source.accessSeconds,
                    accessDistance: source.accessDistance,
                    pathwaySeconds: source.pathwaySeconds + route.durationSeconds,
                    pathwayDistance: source.pathwayDistance + route.distanceMeters,
                    transferWalkSeconds: source.transferWalkSeconds + route.durationSeconds,
                    tripKey: source.tripKey
                )
                nextLabelID += 1
                _ = insert(label, at: to, into: &labels)
            }
        }
    }

    private static func insert(_ candidate: Label, at stop: Int, into labels: inout [Int: [Label]]) -> Bool {
        var profile = labels[stop] ?? []
        if let existingIndex = profile.firstIndex(where: { $0.tripKey == candidate.tripKey }) {
            guard prefers(candidate, over: profile[existingIndex]) else { return false }
            profile[existingIndex] = candidate
        } else {
            profile.append(candidate)
        }
        profile = profile.filter { candidate in !profile.contains { other in
            guard let candidateDeparture = candidate.firstDeparture, let otherDeparture = other.firstDeparture else { return false }
            return otherDeparture >= candidateDeparture && other.time <= candidate.time && (otherDeparture > candidateDeparture || other.time < candidate.time)
        } }
        profile.sort { lhs, rhs in
            if (lhs.firstDeparture ?? .distantPast) != (rhs.firstDeparture ?? .distantPast) { return (lhs.firstDeparture ?? .distantPast) < (rhs.firstDeparture ?? .distantPast) }
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            if lhs.minimumSlack != rhs.minimumSlack { return lhs.minimumSlack > rhs.minimumSlack }
            if lhs.totalSlack != rhs.totalSlack { return lhs.totalSlack > rhs.totalSlack }
            if lhs.pathwaySeconds != rhs.pathwaySeconds { return lhs.pathwaySeconds < rhs.pathwaySeconds }
            return precedes(lhs.tripKey, rhs.tripKey)
        }
        profile = Array(profile.prefix(profileWidth))
        labels[stop] = profile
        return profile.contains(where: { $0.id == candidate.id })
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
        return lhs.legs.count < rhs.legs.count
    }

    private static func precedes(_ lhs: [TripInstance], _ rhs: [TripInstance]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a.trip != b.trip { return a.trip < b.trip }
            if a.day != b.day { return a.day < b.day }
        }
        return lhs.count < rhs.count
    }

    private static func patchTime(_ patch: PatchOverlay?, stop: String, departure: Bool) -> Date? { guard let event = patch?.eventsByStopID[stop] else { return nil }; return departure ? event.effectiveDeparture : event.effectiveArrival }
    /// Resolves the single maximally-specific GTFS transfer rule. Returning nil
    /// means type 3 forbids the operation. This is intentionally centralised so
    /// numerical scan code cannot accidentally apply several conflicting rules.
    private static func transferDecision(snapshot: RoutingSnapshot, incoming: TransitLeg?, at stop: Int, outgoing: Int, preferences: RoutingPreferences) -> Int? {
        guard let incoming else { return 0 }
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
        guard let rule = candidates.filter(applies).max(by: { score($0) < score($1) }) else { return preferences.minimumTransferSeconds }
        switch rule.type { case 3: return nil; case 1, 4: return 0; case 2: return max(preferences.minimumTransferSeconds, rule.minimum ?? 0); default: return preferences.minimumTransferSeconds }
    }
}

private extension Raptor.Label {
    var minimumSlack: Int { transferSlacks.min() ?? .max }
    var totalSlack: Int { transferSlacks.reduce(0, +) }
}

private func strictEnvelope(_ journeys: [JourneyPlanningSession.BuiltJourney]) -> [JourneyPlanningSession.BuiltJourney] { journeys.filter { b in !journeys.contains { a in a.tripInstanceKey != b.tripInstanceKey && a.journey.effectiveDeparture >= b.journey.effectiveDeparture && a.journey.effectiveArrival <= b.journey.effectiveArrival && (a.journey.effectiveDeparture > b.journey.effectiveDeparture || a.journey.effectiveArrival < b.journey.effectiveArrival) } } }
private func journeyOrder(_ a: JourneyPlanningSession.BuiltJourney, _ b: JourneyPlanningSession.BuiltJourney) -> Bool { (a.journey.effectiveDeparture, a.journey.effectiveArrival, a.journey.transferCount, a.journey.walkingDuration, a.journey.duration, a.tripInstanceKey) < (b.journey.effectiveDeparture, b.journey.effectiveArrival, b.journey.transferCount, b.journey.walkingDuration, b.journey.duration, b.tripInstanceKey) }
private func distance(_ a: Coordinate, _ b: Coordinate) -> Double { let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180, dp = q-p, dl = (b.longitude-a.longitude) * .pi / 180; let x = sin(dp/2)*sin(dp/2)+cos(p)*cos(q)*sin(dl/2)*sin(dl/2); return 6_371_000 * 2 * atan2(sqrt(x),sqrt(1-x)) }
