import Dispatch
import Foundation
import SQLite3

// MARK: - SQLite Errors & Value Types

public struct SQLiteError: Error, LocalizedError, Equatable, Sendable {
    public var code: Int32
    public var extendedCode: Int32
    public var message: String
    public var sql: String?

    public init(code: Int32, extendedCode: Int32 = 0, message: String, sql: String? = nil) {
        self.code = code
        self.extendedCode = extendedCode
        self.message = message
        self.sql = sql
    }

    public var errorDescription: String? {
        if let sql, !sql.isEmpty {
            return "SQLite error (\(code)/\(extendedCode)): \(message) [SQL: \(sql)]"
        }
        return "SQLite error (\(code)/\(extendedCode)): \(message)"
    }
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int64Value: Int64? {
        if case let .integer(v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case let .real(v): return v
        case let .integer(v): return Double(v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case let .text(v) = self { return v }
        return nil
    }

    public var dataValue: Data? {
        if case let .blob(v) = self { return v }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Low-Level Statement & Connection (Actor-Serialized Only)

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStatement {
    let handle: OpaquePointer
    private unowned let connection: SQLiteConnection
    let sql: String
    private var finalized = false

    init(connection: SQLiteConnection, sql: String) throws {
        let dbHandle = try connection.requireHandle()
        var stmt: OpaquePointer?
        let rc = sql.utf8CString.withUnsafeBufferPointer { buf in
            sqlite3_prepare_v2(dbHandle, buf.baseAddress, Int32(buf.count - 1), &stmt, nil)
        }
        guard rc == SQLITE_OK, let validStmt = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw connection.makeError(code: rc, sql: sql)
        }
        self.handle = validStmt
        self.connection = connection
        self.sql = sql
    }

    deinit {
        finalize()
    }

    func finalize() {
        guard !finalized else { return }
        finalized = true
        sqlite3_finalize(handle)
    }

    func reset() {
        guard !finalized else { return }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bindNull(_ index: Int32) throws {
        let rc = sqlite3_bind_null(handle, index)
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindInt64(_ index: Int32, _ value: Int64) throws {
        let rc = sqlite3_bind_int64(handle, index, value)
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindInt(_ index: Int32, _ value: Int) throws {
        try bindInt64(index, Int64(value))
    }

    func bindBool(_ index: Int32, _ value: Bool) throws {
        try bindInt64(index, value ? 1 : 0)
    }

    func bindDateSeconds(_ index: Int32, _ date: Date) throws {
        try bindInt64(index, Int64(date.timeIntervalSince1970))
    }

    func bindDouble(_ index: Int32, _ value: Double?) throws {
        guard let value else {
            try bindNull(index)
            return
        }
        let rc = sqlite3_bind_double(handle, index, value)
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindText(_ index: Int32, _ value: String?) throws {
        guard let value else {
            try bindNull(index)
            return
        }
        if value.isEmpty {
            let rc = sqlite3_bind_text(handle, index, "", 0, nil)
            guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
            return
        }
        let rc = value.utf8CString.withUnsafeBufferPointer { buf in
            sqlite3_bind_text(handle, index, buf.baseAddress, Int32(buf.count - 1), sqliteTransient)
        }
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindUTF8Data(_ index: Int32, _ data: Data?) throws {
        guard let data else {
            try bindNull(index)
            return
        }
        if data.isEmpty {
            let rc = sqlite3_bind_text(handle, index, "", 0, nil)
            guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
            return
        }
        let rc = data.withUnsafeBytes { rawBuf -> Int32 in
            let charBuf = rawBuf.bindMemory(to: CChar.self)
            guard let base = charBuf.baseAddress else {
                return sqlite3_bind_text(handle, index, "", 0, nil)
            }
            return sqlite3_bind_text(handle, index, base, Int32(charBuf.count), sqliteTransient)
        }
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindBlob(_ index: Int32, _ data: Data?) throws {
        guard let data else {
            try bindNull(index)
            return
        }
        if data.isEmpty {
            var emptyByte: UInt8 = 0
            let rc = withUnsafePointer(to: &emptyByte) { ptr in
                sqlite3_bind_blob(handle, index, ptr, 0, sqliteTransient)
            }
            guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
            return
        }
        let rc = data.withUnsafeBytes { rawBuf in
            sqlite3_bind_blob(handle, index, rawBuf.baseAddress, Int32(rawBuf.count), sqliteTransient)
        }
        guard rc == SQLITE_OK else { throw connection.makeError(code: rc, sql: sql) }
    }

    func bindValue(_ index: Int32, _ value: SQLiteValue) throws {
        switch value {
        case .null:
            try bindNull(index)
        case let .integer(v):
            try bindInt64(index, v)
        case let .real(v):
            try bindDouble(index, v)
        case let .text(v):
            try bindText(index, v)
        case let .blob(v):
            try bindBlob(index, v)
        }
    }

    func bindAll(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bindValue(Int32(offset + 1), value)
        }
    }

    /// Advances statement by one row. Returns `true` for `SQLITE_ROW`, `false` for `SQLITE_DONE`.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw connection.makeError(code: rc, sql: sql)
        }
    }

    func columnIsNull(_ col: Int32) -> Bool {
        sqlite3_column_type(handle, col) == SQLITE_NULL
    }

    func columnInt64(_ col: Int32) -> Int64 {
        sqlite3_column_int64(handle, col)
    }

    func columnInt(_ col: Int32) -> Int {
        Int(sqlite3_column_int64(handle, col))
    }

    func columnBool(_ col: Int32) -> Bool {
        sqlite3_column_int64(handle, col) != 0
    }

    func columnDateSeconds(_ col: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(handle, col)))
    }

    func columnOptionalDouble(_ col: Int32) -> Double? {
        guard !columnIsNull(col) else { return nil }
        return sqlite3_column_double(handle, col)
    }

    func columnText(_ col: Int32) -> String {
        guard !columnIsNull(col) else { return "" }
        guard let ptr = sqlite3_column_text(handle, col) else { return "" }
        let byteCount = Int(sqlite3_column_bytes(handle, col))
        if byteCount <= 0 { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: byteCount), as: UTF8.self)
    }

    func columnOptionalText(_ col: Int32) -> String? {
        guard !columnIsNull(col) else { return nil }
        return columnText(col)
    }

    func columnOptionalTextData(_ col: Int32) -> Data? {
        guard !columnIsNull(col) else { return nil }
        let ptr = sqlite3_column_text(handle, col)
        let byteCount = Int(sqlite3_column_bytes(handle, col))
        guard byteCount > 0, let ptr else { return Data() }
        return Data(bytes: ptr, count: byteCount)
    }

    func columnOptionalBlob(_ col: Int32) -> Data? {
        guard !columnIsNull(col) else { return nil }
        let ptr = sqlite3_column_blob(handle, col)
        let byteCount = Int(sqlite3_column_bytes(handle, col))
        guard byteCount > 0, let ptr else { return Data() }
        return Data(bytes: ptr, count: byteCount)
    }

    func columnValue(_ col: Int32) -> SQLiteValue {
        switch sqlite3_column_type(handle, col) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(handle, col))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(handle, col))
        case SQLITE_TEXT:
            return .text(columnText(col))
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(handle, col))
            guard byteCount > 0, let ptr = sqlite3_column_blob(handle, col) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: ptr, count: byteCount))
        default:
            return .null
        }
    }
}

final class SQLiteConnection: @unchecked Sendable {
    static let statementCacheCapacity = 64

    private var handle: OpaquePointer?
    private var transactionDepth: Int = 0
    private var savepointCounter: Int = 0
    private var statementCache: [String: SQLiteStatement] = [:]
    private var statementLRUOrder: [String] = []
    private var touchedCachedSQLs: [String] = []
    let isMemory: Bool

    init(path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let inMem = trimmed.isEmpty || trimmed == ":memory:"
        self.isMemory = inMem

        if !inMem {
            let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if !parentDir.path.isEmpty {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
        }

        var rawDb: OpaquePointer?
        let openPath = inMem ? ":memory:" : path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE
        let rc = sqlite3_open_v2(openPath, &rawDb, flags, nil)
        guard rc == SQLITE_OK, let db = rawDb else {
            let msg = rawDb.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "Failed to open SQLite database at \(openPath)"
            if let rawDb { sqlite3_close_v2(rawDb) }
            throw SQLiteError(code: rc, extendedCode: rc, message: msg)
        }
        self.handle = db
        sqlite3_busy_timeout(db, 5_000)

        do {
            try configureAndMigrate()
        } catch {
            clearStatementCache()
            sqlite3_close_v2(db)
            self.handle = nil
            throw error
        }
    }

    deinit {
        close()
    }

    var isClosed: Bool {
        handle == nil
    }

    var cachedStatementCount: Int {
        statementCache.count
    }

    func close() {
        guard let db = handle else { return }
        clearStatementCache()
        try? execScript("PRAGMA optimize")
        handle = nil
        sqlite3_close_v2(db)
    }

    func clearStatementCache() {
        touchedCachedSQLs.removeAll(keepingCapacity: false)
        statementLRUOrder.removeAll(keepingCapacity: false)
        for stmt in statementCache.values {
            stmt.finalize()
        }
        statementCache.removeAll(keepingCapacity: false)
    }

    func resetTouchedCachedStatements() {
        guard !touchedCachedSQLs.isEmpty else { return }
        for sql in touchedCachedSQLs {
            statementCache[sql]?.reset()
        }
        touchedCachedSQLs.removeAll(keepingCapacity: true)
    }

    func changes() -> Int {
        guard let db = handle else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func requireHandle() throws -> OpaquePointer {
        guard let db = handle else {
            throw SQLiteError(code: SQLITE_MISUSE, extendedCode: SQLITE_MISUSE, message: "SQLiteDatabase is already closed")
        }
        return db
    }

    func makeError(code: Int32, sql: String? = nil) -> SQLiteError {
        guard let db = handle else {
            return SQLiteError(code: code, extendedCode: code, message: "Database closed", sql: sql)
        }
        let ext = sqlite3_extended_errcode(db)
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite error \(code)"
        return SQLiteError(code: code, extendedCode: ext, message: msg, sql: sql)
    }

    func execScript(_ sql: String) throws {
        let db = try requireHandle()
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message: String
            if let errMsg {
                message = String(cString: errMsg)
                sqlite3_free(errMsg)
            } else {
                message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite exec failed"
            }
            throw SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(db), message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        _ = try requireHandle()
        return try SQLiteStatement(connection: self, sql: sql)
    }

    func prepareCached(_ sql: String) throws -> SQLiteStatement {
        _ = try requireHandle()
        if let cached = statementCache[sql] {
            if statementLRUOrder.last != sql {
                if let idx = statementLRUOrder.firstIndex(of: sql) {
                    statementLRUOrder.remove(at: idx)
                }
                statementLRUOrder.append(sql)
            }
            cached.reset()
            if !touchedCachedSQLs.contains(sql) {
                touchedCachedSQLs.append(sql)
            }
            return cached
        }

        let stmt = try SQLiteStatement(connection: self, sql: sql)
        while statementLRUOrder.count >= Self.statementCacheCapacity {
            let oldest = statementLRUOrder.removeFirst()
            statementCache.removeValue(forKey: oldest)
        }
        statementCache[sql] = stmt
        statementLRUOrder.append(sql)
        if !touchedCachedSQLs.contains(sql) {
            touchedCachedSQLs.append(sql)
        }
        return stmt
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bindAll(bindings)
        try stmt.step()
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let stmt = try prepare(sql)
        try stmt.bindAll(bindings)
        let colCount = sqlite3_column_count(stmt.handle)
        var rows: [[SQLiteValue]] = []
        while try stmt.step() {
            var row: [SQLiteValue] = []
            row.reserveCapacity(Int(colCount))
            for col in 0..<colCount {
                row.append(stmt.columnValue(col))
            }
            rows.append(row)
        }
        return rows
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        _ = try requireHandle()
        if transactionDepth == 0 {
            try execScript("BEGIN IMMEDIATE TRANSACTION")
            transactionDepth = 1
            var committed = false
            defer {
                transactionDepth = 0
                if !committed, handle != nil {
                    try? execScript("ROLLBACK")
                }
            }
            let result = try body()
            try execScript("COMMIT")
            committed = true
            return result
        } else {
            savepointCounter += 1
            let spName = "sp_\(savepointCounter)"
            try execScript("SAVEPOINT \(spName)")
            transactionDepth += 1
            var released = false
            defer {
                transactionDepth -= 1
                if !released, handle != nil {
                    try? execScript("ROLLBACK TO SAVEPOINT \(spName); RELEASE SAVEPOINT \(spName)")
                }
            }
            let result = try body()
            try execScript("RELEASE SAVEPOINT \(spName)")
            released = true
            return result
        }
    }

    // MARK: - Pragmas & Migrations (v0..v6 -> v7)

    func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version")
        guard try stmt.step() else { return 0 }
        return stmt.columnInt(0)
    }

    private func tableExists(_ name: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1")
        try stmt.bindText(1, name)
        return try stmt.step()
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let stmt = try prepare("PRAGMA table_info(\(table))")
        while try stmt.step() {
            if stmt.columnText(1) == column {
                return true
            }
        }
        return false
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard try tableExists(table) else { return }
        if try !columnExists(table: table, column: column) {
            try execScript("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }

    private func configureAndMigrate() throws {
        try execScript("PRAGMA foreign_keys = ON")
        if !isMemory {
            try execScript("PRAGMA journal_mode = WAL")
        }
        try execScript("PRAGMA synchronous = NORMAL")
        try execScript("PRAGMA cache_size = -16000")
        try execScript("PRAGMA temp_store = MEMORY")
        if !isMemory {
            try execScript("PRAGMA mmap_size = 67108864")
        }

        let fromVersion = try userVersion()
        let targetVersion = SQLiteDatabase.currentSchemaVersion

        try withTransaction {
            if fromVersion == 0 {
                try createAllTablesAndIndexes()
                try execScript("PRAGMA user_version = \(targetVersion)")
            } else {
                // Ensure base tables exist even if an older DB was partially initialized.
                try createBaseTablesIfNeeded()

                if fromVersion < 2 {
                    try execScript(Self.indexHistoryDstStatusDDL)
                }
                if fromVersion < 3 {
                    try addColumnIfMissing(
                        table: "tasks",
                        column: "scrape",
                        definition: #"INTEGER NOT NULL DEFAULT 0 CHECK ("scrape" IN (0, 1))"#
                    )
                }
                if fromVersion < 4 {
                    try addColumnIfMissing(
                        table: "tasks",
                        column: "scrape_only",
                        definition: #"INTEGER NOT NULL DEFAULT 0 CHECK ("scrape_only" IN (0, 1))"#
                    )
                    try execScript(Self.tableFolderStatsCacheDDL)
                }
                if fromVersion < 5 {
                    try addColumnIfMissing(
                        table: "history_records",
                        column: "overwrite",
                        definition: #"INTEGER NOT NULL DEFAULT 0 CHECK ("overwrite" IN (0, 1))"#
                    )
                    try addColumnIfMissing(
                        table: "tasks",
                        column: "unassigned_deletes_json",
                        definition: "TEXT NULL"
                    )
                }
                if fromVersion < 6 {
                    try execScript(Self.tableTmdbHttpCacheDDL)
                    try execScript(Self.indexTmdbUpdatedAtDDL)
                }
                if fromVersion < 7 {
                    try execScript(Self.tableTaskReviewsDDL)
                    try addColumnIfMissing(
                        table: "tasks",
                        column: "card_meta_json",
                        definition: "TEXT NULL"
                    )
                    try execScript(Self.tableMediaProbeCacheDDL)
                    try execScript(Self.dropRedundantFolderStatsIndexDDL)
                    try execScript("""
                        INSERT OR REPLACE INTO task_reviews (
                            task_id, scan_blob, decisions_json, unassigned_deletes_json
                        )
                        SELECT id, CAST(scan_json AS BLOB), decisions_json, unassigned_deletes_json
                        FROM tasks
                        WHERE scan_json IS NOT NULL
                           OR decisions_json IS NOT NULL
                           OR unassigned_deletes_json IS NOT NULL;
                        """)
                    try execScript("""
                        UPDATE tasks
                        SET scan_json = NULL,
                            decisions_json = NULL,
                            unassigned_deletes_json = NULL
                        WHERE scan_json IS NOT NULL
                           OR decisions_json IS NOT NULL
                           OR unassigned_deletes_json IS NOT NULL;
                        """)
                }

                if fromVersion < 8 {
                    try addColumnIfMissing(table: "history_records", column: "written_digest", definition: "TEXT NULL")
                    // Older scans marked a tree complete even if a child listing failed.
                    // Keep the listings, but verify tree coverage on the next visit.
                    try execScript("UPDATE folder_stats_cache SET complete = 0 WHERE complete = 1")
                }

                // Always ensure all required tables & indexes exist and redundant indexes stay dropped.
                try ensureAllIndexesAndModernTables()

                if fromVersion < targetVersion {
                    try execScript("PRAGMA user_version = \(targetVersion)")
                }
            }
        }
    }

    private func createBaseTablesIfNeeded() throws {
        try execScript(Self.tableBatchesDDL)
        try execScript(Self.tableHistoryRecordsDDL)
        try execScript(Self.tableTasksDDL)
        try execScript(Self.tableFolderStatsCacheDDL)
    }

    private func ensureAllIndexesAndModernTables() throws {
        try execScript(Self.tableTmdbHttpCacheDDL)
        try execScript(Self.tableTaskReviewsDDL)
        try execScript(Self.tableMediaProbeCacheDDL)
        try addColumnIfMissing(
            table: "tasks",
            column: "card_meta_json",
            definition: "TEXT NULL"
        )
        try execScript(Self.dropRedundantFolderStatsIndexDDL)
        try execScript(Self.indexHistoryDstStatusDDL)
        try execScript(Self.indexBatchesConnDDL)
        try execScript(Self.indexBatchesTaskCreatedDDL)
        try execScript(Self.indexHistoryBatchPhaseDDL)
        try execScript(Self.indexHistoryBatchStatusDDL)
        try execScript(Self.indexTmdbUpdatedAtDDL)
        try execScript(Self.indexMediaProbeCacheUpdatedAtDDL)
    }

    private func createAllTablesAndIndexes() throws {
        try createBaseTablesIfNeeded()
        try ensureAllIndexesAndModernTables()
    }

    // Exact Drift v5 + v6 + v7 DDL statements
    private static let tableBatchesDDL = """
        CREATE TABLE IF NOT EXISTS batches (
            id TEXT NOT NULL PRIMARY KEY,
            task_id TEXT NOT NULL,
            connection_id TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        """

    private static let tableHistoryRecordsDDL = #"""
        CREATE TABLE IF NOT EXISTS history_records (
            batch_id TEXT NOT NULL REFERENCES batches (id),
            op_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            kind TEXT NOT NULL,
            phase TEXT NOT NULL,
            src TEXT NOT NULL,
            dst TEXT NOT NULL,
            group_id TEXT NULL,
            selected INTEGER NOT NULL CHECK ("selected" IN (0, 1)),
            warning TEXT NULL,
            overwrite INTEGER NOT NULL DEFAULT 0 CHECK ("overwrite" IN (0, 1)),
            written_digest TEXT NULL,
            status TEXT NOT NULL,
            error TEXT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (batch_id, op_id),
            UNIQUE (batch_id, seq)
        );
        """#

    private static let tableTasksDDL = #"""
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT NOT NULL PRIMARY KEY,
            connection_id TEXT NOT NULL,
            paths_json TEXT NOT NULL,
            mode TEXT NOT NULL,
            scrape INTEGER NOT NULL DEFAULT 0 CHECK ("scrape" IN (0, 1)),
            scrape_only INTEGER NOT NULL DEFAULT 0 CHECK ("scrape_only" IN (0, 1)),
            stage TEXT NOT NULL,
            message TEXT NOT NULL,
            imported_count INTEGER NOT NULL,
            video_count INTEGER NOT NULL,
            folder_count INTEGER NOT NULL,
            subtitle_count INTEGER NOT NULL,
            progress REAL NULL,
            batch_id TEXT NULL,
            created_at INTEGER NOT NULL,
            scan_json TEXT NULL,
            decisions_json TEXT NULL,
            unassigned_deletes_json TEXT NULL,
            card_meta_json TEXT NULL
        );
        """#

    private static let tableTaskReviewsDDL = """
        CREATE TABLE IF NOT EXISTS task_reviews (
            task_id TEXT NOT NULL PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
            scan_blob BLOB NULL,
            decisions_json TEXT NULL,
            unassigned_deletes_json TEXT NULL
        );
        """

    private static let tableFolderStatsCacheDDL = #"""
        CREATE TABLE IF NOT EXISTS folder_stats_cache (
            connection_id TEXT NOT NULL,
            dir_path TEXT NOT NULL,
            entries_json TEXT NOT NULL,
            complete INTEGER NOT NULL DEFAULT 0 CHECK ("complete" IN (0, 1)),
            scanned_at INTEGER NOT NULL,
            PRIMARY KEY (connection_id, dir_path)
        );
        """#

    private static let tableTmdbHttpCacheDDL = """
        CREATE TABLE IF NOT EXISTS tmdb_http_cache (
            cache_key TEXT NOT NULL PRIMARY KEY,
            json_text TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """

    private static let tableMediaProbeCacheDDL = """
        CREATE TABLE IF NOT EXISTS media_probe_cache (
            connection_id TEXT NOT NULL,
            path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            probe_json TEXT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (connection_id, path)
        );
        """

    private static let dropRedundantFolderStatsIndexDDL =
        "DROP INDEX IF EXISTS folder_stats_cache_conn;"
    private static let indexHistoryDstStatusDDL =
        "CREATE INDEX IF NOT EXISTS history_records_dst_status ON history_records (dst, status);"
    private static let indexBatchesConnDDL =
        "CREATE INDEX IF NOT EXISTS idx_batches_conn ON batches (connection_id);"
    private static let indexBatchesTaskCreatedDDL =
        "CREATE INDEX IF NOT EXISTS idx_batches_task_created ON batches (task_id, created_at DESC);"
    private static let indexHistoryBatchPhaseDDL =
        "CREATE INDEX IF NOT EXISTS idx_history_batch_phase ON history_records (batch_id, phase, kind, status);"
    private static let indexHistoryBatchStatusDDL =
        "CREATE INDEX IF NOT EXISTS idx_history_batch_status ON history_records (batch_id, status);"
    private static let indexTmdbUpdatedAtDDL =
        "CREATE INDEX IF NOT EXISTS idx_tmdb_http_cache_updated_at ON tmdb_http_cache (updated_at);"
    private static let indexMediaProbeCacheUpdatedAtDDL =
        "CREATE INDEX IF NOT EXISTS idx_media_probe_cache_updated_at ON media_probe_cache (updated_at);"
}

// MARK: - Public SQLiteDatabase Actor

/// Pure-Swift SQLite3 database actor serialized on a dedicated background `DispatchSerialQueue`.
/// Never blocks `@MainActor` or starves Swift's cooperative thread pool during disk I/O.
public actor SQLiteDatabase {
    public static let currentSchemaVersion: Int = 8

    private let serialQueue: DispatchSerialQueue
    private let connection: SQLiteConnection

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialQueue.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        let queue = DispatchSerialQueue(label: "app.tidyreel.persistence.sqlite", qos: .userInitiated)
        self.serialQueue = queue
        self.connection = try queue.sync {
            try SQLiteConnection(path: path)
        }
    }

    public init(url: URL) throws {
        try self.init(path: url.path)
    }

    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    public func close() async {
        connection.close()
    }

    public func schemaVersion() throws -> Int {
        try connection.userVersion()
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try connection.execute(sql, bindings: bindings)
    }

    public func executeScript(_ sql: String) throws {
        try connection.execScript(sql)
    }

    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try connection.query(sql, bindings: bindings)
    }

    func withConnection<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) throws -> T {
        _ = try connection.requireHandle()
        defer { connection.resetTouchedCachedStatements() }
        return try body(connection)
    }
}
