import Foundation
import TidyreelModels

/// Indexed SQLite-backed `TmdbResponseCache` replacing `FileTmdbCache`'s full-file JSON decode/encode.
/// Supports TTL expiration, throttled LRU touch refresh via `updated_at`, indexed cutoff trimming,
/// and one-time migration from legacy `tmdb_cache.json`.
public actor SQLiteTmdbCache: TmdbResponseCache {
    private let db: SQLiteDatabase
    private let maxEntries: Int
    private let ttlMs: Int64
    private let touchIntervalMs: Int64
    private let trimInterval: Int
    private var writesSinceTrim: Int
    private var lastTimestampMs: Int64 = 0

    public init(
        db: SQLiteDatabase,
        maxEntries: Int = 5000,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        touchInterval: TimeInterval = 12 * 60 * 60
    ) {
        let clampedMax = max(0, maxEntries)
        let interval = clampedMax > 0 ? max(1, min(64, clampedMax / 10)) : 1
        self.db = db
        self.maxEntries = clampedMax
        self.ttlMs = Int64((max(0, ttl) * 1000.0).rounded())
        self.touchIntervalMs = Int64((max(0, touchInterval) * 1000.0).rounded())
        self.trimInterval = interval
        // Trigger a trim check on the first write after startup in case previous sessions exceeded maxEntries.
        self.writesSinceTrim = interval - 1
    }

    public func get(_ key: String) async -> String? {
        guard maxEntries > 0 else { return nil }
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        let touchMs = nextTimestampMs(nowMs: nowMs)
        let ttlWindowMs = ttlMs
        let touchWindowMs = touchIntervalMs

        return try? await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT json_text, updated_at
                FROM tmdb_http_cache
                WHERE cache_key = ?
                """)
            try stmt.bindText(1, key)
            guard try stmt.step() else {
                stmt.reset()
                return nil
            }

            let jsonText = stmt.columnText(0)
            let rawUpdated = stmt.columnInt64(1)
            stmt.reset()

            let updatedAtMs = Self.normalizeToMillis(rawUpdated)

            if ttlWindowMs > 0 && (nowMs - updatedAtMs) > ttlWindowMs {
                let delStmt = try conn.prepareCached("DELETE FROM tmdb_http_cache WHERE cache_key = ?")
                try delStmt.bindText(1, key)
                try delStmt.step()
                return nil
            }

            if touchWindowMs <= 0 || (nowMs - updatedAtMs) >= touchWindowMs {
                let touchStmt = try conn.prepareCached("""
                    UPDATE tmdb_http_cache SET updated_at = ? WHERE cache_key = ?
                    """)
                try touchStmt.bindInt64(1, touchMs)
                try touchStmt.bindText(2, key)
                try touchStmt.step()
            }

            return jsonText
        }
    }

    public func put(_ key: String, json: String) async {
        guard maxEntries > 0 else { return }
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        let tsMs = nextTimestampMs(nowMs: nowMs)

        writesSinceTrim += 1
        let shouldTrim = writesSinceTrim >= trimInterval
        if shouldTrim {
            writesSinceTrim = 0
        }
        let limit = maxEntries
        let ttlWindowMs = ttlMs

        try? await db.withConnection { conn in
            let upsertStmt = try conn.prepareCached("""
                INSERT OR REPLACE INTO tmdb_http_cache (cache_key, json_text, updated_at)
                VALUES (?, ?, ?)
                """)
            try upsertStmt.bindText(1, key)
            try upsertStmt.bindText(2, json)
            try upsertStmt.bindInt64(3, tsMs)
            try upsertStmt.step()

            if shouldTrim {
                try Self.trimEntries(conn: conn, maxEntries: limit, ttlMs: ttlWindowMs, nowMs: nowMs)
            }
        }
    }

    public func trim() async {
        let limit = maxEntries
        let ttlWindowMs = ttlMs
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        writesSinceTrim = 0
        try? await db.withConnection { conn in
            if limit <= 0 {
                try conn.execScript("DELETE FROM tmdb_http_cache")
            } else {
                try Self.trimEntries(conn: conn, maxEntries: limit, ttlMs: ttlWindowMs, nowMs: nowMs)
            }
        }
    }

    public func clear() async {
        writesSinceTrim = 0
        try? await db.withConnection { conn in
            try conn.execScript("DELETE FROM tmdb_http_cache")
        }
    }

    public func count() async -> Int {
        (try? await db.withConnection { conn in
            let stmt = try conn.prepareCached("SELECT COUNT(*) FROM tmdb_http_cache")
            guard try stmt.step() else { return 0 }
            return stmt.columnInt(0)
        }) ?? 0
    }

    /// Imports an existing legacy `tmdb_cache.json` file if present, bulk-inserting entries into
    /// `tmdb_http_cache` in a single SQLite transaction, and renames the file to `tmdb_cache.json.migrated`.
    ///
    /// Supports all legacy formats:
    /// 1. Dart `FileTmdbCache`: `{"key": [timestampMs, {jsonObject}]}`
    /// 2. Wrapped entries object: `{"entries": {"key": "{...}" | {...} | [ts, {...}]}}`
    /// 3. Flat key-value map: `{"key": "{...}" | {...}}`
    public func importLegacyJsonFileIfNeeded(at url: URL) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        let ttlWindowMs = ttlMs
        let cutoffMs = ttlWindowMs > 0 ? (nowMs - ttlWindowMs) : Int64.min
        let limit = maxEntries

        let parsedEntries: [(key: String, json: String, updatedAtMs: Int64)]
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.renameToMigrated(url: url)
                return
            }
            let mapToImport: [String: Any]
            if let nested = root["entries"] as? [String: Any], root.count == 1 {
                mapToImport = nested
            } else {
                mapToImport = root
            }

            var extracted: [(key: String, json: String, updatedAtMs: Int64)] = []
            extracted.reserveCapacity(mapToImport.count)

            var fallbackClock = nextTimestampMs(nowMs: nowMs)
            for (key, rawVal) in mapToImport.sorted(by: { $0.key < $1.key }) {
                if let entry = Self.extractLegacyEntry(
                    key: key,
                    rawValue: rawVal,
                    defaultTimestampMs: fallbackClock,
                    cutoffMs: cutoffMs
                ) {
                    extracted.append(entry)
                    fallbackClock += 1
                }
            }
            if fallbackClock > lastTimestampMs {
                lastTimestampMs = fallbackClock
            }
            parsedEntries = extracted
        } catch {
            // Corrupt legacy cache file should not block startup; move it aside so we don't retry every launch.
            Self.renameToMigrated(url: url)
            return
        }

        do {
            try await db.withConnection { conn in
                try conn.withTransaction {
                    if !parsedEntries.isEmpty && limit > 0 {
                        let stmt = try conn.prepareCached("""
                            INSERT INTO tmdb_http_cache (cache_key, json_text, updated_at)
                            VALUES (?, ?, ?)
                            ON CONFLICT(cache_key) DO UPDATE SET
                                json_text = excluded.json_text,
                                updated_at = excluded.updated_at
                            WHERE excluded.updated_at >= tmdb_http_cache.updated_at
                            """)
                        for item in parsedEntries {
                            stmt.reset()
                            try stmt.bindText(1, item.key)
                            try stmt.bindText(2, item.json)
                            try stmt.bindInt64(3, item.updatedAtMs)
                            try stmt.step()
                        }
                        try Self.trimEntries(conn: conn, maxEntries: limit, ttlMs: ttlWindowMs, nowMs: nowMs)
                    }
                }
            }
            Self.renameToMigrated(url: url)
        } catch {
            // Leave file untouched if database write failed transiently.
        }
    }

    // MARK: - Helpers

    private func nextTimestampMs(nowMs: Int64) -> Int64 {
        let next = max(nowMs, lastTimestampMs + 1)
        lastTimestampMs = next
        return next
    }

    private static func normalizeToMillis(_ raw: Int64) -> Int64 {
        // Values under 10_000_000_000 (year 2286 in seconds) were stored as Unix seconds.
        if raw > 0 && raw < 10_000_000_000 {
            return raw * 1000
        }
        return raw
    }

    private static func trimEntries(
        conn: SQLiteConnection,
        maxEntries: Int,
        ttlMs: Int64,
        nowMs: Int64
    ) throws {
        if ttlMs > 0 {
            let ttlStmt = try conn.prepareCached("""
                DELETE FROM tmdb_http_cache
                WHERE updated_at < ?
                """)
            try ttlStmt.bindInt64(1, nowMs - ttlMs)
            try ttlStmt.step()
        }

        let countStmt = try conn.prepareCached("SELECT COUNT(*) FROM tmdb_http_cache")
        let total: Int
        if try countStmt.step() {
            total = countStmt.columnInt(0)
        } else {
            total = 0
        }
        countStmt.reset()

        guard total > maxEntries else { return }

        let cutoffStmt = try conn.prepareCached("""
            SELECT updated_at
            FROM tmdb_http_cache
            ORDER BY updated_at DESC
            LIMIT 1 OFFSET ?
            """)
        try cutoffStmt.bindInt(1, maxEntries - 1)
        guard try cutoffStmt.step() else {
            cutoffStmt.reset()
            return
        }
        let cutoffTs = cutoffStmt.columnInt64(0)
        cutoffStmt.reset()

        let delOlderStmt = try conn.prepareCached("""
            DELETE FROM tmdb_http_cache
            WHERE updated_at < ?
            """)
        try delOlderStmt.bindInt64(1, cutoffTs)
        try delOlderStmt.step()
        let deletedOlder = conn.changes()

        let remaining = total - deletedOlder
        if remaining > maxEntries {
            let excess = remaining - maxEntries
            let tieBreakStmt = try conn.prepareCached("""
                DELETE FROM tmdb_http_cache
                WHERE rowid IN (
                    SELECT rowid FROM tmdb_http_cache
                    WHERE updated_at = ?
                    ORDER BY rowid ASC
                    LIMIT ?
                )
                """)
            try tieBreakStmt.bindInt64(1, cutoffTs)
            try tieBreakStmt.bindInt(2, excess)
            try tieBreakStmt.step()
        }
    }

    private static func extractLegacyEntry(
        key: String,
        rawValue: Any,
        defaultTimestampMs: Int64,
        cutoffMs: Int64
    ) -> (key: String, json: String, updatedAtMs: Int64)? {
        if let str = rawValue as? String {
            return (key: key, json: str, updatedAtMs: defaultTimestampMs)
        }
        if let arr = rawValue as? [Any], arr.count >= 2, let tsNum = arr[0] as? NSNumber {
            let tsMs = normalizeToMillis(tsNum.int64Value)
            if tsMs < cutoffMs {
                return nil
            }
            let payload = arr[1]
            if let str = payload as? String {
                return (key: key, json: str, updatedAtMs: tsMs)
            }
            if JSONSerialization.isValidJSONObject(payload),
               let encoded = try? JSONSerialization.data(withJSONObject: payload) {
                return (key: key, json: String(decoding: encoded, as: UTF8.self), updatedAtMs: tsMs)
            }
            return nil
        }
        if let dict = rawValue as? [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: dict) {
            return (key: key, json: String(decoding: encoded, as: UTF8.self), updatedAtMs: defaultTimestampMs)
        }
        return nil
    }

    private static func renameToMigrated(url: URL) {
        let migratedURL = URL(fileURLWithPath: url.path + ".migrated")
        let fm = FileManager.default
        if fm.fileExists(atPath: migratedURL.path) {
            try? fm.removeItem(at: migratedURL)
        }
        try? fm.moveItem(at: url, to: migratedURL)
    }
}
