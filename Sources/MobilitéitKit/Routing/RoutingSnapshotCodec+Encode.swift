import Foundation

extension RoutingSnapshotCodec {
    /// Throws `SnapshotFileError.unencodable` for any value the compact columns
    /// cannot hold exactly. The caller then keeps the database build and writes no file.
    static func encodePayload(_ snapshot: RoutingSnapshot) throws -> [UInt8] {
        var strings = SnapshotStringTable()
        var body = SnapshotWriter(capacity: 16 << 20)
        try encodeInfo(snapshot, strings: &strings, into: &body)
        try encodeStops(snapshot.stops, strings: &strings, into: &body)
        try encodeRoutes(snapshot.routes, strings: &strings, into: &body)
        try encodeTrips(snapshot.trips, strings: &strings, into: &body)
        try encodeDays(snapshot.serviceDays, into: &body)
        try encodeRules(snapshot.rulesByGroup, into: &body)
        body.append(Section.paths)
        try encodePaths(snapshot.pathsByFrom, into: &body); try encodePaths(snapshot.pathsByTo, into: &body)
        try encodeIndexes(snapshot, into: &body)
        body.append(Section.end)

        var payload = SnapshotWriter(capacity: body.bytes.count + strings.blob.count + 1 << 20)
        payload.append(Section.strings)
        payload.column(strings.offsets); payload.column(strings.blob)
        payload.append(contentsOf: body)
        return payload.bytes
    }

    private static func encodeInfo(_ snapshot: RoutingSnapshot, strings: inout SnapshotStringTable, into out: inout SnapshotWriter) throws {
        let info = snapshot.info
        out.append(Section.info)
        for date in [info.firstServiceDate, info.lastServiceDate] { out.append(date.year); out.append(date.month); out.append(date.day) }
        out.append(Int(info.maximumServiceTime.rawValue)); out.append(info.generation)
        out.append(Int(try strings.reference(snapshot.converter.timeZone.identifier)))
        out.append(snapshot.lastActiveDayStartByService.count)
    }

    private static func encodeStops(_ stops: [SnapshotStop], strings: inout SnapshotStringTable, into out: inout SnapshotWriter) throws {
        var ids: [UInt32] = [], codes: [UInt32] = [], names: [UInt32] = [], descriptions: [UInt32] = []
        var parents: [UInt32] = [], platforms: [UInt32] = [], latitudes: [UInt64] = [], longitudes: [UInt64] = []
        var locationTypes: [Int64] = [], wheelchair: [Int64] = []
        for stop in stops {
            let model = stop.model
            guard stop.id == model.id, stop.parent == model.parentStationID else {
                throw SnapshotFileError.unencodable("stop \(stop.id) differs from its model")
            }
            ids.append(try strings.reference(model.id)); codes.append(try strings.reference(model.code))
            names.append(try strings.reference(model.name)); descriptions.append(try strings.reference(model.stopDescription))
            parents.append(try strings.reference(model.parentStationID)); platforms.append(try strings.reference(model.platformCode))
            latitudes.append(model.coordinate.latitude.bitPattern); longitudes.append(model.coordinate.longitude.bitPattern)
            locationTypes.append(Int64(model.locationType)); wheelchair.append(Int64(model.wheelchairBoarding))
        }
        out.append(Section.stops)
        out.column(ids); out.column(codes); out.column(names); out.column(descriptions); out.column(parents); out.column(platforms)
        out.column(latitudes); out.column(longitudes); out.column(locationTypes); out.column(wheelchair)
    }

    private static func encodeRoutes(_ routes: [TransitRoute], strings: inout SnapshotStringTable, into out: inout SnapshotWriter) throws {
        var ids: [UInt32] = [], agencies: [UInt32] = [], shortNames: [UInt32] = [], longNames: [UInt32] = []
        var colors: [UInt32] = [], textColors: [UInt32] = [], descriptions: [UInt32] = [], types: [Int64] = []
        for route in routes {
            ids.append(try strings.reference(route.id)); agencies.append(try strings.reference(route.agencyID))
            shortNames.append(try strings.reference(route.shortName)); longNames.append(try strings.reference(route.longName))
            colors.append(try strings.reference(route.color)); textColors.append(try strings.reference(route.textColor))
            descriptions.append(try strings.reference(route.routeDescription)); types.append(Int64(route.type))
        }
        out.append(Section.routes)
        out.column(ids); out.column(agencies); out.column(shortNames); out.column(longNames)
        out.column(colors); out.column(textColors); out.column(descriptions); out.column(types)
    }

    /// Trips are columns of per-trip values plus columns over all stop times,
    /// addressed through `offsets`. A stop headsign is rare and stored sparsely.
    private static func encodeTrips(_ trips: [SnapshotTrip], strings: inout SnapshotStringTable, into out: inout SnapshotWriter) throws {
        let timeCount = trips.reduce(0) { $0 + $1.times.count }
        var ids: [UInt32] = [], blocks: [UInt32] = [], headsigns: [UInt32] = [], flags: [UInt8] = []
        var routes: [Int32] = [], services: [Int32] = [], wheelchair: [Int32] = [], bikes: [Int32] = []
        var offsets: [UInt32] = [0]; offsets.reserveCapacity(trips.count + 1)
        var stops: [Int32] = [], sequences: [Int32] = [], arrivals: [Int32] = [], departures: [Int32] = []
        var presence: [UInt8] = [], pickups: [UInt8] = [], dropoffs: [UInt8] = []
        var headsignPositions: [UInt32] = [], headsignReferences: [UInt32] = []
        stops.reserveCapacity(timeCount); sequences.reserveCapacity(timeCount)
        arrivals.reserveCapacity(timeCount); departures.reserveCapacity(timeCount)
        presence.reserveCapacity(timeCount); pickups.reserveCapacity(timeCount); dropoffs.reserveCapacity(timeCount)
        for trip in trips {
            ids.append(try strings.reference(trip.id)); blocks.append(try strings.reference(trip.blockID))
            headsigns.append(try strings.reference(trip.headsign)); flags.append(trip.isFrequencyTemplate ? 1 : 0)
            routes.append(try SnapshotNarrow.int32(trip.route, "trip route")); services.append(try SnapshotNarrow.int32(trip.service, "trip service"))
            wheelchair.append(try SnapshotNarrow.int32(trip.wheelchairAccessible, "wheelchair accessible"))
            bikes.append(try SnapshotNarrow.int32(trip.bikesAllowed, "bikes allowed"))
            for time in trip.times {
                stops.append(try SnapshotNarrow.int32(time.stop, "stop index")); sequences.append(try SnapshotNarrow.int32(time.sequence, "stop sequence"))
                arrivals.append(time.arrival ?? 0); departures.append(time.departure ?? 0)
                presence.append((time.arrival == nil ? 1 : 0) | (time.departure == nil ? 2 : 0))
                pickups.append(try SnapshotNarrow.uint8(time.pickup, "pickup type")); dropoffs.append(try SnapshotNarrow.uint8(time.dropoff, "drop-off type"))
                if time.headsign != nil {
                    headsignPositions.append(try SnapshotNarrow.uint32(stops.count - 1, "stop headsign position"))
                    headsignReferences.append(try strings.reference(time.headsign))
                }
            }
            offsets.append(try SnapshotNarrow.uint32(stops.count, "stop time offset"))
        }
        out.append(Section.trips)
        out.column(ids); out.column(blocks); out.column(headsigns); out.column(flags)
        out.column(routes); out.column(services); out.column(wheelchair); out.column(bikes); out.column(offsets)
        out.column(stops); out.column(sequences); out.column(arrivals); out.column(departures)
        out.column(presence); out.column(pickups); out.column(dropoffs)
        out.column(headsignPositions); out.column(headsignReferences)
    }

    private static func encodeDays(_ days: [SnapshotServiceDay], into out: inout SnapshotWriter) throws {
        out.append(Section.days)
        try out.lists(days.map { $0.activeServices.sorted() })
    }

    /// The rules are flattened back into their original row order, which the
    /// continuation index and the rule groups both derive from.
    private static func encodeRules(_ groups: [RuleGroupKey: [SnapshotRule]], into out: inout SnapshotWriter) throws {
        let rules = groups.values.flatMap { $0 }.sorted { $0.order < $1.order }
        guard rules.enumerated().allSatisfy({ $0.offset == $0.element.order }) else {
            throw SnapshotFileError.unencodable("transfer rule order is not contiguous")
        }
        func value(_ number: Int?) throws -> Int64 {
            guard let number else { return absent }
            guard Int64(number) != absent else { throw SnapshotFileError.unencodable("transfer rule value") }
            return Int64(number)
        }
        out.append(Section.rules)
        out.column(try rules.map { try value($0.from) }); out.column(try rules.map { try value($0.to) })
        out.column(try rules.map { try value($0.type) }); out.column(try rules.map { try value($0.minimum) })
        out.column(try rules.map { try value($0.fromRoute) }); out.column(try rules.map { try value($0.toRoute) })
        out.column(try rules.map { try value($0.fromTrip) }); out.column(try rules.map { try value($0.toTrip) })
    }

    private static func encodePaths(_ lists: [[SnapshotPath]], into out: inout SnapshotWriter) throws {
        let paths = lists.flatMap { $0 }
        var offsets: [UInt32] = [0]
        for list in lists { offsets.append(offsets.last! + UInt32(list.count)) }
        out.column(offsets)
        out.column(try paths.map { try SnapshotNarrow.int32($0.from, "path origin") }); out.column(try paths.map { try SnapshotNarrow.int32($0.to, "path destination") })
        out.column(paths.map { Int64($0.seconds) }); out.column(paths.map { $0.distance.bitPattern }); out.column(paths.map { Int64($0.mode) })
        out.column(paths.map { Int64($0.stairCount ?? 0) })
        out.column(paths.map { ($0.maxSlope ?? 0).bitPattern }); out.column(paths.map { ($0.minWidth ?? 0).bitPattern })
        out.column(paths.map { UInt8(($0.stairCount == nil ? 0 : 1) | ($0.maxSlope == nil ? 0 : 2) | ($0.minWidth == nil ? 0 : 4)) })
    }

    private static func encodeIndexes(_ snapshot: RoutingSnapshot, into out: inout SnapshotWriter) throws {
        out.append(Section.indexes)
        try out.lists(snapshot.tripIndicesByDepartureStop)
        try encodePairs(snapshot.serviceRoutesByStop.map { $0.map { ($0.service, $0.route) } }, into: &out)
        out.column(try snapshot.boardableStops.sorted().map { try SnapshotNarrow.int32($0, "boardable stop") })
        out.column(try snapshot.alightableStops.sorted().map { try SnapshotNarrow.int32($0, "alightable stop") })
        try out.lists(snapshot.nearbyTransferStopsByStop)
        try out.lists(snapshot.continuations.sourcesByStop)
        try out.lists(snapshot.patterns.map(\.trips)); try out.lists(snapshot.patterns.map(\.stops))
        try encodePairs(snapshot.patternOccurrencesByStop.map { $0.map { ($0.pattern, $0.position) } }, into: &out)
    }

    private static func encodePairs(_ lists: [[(Int, Int)]], into out: inout SnapshotWriter) throws {
        try out.lists(lists.map { $0.map(\.0) })
        out.column(try lists.flatMap { $0 }.map { try SnapshotNarrow.int32($0.1, "pair value") })
    }
}
