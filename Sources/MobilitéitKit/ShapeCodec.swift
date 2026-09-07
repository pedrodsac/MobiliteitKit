import Foundation

/// Delta and varint codec for one shape at 1e-6 degree precision.
/// A shape is stored as one SQLite BLOB, so rendering a route never scans the
/// 1.5M-row source geometry table.
enum ShapeCodec {
    static let version: UInt8 = 1

    static func decode(_ data: Data) throws -> [Coordinate] {
        var cursor = data.startIndex
        guard readByte(data, &cursor) == version,
              let countValue = readUnsigned(data, &cursor),
              countValue <= UInt64(Int.max),
              let firstLatitude = readSigned(data, &cursor),
              let firstLongitude = readSigned(data, &cursor) else {
            throw GTFSArchiveError.unsupportedArchive("invalid shape blob")
        }

        let count = Int(countValue)
        guard count > 0 else { return [] }
        var result: [Coordinate] = []
        result.reserveCapacity(count)
        var latitude = firstLatitude
        var longitude = firstLongitude
        result.append(coordinate(latitude, longitude))

        for _ in 1..<count {
            guard let latitudeDelta = readSigned(data, &cursor),
                  let longitudeDelta = readSigned(data, &cursor) else {
                throw GTFSArchiveError.unsupportedArchive("truncated shape blob")
            }
            latitude &+= latitudeDelta
            longitude &+= longitudeDelta
            result.append(coordinate(latitude, longitude))
        }
        guard cursor == data.endIndex else {
            throw GTFSArchiveError.unsupportedArchive("trailing shape blob data")
        }
        return result
    }

    private static func coordinate(_ latitude: Int32, _ longitude: Int32) -> Coordinate {
        Coordinate(latitude: Double(latitude) / 1_000_000, longitude: Double(longitude) / 1_000_000)
    }

    private static func readByte(_ data: Data, _ cursor: inout Data.Index) -> UInt8? {
        guard cursor < data.endIndex else { return nil }
        defer { data.formIndex(after: &cursor) }
        return data[cursor]
    }

    private static func readUnsigned(_ data: Data, _ cursor: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = readByte(data, &cursor) {
            guard shift <= 63 else { return nil }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func readSigned(_ data: Data, _ cursor: inout Data.Index) -> Int32? {
        guard let zigZag = readUnsigned(data, &cursor), zigZag <= UInt64(UInt32.max) else { return nil }
        let value = Int64(zigZag >> 1) ^ -Int64(zigZag & 1)
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { return nil }
        return Int32(value)
    }
}

struct ShapeAccumulator {
    let id: String
    private var firstLatitude: Int32
    private var firstLongitude: Int32
    private var previousLatitude: Int32
    private var previousLongitude: Int32
    private var payload = Data()
    private(set) var count = 1
    private(set) var lastSequence: Int

    init(id: String, latitude: Double, longitude: Double, sequence: Int) throws {
        guard let lat = Self.e6(latitude), let lon = Self.e6(longitude) else {
            throw GTFSArchiveError.unsupportedArchive("coordinate outside Int32 precision")
        }
        self.id = id
        firstLatitude = lat
        firstLongitude = lon
        previousLatitude = lat
        previousLongitude = lon
        lastSequence = sequence
    }

    mutating func append(latitude: Double, longitude: Double, sequence: Int) throws {
        guard sequence > lastSequence else {
            throw GTFSArchiveError.unsupportedArchive("shape \(id) has non-increasing point sequence")
        }
        guard let lat = Self.e6(latitude), let lon = Self.e6(longitude) else {
            throw GTFSArchiveError.unsupportedArchive("coordinate outside Int32 precision")
        }
        appendSigned(lat &- previousLatitude, to: &payload)
        appendSigned(lon &- previousLongitude, to: &payload)
        previousLatitude = lat
        previousLongitude = lon
        lastSequence = sequence
        count += 1
    }

    func encoded() -> Data {
        var result = Data([ShapeCodec.version])
        appendUnsigned(UInt64(count), to: &result)
        appendSigned(firstLatitude, to: &result)
        appendSigned(firstLongitude, to: &result)
        result.append(payload)
        return result
    }

    private static func e6(_ value: Double) -> Int32? {
        let rounded = (value * 1_000_000).rounded()
        guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else { return nil }
        return Int32(rounded)
    }
}

private func appendSigned(_ value: Int32, to data: inout Data) {
    let zigZag = UInt64(bitPattern: Int64(value) << 1 ^ Int64(value) >> 63)
    appendUnsigned(zigZag, to: &data)
}

private func appendUnsigned(_ value: UInt64, to data: inout Data) {
    var value = value
    while value >= 0x80 {
        data.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
    }
    data.append(UInt8(value))
}
