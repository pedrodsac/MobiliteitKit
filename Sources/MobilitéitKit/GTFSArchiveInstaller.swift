import Foundation
import ZIPFoundation

/// Installs a GTFS ZIP into the package's compact, query-oriented SQLite format.
/// The ZIP entries are extracted one at a time and parsed line-by-line; the raw
/// CSV is never decoded into an in-memory feed object graph.
/// Imports a static GTFS ZIP archive into an atomically replaceable SQLite database.
public enum GTFSArchiveInstaller {
    /// Downloads a feed to a temporary file before installing it. The caller owns
    /// the feed URL, making update policy (ETag, schedule, and user consent) an
    /// application decision.
    ///
    /// The resulting database is installed atomically after the archive has
    /// been fully validated and imported.
    ///
    /// - Parameters:
    ///   - sourceURL: The URL of a GTFS ZIP archive.
    ///   - databaseURL: The destination SQLite database.
    ///   - generation: An application-defined version for the installed feed.
    ///   - session: The URL session used for downloading.
    /// - Returns: Metadata describing the installed feed.
    /// - Throws: ``GTFSArchiveError`` for an invalid response or archive, or a
    ///   filesystem/SQLite error during installation.
    @discardableResult
    public static func downloadAndInstall(
        from sourceURL: URL,
        databaseAt databaseURL: URL,
        generation: Int = 1,
        session: URLSession = .shared
    ) async throws -> FeedInfo {
        let (temporaryURL, response) = try await session.download(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw GTFSArchiveError.downloadFailed(statusCode: response.statusCode)
        }
        return try await install(archiveAt: temporaryURL, databaseAt: databaseURL, generation: generation)
    }

    /// Creates a complete replacement database, then swaps it into place only
    /// after the import has succeeded.
    ///
    /// Required GTFS files are imported in a streaming fashion. An existing
    /// database at `databaseURL` remains untouched if import fails.
    ///
    /// - Parameters:
    ///   - archiveURL: A local GTFS ZIP archive.
    ///   - databaseURL: The destination SQLite database.
    ///   - generation: An application-defined version for the installed feed.
    /// - Returns: Metadata describing the installed feed.
    /// - Throws: ``GTFSArchiveError`` when the archive is incomplete or
    ///   malformed, or a filesystem/SQLite error during installation.
    @discardableResult
    public static func install(
        archiveAt archiveURL: URL,
        databaseAt databaseURL: URL,
        generation: Int = 1
    ) async throws -> FeedInfo {
        try await Task.detached(priority: .utility) {
            try installSynchronously(archiveAt: archiveURL, databaseAt: databaseURL, generation: generation)
        }.value
    }

    private static func installSynchronously(
        archiveAt archiveURL: URL,
        databaseAt databaseURL: URL,
        generation: Int
    ) throws -> FeedInfo {
        let manager = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let stagingURL = parent.appendingPathComponent(".mobiliteit-gtfs-staging-\(token)", isDirectory: true)
        let temporaryDatabaseURL = parent.appendingPathComponent(".\(databaseURL.lastPathComponent).\(token).sqlite")
        defer {
            try? manager.removeItem(at: stagingURL)
            try? manager.removeItem(at: temporaryDatabaseURL)
        }
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw GTFSArchiveError.unsupportedArchive(error.localizedDescription)
        }

        // GTFS deliberately permits calendar.txt and shapes.txt to be absent.
        // calendar_dates.txt is sufficient when it describes all active dates;
        // shapes are presentation data and never a routing prerequisite.
        let required = ["agency.txt", "stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
        let optional = ["calendar.txt", "calendar_dates.txt", "shapes.txt", "frequencies.txt", "transfers.txt", "pathways.txt", "levels.txt"]
        var files: [String: URL] = [:]
        for name in required + optional {
            guard let entry = archive[name] else {
                if required.contains(name) { throw GTFSArchiveError.missingRequiredFile(name) }
                continue
            }
            let output = stagingURL.appendingPathComponent(name)
            _ = try archive.extract(entry, to: output)
            files[name] = output
        }

        let database = try SQLiteDatabase(path: temporaryDatabaseURL.path)
        try database.execute("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA temp_store = MEMORY;")
        try createSchema(in: database)
        try database.execute("BEGIN IMMEDIATE")

        do {
            try importAgencies(from: files["agency.txt"]!, into: database)
            try importStops(from: files["stops.txt"]!, into: database)
            try importRoutes(from: files["routes.txt"]!, into: database)
            guard files["calendar.txt"] != nil || files["calendar_dates.txt"] != nil else {
                throw GTFSArchiveError.missingRequiredFile("calendar.txt or calendar_dates.txt")
            }
            let calendarState = try importCalendars(
                calendarURL: files["calendar.txt"],
                dateExceptionsURL: files["calendar_dates.txt"],
                into: database
            )
            if let shapes = files["shapes.txt"] { try importShapes(from: shapes, into: database) }

            var ids = try IdentifierMaps.load(from: database)
            try importTrips(from: files["trips.txt"]!, ids: ids, into: database)
            ids.trip = try IdentifierMaps.ids(table: "trip", in: database)
            try importStopTimes(from: files["stop_times.txt"]!, ids: ids, into: database)
            if let frequencyURL = files["frequencies.txt"] {
                try importFrequencies(from: frequencyURL, ids: ids, into: database)
            }
            if let transfersURL = files["transfers.txt"] {
                try importTransfers(from: transfersURL, ids: ids, into: database)
            }
            if let pathwaysURL = files["pathways.txt"] {
                try importPathways(from: pathwaysURL, ids: ids, into: database)
            }

            let info = try materializeServiceDates(calendarState, ids: ids, generation: generation, into: database)
            try createIndexes(in: database)
            try database.execute("COMMIT; PRAGMA optimize;")

            if manager.fileExists(atPath: databaseURL.path) {
                _ = try manager.replaceItemAt(databaseURL, withItemAt: temporaryDatabaseURL)
            } else {
                try manager.moveItem(at: temporaryDatabaseURL, to: databaseURL)
            }
            return info
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }
}

private extension GTFSArchiveInstaller {
    static func createSchema(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE agency (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
            url TEXT, timezone TEXT NOT NULL, language TEXT, phone TEXT
        );
        CREATE TABLE service (id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE);
        CREATE TABLE calendar_rule (
            service_id INTEGER PRIMARY KEY REFERENCES service(id), monday INTEGER NOT NULL,
            tuesday INTEGER NOT NULL, wednesday INTEGER NOT NULL, thursday INTEGER NOT NULL,
            friday INTEGER NOT NULL, saturday INTEGER NOT NULL, sunday INTEGER NOT NULL,
            start_date TEXT NOT NULL, end_date TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE calendar_exception (
            service_id INTEGER NOT NULL REFERENCES service(id), date TEXT NOT NULL,
            exception_type INTEGER NOT NULL, PRIMARY KEY(service_id, date)
        ) WITHOUT ROWID;
        CREATE TABLE service_date (
            day_index INTEGER NOT NULL, service_id INTEGER NOT NULL REFERENCES service(id),
            PRIMARY KEY(day_index, service_id)
        ) WITHOUT ROWID;
        CREATE TABLE route (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE,
            agency_id INTEGER REFERENCES agency(id), short_name TEXT, long_name TEXT,
            route_type INTEGER NOT NULL, color TEXT, text_color TEXT, route_description TEXT
        );
        CREATE TABLE stop (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE, code TEXT, name TEXT NOT NULL,
            stop_description TEXT, lat_e6 INTEGER NOT NULL, lon_e6 INTEGER NOT NULL,
            location_type INTEGER NOT NULL, parent_station_id TEXT,
            wheelchair_boarding INTEGER NOT NULL, platform_code TEXT, search_name TEXT NOT NULL,
            stop_timezone TEXT, level_id TEXT, stop_access INTEGER
        );
        CREATE VIRTUAL TABLE stop_spatial USING rtree(id, min_lat, max_lat, min_lon, max_lon);
        CREATE TABLE shape (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE, point_count INTEGER NOT NULL,
            encoded BLOB NOT NULL
        );
        CREATE TABLE trip (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE,
            route_id INTEGER NOT NULL REFERENCES route(id), service_id INTEGER NOT NULL REFERENCES service(id),
            headsign TEXT, short_name TEXT, direction_id INTEGER, block_id TEXT,
            shape_id INTEGER REFERENCES shape(id), wheelchair_accessible INTEGER NOT NULL,
            bikes_allowed INTEGER NOT NULL
        );
        CREATE TABLE stop_time (
            trip_id INTEGER NOT NULL REFERENCES trip(id), stop_id INTEGER NOT NULL REFERENCES stop(id),
            sequence INTEGER NOT NULL, arrival_sec INTEGER, departure_sec INTEGER,
            stop_headsign TEXT, pickup_type INTEGER NOT NULL, dropoff_type INTEGER NOT NULL,
            shape_dist_traveled REAL, timepoint INTEGER, continuous_pickup INTEGER, continuous_dropoff INTEGER,
            PRIMARY KEY(trip_id, sequence)
        ) WITHOUT ROWID;
        CREATE TABLE frequency (
            trip_id INTEGER NOT NULL REFERENCES trip(id), start_sec INTEGER NOT NULL,
            end_sec INTEGER NOT NULL, headway_sec INTEGER NOT NULL, exact_times INTEGER,
            PRIMARY KEY(trip_id, start_sec)
        ) WITHOUT ROWID;
        CREATE TABLE transfer_rule (
            id INTEGER PRIMARY KEY, from_stop_id INTEGER REFERENCES stop(id),
            to_stop_id INTEGER REFERENCES stop(id), transfer_type INTEGER NOT NULL,
            min_transfer_sec INTEGER, from_route_id INTEGER REFERENCES route(id),
            to_route_id INTEGER REFERENCES route(id), from_trip_id INTEGER REFERENCES trip(id),
            to_trip_id INTEGER REFERENCES trip(id)
        );
        CREATE TABLE pathway (
            id INTEGER PRIMARY KEY, gtfs_id TEXT NOT NULL UNIQUE,
            from_stop_id INTEGER NOT NULL REFERENCES stop(id), to_stop_id INTEGER NOT NULL REFERENCES stop(id),
            pathway_mode INTEGER, is_bidirectional INTEGER, length REAL, traversal_time INTEGER,
            stair_count INTEGER, max_slope REAL, min_width REAL, signposted_as TEXT, reversed_signposted_as TEXT
        );
        """)
    }

    static func createIndexes(in database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE INDEX idx_stop_search ON stop(search_name);
        CREATE INDEX idx_stop_time_stop_departure ON stop_time(stop_id, departure_sec, trip_id);
        CREATE INDEX idx_stop_time_stop_arrival ON stop_time(stop_id, arrival_sec, trip_id);
        CREATE INDEX idx_trip_route_service_direction ON trip(route_id, service_id, direction_id);
        CREATE INDEX idx_trip_service ON trip(service_id);
        CREATE INDEX idx_trip_shape ON trip(shape_id);
        CREATE INDEX idx_service_date_service_day ON service_date(service_id, day_index);
        CREATE INDEX idx_transfer_from_stop ON transfer_rule(from_stop_id);
        CREATE INDEX idx_route_agency ON route(agency_id);
        """)
    }

    static func importAgencies(from url: URL, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "agency.txt")
        for column in ["agency_id", "agency_name", "agency_url", "agency_timezone"] { try csv.requireColumn(column) }
        let statement = try database.prepare("INSERT INTO agency(gtfs_id,name,url,timezone,language,phone) VALUES(?,?,?,?,?,?)")
        while let row = try csv.nextRow() {
            try statement.reset()
            try statement.bind(try row.required("agency_id"), at: 1)
            try statement.bind(try row.required("agency_name"), at: 2)
            try statement.bind(row.optional("agency_url"), at: 3)
            try statement.bind(try row.required("agency_timezone"), at: 4)
            try statement.bind(row.optional("agency_lang"), at: 5)
            try statement.bind(row.optional("agency_phone"), at: 6)
            try statement.step()
        }
    }

    static func importStops(from url: URL, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "stops.txt")
        for column in ["stop_id", "stop_name", "stop_lat", "stop_lon"] { try csv.requireColumn(column) }
        let insert = try database.prepare("""
            INSERT INTO stop(gtfs_id,code,name,stop_description,lat_e6,lon_e6,location_type,parent_station_id,wheelchair_boarding,platform_code,search_name,stop_timezone,level_id,stop_access)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """)
        let spatial = try database.prepare("INSERT INTO stop_spatial(id,min_lat,max_lat,min_lon,max_lon) VALUES(?,?,?,?,?)")
        while let row = try csv.nextRow() {
            let latitude = try requiredDouble(row, "stop_lat")
            let longitude = try requiredDouble(row, "stop_lon")
            let name = try row.required("stop_name")
            try insert.reset()
            try insert.bind(try row.required("stop_id"), at: 1)
            try insert.bind(row.optional("stop_code"), at: 2)
            try insert.bind(name, at: 3)
            try insert.bind(row.optional("stop_desc"), at: 4)
            try insert.bind(Int((latitude * 1_000_000).rounded()), at: 5)
            try insert.bind(Int((longitude * 1_000_000).rounded()), at: 6)
            try insert.bind(try row.integer("location_type", required: false) ?? 0, at: 7)
            try insert.bind(row.optional("parent_station"), at: 8)
            try insert.bind(try row.integer("wheelchair_boarding", required: false) ?? 0, at: 9)
            try insert.bind(row.optional("platform_code"), at: 10)
            try insert.bind(normalizeSearch(name), at: 11)
            try insert.bind(row.optional("stop_timezone"), at: 12)
            try insert.bind(row.optional("level_id"), at: 13)
            try insert.bind(try row.integer("stop_access", required: false), at: 14)
            try insert.step()

            try spatial.reset()
            try spatial.bind(database.lastInsertRowID, at: 1)
            try spatial.bind(latitude, at: 2); try spatial.bind(latitude, at: 3)
            try spatial.bind(longitude, at: 4); try spatial.bind(longitude, at: 5)
            try spatial.step()
        }
    }

    static func importRoutes(from url: URL, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "routes.txt")
        for column in ["route_id", "route_type"] { try csv.requireColumn(column) }
        let statement = try database.prepare("""
            INSERT INTO route(gtfs_id,agency_id,short_name,long_name,route_type,color,text_color,route_description)
            VALUES(?,(SELECT id FROM agency WHERE gtfs_id = ?),?,?,?,?,?,?)
        """)
        while let row = try csv.nextRow() {
            try statement.reset()
            try statement.bind(try row.required("route_id"), at: 1)
            try statement.bind(row.optional("agency_id"), at: 2)
            try statement.bind(row.optional("route_short_name"), at: 3)
            try statement.bind(row.optional("route_long_name"), at: 4)
            try statement.bind(try row.integer("route_type")!, at: 5)
            try statement.bind(row.optional("route_color"), at: 6)
            try statement.bind(row.optional("route_text_color"), at: 7)
            try statement.bind(row.optional("route_desc"), at: 8)
            try statement.step()
        }
    }

    static func importCalendars(
        calendarURL: URL?,
        dateExceptionsURL: URL?,
        into database: SQLiteDatabase
    ) throws -> CalendarImportState {
        var rules: [String: CalendarRule] = [:]
        var exceptions: [String: [GTFSDate: Int]] = [:]
        var firstDate: GTFSDate?
        var lastDate: GTFSDate?
        let service = try database.prepare("INSERT INTO service(gtfs_id) VALUES(?) ON CONFLICT(gtfs_id) DO NOTHING")
        let rule = try database.prepare("""
            INSERT INTO calendar_rule(service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date)
            VALUES(?,?,?,?,?,?,?,?,?,?)
        """)

        if let calendarURL {
          var csv = try StreamingCSV(url: calendarURL, file: "calendar.txt")
          for column in ["service_id", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "start_date", "end_date"] {
              try csv.requireColumn(column)
          }
          while let row = try csv.nextRow() {
            let serviceID = try row.required("service_id")
            let start = try GTFSDate(parsing: row.required("start_date"))
            let end = try GTFSDate(parsing: row.required("end_date"))
            guard start <= end else {
                throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "end_date", value: end.compactString)
            }
            let days = try (1...7).map { day in
                try row.integer(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"][day - 1])!
            }
            guard days.allSatisfy({ $0 == 0 || $0 == 1 }) else {
                throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "weekday", value: "must be 0 or 1")
            }
            try service.reset(); try service.bind(serviceID, at: 1); try service.step()
            let serviceIDValue = try identifier(for: serviceID, in: "service", database: database)
            try rule.reset()
            try rule.bind(serviceIDValue, at: 1)
            for (offset, day) in days.enumerated() { try rule.bind(day, at: Int32(offset + 2)) }
            try rule.bind(start.compactString, at: 9); try rule.bind(end.compactString, at: 10); try rule.step()
            rules[serviceID] = CalendarRule(weekdays: days, start: start, end: end)
            firstDate = firstDate.map { Swift.min($0, start) } ?? start
            lastDate = lastDate.map { Swift.max($0, end) } ?? end
          }
        }

        if let dateExceptionsURL {
            var exceptionsCSV = try StreamingCSV(url: dateExceptionsURL, file: "calendar_dates.txt")
            for column in ["service_id", "date", "exception_type"] { try exceptionsCSV.requireColumn(column) }
            let exception = try database.prepare("INSERT INTO calendar_exception(service_id,date,exception_type) VALUES(?,?,?)")
            while let row = try exceptionsCSV.nextRow() {
                let serviceID = try row.required("service_id")
                let date = try GTFSDate(parsing: row.required("date"))
                let type = try row.integer("exception_type")!
                guard type == 1 || type == 2 else {
                    throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "exception_type", value: String(type))
                }
                try service.reset(); try service.bind(serviceID, at: 1); try service.step()
                try exception.reset()
                try exception.bind(try identifier(for: serviceID, in: "service", database: database), at: 1)
                try exception.bind(date.compactString, at: 2); try exception.bind(type, at: 3); try exception.step()
                exceptions[serviceID, default: [:]][date] = type
                firstDate = firstDate.map { Swift.min($0, date) } ?? date
                lastDate = lastDate.map { Swift.max($0, date) } ?? date
            }
        }

        guard let firstDate, let lastDate else {
            throw GTFSArchiveError.unsupportedArchive("calendar data contains no service dates")
        }
        return CalendarImportState(rules: rules, exceptions: exceptions, firstDate: firstDate, lastDate: lastDate)
    }

    static func importShapes(from url: URL, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "shapes.txt")
        for column in ["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"] { try csv.requireColumn(column) }
        let statement = try database.prepare("INSERT INTO shape(gtfs_id,point_count,encoded) VALUES(?,?,?)")
        var completed = Set<String>()
        var current: ShapeAccumulator?

        func save(_ accumulator: ShapeAccumulator) throws {
            try statement.reset()
            try statement.bind(accumulator.id, at: 1)
            try statement.bind(accumulator.count, at: 2)
            try statement.bind(accumulator.encoded(), at: 3)
            try statement.step()
        }

        while let row = try csv.nextRow() {
            let id = try row.required("shape_id")
            let latitude = try requiredDouble(row, "shape_pt_lat")
            let longitude = try requiredDouble(row, "shape_pt_lon")
            let sequence = try row.integer("shape_pt_sequence")!
            if var accumulator = current, accumulator.id == id {
                try accumulator.append(latitude: latitude, longitude: longitude, sequence: sequence)
                current = accumulator
            } else {
                if let current {
                    try save(current)
                    completed.insert(current.id)
                }
                guard !completed.contains(id) else { throw GTFSArchiveError.inconsistentShapeOrder(id) }
                current = try ShapeAccumulator(id: id, latitude: latitude, longitude: longitude, sequence: sequence)
            }
        }
        if let current { try save(current) }
    }

    static func importTrips(from url: URL, ids: IdentifierMaps, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "trips.txt")
        for column in ["route_id", "service_id", "trip_id"] { try csv.requireColumn(column) }
        let statement = try database.prepare("""
            INSERT INTO trip(gtfs_id,route_id,service_id,headsign,short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed)
            VALUES(?,?,?,?,?,?,?,?,?,?)
        """)
        while let row = try csv.nextRow() {
            let routeID = try row.required("route_id")
            let serviceID = try row.required("service_id")
            let tripID = try row.required("trip_id")
            try statement.reset()
            try statement.bind(tripID, at: 1)
            try statement.bind(try ids.requiredRoute(routeID, row: row), at: 2)
            try statement.bind(try ids.requiredService(serviceID, row: row), at: 3)
            try statement.bind(row.optional("trip_headsign"), at: 4)
            try statement.bind(row.optional("trip_short_name"), at: 5)
            try statement.bind(try row.integer("direction_id", required: false), at: 6)
            try statement.bind(row.optional("block_id"), at: 7)
            if let shapeID = row.optional("shape_id"), let shape = ids.shape[shapeID] {
                // Shapes are optional GTFS presentation data. A feed that
                // omits shapes.txt remains routable even when trips retain
                // historical shape identifiers.
                try statement.bind(shape, at: 8)
            } else {
                try statement.bind(Optional<Int>.none, at: 8)
            }
            try statement.bind(try row.integer("wheelchair_accessible", required: false) ?? 0, at: 9)
            try statement.bind(try row.integer("bikes_allowed", required: false) ?? 0, at: 10)
            try statement.step()
        }
    }

    static func importStopTimes(from url: URL, ids: IdentifierMaps, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "stop_times.txt")
        for column in ["trip_id", "stop_id", "stop_sequence"] { try csv.requireColumn(column) }
        let statement = try database.prepare("""
            INSERT INTO stop_time(trip_id,stop_id,sequence,arrival_sec,departure_sec,stop_headsign,pickup_type,dropoff_type,shape_dist_traveled,timepoint,continuous_pickup,continuous_dropoff)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """)
        while let row = try csv.nextRow() {
            let tripID = try row.required("trip_id")
            let stopID = try row.required("stop_id")
            let arrival = try row.optional("arrival_time").map { try ServiceTime(parsing: $0).rawValue }
            let departure = try row.optional("departure_time").map { try ServiceTime(parsing: $0).rawValue }
            try statement.reset()
            try statement.bind(try ids.requiredTrip(tripID, row: row), at: 1)
            try statement.bind(try ids.requiredStop(stopID, row: row), at: 2)
            try statement.bind(try row.integer("stop_sequence")!, at: 3)
            try statement.bind(arrival, at: 4); try statement.bind(departure, at: 5)
            try statement.bind(row.optional("stop_headsign"), at: 6)
            try statement.bind(try row.integer("pickup_type", required: false) ?? 0, at: 7)
            try statement.bind(try row.integer("drop_off_type", required: false) ?? 0, at: 8)
            try statement.bind(try row.double("shape_dist_traveled", required: false), at: 9)
            try statement.bind(try row.integer("timepoint", required: false), at: 10)
            try statement.bind(try row.integer("continuous_pickup", required: false), at: 11)
            try statement.bind(try row.integer("continuous_drop_off", required: false), at: 12)
            try statement.step()
        }
    }

    static func importFrequencies(from url: URL, ids: IdentifierMaps, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "frequencies.txt")
        for column in ["trip_id", "start_time", "end_time", "headway_secs"] { try csv.requireColumn(column) }
        let statement = try database.prepare("INSERT INTO frequency(trip_id,start_sec,end_sec,headway_sec,exact_times) VALUES(?,?,?,?,?)")
        while let row = try csv.nextRow() {
            let tripID = try row.required("trip_id")
            let start = try ServiceTime(parsing: row.required("start_time"))
            let end = try ServiceTime(parsing: row.required("end_time"))
            let headway = try row.integer("headway_secs")!
            guard end > start, headway > 0 else {
                throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "headway_secs", value: String(headway))
            }
            try statement.reset()
            try statement.bind(try ids.requiredTrip(tripID, row: row), at: 1)
            try statement.bind(start.rawValue, at: 2); try statement.bind(end.rawValue, at: 3)
            try statement.bind(headway, at: 4)
            try statement.bind(try row.integer("exact_times", required: false), at: 5)
            try statement.step()
        }
    }

    static func importTransfers(from url: URL, ids: IdentifierMaps, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "transfers.txt")
        try csv.requireColumn("transfer_type")
        let statement = try database.prepare("""
            INSERT INTO transfer_rule(from_stop_id,to_stop_id,transfer_type,min_transfer_sec,from_route_id,to_route_id,from_trip_id,to_trip_id)
            VALUES(?,?,?,?,?,?,?,?)
        """)
        while let row = try csv.nextRow() {
            let type = try row.integer("transfer_type")!
            let fromStopID = row.optional("from_stop_id")
            let toStopID = row.optional("to_stop_id")
            // Linked transfer types are allowed to omit stop endpoints. Other
            // types need a concrete physical pair to be meaningful.
            if type != 4 && type != 5 && (fromStopID == nil || toStopID == nil) {
                throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "from_stop_id/to_stop_id", value: "required for transfer type \(type)")
            }
            try statement.reset()
            try statement.bind(try fromStopID.map { try ids.requiredStop($0, row: row) }, at: 1)
            try statement.bind(try toStopID.map { try ids.requiredStop($0, row: row) }, at: 2)
            try statement.bind(type, at: 3)
            try statement.bind(try row.integer("min_transfer_time", required: false), at: 4)
            try statement.bind(try ids.routeID(row.optional("from_route_id"), row: row), at: 5)
            try statement.bind(try ids.routeID(row.optional("to_route_id"), row: row), at: 6)
            try statement.bind(try ids.tripID(row.optional("from_trip_id"), row: row), at: 7)
            try statement.bind(try ids.tripID(row.optional("to_trip_id"), row: row), at: 8)
            try statement.step()
        }
    }

    static func importPathways(from url: URL, ids: IdentifierMaps, into database: SQLiteDatabase) throws {
        var csv = try StreamingCSV(url: url, file: "pathways.txt")
        for column in ["pathway_id", "from_stop_id", "to_stop_id"] { try csv.requireColumn(column) }
        let statement = try database.prepare("""
            INSERT INTO pathway(gtfs_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length,traversal_time,stair_count,max_slope,min_width,signposted_as,reversed_signposted_as)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """)
        while let row = try csv.nextRow() {
            try statement.reset()
            try statement.bind(try row.required("pathway_id"), at: 1)
            try statement.bind(try ids.requiredStop(row.required("from_stop_id"), row: row), at: 2)
            try statement.bind(try ids.requiredStop(row.required("to_stop_id"), row: row), at: 3)
            try statement.bind(try row.integer("pathway_mode", required: false), at: 4)
            try statement.bind(try row.integer("is_bidirectional", required: false), at: 5)
            try statement.bind(try row.double("length", required: false), at: 6)
            try statement.bind(try row.integer("traversal_time", required: false), at: 7)
            try statement.bind(try row.integer("stair_count", required: false), at: 8)
            try statement.bind(try row.double("max_slope"), at: 9)
            try statement.bind(try row.double("min_width"), at: 10)
            try statement.bind(row.optional("signposted_as"), at: 11)
            try statement.bind(row.optional("reversed_signposted_as"), at: 12)
            try statement.step()
        }
    }

    static func materializeServiceDates(
        _ state: CalendarImportState,
        ids: IdentifierMaps,
        generation: Int,
        into database: SQLiteDatabase
    ) throws -> FeedInfo {
        let insert = try database.prepare("INSERT INTO service_date(day_index,service_id) VALUES(?,?)")
        let dayCount = state.firstDate.days(until: state.lastDate)
        for (serviceID, identifier) in ids.service {
            let rule = state.rules[serviceID]
            let exceptions = state.exceptions[serviceID] ?? [:]
            for index in 0...dayCount {
                let date = state.firstDate.adding(days: index)
                let weekday = GTFSDate.utcCalendar.component(.weekday, from: date.foundationDate)
                var active = rule?.isActive(onCalendarWeekday: weekday, date: date) ?? false
                if let exception = exceptions[date] { active = exception == 1 }
                if active {
                    try insert.reset()
                    try insert.bind(index, at: 1); try insert.bind(identifier, at: 2); try insert.step()
                }
            }
        }

        let maximumTime = try maximumServiceTime(in: database)
        let metadata = try database.prepare("INSERT INTO metadata(key,value) VALUES(?,?)")
        let pairs = [
            ("feed_start", state.firstDate.compactString),
            ("feed_end", state.lastDate.compactString),
            ("maximum_service_time", String(maximumTime.rawValue)),
            ("generation", String(generation)),
            ("schema_version", "2"),
        ]
        for (key, value) in pairs {
            try metadata.reset(); try metadata.bind(key, at: 1); try metadata.bind(value, at: 2); try metadata.step()
        }
        return FeedInfo(
            firstServiceDate: state.firstDate,
            lastServiceDate: state.lastDate,
            maximumServiceTime: maximumTime,
            generation: generation
        )
    }

    static func maximumServiceTime(in database: SQLiteDatabase) throws -> ServiceTime {
        let statement = try database.prepare("SELECT MAX(MAX(COALESCE(arrival_sec, 0), COALESCE(departure_sec, 0))) FROM stop_time")
        guard try statement.step(), !statement.isNull(0) else { return ServiceTime(rawValue: 0) }
        return ServiceTime(rawValue: statement.int32(0))
    }

    static func identifier(for gtfsID: String, in table: String, database: SQLiteDatabase) throws -> Int {
        let statement = try database.prepare("SELECT id FROM \(table) WHERE gtfs_id = ?")
        try statement.bind(gtfsID, at: 1)
        guard try statement.step() else {
            throw GTFSArchiveError.database("Missing \(table) identifier \(gtfsID)")
        }
        return statement.int(0)
    }

    static func requiredDouble(_ row: CSVRow, _ column: String) throws -> Double {
        guard let value = try row.double(column) else {
            throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: column, value: "")
        }
        return value
    }

    static func normalizeSearch(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct CalendarImportState {
    let rules: [String: CalendarRule]
    let exceptions: [String: [GTFSDate: Int]]
    let firstDate: GTFSDate
    let lastDate: GTFSDate
}

private struct CalendarRule {
    /// Monday through Sunday.
    let weekdays: [Int]
    let start: GTFSDate
    let end: GTFSDate

    func isActive(onCalendarWeekday weekday: Int, date: GTFSDate) -> Bool {
        guard date >= start, date <= end else { return false }
        // Foundation: Sunday = 1. Our array: Monday = 0.
        let index = weekday == 1 ? 6 : weekday - 2
        return weekdays[index] == 1
    }
}

private struct IdentifierMaps {
    var agency: [String: Int]
    var route: [String: Int]
    var stop: [String: Int]
    var service: [String: Int]
    var shape: [String: Int]
    var trip: [String: Int]

    static func load(from database: SQLiteDatabase) throws -> IdentifierMaps {
        try IdentifierMaps(
            agency: ids(table: "agency", in: database),
            route: ids(table: "route", in: database),
            stop: ids(table: "stop", in: database),
            service: ids(table: "service", in: database),
            shape: ids(table: "shape", in: database),
            trip: [:]
        )
    }

    static func ids(table: String, in database: SQLiteDatabase) throws -> [String: Int] {
        let statement = try database.prepare("SELECT gtfs_id, id FROM \(table)")
        var result: [String: Int] = [:]
        while try statement.step() {
            result[statement.text(0)!] = statement.int(1)
        }
        return result
    }

    func requiredStop(_ id: String, row: CSVRow) throws -> Int { try required(id, in: stop, type: "stop", row: row) }
    func requiredRoute(_ id: String, row: CSVRow) throws -> Int { try required(id, in: route, type: "route", row: row) }
    func requiredService(_ id: String, row: CSVRow) throws -> Int { try required(id, in: service, type: "service", row: row) }
    func requiredShape(_ id: String, row: CSVRow) throws -> Int { try required(id, in: shape, type: "shape", row: row) }
    func requiredTrip(_ id: String, row: CSVRow) throws -> Int { try required(id, in: trip, type: "trip", row: row) }

    func routeID(_ value: String?, row: CSVRow) throws -> Int? {
        guard let value else { return nil }
        return try requiredRoute(value, row: row)
    }

    func tripID(_ value: String?, row: CSVRow) throws -> Int? {
        guard let value else { return nil }
        return try requiredTrip(value, row: row)
    }

    private func required(_ value: String, in identifiers: [String: Int], type: String, row: CSVRow) throws -> Int {
        guard let identifier = identifiers[value] else {
            throw GTFSArchiveError.invalidValue(file: row.file, line: row.line, column: "\(type)_id", value: value)
        }
        return identifier
    }
}
