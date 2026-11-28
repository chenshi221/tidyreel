import Foundation
import TidyreelModels

/// Pure-Swift `FolderStatsCacheStore` backed by `SQLiteDatabase`, compatible with Drift's
/// `folder_stats_cache` table (`folder_stats_store.dart`).
/// Reads rows and decodes `entries_json` in a single pass entirely on the background SQLite actor.
public final class SQLiteFolderStatsStore: FolderStatsCacheStore, Sendable {
    private let db: SQLiteDatabase

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public func loadFor(_ connection: ConnectionId) async throws -> [String: CachedFolderRecord] {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT dir_path, entries_json, complete, scanned_at
                FROM folder_stats_cache
                WHERE connection_id = ?
                """)
            try stmt.bindText(1, connection.value)
            return try Self.readFolderRecords(from: stmt)
        }
    }

    /// Loads cached rows at or below `root` using an indexed B-tree prefix range scan
    /// on `PRIMARY KEY (connection_id, dir_path)`.
    public func loadBelow(connection: ConnectionId, root: String) async throws -> [String: CachedFolderRecord] {
        let norm = normalizeDir(root)
        if norm == "/" {
            return try await loadFor(connection)
        }
        let prefix = norm + "/"
        let upper = norm + "0" // ASCII '/' (47) + 1 == '0' (48)
        return try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT dir_path, entries_json, complete, scanned_at
                FROM folder_stats_cache
                WHERE connection_id = ? AND (dir_path = ? OR (dir_path >= ? AND dir_path < ?))
                """)
            try stmt.bindText(1, connection.value)
            try stmt.bindText(2, norm)
            try stmt.bindText(3, prefix)
            try stmt.bindText(4, upper)
            return try Self.readFolderRecords(from: stmt)
        }
    }

    /// Reads only completion metadata for ancestors when opening a cached subtree.
    public func completeAncestors(connection: ConnectionId, root: String) async throws -> [String: Date] {
        let ancestors = Self.ancestorDirs(of: normalizeDir(root))
        guard !ancestors.isEmpty else { return [:] }
        return try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT scanned_at FROM folder_stats_cache
                WHERE connection_id = ? AND dir_path = ? AND complete = 1
                """)
            var result: [String: Date] = [:]
            for path in ancestors {
                stmt.reset()
                try stmt.bindText(1, connection.value)
                try stmt.bindText(2, path)
                if try stmt.step() { result[path] = stmt.columnDateSeconds(0) }
            }
            stmt.reset()
            return result
        }
    }

    public func saveBatch(connection: ConnectionId, records: [CachedFolderRecord]) async throws {
        if records.isEmpty { return }
        try await db.withConnection { conn in
            try conn.withTransaction {
                let stmt = try conn.prepareCached("""
                    INSERT INTO folder_stats_cache (
                        connection_id, dir_path, entries_json, complete, scanned_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(connection_id, dir_path) DO UPDATE SET
                        entries_json = excluded.entries_json,
                        complete = excluded.complete,
                        scanned_at = excluded.scanned_at
                    """)
                for record in records {
                    let entriesJson: String = try autoreleasepool {
                        try TidyreelCodecs.entriesToCompactJson(record.entries)
                    }
                    stmt.reset()
                    try stmt.bindText(1, connection.value)
                    try stmt.bindText(2, record.dirPath)
                    try stmt.bindText(3, entriesJson)
                    try stmt.bindBool(4, record.complete)
                    try stmt.bindDateSeconds(5, record.scannedAt)
                    try stmt.step()
                }
            }
        }
    }

    public func saveDir(
        connection: ConnectionId,
        dirPath: String,
        entries: [RemoteEntry],
        complete: Bool = false,
        scannedAt: Date = Date()
    ) async throws {
        try await saveBatch(
            connection: connection,
            records: [
                CachedFolderRecord(
                    dirPath: dirPath,
                    entries: entries,
                    complete: complete,
                    scannedAt: scannedAt
                ),
            ]
        )
    }

    public func markComplete(
        connection: ConnectionId,
        dirPath: String,
        scannedAt: Date = Date()
    ) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                UPDATE folder_stats_cache
                SET complete = 1, scanned_at = ?
                WHERE connection_id = ? AND dir_path = ?
                """)
            try stmt.bindDateSeconds(1, scannedAt)
            try stmt.bindText(2, connection.value)
            try stmt.bindText(3, dirPath)
            try stmt.step()
        }
    }

    /// Deletes cached rows at or below `root` via an indexed B-tree range DELETE,
    /// and marks computed ancestor directories incomplete.
    public func deleteBelow(connection: ConnectionId, root: String) async throws {
        let norm = normalizeDir(root)
        if norm == "/" {
            try await clearFor(connection)
            return
        }

        let prefix = norm + "/"
        let upper = norm + "0" // ASCII '/' (47) + 1 == '0' (48)
        let ancestors = Self.ancestorDirs(of: norm)

        try await db.withConnection { conn in
            try conn.withTransaction {
                let delStmt = try conn.prepareCached("""
                    DELETE FROM folder_stats_cache
                    WHERE connection_id = ? AND (dir_path = ? OR (dir_path >= ? AND dir_path < ?))
                    """)
                try delStmt.bindText(1, connection.value)
                try delStmt.bindText(2, norm)
                try delStmt.bindText(3, prefix)
                try delStmt.bindText(4, upper)
                try delStmt.step()

                if !ancestors.isEmpty {
                    let invStmt = try conn.prepareCached("""
                        UPDATE folder_stats_cache
                        SET complete = 0
                        WHERE connection_id = ? AND dir_path = ?
                        """)
                    for ancestor in ancestors {
                        invStmt.reset()
                        try invStmt.bindText(1, connection.value)
                        try invStmt.bindText(2, ancestor)
                        try invStmt.step()
                    }
                }
            }
        }
    }

    /// Invalidates specific mutated directories and marks their ancestor directories incomplete
    /// without discarding cached sibling or child directory rows.
    public func deleteDirs(connection: ConnectionId, dirs: [String]) async throws {
        guard !dirs.isEmpty else { return }

        var targets: Set<String> = []
        targets.reserveCapacity(dirs.count)
        for raw in dirs {
            targets.insert(normalizeDir(raw))
        }

        var ancestors: Set<String> = []
        for dir in targets {
            for ancestor in Self.ancestorDirs(of: dir) where !targets.contains(ancestor) {
                ancestors.insert(ancestor)
            }
        }

        let targetList = Array(targets)
        let ancestorList = Array(ancestors)

        try await db.withConnection { conn in
            try conn.withTransaction {
                let delStmt = try conn.prepareCached("""
                    DELETE FROM folder_stats_cache
                    WHERE connection_id = ? AND dir_path = ?
                    """)
                for dir in targetList {
                    delStmt.reset()
                    try delStmt.bindText(1, connection.value)
                    try delStmt.bindText(2, dir)
                    try delStmt.step()
                }

                if !ancestorList.isEmpty {
                    let invStmt = try conn.prepareCached("""
                        UPDATE folder_stats_cache
                        SET complete = 0
                        WHERE connection_id = ? AND dir_path = ?
                        """)
                    for ancestor in ancestorList {
                        invStmt.reset()
                        try invStmt.bindText(1, connection.value)
                        try invStmt.bindText(2, ancestor)
                        try invStmt.step()
                    }
                }
            }
        }
    }

    public func clearFor(_ connection: ConnectionId) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("DELETE FROM folder_stats_cache WHERE connection_id = ?")
            try stmt.bindText(1, connection.value)
            try stmt.step()
        }
    }

    // MARK: - Helpers

    private static func readFolderRecords(from stmt: SQLiteStatement) throws -> [String: CachedFolderRecord] {
        var out: [String: CachedFolderRecord] = [:]
        while try stmt.step() {
            let dirPath = stmt.columnText(0)
            guard let entriesData = stmt.columnOptionalTextData(1),
                  let entries = decodeEntriesOrNil(entriesData) else {
                // Ignore corrupt single-row payload, matching folder_stats_store.dart.
                continue
            }
            let complete = stmt.columnBool(2)
            let scannedAt = stmt.columnDateSeconds(3)
            out[dirPath] = CachedFolderRecord(
                dirPath: dirPath,
                entries: entries,
                complete: complete,
                scannedAt: scannedAt
            )
        }
        return out
    }

    private static func decodeEntriesOrNil(_ data: Data) -> [RemoteEntry]? {
        if data.count == 2 && data[data.startIndex] == 0x5B && data[data.index(after: data.startIndex)] == 0x5D {
            return []
        }
        return autoreleasepool {
            guard !data.isEmpty,
                  let rawArray = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                return nil
            }
            var out: [RemoteEntry] = []
            out.reserveCapacity(rawArray.count)
            for item in rawArray {
                guard let m = item as? [String: Any] else {
                    return nil
                }
                guard let p = m["p"] as? String,
                      let n = m["n"] as? String else {
                    continue
                }
                let isDir = (m["d"] as? Bool) ?? ((m["d"] as? NSNumber)?.boolValue ?? false)
                let size = (m["s"] as? NSNumber)?.int64Value ?? 0
                let mod: Date?
                if let ms = m["m"] as? NSNumber {
                    mod = Date(timeIntervalSince1970: ms.doubleValue / 1000.0)
                } else if let str = m["m"] as? String {
                    mod = TidyreelCodecs.parseISO(str)
                } else {
                    mod = nil
                }
                out.append(RemoteEntry(path: p, name: n, isDir: isDir, size: size, modified: mod, deleteIdentity: m["i"] as? String))
            }
            return out
        }
    }

    private static func ancestorDirs(of normDir: String) -> [String] {
        guard normDir != "/" else { return [] }
        var out: [String] = []
        var cur = dirOf(normDir)
        while true {
            out.append(cur)
            if cur == "/" { break }
            let parent = dirOf(cur)
            if parent == cur { break }
            cur = parent
        }
        return out
    }
}
