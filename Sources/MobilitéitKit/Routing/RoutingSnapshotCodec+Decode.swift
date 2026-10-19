import Foundation

extension RoutingSnapshotCodec {
    private static func corrupt(_ what: String) -> SnapshotFileError { .corrupt(what) }

    /// Rebuilds the snapshot from a checksummed payload. Every index a column
    /// holds is range-checked here, so later routing code can subscript freely.
    static func decodePayload(_ payload: UnsafeRawBufferPointer, started: ContinuousClock.Instant = .now) throws -> RoutingSnapshot {
        var cursor = try SnapshotCursor(payload)
        try cursor.expect(Section.strings)
        let strings = try decodeStrings(&cursor)
        func string(_ reference: UInt32) throws -> String? {
            if reference == noReference { return nil }
            guard Int(reference) < strings.count else { throw corrupt("string reference") }
            return strings[Int(reference)]
        }
        func required(_ reference: UInt32) throws -> String {
            guard let value = try string(reference) else { throw corrupt("missing string") }
            return value
        }

        try cursor.expect(Section.info)
        func date() throws -> GTFSDate {
            let year = try cursor.int(), month = try cursor.int(), day = try cursor.int()
            do { return try GTFSDate(year: year, month: month, day: day) } catch { throw corrupt("service date") }
        }
        let first = try date(), last = try date()
        guard let maximumServiceTime = Int32(exactly: try cursor.int()) else { throw corrupt("maximum service time") }
        let info = FeedInfo(firstServiceDate: first, lastServiceDate: last, maximumServiceTime: ServiceTime(rawValue: maximumServiceTime), generation: try cursor.int())
        guard let zone = TimeZone(identifier: try required(UInt32(truncatingIfNeeded: try cursor.int()))) else { throw corrupt("time zone") }
        let serviceCount = try cursor.int()
        guard serviceCount >= 0, serviceCount < Int(Int32.max) else { throw corrupt("service count") }
        let dayCount = info.firstServiceDate.days(until: info.lastServiceDate) + 1
        guard dayCount >= 0 else { throw corrupt("service calendar") }

        let stops = try decodeStops(&cursor, string: required, optional: string)
        let stopByID = Dictionary(stops.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, later in later })
        let routes = try decodeRoutes(&cursor, string: required, optional: string)
        let trips = try decodeTrips(&cursor, stopCount: stops.count, routeCount: routes.count, serviceCount: serviceCount, string: required, optional: string)
        var tripByID = [String: Int](minimumCapacity: trips.count)
        for (index, trip) in trips.enumerated() { tripByID[trip.id] = index }

        try cursor.expect(Section.days)
        let days = try cursor.lists(expecting: dayCount, valueLimit: serviceCount)
        let active = days.offsets.lists(days.values).map(Set.init)
        let rules = try decodeRules(&cursor, stopCount: stops.count, routeCount: routes.count, tripCount: trips.count)

        try cursor.expect(Section.paths)
        let pathsByFrom = try decodePaths(&cursor, stopCount: stops.count), pathsByTo = try decodePaths(&cursor, stopCount: stops.count)

        try cursor.expect(Section.indexes)
        let departureLists = try cursor.lists(expecting: stops.count, valueLimit: trips.count)
        let serviceRoutes = try decodePairs(&cursor, count: stops.count, firstLimit: serviceCount, secondLimit: routes.count)
        let boardable = Set(try decodeStopSet(&cursor, stopCount: stops.count)), alightable = Set(try decodeStopSet(&cursor, stopCount: stops.count))
        let nearby = try cursor.lists(expecting: stops.count, valueLimit: stops.count)
        let sources = try cursor.lists(expecting: stops.count, valueLimit: stops.count)
        let patternTrips = try cursor.lists(valueLimit: trips.count)
        let patternStops = try cursor.lists(expecting: patternTrips.offsets.count - 1, valueLimit: stops.count)
        let patterns = zip(patternTrips.offsets.lists(patternTrips.values), patternStops.offsets.lists(patternStops.values)).map {
            SnapshotPattern(trips: $0, stops: $1)
        }
        let occurrences = try decodePairs(&cursor, count: stops.count, firstLimit: patterns.count, secondLimit: Int(Int32.max))
        for list in occurrences { for (pattern, position) in list { guard position < patterns[pattern].stops.count else { throw corrupt("pattern position") } } }
        try cursor.expect(Section.end)

        let converter = ServiceInstantConverter(timeZone: zone)
        let serviceDays = SnapshotDerivedIndexes.serviceDays(info: info, converter: converter, active: active)
        let stationGroupByStop = SnapshotDerivedIndexes.stationGroups(stops: stops, stopByID: stopByID)
        let nearbyLists = nearby.offsets.lists(nearby.values)
        return RoutingSnapshot(
            info: info, converter: converter, stops: stops, stopByID: stopByID, routes: routes, trips: trips, tripByID: tripByID,
            tripIndicesByDepartureStop: departureLists.offsets.lists(departureLists.values),
            serviceRoutesByStop: serviceRoutes.map { $0.map { ServiceRoute(service: $0.0, route: $0.1) } },
            boardableStops: boardable, alightableStops: alightable, serviceDays: serviceDays,
            lastActiveDayStartByService: SnapshotDerivedIndexes.lastActiveDayStart(serviceDays: serviceDays, serviceCount: serviceCount),
            rulesByGroup: SnapshotDerivedIndexes.rulesByGroup(rules, stationGroupByStop: stationGroupByStop),
            stationGroupByStop: stationGroupByStop, pathsByFrom: pathsByFrom, pathsByTo: pathsByTo,
            nearbyTransferStopsByStop: nearbyLists, serviceDayByDate: SnapshotDerivedIndexes.serviceDayByDate(serviceDays),
            nearbyTransferSourcesByStop: SnapshotDerivedIndexes.nearbyTransferSources(nearbyLists),
            continuations: SnapshotContinuationIndex(trips: trips, rules: rules, sourcesByStop: sources.offsets.lists(sources.values)),
            patterns: patterns, patternOccurrencesByStop: occurrences.map { $0.map { PatternOccurrence(pattern: $0.0, position: $0.1) } },
            loadMilliseconds: Int(RoutingDiagnostics.elapsed(since: started))
        )
    }

    private static func decodeStrings(_ cursor: inout SnapshotCursor) throws -> [String] {
        let offsets = try cursor.column(UInt32.self), blob = try cursor.column(UInt8.self)
        guard offsets.first == 0, Int(offsets[offsets.count - 1]) == blob.count else { throw corrupt("string table") }
        return try (0..<(offsets.count - 1)).map { index in
            let low = Int(offsets[index]), high = Int(offsets[index + 1])
            guard low <= high, high <= blob.count else { throw corrupt("string offsets") }
            return String(decoding: UnsafeBufferPointer(rebasing: blob[low..<high]), as: UTF8.self)
        }
    }

    private static func decodeStops(
        _ cursor: inout SnapshotCursor, string required: (UInt32) throws -> String, optional: (UInt32) throws -> String?
    ) throws -> [SnapshotStop] {
        try cursor.expect(Section.stops)
        let ids = try cursor.column(UInt32.self), codes = try cursor.column(UInt32.self), names = try cursor.column(UInt32.self)
        let descriptions = try cursor.column(UInt32.self), parents = try cursor.column(UInt32.self), platforms = try cursor.column(UInt32.self)
        let latitudes = try cursor.column(UInt64.self), longitudes = try cursor.column(UInt64.self)
        let locationTypes = try cursor.column(Int64.self), wheelchair = try cursor.column(Int64.self)
        let n = ids.count
        guard [codes.count, names.count, descriptions.count, parents.count, platforms.count, latitudes.count, longitudes.count, locationTypes.count, wheelchair.count].allSatisfy({ $0 == n }) else {
            throw corrupt("stop columns")
        }
        return try (0..<n).map { index in
            let id = try required(ids[index]), parent = try optional(parents[index])
            let model = TransitStop(
                id: id, code: try optional(codes[index]), name: try required(names[index]), stopDescription: try optional(descriptions[index]),
                coordinate: Coordinate(latitude: Double(bitPattern: latitudes[index]), longitude: Double(bitPattern: longitudes[index])),
                locationType: Int(locationTypes[index]), parentStationID: parent, wheelchairBoarding: Int(wheelchair[index]),
                platformCode: try optional(platforms[index]))
            return SnapshotStop(id: id, model: model, parent: parent)
        }
    }

    private static func decodeRoutes(
        _ cursor: inout SnapshotCursor, string required: (UInt32) throws -> String, optional: (UInt32) throws -> String?
    ) throws -> [TransitRoute] {
        try cursor.expect(Section.routes)
        let ids = try cursor.column(UInt32.self), agencies = try cursor.column(UInt32.self), shortNames = try cursor.column(UInt32.self)
        let longNames = try cursor.column(UInt32.self), colors = try cursor.column(UInt32.self), textColors = try cursor.column(UInt32.self)
        let descriptions = try cursor.column(UInt32.self), types = try cursor.column(Int64.self)
        let n = ids.count
        guard [agencies.count, shortNames.count, longNames.count, colors.count, textColors.count, descriptions.count, types.count].allSatisfy({ $0 == n }) else {
            throw corrupt("route columns")
        }
        return try (0..<n).map { index in
            TransitRoute(
                id: try required(ids[index]), agencyID: try optional(agencies[index]), shortName: try optional(shortNames[index]),
                longName: try optional(longNames[index]), type: Int(types[index]), color: try optional(colors[index]),
                textColor: try optional(textColors[index]), routeDescription: try optional(descriptions[index]))
        }
    }

    private static func decodeTrips(
        _ cursor: inout SnapshotCursor, stopCount: Int, routeCount: Int, serviceCount: Int,
        string required: (UInt32) throws -> String, optional: (UInt32) throws -> String?
    ) throws -> [SnapshotTrip] {
        try cursor.expect(Section.trips)
        let ids = try cursor.column(UInt32.self), blocks = try cursor.column(UInt32.self), headsigns = try cursor.column(UInt32.self)
        let flags = try cursor.column(UInt8.self), routes = try cursor.column(Int32.self), services = try cursor.column(Int32.self)
        let wheelchair = try cursor.column(Int32.self), bikes = try cursor.column(Int32.self), offsets = try cursor.column(UInt32.self)
        let stops = try cursor.column(Int32.self), sequences = try cursor.column(Int32.self)
        let arrivals = try cursor.column(Int32.self), departures = try cursor.column(Int32.self)
        let presence = try cursor.column(UInt8.self), pickups = try cursor.column(UInt8.self), dropoffs = try cursor.column(UInt8.self)
        let headsignPositions = try cursor.column(UInt32.self), headsignReferences = try cursor.column(UInt32.self)
        let n = ids.count, m = stops.count
        guard [blocks.count, headsigns.count, flags.count, routes.count, services.count, wheelchair.count, bikes.count].allSatisfy({ $0 == n }),
              offsets.count == n + 1, offsets.first == 0, Int(offsets[n]) == m,
              [sequences.count, arrivals.count, departures.count, presence.count, pickups.count, dropoffs.count].allSatisfy({ $0 == m }),
              headsignPositions.count == headsignReferences.count else { throw corrupt("trip columns") }
        var previous: UInt32 = 0
        for offset in offsets { guard offset >= previous else { throw corrupt("trip offsets") }; previous = offset }
        for stop in stops { guard stop >= 0, Int(stop) < stopCount else { throw corrupt("stop index") } }
        for route in routes { guard route >= 0, Int(route) < routeCount else { throw corrupt("route index") } }
        for service in services { guard service >= 0, Int(service) < serviceCount else { throw corrupt("service index") } }
        var lastHeadsign = -1
        for position in headsignPositions { guard Int(position) > lastHeadsign, Int(position) < m else { throw corrupt("headsign position") }; lastHeadsign = Int(position) }

        let headsignStrings = try headsignReferences.map { try optional($0) }
        var trips: [SnapshotTrip] = []; trips.reserveCapacity(n)
        var nextHeadsign = 0
        for index in 0..<n {
            let low = Int(offsets[index]), count = Int(offsets[index + 1]) - low
            let times = [SnapshotTime](unsafeUninitializedCapacity: count) { buffer, initialized in
                for position in 0..<count {
                    let source = low + position
                    var headsign: String? = nil
                    if nextHeadsign < headsignPositions.count, Int(headsignPositions[nextHeadsign]) == source {
                        headsign = headsignStrings[nextHeadsign]; nextHeadsign += 1
                    }
                    let flags = presence[source]
                    buffer.initializeElement(at: position, to: SnapshotTime(
                        stop: Int(stops[source]), sequence: Int(sequences[source]),
                        arrival: flags & 1 == 0 ? arrivals[source] : nil, departure: flags & 2 == 0 ? departures[source] : nil,
                        pickup: Int(pickups[source]), dropoff: Int(dropoffs[source]), headsign: headsign))
                }
                initialized = count
            }
            var trip = SnapshotTrip(id: try required(ids[index]), route: Int(routes[index]), service: Int(services[index]),
                                    times: times, headsign: try optional(headsigns[index]), wheelchairAccessible: Int(wheelchair[index]))
            trip.blockID = try optional(blocks[index]); trip.bikesAllowed = Int(bikes[index]); trip.isFrequencyTemplate = flags[index] & 1 != 0
            trips.append(trip)
        }
        guard nextHeadsign == headsignPositions.count else { throw corrupt("headsign references") }
        return trips
    }

    private static func decodeRules(_ cursor: inout SnapshotCursor, stopCount: Int, routeCount: Int, tripCount: Int) throws -> [SnapshotRule] {
        try cursor.expect(Section.rules)
        let columns = try (0..<8).map { _ in try cursor.column(Int64.self) }
        let n = columns[0].count
        guard columns.allSatisfy({ $0.count == n }) else { throw corrupt("rule columns") }
        func value(_ column: Int, _ index: Int, limit: Int?) throws -> Int? {
            let stored = columns[column][index]
            if stored == absent { return nil }
            if let limit { guard stored >= 0, stored < Int64(limit) else { throw corrupt("rule reference") } }
            return Int(stored)
        }
        return try (0..<n).map { index in
            guard let type = try value(2, index, limit: nil) else { throw corrupt("rule type") }
            return SnapshotRule(
                order: index, from: try value(0, index, limit: stopCount), to: try value(1, index, limit: stopCount), type: type,
                minimum: try value(3, index, limit: nil), fromRoute: try value(4, index, limit: routeCount),
                toRoute: try value(5, index, limit: routeCount), fromTrip: try value(6, index, limit: tripCount), toTrip: try value(7, index, limit: tripCount))
        }
    }

    private static func decodePaths(_ cursor: inout SnapshotCursor, stopCount: Int) throws -> [[SnapshotPath]] {
        let offsets = try cursor.column(UInt32.self)
        let from = try cursor.column(Int32.self), to = try cursor.column(Int32.self), seconds = try cursor.column(Int64.self)
        let distances = try cursor.column(UInt64.self), modes = try cursor.column(Int64.self), stairs = try cursor.column(Int64.self)
        let slopes = try cursor.column(UInt64.self), widths = try cursor.column(UInt64.self), presence = try cursor.column(UInt8.self)
        let n = from.count
        guard offsets.count == stopCount + 1, offsets.first == 0, Int(offsets[stopCount]) == n,
              [to.count, seconds.count, distances.count, modes.count, stairs.count, slopes.count, widths.count, presence.count].allSatisfy({ $0 == n }) else {
            throw corrupt("path columns")
        }
        for index in 0..<n { guard from[index] >= 0, Int(from[index]) < stopCount, to[index] >= 0, Int(to[index]) < stopCount else { throw corrupt("path stop") } }
        var previous: UInt32 = 0
        for offset in offsets { guard offset >= previous else { throw corrupt("path offsets") }; previous = offset }
        return (0..<stopCount).map { stop in
            (Int(offsets[stop])..<Int(offsets[stop + 1])).map { index in
                SnapshotPath(
                    from: Int(from[index]), to: Int(to[index]), seconds: Int(seconds[index]), distance: Double(bitPattern: distances[index]), mode: Int(modes[index]),
                    stairCount: presence[index] & 1 != 0 ? Int(stairs[index]) : nil,
                    maxSlope: presence[index] & 2 != 0 ? Double(bitPattern: slopes[index]) : nil,
                    minWidth: presence[index] & 4 != 0 ? Double(bitPattern: widths[index]) : nil)
            }
        }
    }

    private static func decodeStopSet(_ cursor: inout SnapshotCursor, stopCount: Int) throws -> [Int] {
        try cursor.column(Int32.self).map { value in
            guard value >= 0, Int(value) < stopCount else { throw corrupt("stop set") }
            return Int(value)
        }
    }

    private static func decodePairs(_ cursor: inout SnapshotCursor, count: Int, firstLimit: Int, secondLimit: Int) throws -> [[(Int, Int)]] {
        let firsts = try cursor.lists(expecting: count, valueLimit: firstLimit)
        let seconds = try cursor.column(Int32.self)
        guard seconds.count == firsts.values.count else { throw corrupt("pair columns") }
        for value in seconds { guard value >= 0, Int(value) < secondLimit else { throw corrupt("pair value") } }
        return (0..<count).map { stop in
            (Int(firsts.offsets[stop])..<Int(firsts.offsets[stop + 1])).map { (Int(firsts.values[$0]), Int(seconds[$0])) }
        }
    }
}
