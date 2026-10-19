import Foundation

#if !_endian(little)
#error("The routing snapshot file stores little-endian columns and is read in place.")
#endif

/// Failures of the snapshot file layer. None of them is fatal: the caller
/// rebuilds the snapshot from the database and rewrites the file.
enum SnapshotFileError: Error, Equatable, Sendable {
    /// The snapshot holds a value the compact columns cannot represent exactly.
    case unencodable(String)
    case corrupt(String)
}

/// Section markers. A reader that drifts out of step fails at the next marker
/// instead of misreading columns.
struct SnapshotTag: Equatable {
    let rawValue: UInt64
    init(_ name: StaticString) {
        precondition(name.utf8CodeUnitCount <= 8)
        var value: UInt64 = 0
        for (index, byte) in UnsafeBufferPointer(start: name.utf8Start, count: name.utf8CodeUnitCount).enumerated() {
            value |= UInt64(byte) << UInt64(8 * index)
        }
        rawValue = value
    }
}

/// Appends little-endian, 8-byte aligned columns.
struct SnapshotWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    mutating func append(_ value: UInt64) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int) { append(UInt64(bitPattern: Int64(value))) }
    mutating func append(_ tag: SnapshotTag) { append(tag.rawValue) }

    /// A count followed by the raw elements, padded to the next 8 bytes.
    mutating func column<T: FixedWidthInteger>(_ values: [T]) {
        append(UInt64(values.count))
        values.withUnsafeBytes { bytes.append(contentsOf: $0) }
        pad()
    }

    /// Bytes without a count prefix, for the header, whose lengths the reader knows.
    mutating func rawBytesUnprefixed(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
        pad()
    }

    mutating func append(contentsOf other: SnapshotWriter) {
        bytes.append(contentsOf: other.bytes)
    }

    private mutating func pad() {
        let remainder = bytes.count & 7
        if remainder != 0 { bytes.append(contentsOf: repeatElement(0, count: 8 - remainder)) }
    }

    /// Offsets (count + 1 entries) and flattened values for a list of lists.
    mutating func lists(_ lists: [[Int]]) throws {
        var offsets: [UInt32] = []; offsets.reserveCapacity(lists.count + 1); offsets.append(0)
        var values: [Int32] = []; values.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        for list in lists {
            for value in list { values.append(try SnapshotNarrow.int32(value, "list element")) }
            offsets.append(try SnapshotNarrow.uint32(values.count, "list offset"))
        }
        column(offsets); column(values)
    }
}

enum SnapshotNarrow {
    static func int32(_ value: Int, _ what: @autoclosure () -> String) throws -> Int32 {
        guard let narrowed = Int32(exactly: value) else { throw SnapshotFileError.unencodable("\(what()) \(value) exceeds 32 bits") }
        return narrowed
    }
    static func uint32(_ value: Int, _ what: @autoclosure () -> String) throws -> UInt32 {
        guard let narrowed = UInt32(exactly: value) else { throw SnapshotFileError.unencodable("\(what()) \(value) exceeds 32 bits") }
        return narrowed
    }
    static func uint8(_ value: Int, _ what: @autoclosure () -> String) throws -> UInt8 {
        guard let narrowed = UInt8(exactly: value) else { throw SnapshotFileError.unencodable("\(what()) \(value) exceeds 8 bits") }
        return narrowed
    }
}

/// Reads columns in place from a mapped file. Every access is bounds-checked
/// against the buffer, so a damaged file throws instead of trapping.
struct SnapshotCursor {
    private let base: UnsafeRawPointer
    private let size: Int
    private(set) var offset: Int

    init(_ buffer: UnsafeRawBufferPointer, offset: Int = 0) throws {
        guard let address = buffer.baseAddress, Int(bitPattern: address) & 7 == 0 else {
            throw SnapshotFileError.corrupt("buffer is not 8-byte aligned")
        }
        base = address; size = buffer.count; self.offset = offset
    }

    mutating func u64() throws -> UInt64 {
        guard offset >= 0, size - offset >= 8 else { throw SnapshotFileError.corrupt("truncated") }
        defer { offset += 8 }
        return base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
    }

    mutating func int() throws -> Int { Int(Int64(bitPattern: try u64())) }

    mutating func expect(_ tag: SnapshotTag) throws {
        guard try u64() == tag.rawValue else { throw SnapshotFileError.corrupt("section marker mismatch") }
    }

    mutating func column<T: FixedWidthInteger>(_ type: T.Type) throws -> UnsafeBufferPointer<T> {
        let count = try u64()
        let stride = MemoryLayout<T>.stride
        guard count <= UInt64((size - offset) / stride) else { throw SnapshotFileError.corrupt("column exceeds file") }
        let n = Int(count)
        let padded = (n * stride + 7) & ~7
        guard padded <= size - offset else { throw SnapshotFileError.corrupt("column padding exceeds file") }
        let start = (base + offset).bindMemory(to: T.self, capacity: n)
        offset += padded
        return UnsafeBufferPointer(start: start, count: n)
    }

    /// Offsets and values written by `SnapshotWriter.lists`, validated.
    mutating func lists(expecting count: Int? = nil, valueLimit: Int? = nil) throws -> (offsets: UnsafeBufferPointer<UInt32>, values: UnsafeBufferPointer<Int32>) {
        let offsets = try column(UInt32.self), values = try column(Int32.self)
        guard !offsets.isEmpty, count.map({ offsets.count == $0 + 1 }) ?? true, offsets.first == 0, Int(offsets[offsets.count - 1]) == values.count else {
            throw SnapshotFileError.corrupt("list offsets")
        }
        var previous: UInt32 = 0
        for offset in offsets { guard offset >= previous else { throw SnapshotFileError.corrupt("list offsets") }; previous = offset }
        if let valueLimit {
            for value in values { guard value >= 0, Int(value) < valueLimit else { throw SnapshotFileError.corrupt("list value") } }
        }
        return (offsets, values)
    }
}

extension UnsafeBufferPointer where Element == UInt32 {
    /// Materializes the lists written by `SnapshotWriter.lists`.
    func lists(_ values: UnsafeBufferPointer<Int32>) -> [[Int]] {
        (0..<(count - 1)).map { index in
            let low = Int(self[index]), high = Int(self[index + 1])
            return [Int](unsafeUninitializedCapacity: high - low) { buffer, initialized in
                for position in low..<high { buffer[position - low] = Int(values[position]) }
                initialized = high - low
            }
        }
    }
}

/// XXH64: fast corruption detection for the payload. It is not a security
/// measure; the cache directory is private to the app.
enum SnapshotChecksum {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87, p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9, p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always) private static func rotate(_ value: UInt64, _ bits: UInt64) -> UInt64 { (value << bits) | (value >> (64 - bits)) }
    @inline(__always) private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        rotate(accumulator &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        (hash ^ round(0, value)) &* p1 &+ p4
    }

    static func hash(_ buffer: UnsafeRawBufferPointer) -> UInt64 {
        guard let base = buffer.baseAddress else { return avalanche(p5) }
        let length = buffer.count
        var offset = 0
        var hash: UInt64
        if length >= 32 {
            var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
            while length - offset >= 32 {
                v1 = round(v1, base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                v2 = round(v2, base.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
                v3 = round(v3, base.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self))
                v4 = round(v4, base.loadUnaligned(fromByteOffset: offset + 24, as: UInt64.self))
                offset += 32
            }
            hash = rotate(v1, 1) &+ rotate(v2, 7) &+ rotate(v3, 12) &+ rotate(v4, 18)
            hash = merge(hash, v1); hash = merge(hash, v2); hash = merge(hash, v3); hash = merge(hash, v4)
        } else {
            hash = p5
        }
        hash &+= UInt64(length)
        while length - offset >= 8 {
            hash ^= round(0, base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            hash = rotate(hash, 27) &* p1 &+ p4
            offset += 8
        }
        if length - offset >= 4 {
            hash ^= UInt64(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) &* p1
            hash = rotate(hash, 23) &* p2 &+ p3
            offset += 4
        }
        while offset < length {
            hash ^= UInt64(base.load(fromByteOffset: offset, as: UInt8.self)) &* p5
            hash = rotate(hash, 11) &* p1
            offset += 1
        }
        return avalanche(hash)
    }

    private static func avalanche(_ value: UInt64) -> UInt64 {
        var hash = value
        hash ^= hash >> 33; hash = hash &* p2; hash ^= hash >> 29; hash = hash &* p3; hash ^= hash >> 32
        return hash
    }
}
