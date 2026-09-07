import Foundation

/// A row-at-a-time RFC 4180 reader. Its memory use is bounded by one line and a
/// 64 KiB file chunk, even for `stop_times.txt` and `shapes.txt`.
struct StreamingCSV {
    private let file: String
    private let handle: FileHandle
    private var chunk: [UInt8] = []
    private var chunkOffset = 0
    private var lineNumber = 0
    private var reachedEnd = false
    private(set) var headers: [String: Int]

    init(url: URL, file: String) throws {
        self.file = file
        handle = try FileHandle(forReadingFrom: url)
        headers = [:]
        guard let header = try nextFields() else {
            throw GTFSArchiveError.malformedCSV(file: file, line: 1, reason: "missing header")
        }
        var columns: [String: Int] = [:]
        for (index, value) in header.enumerated() {
            let normalized = index == 0 ? value.trimmingPrefix("\u{FEFF}") : value
            columns[normalized] = index
        }
        headers = columns
    }

    mutating func nextRow() throws -> CSVRow? {
        guard let fields = try nextFields() else { return nil }
        return CSVRow(file: file, line: lineNumber, fields: fields, headers: headers)
    }

    mutating func requireColumn(_ name: String) throws {
        guard headers[name] != nil else {
            throw GTFSArchiveError.missingColumn(file: file, column: name)
        }
    }

    private mutating func nextFields() throws -> [String]? {
        guard let bytes = try nextLine() else { return nil }
        lineNumber += 1
        return try Self.parse(bytes, file: file, line: lineNumber)
    }

    private mutating func nextLine() throws -> [UInt8]? {
        if reachedEnd { return nil }
        var line: [UInt8] = []
        while true {
            if chunkOffset == chunk.count {
                let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                chunk = Array(data)
                chunkOffset = 0
                if chunk.isEmpty {
                    reachedEnd = true
                    return line.isEmpty ? nil : line
                }
            }
            let byte = chunk[chunkOffset]
            chunkOffset += 1
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                return line
            }
            line.append(byte)
        }
    }

    private static func parse(_ bytes: [UInt8], file: String, line: Int) throws -> [String] {
        var values: [String] = []
        var current: [UInt8] = []
        var quoted = false
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 0x22 { // quote
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        current.append(byte)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(byte)
                }
            } else if byte == 0x2C { // comma
                values.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else if byte == 0x22, current.isEmpty {
                quoted = true
            } else {
                current.append(byte)
            }
            index += 1
        }
        guard !quoted else {
            throw GTFSArchiveError.malformedCSV(file: file, line: line, reason: "unterminated quote")
        }
        values.append(String(decoding: current, as: UTF8.self))
        return values
    }
}

struct CSVRow {
    let file: String
    let line: Int
    private let fields: [String]
    private let headers: [String: Int]

    init(file: String, line: Int, fields: [String], headers: [String: Int]) {
        self.file = file
        self.line = line
        self.fields = fields
        self.headers = headers
    }

    func required(_ column: String) throws -> String {
        guard let index = headers[column], index < fields.count else {
            throw GTFSArchiveError.missingColumn(file: file, column: column)
        }
        let value = fields[index]
        guard !value.isEmpty else {
            throw GTFSArchiveError.invalidValue(file: file, line: line, column: column, value: value)
        }
        return value
    }

    func optional(_ column: String) -> String? {
        guard let index = headers[column], index < fields.count, !fields[index].isEmpty else { return nil }
        return fields[index]
    }

    func integer(_ column: String, required: Bool = true) throws -> Int? {
        let text = required ? try self.required(column) : optional(column)
        guard let text else { return nil }
        guard let value = Int(text) else {
            throw GTFSArchiveError.invalidValue(file: file, line: line, column: column, value: text)
        }
        return value
    }

    func double(_ column: String, required: Bool = true) throws -> Double? {
        let text = required ? try self.required(column) : optional(column)
        guard let text else { return nil }
        guard let value = Double(text) else {
            throw GTFSArchiveError.invalidValue(file: file, line: line, column: column, value: text)
        }
        return value
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
