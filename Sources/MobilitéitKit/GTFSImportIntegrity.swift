import Foundation

extension GTFSArchiveInstaller {
    /// Validate the staged database before the atomic replacement of a usable feed.
    static func validateRoutingIntegrity(in database: SQLiteDatabase) throws {
        let times = try database.prepare("SELECT trip_id,sequence,arrival_sec,departure_sec FROM stop_time ORDER BY trip_id,sequence")
        var trip: Int?; var sequence: Int?; var previous: Int32?
        while try times.step() {
            if trip != times.int(0) { trip = times.int(0); sequence = nil; previous = nil }
            guard sequence.map({ times.int(1) > $0 }) ?? true else { throw invalid("stop_sequence") }
            sequence = times.int(1)
            for column: Int32 in [2, 3] where !times.isNull(column) {
                let instant = times.int32(column)
                guard instant >= 0, previous.map({ instant >= $0 }) ?? true else { throw invalid("arrival_time/departure_time") }
                previous = instant
            }
        }
        let paths = try database.prepare("SELECT traversal_time,length FROM pathway")
        while try paths.step() {
            if (!paths.isNull(0) && paths.int(0) <= 0) || (!paths.isNull(1) && (!paths.double(1).isFinite || paths.double(1) < 0)) {
                throw GTFSArchiveError.invalidValue(file: "pathways.txt", line: 0, column: "traversal_time/length", value: "positive movement required")
            }
        }
        let transfers = try database.prepare("SELECT min_transfer_sec FROM transfer_rule WHERE min_transfer_sec < 0")
        if try transfers.step() { throw GTFSArchiveError.invalidValue(file: "transfers.txt", line: 0, column: "min_transfer_time", value: "negative") }
    }
    private static func invalid(_ column: String) -> GTFSArchiveError {
        .invalidValue(file: "stop_times.txt", line: 0, column: column, value: "non-monotonic trip timeline")
    }
}
