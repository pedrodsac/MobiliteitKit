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
public enum RealtimePolicy: Hashable, Sendable, Codable { case disabled, bestEffort(RealtimeConfiguration = .default) }

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
public struct RealtimeStopEventPatch: Hashable, Sendable { public let stopID: String; public let scheduledDeparture: Date?; public let effectiveDeparture: Date?; public let scheduledArrival: Date?; public let effectiveArrival: Date?; public init(stopID: String, scheduledDeparture: Date? = nil, effectiveDeparture: Date? = nil, scheduledArrival: Date? = nil, effectiveArrival: Date? = nil) { self.stopID = stopID; self.scheduledDeparture = scheduledDeparture; self.effectiveDeparture = effectiveDeparture; self.scheduledArrival = scheduledArrival; self.effectiveArrival = effectiveArrival } }
/// A high-confidence, already matched GTFS trip-instance update. The mapping
/// layer belongs outside RAPTOR; this compact value is its immutable hand-off.
public struct RealtimeTripPatch: Hashable, Sendable { public let tripID: String; public let serviceDate: GTFSDate; public let status: RealtimeTripStatus; public let events: [RealtimeStopEventPatch]; public init(tripID: String, serviceDate: GTFSDate, status: RealtimeTripStatus = .active, events: [RealtimeStopEventPatch]) { self.tripID = tripID; self.serviceDate = serviceDate; self.status = status; self.events = events } }
public protocol RealtimeRoutingProvider: Sendable { func patches(for stopIDs: [String], from: Date, through: Date) async throws -> [RealtimeTripPatch] }

public enum WalkingSource: String, Hashable, Sendable, Codable { case provider, pathway }
public struct JourneyLocation: Hashable, Sendable { public let stop: TransitStop?; public let coordinate: Coordinate; public let label: String?; public init(stop: TransitStop? = nil, coordinate: Coordinate, label: String? = nil) { self.stop = stop; self.coordinate = coordinate; self.label = label } }
public struct WalkingLeg: Hashable, Sendable { public let from: JourneyLocation; public let to: JourneyLocation; public let departure: Date; public let arrival: Date; public let duration: TimeInterval; public let distanceMeters: Double; public let polyline: [Coordinate]; public let steps: [WalkingStep]; public let source: WalkingSource }
public struct JourneyStopEvent: Hashable, Sendable { public let stop: TransitStop; public let scheduledTime: Date; public let effectiveTime: Date; public let platform: String?; public init(stop: TransitStop, scheduledTime: Date, effectiveTime: Date, platform: String? = nil) { self.stop = stop; self.scheduledTime = scheduledTime; self.effectiveTime = effectiveTime; self.platform = platform } }
public struct TransitLeg: Hashable, Sendable { public let tripID: String; public let route: TransitRoute; public let headsign: String?; public let board: JourneyStopEvent; public let alight: JourneyStopEvent; public let intermediateStops: [JourneyStopEvent]; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date }
public struct InSeatContinuationLeg: Hashable, Sendable { public let fromTripID: String; public let toTripID: String }
public enum JourneyLeg: Hashable, Sendable { case walk(WalkingLeg), transit(TransitLeg), inSeatContinuation(InSeatContinuationLeg) }
public struct JourneySignature: Hashable, Sendable, Codable, Comparable, Identifiable { public let value: String; public var id: String { value }; public init(_ value: String) { self.value = value }; public static func < (l: Self, r: Self) -> Bool { l.value < r.value } }
public enum PageRealtimeState: String, Hashable, Sendable, Codable { case disabled, unavailable, partial, live }
public struct Journey: Hashable, Sendable, Identifiable { public let id: JourneySignature; public let origin: JourneyEndpoint; public let destination: JourneyEndpoint; public let scheduledDeparture: Date; public let scheduledArrival: Date; public let effectiveDeparture: Date; public let effectiveArrival: Date; public let transferCount: Int; public let walkingDuration: TimeInterval; public let walkingDistance: Double; public let waitingDuration: TimeInterval; public let inVehicleDuration: TimeInterval; public let legs: [JourneyLeg]; public let feedGeneration: Int; public var duration: TimeInterval { effectiveArrival.timeIntervalSince(effectiveDeparture) } }
public struct RoutingMetrics: Hashable, Sendable {
    public var pointRaptorScans = 0; public var profileGenerationMilliseconds = 0
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
private struct SnapshotTrip: Sendable { let id: String; let route: Int; let service: Int; let times: [SnapshotTime]; let headsign: String? }
private struct SnapshotRule: Sendable { let from: Int?; let to: Int?; let type: Int; let minimum: Int?; let fromRoute: Int?; let toRoute: Int?; let fromTrip: Int?; let toTrip: Int? }
private struct SnapshotPath: Sendable { let from: Int; let to: Int; let seconds: Int }
private struct RoutingSnapshot: Sendable {
    let info: FeedInfo; let converter: ServiceInstantConverter; let stops: [SnapshotStop]; let stopByID: [String: Int]; let routes: [TransitRoute]; let trips: [SnapshotTrip]; let active: [Set<Int>]; let rules: [SnapshotRule]; let paths: [SnapshotPath]
    let patterns: [[Int]]
}

private enum SnapshotBuilder {
    static func load(databaseURL: URL) throws -> RoutingSnapshot {
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
        let tripStmt = try db.prepare("SELECT id,gtfs_id,route_id,service_id,headsign FROM trip ORDER BY id"); var trips: [SnapshotTrip] = []; var tripIndex: [Int: Int] = [:]
        let timeStmt = try db.prepare("SELECT stop_id,sequence,arrival_sec,departure_sec,pickup_type,dropoff_type FROM stop_time WHERE trip_id=? ORDER BY sequence")
        while try tripStmt.step() { let sqliteTrip = tripStmt.int(0); try timeStmt.reset(); try timeStmt.bind(sqliteTrip, at: 1); var times: [SnapshotTime] = []; while try timeStmt.step() { guard let stop = sqliteStopIndex[timeStmt.int(0)] else { continue }; times.append(.init(stop: stop, sequence: timeStmt.int(1), arrival: timeStmt.isNull(2) ? nil : timeStmt.int32(2), departure: timeStmt.isNull(3) ? nil : timeStmt.int32(3), pickup: timeStmt.int(4), dropoff: timeStmt.int(5))) }; guard let route = routeIndex[tripStmt.int(2)], let service = serviceIndex[tripStmt.int(3)], times.count >= 2 else { continue }; tripIndex[sqliteTrip] = trips.count; trips.append(.init(id: tripStmt.text(1)!, route: route, service: service, times: times, headsign: tripStmt.text(4))) }
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
        var active = Array(repeating: Set<Int>(), count: info.firstServiceDate.days(until: info.lastServiceDate) + 1); let activeStmt = try db.prepare("SELECT day_index,service_id FROM service_date"); while try activeStmt.step() { let day = activeStmt.int(0); if active.indices.contains(day), let s = serviceIndex[activeStmt.int(1)] { active[day].insert(s) } }
        let rstmt = try db.prepare("SELECT from_stop_id,to_stop_id,transfer_type,min_transfer_sec,from_route_id,to_route_id,from_trip_id,to_trip_id FROM transfer_rule"); var rules: [SnapshotRule] = []; while try rstmt.step() { rules.append(.init(from: rstmt.isNull(0) ? nil : sqliteStopIndex[rstmt.int(0)], to: rstmt.isNull(1) ? nil : sqliteStopIndex[rstmt.int(1)], type: rstmt.int(2), minimum: rstmt.isNull(3) ? nil : rstmt.int(3), fromRoute: rstmt.isNull(4) ? nil : routeIndex[rstmt.int(4)], toRoute: rstmt.isNull(5) ? nil : routeIndex[rstmt.int(5)], fromTrip: rstmt.isNull(6) ? nil : tripIndex[rstmt.int(6)], toTrip: rstmt.isNull(7) ? nil : tripIndex[rstmt.int(7)])) }
        var paths: [SnapshotPath] = []; if let pstmt = try? db.prepare("SELECT from_stop_id,to_stop_id,traversal_time,is_bidirectional FROM pathway") { while try pstmt.step() { guard !pstmt.isNull(2), let a = sqliteStopIndex[pstmt.int(0)], let b = sqliteStopIndex[pstmt.int(1)] else { continue }; paths.append(.init(from: a, to: b, seconds: pstmt.int(2))); if pstmt.int(3) == 1 { paths.append(.init(from: b, to: a, seconds: pstmt.int(2))) } } }
        // Grouping by route + ordered occurrence sequence gives RAPTOR patterns,
        // never merely route_id. Families are split conservatively by an
        // overtaking check at search time (small feeds remain inexpensive).
        var grouped: [String: [Int]] = [:]; for (i,t) in trips.enumerated() { grouped["\(t.route)|\(t.times.map(\.stop).map(String.init).joined(separator: ","))", default: []].append(i) }
        return .init(info: info, converter: .init(timeZone: zone), stops: stops, stopByID: stopByID, routes: routes, trips: trips, active: active, rules: rules, paths: paths, patterns: Array(grouped.values))
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
    fileprivate init(snapshot: RoutingSnapshot, query: RouteQuery, walking: (any WalkingRoutingProvider)?, realtime: (any RealtimeRoutingProvider)?) throws { self.snapshot = snapshot; self.query = query; self.walking = walking; self.realtimeProvider = realtime; self.state = query.realtimePolicy == .disabled ? .disabled : .unavailable }
    public func initial(count: Int = 5) async throws -> JourneyPage { if all.isEmpty { all = try await generate(anchor: query.departureTime); visibleStart = 0 }; visibleEnd = min(all.count, max(0, count)); return page() }
    public func later(count: Int = 3) async throws -> JourneyPage { if all.isEmpty { _ = try await initial() }; visibleEnd = min(all.count, visibleEnd + max(0, count)); return page() }
    public func earlier(count: Int = 3) async throws -> JourneyPage { visibleStart = max(0, visibleStart - max(0, count)); return page() }
    public func refreshRealtime() async throws -> JourneyPage { all = try await generate(anchor: query.departureTime, forceRealtime: true); visibleStart = 0; visibleEnd = min(max(visibleEnd, 5), all.count); revision &+= 1; return page() }
    private func page() -> JourneyPage { .init(journeys: Array(all[visibleStart..<visibleEnd]), hasEarlier: visibleStart > 0, hasLater: visibleEnd < all.count, realtimeState: state, revision: revision, metrics: metrics) }
    private func generate(anchor: Date, forceRealtime: Bool = false) async throws -> [Journey] {
        let started = Date()
        let access = try await endpointEdges(query.origin, anchor: anchor); let egress = try await endpointEdges(query.destination, anchor: anchor)
        var patches: [RealtimeTripPatch] = []
        if case let .bestEffort(configuration) = query.realtimePolicy, let realtimeProvider {
            // Bootstrap with every access stop and the bounded, timetable
            // derived interchange frontier reachable from those first boards.
            // The backwards start is crucial: a 17:50 scheduled departure can
            // be returned and injected when its effective time is 18:05.
            let ids = realtimeFrontier(access: access, anchor: anchor, lookback: configuration.scheduledLookbackSeconds); metrics.realtimeFrontierSize = ids.count
            do { metrics.hafasRequests += 1; patches = try await realtimeProvider.patches(for: ids, from: anchor.addingTimeInterval(-TimeInterval(configuration.scheduledLookbackSeconds)), through: anchor.addingTimeInterval(TimeInterval(configuration.minimumForwardHorizonSeconds))); metrics.delayedPastBoardingsInjected += patches.reduce(0) { partial, patch in partial + patch.events.filter { ($0.scheduledDeparture ?? .distantFuture) < anchor && ($0.effectiveDeparture ?? .distantPast) >= anchor }.count }; metrics.realtimeOverlayRevisions += 1; state = .live } catch { state = .unavailable }
        }
        metrics.pointRaptorScans += 1
        let candidates = Raptor.search(snapshot: snapshot, query: query, access: access, egress: egress, patches: patches)
        var journeys = candidates.compactMap { buildJourney($0, access: access, egress: egress) }
        journeys = strictEnvelope(journeys).sorted(by: journeyOrder)
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
                let activeDays = snapshot.active.indices.filter { snapshot.active[$0].contains(trip.service) }
                if activeDays.contains(where: { snapshot.converter.date(serviceDate: snapshot.info.firstServiceDate.adding(days: $0), serviceSeconds: departure) >= anchor.addingTimeInterval(-TimeInterval(lookback)) }) {
                    result.formUnion(trip.times.map(\.stop))
                }
            }
            if result.count >= 64 { break }
        }
        return result.sorted().prefix(64).map { snapshot.stops[$0].id }
    }
    fileprivate struct Edge { let stop: Int; let seconds: Int; let distance: Double; let walk: WalkingRoute? }
    private func endpointEdges(_ endpoint: JourneyEndpoint, anchor: Date) async throws -> [Edge] {
        if case let .stop(id) = endpoint { guard let i = snapshot.stopByID[id] else { throw JourneyPlannerError.endpointNotFound }; return [.init(stop: i, seconds: 0, distance: 0, walk: nil)] }
        guard case let .coordinate(c, _) = endpoint, let walking else { throw JourneyPlannerError.endpointNotFound }
        let candidates = snapshot.stops.enumerated().sorted { distance(c, $0.element.model.coordinate) < distance(c, $1.element.model.coordinate) }.prefix(24)
        var edges: [Edge] = []; for (i,s) in candidates { metrics.walkingRequests += 1; if let route = try? await walking.route(.init(source: c, destination: s.model.coordinate, departure: anchor)) { edges.append(.init(stop: i, seconds: route.durationSeconds, distance: route.distanceMeters, walk: route)) } }; return edges
    }
    private func directWalk(anchor: Date) async throws -> Journey? { guard case let .coordinate(a,al) = query.origin, case let .coordinate(b,bl) = query.destination, let walking, let route = try? await walking.route(.init(source: a, destination: b, departure: anchor)) else { return nil }; let arrival = anchor.addingTimeInterval(TimeInterval(route.durationSeconds)); let leg = WalkingLeg(from: .init(coordinate: a, label: al), to: .init(coordinate: b, label: bl), departure: anchor, arrival: arrival, duration: TimeInterval(route.durationSeconds), distanceMeters: route.distanceMeters, polyline: route.polyline, steps: route.steps, source: .provider); return .init(id: .init("walk:\(a.latitude),\(a.longitude):\(b.latitude),\(b.longitude)"), origin: query.origin, destination: query.destination, scheduledDeparture: anchor, scheduledArrival: arrival, effectiveDeparture: anchor, effectiveArrival: arrival, transferCount: 0, walkingDuration: TimeInterval(route.durationSeconds), walkingDistance: route.distanceMeters, waitingDuration: 0, inVehicleDuration: 0, legs: [.walk(leg)], feedGeneration: snapshot.info.generation) }
    private func buildJourney(_ candidate: Raptor.Candidate, access: [Edge], egress: [Edge]) -> Journey? {
        guard let a = access.first(where: { $0.stop == candidate.firstStop }), let e = egress.first(where: { $0.stop == candidate.lastStop }) else { return nil }
        let depart = candidate.firstDeparture.addingTimeInterval(-TimeInterval(a.seconds)); let arrive = candidate.lastArrival.addingTimeInterval(TimeInterval(e.seconds)); guard depart >= query.departureTime, let firstLeg = candidate.legs.first, let lastLeg = candidate.legs.last else { return nil }
        let scheduledDepart = firstLeg.scheduledBoard.addingTimeInterval(-TimeInterval(a.seconds))
        let scheduledArrive = lastLeg.scheduledAlight.addingTimeInterval(TimeInterval(e.seconds))
        let legs = candidate.legs.map { item -> JourneyLeg in let trip = snapshot.trips[item.trip]; let board = snapshot.stops[item.board].model; let alight = snapshot.stops[item.alight].model; let b = JourneyStopEvent(stop: board, scheduledTime: item.scheduledBoard, effectiveTime: item.boardTime); let x = JourneyStopEvent(stop: alight, scheduledTime: item.scheduledAlight, effectiveTime: item.alightTime); let middle = trip.times[(item.boardPos + 1)..<item.alightPos].map { JourneyStopEvent(stop: snapshot.stops[$0.stop].model, scheduledTime: snapshot.converter.date(serviceDate: item.day, serviceSeconds: $0.arrival ?? $0.departure ?? 0), effectiveTime: snapshot.converter.date(serviceDate: item.day, serviceSeconds: $0.arrival ?? $0.departure ?? 0)) }; return .transit(.init(tripID: trip.id, route: snapshot.routes[trip.route], headsign: trip.headsign, board: b, alight: x, intermediateStops: Array(middle), scheduledDeparture: item.scheduledBoard, scheduledArrival: item.scheduledAlight, effectiveDeparture: item.boardTime, effectiveArrival: item.alightTime)) }
        let signature = candidate.legs.map { "\(snapshot.trips[$0.trip].id):\($0.boardPos)-\($0.alightPos):\($0.day.compactString)" }.joined(separator: "|")
        return .init(id: .init(signature), origin: query.origin, destination: query.destination, scheduledDeparture: scheduledDepart, scheduledArrival: scheduledArrive, effectiveDeparture: depart, effectiveArrival: arrive, transferCount: max(0, candidate.legs.count - 1), walkingDuration: TimeInterval(a.seconds + e.seconds), walkingDistance: a.distance + e.distance, waitingDuration: 0, inVehicleDuration: candidate.legs.reduce(0) { $0 + $1.alightTime.timeIntervalSince($1.boardTime) }, legs: legs, feedGeneration: snapshot.info.generation)
    }
}

private enum Raptor {
    struct Leg { let trip: Int; let board: Int; let alight: Int; let boardPos: Int; let alightPos: Int; let day: GTFSDate; let scheduledBoard: Date; let scheduledAlight: Date; let boardTime: Date; let alightTime: Date }
    struct Candidate { let legs: [Leg]; let firstStop: Int; let lastStop: Int; let firstDeparture: Date; let lastArrival: Date }
    private struct Label { let time: Date; let legs: [Leg]; let firstStop: Int; let firstDeparture: Date }
    static func search(snapshot: RoutingSnapshot, query: RouteQuery, access: [JourneyPlanningSession.Edge], egress: [JourneyPlanningSession.Edge], patches: [RealtimeTripPatch]) -> [Candidate] {
        guard !access.isEmpty, !egress.isEmpty else { return [] }
        let maxRounds = (query.preferences.maxTransfers ?? max(1, snapshot.trips.count)) + 1
        var labels: [Int: Label] = [:]; for a in access { labels[a.stop] = .init(time: query.departureTime.addingTimeInterval(TimeInterval(a.seconds)), legs: [], firstStop: a.stop, firstDeparture: query.departureTime.addingTimeInterval(TimeInterval(a.seconds))) }
        var destination: [Candidate] = []
        for _ in 0..<maxRounds { var next: [Int: Label] = [:]
            // Patterns are constructed from route + ordered stop occurrences;
            // scanning each family once per round is the RAPTOR unit of work.
            for family in snapshot.patterns { for tripIndex in family { let trip = snapshot.trips[tripIndex]; guard query.preferences.allowedModes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
                for dayOffset in snapshot.active.indices where snapshot.active[dayOffset].contains(trip.service) { let day = snapshot.info.firstServiceDate.adding(days: dayOffset); let patch = patches.first { $0.tripID == trip.id && $0.serviceDate == day }; guard patch?.status != .cancelled && patch?.status != .unreachable else { continue }
                    for boardPos in trip.times.indices { let bt = trip.times[boardPos]; guard let depart = bt.departure, bt.pickup == 0 else { continue }; guard let source = labels[bt.stop] else { continue }; let scheduled = snapshot.converter.date(serviceDate: day, serviceSeconds: depart); let effective = patchTime(patch, stop: snapshot.stops[bt.stop].id, departure: true) ?? scheduled; guard let transfer = transferDecision(snapshot: snapshot, incoming: source.legs.last, at: bt.stop, outgoing: tripIndex, preferences: query.preferences), effective >= source.time.addingTimeInterval(TimeInterval(source.legs.isEmpty ? 0 : transfer)) else { continue }
                        for alightPos in (boardPos + 1)..<trip.times.count { let at = trip.times[alightPos]; guard at.dropoff == 0, let arrival = at.arrival else { continue }; let schedArrival = snapshot.converter.date(serviceDate: day, serviceSeconds: arrival); let effectiveArrival = patchTime(patch, stop: snapshot.stops[at.stop].id, departure: false) ?? schedArrival; let leg = Leg(trip: tripIndex, board: bt.stop, alight: at.stop, boardPos: boardPos, alightPos: alightPos, day: day, scheduledBoard: scheduled, scheduledAlight: schedArrival, boardTime: effective, alightTime: effectiveArrival); let label = Label(time: effectiveArrival, legs: source.legs + [leg], firstStop: source.firstStop, firstDeparture: source.legs.isEmpty ? effective : source.firstDeparture); if next[at.stop].map({ $0.time <= label.time }) != true { next[at.stop] = label } }
                    }
                }
            } }
            // Internal pathways are explicit GTFS footpaths, so they remain
            // usable without MapKit and never use geometric invented timings.
            for path in snapshot.paths { if let l = next[path.from] { let candidate = Label(time: l.time.addingTimeInterval(TimeInterval(path.seconds)), legs: l.legs, firstStop: l.firstStop, firstDeparture: l.firstDeparture); if next[path.to].map({ $0.time <= candidate.time }) != true { next[path.to] = candidate } } }
            for e in egress { if let l = next[e.stop] { destination.append(.init(legs: l.legs, firstStop: l.firstStop, lastStop: e.stop, firstDeparture: l.firstDeparture, lastArrival: l.time)) } }
            labels = next; if labels.isEmpty { break }
        }
        var seen = Set<String>(); return destination.filter { !$0.legs.isEmpty && seen.insert($0.legs.map { "\($0.trip)-\($0.boardPos)-\($0.alightPos)-\($0.day.compactString)" }.joined(separator: "|")).inserted }
    }
    private static func patchTime(_ patch: RealtimeTripPatch?, stop: String, departure: Bool) -> Date? { guard let event = patch?.events.first(where: { $0.stopID == stop }) else { return nil }; return departure ? event.effectiveDeparture : event.effectiveArrival }
    /// Resolves the single maximally-specific GTFS transfer rule. Returning nil
    /// means type 3 forbids the operation. This is intentionally centralised so
    /// numerical scan code cannot accidentally apply several conflicting rules.
    private static func transferDecision(snapshot: RoutingSnapshot, incoming: Leg?, at stop: Int, outgoing: Int, preferences: RoutingPreferences) -> Int? {
        guard let incoming else { return 0 }
        let inTrip = snapshot.trips[incoming.trip], outTrip = snapshot.trips[outgoing]
        func equivalent(_ ruleStop: Int?, _ actual: Int) -> Bool {
            guard let ruleStop else { return true }
            if ruleStop == actual { return true }
            let ruleID = snapshot.stops[ruleStop].id
            return snapshot.stops[actual].parent == ruleID || snapshot.stops[ruleStop].parent == snapshot.stops[actual].parent && snapshot.stops[actual].parent != nil
        }
        func applies(_ rule: SnapshotRule) -> Bool {
            guard equivalent(rule.from, incoming.alight), equivalent(rule.to, stop) else { return false }
            guard rule.fromTrip == nil || rule.fromTrip == incoming.trip, rule.toTrip == nil || rule.toTrip == outgoing else { return false }
            return (rule.fromRoute == nil || rule.fromRoute == inTrip.route) && (rule.toRoute == nil || rule.toRoute == outTrip.route)
        }
        func score(_ rule: SnapshotRule) -> Int { if rule.fromTrip != nil && rule.toTrip != nil { return 60 }; if rule.fromTrip != nil || rule.toTrip != nil { return (rule.fromRoute != nil || rule.toRoute != nil) ? 50 : 40 }; if rule.fromRoute != nil && rule.toRoute != nil { return 30 }; if rule.fromRoute != nil || rule.toRoute != nil { return 20 }; return 10 }
        guard let rule = snapshot.rules.filter(applies).max(by: { score($0) < score($1) }) else { return preferences.minimumTransferSeconds }
        switch rule.type { case 3: return nil; case 1, 4: return 0; case 2: return max(preferences.minimumTransferSeconds, rule.minimum ?? 0); default: return preferences.minimumTransferSeconds }
    }
}

private func strictEnvelope(_ journeys: [Journey]) -> [Journey] { journeys.filter { b in !journeys.contains { a in a.id != b.id && a.effectiveDeparture > b.effectiveDeparture && a.effectiveArrival < b.effectiveArrival } } }
private func journeyOrder(_ a: Journey, _ b: Journey) -> Bool { (a.effectiveDeparture, a.effectiveArrival, a.transferCount, a.walkingDuration, a.duration, a.id) < (b.effectiveDeparture, b.effectiveArrival, b.transferCount, b.walkingDuration, b.duration, b.id) }
private func distance(_ a: Coordinate, _ b: Coordinate) -> Double { let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180, dp = q-p, dl = (b.longitude-a.longitude) * .pi / 180; let x = sin(dp/2)*sin(dp/2)+cos(p)*cos(q)*sin(dl/2)*sin(dl/2); return 6_371_000 * 2 * atan2(sqrt(x),sqrt(1-x)) }
