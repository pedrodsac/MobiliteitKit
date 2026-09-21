import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A deliberately small SQLite wrapper. It is used only behind the package's
/// actors, so SQLite connections are never shared concurrently.
final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags: Int32 = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            defer { if let handle { sqlite3_close(handle) } }
            throw GTFSArchiveError.database("Unable to open \(path): \(result)")
        }
        self.handle = handle
        try execute("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw GTFSArchiveError.database(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw GTFSArchiveError.database(lastError)
        }
        return SQLiteStatement(database: self, statement: statement)
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

final class SQLiteStatement {
    // A prepared statement must keep its connection alive until finalize.
    // `unowned` allowed the optimizer to release SQLiteDatabase first, making
    // sqlite3_close fail with outstanding statements and sqlite3_finalize hit
    // CoreSimulator's database-tracking assertion afterward.
    private let database: SQLiteDatabase
    private let statement: OpaquePointer

    init(database: SQLiteDatabase, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit { sqlite3_finalize(statement) }

    func reset() throws {
        guard sqlite3_reset(statement) == SQLITE_OK else {
            throw GTFSArchiveError.database(database.lastError)
        }
        guard sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw GTFSArchiveError.database(database.lastError)
        }
    }

    func bind(_ value: String?, at index: Int32) throws {
        let result: Int32
        if let value {
            result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        try check(result)
    }

    func bind(_ value: Int?, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_int64(statement, index, sqlite3_int64(value)))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Int32?, at index: Int32) throws {
        try bind(value.map(Int.init), at: index)
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_int64(statement, index, sqlite3_int64(value)))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Double?, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_double(statement, index, value))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Data?, at index: Int32) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        try check(result)
    }

    /// Returns `true` for a row and `false` once the statement is complete.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw GTFSArchiveError.database(database.lastError)
        }
    }

    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func int32(_ index: Int32) -> Int32 { Int32(sqlite3_column_int(statement, index)) }
    func int64(_ index: Int32) -> Int64 { Int64(sqlite3_column_int64(statement, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }

    func text(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func blob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw GTFSArchiveError.database(database.lastError) }
    }
}
