import Foundation
import Testing
@testable import MobiliteitKit

/// A small feed that touches every table and index the snapshot file stores:
/// parent stations and platform codes, canonically equivalent names, non-consecutive
/// stop sequences, empty arrival and departure times, stop headsigns, boarding and
/// alighting restrictions, vehicle blocks, an in-seat transfer rule, pathways with and
/// without optional values, an exact-times frequency and service past midnight.
enum SnapshotFixture {
    static func files() -> [String: String] {
        [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Luxembourg\n",
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                + "weekday,1,1,1,1,1,0,0,20260901,20260930\nweekend,0,0,0,0,0,1,1,20260901,20260930\n",
            "calendar_dates.txt": "service_id,date,exception_type\nweekday,20260907,2\nweekend,20260907,1\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color,route_desc\n"
                + "bus,operator,16,Bus sixteen,3,00AAFF,FFFFFF,Bus route\ntram,operator,T1,Tram one,0,,,\nrail,operator,RB,Regional,2,FF0000,000000,Regional rail\n",
            "stops.txt": "stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,location_type,parent_station,wheelchair_boarding,platform_code\n"
                + "station,,Gare Étoile,Main station,49.6000,6.1300,1,,1,\n"
                + "s1,A,Gare Étoile,Quai 1,49.6001,6.1301,0,station,1,1\n"
                + "s2,B,Gare E\u{301}toile,,49.6002,6.1302,0,station,2,2\n"
                + "s3,,Hamilius,,49.6100,6.1250,0,,0,\n"
                + "s4,,Kirchberg,,49.6200,6.1400,0,,0,\n"
                + "s5,,Luxexpo,,49.6300,6.1500,0,,1,\n"
                + "s6,,Findel,,49.6300,6.1510,0,,0,\n",
            "trips.txt": "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,wheelchair_accessible,bikes_allowed\n"
                + "bus,weekday,busA,Kirchberg,,0,blockX,1,1\nbus,weekday,busB,Findel,,0,blockX,0,2\ntram,weekday,tram1,,,1,,1,0\n"
                + "rail,weekday,rail1,Findel,,0,,0,0\nbus,weekend,sun1,Sunday ride,,0,,0,0\ntram,weekday,freq1,Shuttle,,0,,1,1\nbus,weekday,late1,Night,,0,,0,0\n",
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,stop_headsign\n"
                + "busA,06:00:00,06:00:00,s1,1,0,0,\nbusA,06:10:00,06:11:00,s3,2,0,0,\nbusA,06:25:00,06:26:00,s4,3,0,0,\nbusA,06:40:00,06:40:00,s5,4,0,0,\n"
                + "busB,06:50:00,06:50:00,s5,1,0,0,\nbusB,07:00:00,,s6,2,0,0,\n"
                + "tram1,06:05:00,06:05:00,s2,10,0,0,\ntram1,06:15:00,06:15:00,s3,20,0,0,Kirchberg via Hamilius\ntram1,06:30:00,06:30:00,s4,30,1,1,\n"
                + "rail1,06:45:00,06:46:00,s5,1,0,0,\nrail1,06:55:00,,s6,2,0,0,\n"
                + "sun1,09:00:00,09:00:00,s1,1,0,0,\nsun1,09:20:00,09:20:00,s4,2,0,0,\n"
                + "freq1,00:00:00,00:00:00,s3,1,0,0,\nfreq1,00:05:00,00:05:00,s4,2,0,0,\n"
                + "late1,25:10:00,25:10:00,s1,1,0,0,\nlate1,25:30:00,25:30:00,s3,2,0,0,\n",
            "frequencies.txt": "trip_id,start_time,end_time,headway_secs,exact_times\nfreq1,06:00:00,07:00:00,1200,1\n",
            "transfers.txt": "from_stop_id,to_stop_id,transfer_type,min_transfer_time,from_route_id,to_route_id,from_trip_id,to_trip_id\n"
                + "s3,s3,2,240,,,,\ns5,s5,4,,,,busA,busB\ns4,s4,3,,bus,tram,,\n",
            "pathways.txt": "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length,traversal_time,stair_count,max_slope,min_width,signposted_as,reversed_signposted_as\n"
                + "p1,s1,s2,2,1,30,60,12,0.08,1.5,,\np2,s2,s3,1,0,200,300,,,,,\n",
        ]
    }

    /// Installs `files` as a database named `name` inside `directory`.
    static func install(files: [String: String] = files(), generation: Int = 7, name: String = "transit.sqlite", in directory: URL) async throws -> URL {
        let archive = directory.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        try writeArchive(to: archive, files: files)
        let database = directory.appendingPathComponent(name)
        _ = try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database, generation: generation)
        return database
    }

    /// The names of every stored property of `RoutingSnapshot`. Adding a field fails
    /// `RoutingSnapshotCodecTests.fieldInventory` until the codec and `differences` cover it.
    static let snapshotFields: Set<String> = [
        "info", "converter", "stops", "stopByID", "routes", "trips", "tripByID", "tripIndicesByDepartureStop", "serviceRoutesByStop",
        "boardableStops", "alightableStops", "serviceDays", "lastActiveDayStartByService", "rulesByGroup", "stationGroupByStop",
        "pathsByFrom", "pathsByTo", "nearbyTransferStopsByStop", "serviceDayByDate", "nearbyTransferSourcesByStop", "continuations",
        "patterns", "patternOccurrencesByStop", "loadMilliseconds",
    ]
}

/// Every table and index routing reads, compared value by value. `loadMilliseconds`
/// is the only field left out: it measures the load itself.
func snapshotDifferences(_ built: RoutingSnapshot, _ loaded: RoutingSnapshot) -> [String] {
    var differences: [String] = []
    func check<T: Equatable>(_ name: String, _ left: T, _ right: T) { if left != right { differences.append(name) } }
    check("info", built.info, loaded.info)
    check("converter.timeZone", built.converter.timeZone, loaded.converter.timeZone)
    check("stops", built.stops, loaded.stops)
    check("stopByID", built.stopByID, loaded.stopByID)
    check("routes", built.routes, loaded.routes)
    check("trips", built.trips, loaded.trips)
    check("tripByID", built.tripByID, loaded.tripByID)
    check("tripIndicesByDepartureStop", built.tripIndicesByDepartureStop, loaded.tripIndicesByDepartureStop)
    check("serviceRoutesByStop", built.serviceRoutesByStop, loaded.serviceRoutesByStop)
    check("boardableStops", built.boardableStops, loaded.boardableStops)
    check("alightableStops", built.alightableStops, loaded.alightableStops)
    check("serviceDays", built.serviceDays, loaded.serviceDays)
    check("lastActiveDayStartByService", built.lastActiveDayStartByService, loaded.lastActiveDayStartByService)
    check("rulesByGroup", built.rulesByGroup, loaded.rulesByGroup)
    check("stationGroupByStop", built.stationGroupByStop, loaded.stationGroupByStop)
    check("pathsByFrom", built.pathsByFrom, loaded.pathsByFrom)
    check("pathsByTo", built.pathsByTo, loaded.pathsByTo)
    check("nearbyTransferStopsByStop", built.nearbyTransferStopsByStop, loaded.nearbyTransferStopsByStop)
    check("serviceDayByDate", built.serviceDayByDate, loaded.serviceDayByDate)
    check("nearbyTransferSourcesByStop", built.nearbyTransferSourcesByStop, loaded.nearbyTransferSourcesByStop)
    check("continuations", built.continuations, loaded.continuations)
    check("patterns", built.patterns, loaded.patterns)
    check("patternOccurrencesByStop", built.patternOccurrencesByStop, loaded.patternOccurrencesByStop)
    // Strict string comparison: `==` on String treats canonically equivalent text as equal.
    if built.stops.map({ Array($0.model.name.utf8) }) != loaded.stops.map({ Array($0.model.name.utf8) }) { differences.append("stop name bytes") }
    return differences
}

/// Encodes then decodes in memory, the way a stored file round-trips.
func roundTrip(_ snapshot: RoutingSnapshot, identity: Data = Data("identity".utf8)) throws -> RoutingSnapshot {
    let file = try RoutingSnapshotCodec.encode(snapshot, identity: identity)
    return try aligned(file) { try RoutingSnapshotCodec.decode($0, identity: identity) }
}

/// Runs `body` over 8-byte aligned memory, as a mapped file would be.
func aligned<T>(_ data: Data, _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
    let words = (data.count + 7) / 8
    let memory = UnsafeMutableRawPointer.allocate(byteCount: max(words * 8, 8), alignment: 8)
    defer { memory.deallocate() }
    data.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: data.count)
    return try body(UnsafeRawBufferPointer(start: memory, count: data.count))
}
