import Foundation

/// A GTFS time expressed as seconds from the beginning of its service day.
///
/// Unlike `DateComponents.hour`, this deliberately permits values after 24:00.
/// For example, `25:15:00` is 90,900 seconds and still belongs to the preceding
/// GTFS service day.
public struct ServiceTime: RawRepresentable, Hashable, Sendable, Comparable, Codable {
    /// The number of seconds since the start of the GTFS service day.
    public let rawValue: Int32

    /// Creates a service time from a raw service-day offset.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Parses an `HH:mm:ss` GTFS time, including hours greater than 23.
    ///
    /// - Parameter text: A GTFS time such as `05:10:00` or `25:10:00`.
    /// - Throws: ``GTFSArchiveError/invalidServiceTime(_:)`` when the value is
    ///   not a valid three-component time.
    public init(parsing text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hour = Int32(parts[0]),
              let minute = Int32(parts[1]),
              let second = Int32(parts[2]),
              hour >= 0,
              (0..<60).contains(minute),
              (0..<60).contains(second) else {
            throw GTFSArchiveError.invalidServiceTime(text)
        }
        self.rawValue = hour * 3_600 + minute * 60 + second
    }

    /// The hour component, without wrapping after midnight.
    public var hours: Int { Int(rawValue / 3_600) }
    /// The minute component.
    public var minutes: Int { Int((rawValue % 3_600) / 60) }
    /// The second component.
    public var seconds: Int { Int(rawValue % 60) }

    /// Renders the GTFS value without wrapping after midnight.
    public var gtfsString: String {
        String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A calendar date in a GTFS feed, intentionally separate from a wall-clock `Date`.
public struct GTFSDate: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// The calendar year in the UTC-based GTFS calendar.
    public let year: Int
    /// The calendar month in the range 1...12.
    public let month: Int
    /// The day of the month.
    public let day: Int

    /// Creates a validated GTFS calendar date.
    public init(year: Int, month: Int, day: Int) throws {
        let components = DateComponents(calendar: Self.utcCalendar, year: year, month: month, day: day)
        guard Self.utcCalendar.date(from: components) != nil else {
            throw GTFSArchiveError.invalidDate("\(year)-\(month)-\(day)")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the compact `yyyyMMdd` representation used by GTFS files.
    public init(parsing value: String) throws {
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count == 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.suffix(2)) else {
            throw GTFSArchiveError.invalidDate(value)
        }
        try self.init(year: year, month: month, day: day)
    }

    /// Returns the compact `yyyyMMdd` representation.
    public var compactString: String {
        String(format: "%04d%02d%02d", year, month, day)
    }

    /// Returns an ISO-like `yyyy-MM-dd` representation.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Returns a date offset by the specified number of calendar days.
    public func adding(days: Int) -> GTFSDate {
        let date = Self.utcCalendar.date(byAdding: .day, value: days, to: foundationDate)!
        let components = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return try! GTFSDate(year: components.year!, month: components.month!, day: components.day!)
    }

    /// Returns the signed number of calendar days from this date to another.
    public func days(until other: GTFSDate) -> Int {
        Self.utcCalendar.dateComponents([.day], from: foundationDate, to: other.foundationDate).day!
    }

    public static func < (lhs: GTFSDate, rhs: GTFSDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    internal var foundationDate: Date {
        Self.utcCalendar.date(from: DateComponents(calendar: Self.utcCalendar, year: year, month: month, day: day))!
    }

    internal static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

/// A compact, zero-based date offset into the installed feed.
public struct ServiceDay: Hashable, Sendable, Comparable, Codable {
    /// The zero-based offset from ``FeedInfo/firstServiceDate``.
    public let index: Int32
    /// Creates a service-day offset.
    public init(index: Int32) { self.index = index }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.index < rhs.index }
}

/// A WGS-84 latitude/longitude pair.
public struct Coordinate: Hashable, Sendable, Codable {
    /// Latitude in decimal degrees.
    public let latitude: Double
    /// Longitude in decimal degrees.
    public let longitude: Double
    /// Creates a coordinate in decimal degrees.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Metadata materialized when a GTFS archive is installed.
public struct FeedInfo: Hashable, Sendable, Codable {
    /// First date covered by the installed service calendar.
    public let firstServiceDate: GTFSDate
    /// Last date covered by the installed service calendar.
    public let lastServiceDate: GTFSDate
    /// Greatest service-day time found in the imported stop times.
    public let maximumServiceTime: ServiceTime
    /// Caller-supplied generation number for this installed feed.
    public let generation: Int
}

/// An operator from `agency.txt`.
public struct Agency: Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let url: String?
    public let timeZone: String
    public let language: String?
    public let phone: String?
}

/// A route from `routes.txt`.
public struct TransitRoute: Hashable, Sendable, Codable {
    public let id: String
    public let agencyID: String?
    public let shortName: String?
    public let longName: String?
    public let type: Int
    public let color: String?
    public let textColor: String?
    public let routeDescription: String?
}

/// A stop from `stops.txt`.
public struct TransitStop: Hashable, Sendable, Codable {
    public let id: String
    public let code: String?
    public let name: String
    public let stopDescription: String?
    public let coordinate: Coordinate
    public let locationType: Int
    public let parentStationID: String?
    /// GTFS `0` means unknown, not inaccessible.
    public let wheelchairBoarding: Int
    public let platformCode: String?
}

/// A trip from `trips.txt`.
public struct TransitTrip: Hashable, Sendable, Codable {
    public let id: String
    public let routeID: String
    public let serviceID: String
    public let headsign: String?
    public let shortName: String?
    public let directionID: Int?
    public let blockID: String?
    public let shapeID: String?
    /// GTFS `0` means unknown, not disallowed.
    public let wheelchairAccessible: Int
    /// GTFS `0` means unknown, not disallowed.
    public let bikesAllowed: Int
}

/// A stop-time row joined with its decoded stop.
public struct TripStopTime: Hashable, Sendable, Codable {
    public let tripID: String
    public let stop: TransitStop
    public let sequence: Int
    public let arrival: ServiceTime?
    public let departure: ServiceTime?
    public let stopHeadsign: String?
    public let pickupType: Int
    public let dropOffType: Int
}

/// A frequency-based service interval from `frequencies.txt`.
public struct Frequency: Hashable, Sendable, Codable {
    public let tripID: String
    public let startTime: ServiceTime
    public let endTime: ServiceTime
    public let headwaySeconds: Int
    public let exactTimes: Int?
}

/// The regular weekly portion of a GTFS service calendar. Calendar-date
/// additions/removals are exposed separately and must be applied as overrides.
public struct ServiceCalendar: Hashable, Sendable, Codable {
    public let serviceID: String
    /// Monday through Sunday, using the original GTFS 0/1 values.
    public let weekdays: [Int]
    public let startDate: GTFSDate
    public let endDate: GTFSDate
}

public struct CalendarException: Hashable, Sendable, Codable {
    public let serviceID: String
    public let date: GTFSDate
    /// 1 adds the service; 2 removes it.
    public let exceptionType: Int
}

/// A source transfer rule from `transfers.txt`.
public struct TransferRule: Hashable, Sendable, Codable {
    public let fromStopID: String
    public let toStopID: String
    public let transferType: Int
    public let minimumTransferSeconds: Int?
    public let fromRouteID: String?
    public let toRouteID: String?
    public let fromTripID: String?
    public let toTripID: String?
}

/// A scheduled arrival or departure returned by a store query.
///
/// The type is shared by both directions of a schedule query: inspect
/// ``departure`` for departures and ``arrival`` for arrivals.
public struct ScheduledDeparture: Hashable, Sendable, Codable {
    public let tripID: String
    public let stopID: String
    public let route: TransitRoute
    public let agency: Agency?
    public let headsign: String?
    public let directionID: Int?
    public let arrival: ServiceTime?
    public let departure: ServiceTime?
    public let pickupType: Int
    public let dropOffType: Int
    public let serviceDay: ServiceDay
}

/// A decoded polyline-like GTFS shape.
public struct Shape: Hashable, Sendable {
    public let id: String
    public let coordinates: [Coordinate]
}

/// Errors raised while downloading, parsing, or installing a GTFS archive.
public enum GTFSArchiveError: Error, LocalizedError, Sendable, Equatable {
    case invalidServiceTime(String)
    case invalidDate(String)
    case malformedCSV(file: String, line: Int, reason: String)
    case missingRequiredFile(String)
    case missingColumn(file: String, column: String)
    case invalidValue(file: String, line: Int, column: String, value: String)
    case inconsistentShapeOrder(String)
    case downloadFailed(statusCode: Int)
    case database(String)
    case unsupportedArchive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServiceTime(let value): return "Invalid GTFS service time: \(value)"
        case .invalidDate(let value): return "Invalid GTFS date: \(value)"
        case .malformedCSV(let file, let line, let reason): return "Malformed \(file) at line \(line): \(reason)"
        case .missingRequiredFile(let file): return "The GTFS archive is missing \(file)."
        case .missingColumn(let file, let column): return "\(file) is missing required column \(column)."
        case .invalidValue(let file, let line, let column, let value): return "Invalid \(column) value \(value) in \(file) line \(line)."
        case .inconsistentShapeOrder(let id): return "Shape \(id) is not contiguous in shapes.txt."
        case .downloadFailed(let statusCode): return "The GTFS download returned HTTP \(statusCode)."
        case .database(let message): return "SQLite error: \(message)"
        case .unsupportedArchive(let message): return "Unsupported GTFS archive: \(message)"
        }
    }
}
