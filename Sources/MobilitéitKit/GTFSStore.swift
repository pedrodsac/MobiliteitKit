import Foundation

/// Actor-isolated access to an installed Mobilitéit GTFS database.
/// All public methods return small, value-typed models and issue bounded SQLite
/// queries; the source archive is never loaded into memory at runtime.
public actor GTFSStore {
    private let database: SQLiteDatabase
    private let installedFeedInfo: FeedInfo

    /// Opens an installed database for read-only, actor-isolated queries.
    ///
    /// - Parameter databaseURL: The SQLite database produced by
    ///   ``GTFSArchiveInstaller``.
    /// - Throws: If the database cannot be opened or its feed metadata is
    ///   incomplete.
    public init(databaseAt databaseURL: URL) throws {
        database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
        installedFeedInfo = try Self.loadFeedInfo(from: database)
    }

    /// Returns metadata for the feed currently opened by this store.
    public func feedInfo() -> FeedInfo { installedFeedInfo }

    /// Converts a GTFS calendar date into the feed's zero-based service-day index.
    ///
    /// Returns `nil` when the date falls outside the installed feed range.
    public func serviceDay(for date: GTFSDate) -> ServiceDay? {
        let offset = installedFeedInfo.firstServiceDate.days(until: date)
        guard offset >= 0, date <= installedFeedInfo.lastServiceDate else { return nil }
        return ServiceDay(index: Int32(offset))
    }

    /// Converts a service-day index back into its GTFS calendar date.
    ///
    /// Returns `nil` when the index is outside the installed feed range.
    public func date(for serviceDay: ServiceDay) -> GTFSDate? {
        guard serviceDay.index >= 0,
              serviceDay.index <= installedFeedInfo.firstServiceDate.days(until: installedFeedInfo.lastServiceDate) else {
            return nil
        }
        return installedFeedInfo.firstServiceDate.adding(days: Int(serviceDay.index))
    }

    /// Looks up one agency by its source GTFS identifier.
    public func agency(id: String) throws -> Agency? {
        let statement = try database.prepare("SELECT gtfs_id,name,url,timezone,language,phone FROM agency WHERE gtfs_id = ?")
        try statement.bind(id, at: 1)
        return try statement.step() ? Self.agency(from: statement, at: 0) : nil
    }

    /// Returns all agencies ordered by display name and source identifier.
    public func agencies() throws -> [Agency] {
        let statement = try database.prepare("SELECT gtfs_id,name,url,timezone,language,phone FROM agency ORDER BY name,gtfs_id")
        var result: [Agency] = []
        while try statement.step() { result.append(Self.agency(from: statement, at: 0)) }
        return result
    }

    /// Looks up one route by its source GTFS identifier.
    public func route(id: String) throws -> TransitRoute? {
        let statement = try database.prepare("""
            SELECT r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
            FROM route r LEFT JOIN agency a ON a.id=r.agency_id WHERE r.gtfs_id = ?
        """)
        try statement.bind(id, at: 1)
        return try statement.step() ? Self.route(from: statement, at: 0) : nil
    }

    /// Returns routes, optionally filtered by agency and GTFS route type.
    /// Results are ordered by short name and capped by `limit`.
    public func routes(agencyID: String? = nil, routeType: Int? = nil, limit: Int = 1_000) throws -> [TransitRoute] {
        let safeLimit = max(0, min(limit, 10_000))
        guard safeLimit > 0 else { return [] }
        let statement: SQLiteStatement
        switch (agencyID, routeType) {
        case let (.some(agencyID), .some(routeType)):
            statement = try database.prepare("""
                SELECT r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
                FROM route r LEFT JOIN agency a ON a.id=r.agency_id
                WHERE a.gtfs_id=? AND r.route_type=? ORDER BY r.short_name, r.gtfs_id LIMIT ?
            """)
            try statement.bind(agencyID, at: 1); try statement.bind(routeType, at: 2); try statement.bind(safeLimit, at: 3)
        case let (.some(agencyID), .none):
            statement = try database.prepare("""
                SELECT r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
                FROM route r LEFT JOIN agency a ON a.id=r.agency_id
                WHERE a.gtfs_id=? ORDER BY r.short_name, r.gtfs_id LIMIT ?
            """)
            try statement.bind(agencyID, at: 1); try statement.bind(safeLimit, at: 2)
        case let (.none, .some(routeType)):
            statement = try database.prepare("""
                SELECT r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
                FROM route r LEFT JOIN agency a ON a.id=r.agency_id
                WHERE r.route_type=? ORDER BY r.short_name, r.gtfs_id LIMIT ?
            """)
            try statement.bind(routeType, at: 1); try statement.bind(safeLimit, at: 2)
        case (.none, .none):
            statement = try database.prepare("""
                SELECT r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
                FROM route r LEFT JOIN agency a ON a.id=r.agency_id
                ORDER BY r.short_name, r.gtfs_id LIMIT ?
            """)
            try statement.bind(safeLimit, at: 1)
        }
        var result: [TransitRoute] = []
        while try statement.step() { result.append(Self.route(from: statement, at: 0)) }
        return result
    }

    /// Returns the distinct routes serving each requested stop.
    ///
    /// The lookup is independent of a service date so callers can classify
    /// stops without issuing one timetable query per stop. Input identifiers
    /// are deduplicated and capped at 500 to stay within the store's bounded
    /// query contract.
    public func routes(servingStopIDs stopIDs: [String]) throws -> [String: [TransitRoute]] {
        var seen: Set<String> = []
        let identifiers = stopIDs
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(500)
        guard !identifiers.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        let statement = try database.prepare("""
            SELECT DISTINCT s.gtfs_id,
                   r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description
            FROM stop s
            JOIN stop_time st ON st.stop_id=s.id
            JOIN trip t ON t.id=st.trip_id
            JOIN route r ON r.id=t.route_id
            LEFT JOIN agency a ON a.id=r.agency_id
            WHERE s.gtfs_id IN (\(placeholders))
            ORDER BY s.gtfs_id, r.short_name, r.long_name, r.gtfs_id
        """)
        for (offset, identifier) in identifiers.enumerated() {
            try statement.bind(identifier, at: Int32(offset + 1))
        }

        var result: [String: [TransitRoute]] = [:]
        while try statement.step() {
            guard let stopID = statement.text(0) else { continue }
            result[stopID, default: []].append(Self.route(from: statement, at: 1))
        }
        return result
    }

    /// Looks up one stop by its source GTFS identifier.
    public func stop(id: String) throws -> TransitStop? {
        let statement = try database.prepare(Self.stopSelect + " WHERE gtfs_id = ?")
        try statement.bind(id, at: 1)
        return try statement.step() ? Self.stop(from: statement, at: 0) : nil
    }

    /// Prefix search that folds case and diacritics without changing display text.
    /// The implementation also supports natural substring matches.
    public func searchStops(matching query: String, limit: Int = 30) throws -> [TransitStop] {
        let safeLimit = max(0, min(limit, 500))
        let normalized = Self.normalizeSearch(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeLimit > 0, !normalized.isEmpty else { return [] }
        // The feed has only ~2,800 stops. A small disk scan permits natural
        // substring matching ("eto" → "Gare Étoile") without an FTS tokenizer
        // changing or losing source text.
        let statement = try database.prepare(Self.stopSelect + " WHERE instr(search_name, ?) > 0 ORDER BY search_name, gtfs_id LIMIT ?")
        try statement.bind(normalized, at: 1); try statement.bind(safeLimit, at: 2)
        var result: [TransitStop] = []
        while try statement.step() { result.append(Self.stop(from: statement, at: 0)) }
        return result
    }

    /// Finds stops via the R-tree bounding box, then applies an exact distance
    /// calculation to the small candidate set.
    /// Results are sorted from nearest to farthest.
    public func nearbyStops(
        to coordinate: Coordinate,
        withinMeters radius: Double,
        limit: Int = 30
    ) throws -> [TransitStop] {
        guard radius >= 0, radius.isFinite else { return [] }
        let safeLimit = max(0, min(limit, 500))
        guard safeLimit > 0 else { return [] }
        let latitudeDelta = radius / 111_320
        let longitudeDelta = radius / max(1, 111_320 * cos(coordinate.latitude * .pi / 180))
        let statement = try database.prepare("""
            SELECT s.gtfs_id,s.code,s.name,s.stop_description,s.lat_e6,s.lon_e6,s.location_type,s.parent_station_id,s.wheelchair_boarding,s.platform_code
            FROM stop_spatial p JOIN stop s ON s.id=p.id
            WHERE p.min_lat <= ? AND p.max_lat >= ? AND p.min_lon <= ? AND p.max_lon >= ?
        """)
        try statement.bind(coordinate.latitude + latitudeDelta, at: 1)
        try statement.bind(coordinate.latitude - latitudeDelta, at: 2)
        try statement.bind(coordinate.longitude + longitudeDelta, at: 3)
        try statement.bind(coordinate.longitude - longitudeDelta, at: 4)

        var results: [(TransitStop, Double)] = []
        while try statement.step() {
            let stop = Self.stop(from: statement, at: 0)
            let distance = Self.distanceMeters(from: coordinate, to: stop.coordinate)
            if distance <= radius { results.append((stop, distance)) }
        }
        return results.sorted { $0.1 < $1.1 }.prefix(safeLimit).map(\.0)
    }

    /// Looks up one trip by its source GTFS identifier.
    public func trip(id: String) throws -> TransitTrip? {
        let statement = try database.prepare("""
            SELECT t.gtfs_id,r.gtfs_id,s.gtfs_id,t.headsign,t.short_name,t.direction_id,t.block_id,sh.gtfs_id,t.wheelchair_accessible,t.bikes_allowed
            FROM trip t JOIN route r ON r.id=t.route_id JOIN service s ON s.id=t.service_id
            LEFT JOIN shape sh ON sh.id=t.shape_id WHERE t.gtfs_id=?
        """)
        try statement.bind(id, at: 1)
        return try statement.step() ? Self.trip(from: statement, at: 0) : nil
    }

    /// Returns trips on a route, optionally constrained by service date and direction.
    public func trips(
        forRouteID routeID: String,
        activeOn date: GTFSDate? = nil,
        directionID: Int? = nil,
        limit: Int = 500
    ) throws -> [TransitTrip] {
        let safeLimit = max(0, min(limit, 10_000))
        guard safeLimit > 0 else { return [] }
        if let date, serviceDay(for: date) == nil { return [] }
        let statement: SQLiteStatement
        switch (date.flatMap(serviceDay(for:)), directionID) {
        case let (.some(day), .some(direction)):
            statement = try database.prepare(Self.tripSelect + " JOIN service_date sd ON sd.service_id=t.service_id WHERE r.gtfs_id=? AND sd.day_index=? AND t.direction_id=? ORDER BY t.headsign,t.gtfs_id LIMIT ?")
            try statement.bind(routeID, at: 1); try statement.bind(day.index, at: 2); try statement.bind(direction, at: 3); try statement.bind(safeLimit, at: 4)
        case let (.some(day), .none):
            statement = try database.prepare(Self.tripSelect + " JOIN service_date sd ON sd.service_id=t.service_id WHERE r.gtfs_id=? AND sd.day_index=? ORDER BY t.direction_id,t.headsign,t.gtfs_id LIMIT ?")
            try statement.bind(routeID, at: 1); try statement.bind(day.index, at: 2); try statement.bind(safeLimit, at: 3)
        case let (.none, .some(direction)):
            statement = try database.prepare(Self.tripSelect + " WHERE r.gtfs_id=? AND t.direction_id=? ORDER BY t.headsign,t.gtfs_id LIMIT ?")
            try statement.bind(routeID, at: 1); try statement.bind(direction, at: 2); try statement.bind(safeLimit, at: 3)
        case (.none, .none):
            statement = try database.prepare(Self.tripSelect + " WHERE r.gtfs_id=? ORDER BY t.direction_id,t.headsign,t.gtfs_id LIMIT ?")
            try statement.bind(routeID, at: 1); try statement.bind(safeLimit, at: 2)
        }
        var result: [TransitTrip] = []
        while try statement.step() { result.append(Self.trip(from: statement, at: 0)) }
        return result
    }

    /// Returns the regular weekly calendar rule for a service identifier.
    public func calendar(forServiceID serviceID: String) throws -> ServiceCalendar? {
        let statement = try database.prepare("""
            SELECT s.gtfs_id,c.monday,c.tuesday,c.wednesday,c.thursday,c.friday,c.saturday,c.sunday,c.start_date,c.end_date
            FROM calendar_rule c JOIN service s ON s.id=c.service_id WHERE s.gtfs_id=?
        """)
        try statement.bind(serviceID, at: 1)
        guard try statement.step() else { return nil }
        return ServiceCalendar(
            serviceID: statement.text(0)!, weekdays: (1...7).map { statement.int(Int32($0)) },
            startDate: try GTFSDate(parsing: statement.text(8)!), endDate: try GTFSDate(parsing: statement.text(9)!)
        )
    }

    /// Returns calendar-date additions and removals for a service identifier.
    public func calendarExceptions(forServiceID serviceID: String) throws -> [CalendarException] {
        let statement = try database.prepare("""
            SELECT s.gtfs_id,c.date,c.exception_type FROM calendar_exception c
            JOIN service s ON s.id=c.service_id WHERE s.gtfs_id=? ORDER BY c.date
        """)
        try statement.bind(serviceID, at: 1)
        var result: [CalendarException] = []
        while try statement.step() {
            result.append(CalendarException(serviceID: statement.text(0)!, date: try GTFSDate(parsing: statement.text(1)!), exceptionType: statement.int(2)))
        }
        return result
    }

    /// Returns a trip's stop times in increasing stop-sequence order.
    public func stopTimes(forTripID tripID: String) throws -> [TripStopTime] {
        let statement = try database.prepare("""
            SELECT t.gtfs_id,s.gtfs_id,s.code,s.name,s.stop_description,s.lat_e6,s.lon_e6,s.location_type,s.parent_station_id,s.wheelchair_boarding,s.platform_code,
                   st.sequence,st.arrival_sec,st.departure_sec,st.stop_headsign,st.pickup_type,st.dropoff_type
            FROM stop_time st JOIN trip t ON t.id=st.trip_id JOIN stop s ON s.id=st.stop_id
            WHERE t.gtfs_id=? ORDER BY st.sequence
        """)
        try statement.bind(tripID, at: 1)
        var result: [TripStopTime] = []
        while try statement.step() {
            let stop = Self.stop(from: statement, at: 1)
            result.append(TripStopTime(
                tripID: statement.text(0)!, stop: stop, sequence: statement.int(11),
                arrival: statement.isNull(12) ? nil : ServiceTime(rawValue: statement.int32(12)),
                departure: statement.isNull(13) ? nil : ServiceTime(rawValue: statement.int32(13)),
                stopHeadsign: statement.text(14), pickupType: statement.int(15), dropOffType: statement.int(16)
            ))
        }
        return result
    }

    /// Decodes a stored shape into its ordered coordinates.
    public func shape(id: String) throws -> Shape? {
        let statement = try database.prepare("SELECT gtfs_id,encoded FROM shape WHERE gtfs_id=?")
        try statement.bind(id, at: 1)
        guard try statement.step(), let blob = statement.blob(1) else { return nil }
        return Shape(id: statement.text(0)!, coordinates: try ShapeCodec.decode(blob))
    }

    /// Returns shapes for the small set of trips selected by journey planning.
    /// Shared GTFS shapes are decoded once even when several trips use them.
    public func shapes(forTripIDs tripIDs: [String]) throws -> [String: [Coordinate]] {
        let identifiers = Array(Set(tripIDs.filter { !$0.isEmpty })).sorted()
        guard !identifiers.isEmpty else { return [:] }
        var shapesByTrip: [String: [Coordinate]] = [:]
        var decodedByShapeID: [Int: [Coordinate]] = [:]
        for start in stride(from: 0, to: identifiers.count, by: 500) {
            let batch = Array(identifiers[start..<min(start + 500, identifiers.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try database.prepare("""
                SELECT t.gtfs_id,sh.id,sh.encoded FROM trip t
                JOIN shape sh ON sh.id=t.shape_id
                WHERE t.gtfs_id IN (\(placeholders))
            """)
            for (offset, id) in batch.enumerated() {
                try statement.bind(id, at: Int32(offset + 1))
            }
            while try statement.step() {
                guard let tripID = statement.text(0) else { continue }
                let shapeID = statement.int(1)
                if let decoded = decodedByShapeID[shapeID] {
                    shapesByTrip[tripID] = decoded
                } else if let blob = statement.blob(2), let decoded = try? ShapeCodec.decode(blob) {
                    decodedByShapeID[shapeID] = decoded
                    shapesByTrip[tripID] = decoded
                }
            }
        }
        return shapesByTrip
    }

    /// Returns source transfer rules whose origin is the supplied stop.
    public func transferRules(fromStopID stopID: String) throws -> [TransferRule] {
        let statement = try database.prepare("""
            SELECT fs.gtfs_id,ts.gtfs_id,tr.transfer_type,tr.min_transfer_sec,fr.gtfs_id,tor.gtfs_id,ft.gtfs_id,tt.gtfs_id
            FROM transfer_rule tr JOIN stop fs ON fs.id=tr.from_stop_id JOIN stop ts ON ts.id=tr.to_stop_id
            LEFT JOIN route fr ON fr.id=tr.from_route_id LEFT JOIN route tor ON tor.id=tr.to_route_id
            LEFT JOIN trip ft ON ft.id=tr.from_trip_id LEFT JOIN trip tt ON tt.id=tr.to_trip_id
            WHERE fs.gtfs_id=?
        """)
        try statement.bind(stopID, at: 1)
        var result: [TransferRule] = []
        while try statement.step() {
            result.append(TransferRule(
                fromStopID: statement.text(0)!, toStopID: statement.text(1)!, transferType: statement.int(2),
                minimumTransferSeconds: statement.isNull(3) ? nil : statement.int(3), fromRouteID: statement.text(4),
                toRouteID: statement.text(5), fromTripID: statement.text(6), toTripID: statement.text(7)
            ))
        }
        return result
    }

    /// Returns frequency-based service intervals for a trip.
    public func frequencies(forTripID tripID: String) throws -> [Frequency] {
        let statement = try database.prepare("""
            SELECT t.gtfs_id,f.start_sec,f.end_sec,f.headway_sec,f.exact_times
            FROM frequency f JOIN trip t ON t.id=f.trip_id WHERE t.gtfs_id=? ORDER BY f.start_sec
        """)
        try statement.bind(tripID, at: 1)
        var result: [Frequency] = []
        while try statement.step() {
            result.append(Frequency(
                tripID: statement.text(0)!, startTime: ServiceTime(rawValue: statement.int32(1)),
                endTime: ServiceTime(rawValue: statement.int32(2)), headwaySeconds: statement.int(3),
                exactTimes: statement.isNull(4) ? nil : statement.int(4)
            ))
        }
        return result
    }

    /// Returns boardable scheduled departures for a specific GTFS service date.
    /// This does not make realtime claims; overlay `MobiliteitAPIClient` results
    /// separately when the caller has a HAFAS API key.
    public func scheduledDepartures(
        fromStopID stopID: String,
        on date: GTFSDate,
        notBefore time: ServiceTime = .init(rawValue: 0),
        limit: Int = 30
    ) throws -> [ScheduledDeparture] {
        guard let day = serviceDay(for: date) else { return [] }
        return try scheduleEvents(
            atStopID: stopID, day: day, lowerBound: time.rawValue,
            upperBound: installedFeedInfo.maximumServiceTime.rawValue, departure: true, limit: limit
        )
    }

    /// Returns alightable scheduled arrivals for a specific GTFS service date.
    /// Arrival values can be after 24:00 when the source feed assigns them to
    /// the preceding service day.
    public func scheduledArrivals(
        atStopID stopID: String,
        on date: GTFSDate,
        notBefore time: ServiceTime = .init(rawValue: 0),
        limit: Int = 30
    ) throws -> [ScheduledDeparture] {
        guard let day = serviceDay(for: date) else { return [] }
        return try scheduleEvents(
            atStopID: stopID, day: day, lowerBound: time.rawValue,
            upperBound: installedFeedInfo.maximumServiceTime.rawValue, departure: false, limit: limit
        )
    }

    /// Queries the timeline as service-day seconds, including previous-day trips
    /// encoded after 24:00. This avoids both midnight and DST conversion bugs.
    /// The supplied `Date` is interpreted in the timezone from the installed
    /// agency data.
    public func nextScheduledDepartures(
        fromStopID stopID: String,
        at date: Date = Date(),
        horizon: TimeInterval = 4 * 60 * 60,
        limit: Int = 30
	) throws -> [ScheduledDeparture] {
		guard horizon >= 0, horizon.isFinite, limit > 0 else { return [] }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try feedTimeZone()
		let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
		guard let year = startComponents.year, let month = startComponents.month, let day = startComponents.day,
			  let hour = startComponents.hour, let minute = startComponents.minute, let second = startComponents.second else {
			return []
		}
		let wallDate = try GTFSDate(year: year, month: month, day: day)
		let wallSeconds = Int64(hour * 3_600 + minute * 60 + second)
		let startAbsolute = Int64(installedFeedInfo.firstServiceDate.days(until: wallDate)) * 86_400 + wallSeconds
		let endAbsolute = startAbsolute + Int64(horizon.rounded(.up))
		let firstCandidateDay = Int(floor(Double(startAbsolute) / 86_400.0)) - 1
		let lastCandidateDay = Int(floor(Double(endAbsolute) / 86_400.0))
		var events: [(ScheduledDeparture, Int64)] = []
		
		let max = max(0, firstCandidateDay)
		let min = min(lastCandidateDay, installedFeedInfo.firstServiceDate.days(until: installedFeedInfo.lastServiceDate))
		
		let range: ClosedRange<Int>
		
		if max > min {
			range = min...max
		} else {
			range = max...min
		}
		
		for dayIndex in range {
            let base = Int64(dayIndex) * 86_400
			let lower = Swift.max(Int64(0), startAbsolute - base)
			let upper = Swift.min(Int64(installedFeedInfo.maximumServiceTime.rawValue), endAbsolute - base)
            guard lower <= upper else { continue }
            let day = ServiceDay(index: Int32(dayIndex))
            let values = try scheduleEvents(
                atStopID: stopID, day: day, lowerBound: Int32(lower), upperBound: Int32(upper), departure: true, limit: limit
            )
            events += values.compactMap { event in
                guard let departure = event.departure else { return nil }
                return (event, base + Int64(departure.rawValue))
            }
        }
        return events.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// Reports whether a service identifier is active on a GTFS calendar date.
    public func isServiceActive(_ serviceID: String, on date: GTFSDate) throws -> Bool {
        guard let day = serviceDay(for: date) else { return false }
        let statement = try database.prepare("""
            SELECT 1 FROM service_date sd JOIN service s ON s.id=sd.service_id
            WHERE s.gtfs_id=? AND sd.day_index=? LIMIT 1
        """)
        try statement.bind(serviceID, at: 1); try statement.bind(day.index, at: 2)
        return try statement.step()
    }

    private func scheduleEvents(
        atStopID stopID: String,
        day: ServiceDay,
        lowerBound: Int32,
        upperBound: Int32,
        departure: Bool,
        limit: Int
    ) throws -> [ScheduledDeparture] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0, lowerBound <= upperBound else { return [] }
        let timeColumn = departure ? "departure_sec" : "arrival_sec"
        let restrictionColumn = departure ? "pickup_type" : "dropoff_type"
        let onwardStopRequirement = departure
            ? "AND EXISTS (SELECT 1 FROM stop_time onward WHERE onward.trip_id=st.trip_id AND onward.sequence>st.sequence)"
            : ""
        let statement = try database.prepare("""
            SELECT t.gtfs_id,r.gtfs_id,a.gtfs_id,r.short_name,r.long_name,r.route_type,r.color,r.text_color,r.route_description,
                   a.name,a.url,a.timezone,a.language,a.phone,t.headsign,t.direction_id,st.arrival_sec,st.departure_sec,st.pickup_type,st.dropoff_type,
                   s.platform_code
            FROM stop_time st JOIN stop s ON s.id=st.stop_id JOIN trip t ON t.id=st.trip_id JOIN route r ON r.id=t.route_id
            JOIN service_date sd ON sd.service_id=t.service_id LEFT JOIN agency a ON a.id=r.agency_id
            WHERE st.stop_id=(SELECT id FROM stop WHERE gtfs_id=?) AND sd.day_index=?
              AND st.\(timeColumn) BETWEEN ? AND ? AND st.\(restrictionColumn) != 1
              \(onwardStopRequirement)
            ORDER BY st.\(timeColumn), t.gtfs_id LIMIT ?
        """)
        try statement.bind(stopID, at: 1); try statement.bind(day.index, at: 2)
        try statement.bind(lowerBound, at: 3); try statement.bind(upperBound, at: 4); try statement.bind(safeLimit, at: 5)
        var result: [ScheduledDeparture] = []
        while try statement.step() {
            let route = TransitRoute(
                id: statement.text(1)!, agencyID: statement.text(2), shortName: statement.text(3), longName: statement.text(4),
                type: statement.int(5), color: statement.text(6), textColor: statement.text(7), routeDescription: statement.text(8)
            )
            let agency: Agency? = statement.text(2).map { id in
                Agency(id: id, name: statement.text(9)!, url: statement.text(10), timeZone: statement.text(11)!, language: statement.text(12), phone: statement.text(13))
            }
            result.append(ScheduledDeparture(
                tripID: statement.text(0)!, stopID: stopID, platformCode: statement.text(20), route: route, agency: agency,
                headsign: statement.text(14), directionID: statement.isNull(15) ? nil : statement.int(15),
                arrival: statement.isNull(16) ? nil : ServiceTime(rawValue: statement.int32(16)),
                departure: statement.isNull(17) ? nil : ServiceTime(rawValue: statement.int32(17)),
                pickupType: statement.int(18), dropOffType: statement.int(19), serviceDay: day
            ))
        }
        return result
    }

    private func feedTimeZone() throws -> TimeZone {
        let statement = try database.prepare("SELECT timezone FROM agency LIMIT 1")
        guard try statement.step(), let identifier = statement.text(0), let zone = TimeZone(identifier: identifier) else {
            return TimeZone(identifier: "Europe/Berlin")!
        }
        return zone
    }
}

private extension GTFSStore {
    static let stopSelect = "SELECT gtfs_id,code,name,stop_description,lat_e6,lon_e6,location_type,parent_station_id,wheelchair_boarding,platform_code FROM stop"
    static let tripSelect = """
        SELECT t.gtfs_id,r.gtfs_id,s.gtfs_id,t.headsign,t.short_name,t.direction_id,t.block_id,sh.gtfs_id,t.wheelchair_accessible,t.bikes_allowed
        FROM trip t JOIN route r ON r.id=t.route_id JOIN service s ON s.id=t.service_id LEFT JOIN shape sh ON sh.id=t.shape_id
    """

    static func loadFeedInfo(from database: SQLiteDatabase) throws -> FeedInfo {
        let statement = try database.prepare("SELECT key,value FROM metadata WHERE key IN ('feed_start','feed_end','maximum_service_time','generation')")
        var values: [String: String] = [:]
        while try statement.step() { values[statement.text(0)!] = statement.text(1)! }
        guard let start = values["feed_start"], let end = values["feed_end"],
              let maximum = values["maximum_service_time"].flatMap(Int32.init),
              let generation = values["generation"].flatMap(Int.init) else {
            throw GTFSArchiveError.database("Database is not a completed Mobilitéit GTFS store")
        }
        return FeedInfo(
            firstServiceDate: try GTFSDate(parsing: start), lastServiceDate: try GTFSDate(parsing: end),
            maximumServiceTime: ServiceTime(rawValue: maximum), generation: generation
        )
    }

    static func agency(from statement: SQLiteStatement, at offset: Int32) -> Agency {
        Agency(
            id: statement.text(offset)!, name: statement.text(offset + 1)!, url: statement.text(offset + 2),
            timeZone: statement.text(offset + 3)!, language: statement.text(offset + 4), phone: statement.text(offset + 5)
        )
    }

    static func route(from statement: SQLiteStatement, at offset: Int32) -> TransitRoute {
        TransitRoute(
            id: statement.text(offset)!, agencyID: statement.text(offset + 1), shortName: statement.text(offset + 2),
            longName: statement.text(offset + 3), type: statement.int(offset + 4), color: statement.text(offset + 5),
            textColor: statement.text(offset + 6), routeDescription: statement.text(offset + 7)
        )
    }

    static func stop(from statement: SQLiteStatement, at offset: Int32) -> TransitStop {
        TransitStop(
            id: statement.text(offset)!, code: statement.text(offset + 1), name: statement.text(offset + 2)!,
            stopDescription: statement.text(offset + 3),
            coordinate: Coordinate(latitude: Double(statement.int64(offset + 4)) / 1_000_000, longitude: Double(statement.int64(offset + 5)) / 1_000_000),
            locationType: statement.int(offset + 6), parentStationID: statement.text(offset + 7),
            wheelchairBoarding: statement.int(offset + 8), platformCode: statement.text(offset + 9)
        )
    }

    static func trip(from statement: SQLiteStatement, at offset: Int32) -> TransitTrip {
        TransitTrip(
            id: statement.text(offset)!, routeID: statement.text(offset + 1)!, serviceID: statement.text(offset + 2)!,
            headsign: statement.text(offset + 3), shortName: statement.text(offset + 4),
            directionID: statement.isNull(offset + 5) ? nil : statement.int(offset + 5), blockID: statement.text(offset + 6),
            shapeID: statement.text(offset + 7), wheelchairAccessible: statement.int(offset + 8), bikesAllowed: statement.int(offset + 9)
        )
    }

    static func normalizeSearch(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func distanceMeters(from lhs: Coordinate, to rhs: Coordinate) -> Double {
        let latitude1 = lhs.latitude * .pi / 180, latitude2 = rhs.latitude * .pi / 180
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
