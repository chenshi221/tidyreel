import Foundation
import TidyreelModels

/// Lookup outcome for `SQLiteMediaProbeCache`, distinguishing a cached negative result
/// (`.hit(nil)`) from a cache miss (`.miss`).
public enum MediaProbeLookup: Equatable, Sendable {
    case hit(MediaProbeInfo?)
    case miss
}

/// Persistent SQLite + bounded L1 memory cache for `MediaProbeInfo` backed by schema v7's
/// `media_probe_cache` table, with in-flight singleflight deduplication per `(connectionId, path)`,
/// `(fileSize, modifiedAt)` validation, negative-result TTL caching, and indexed LRU trimming.
public actor SQLiteMediaProbeCache {
    private struct CacheKey: Hashable, Sendable {
        let connectionId: String
        let path: String
    }

    private struct MemoryEntry: Sendable {
        let fileSize: Int64
        let modifiedAtMs: Int64
        let info: MediaProbeInfo?
        let updatedAtMs: Int64
        var accessTick: UInt64
    }

    private struct L2Row: Sendable {
        let fileSize: Int64
        let modifiedAtMs: Int64
        let info: MediaProbeInfo?
        let updatedAtMs: Int64
    }

    private struct InFlightEntry {
        let id: UInt64
        let task: Task<MediaProbeInfo?, Never>
    }

    private let db: SQLiteDatabase
    private let maxEntries: Int
    private let l1Capacity: Int
    private let negativeTtlMs: Int64
    private let trimInterval: Int

    private var l1: [CacheKey: MemoryEntry] = [:]
    private var inFlight: [CacheKey: InFlightEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var nextFlightId: UInt64 = 1
    private var clearGeneration: UInt64 = 0
    private var writesSinceTrim: Int
    private var lastTimestampMs: Int64 = 0

    public init(
        db: SQLiteDatabase,
        maxEntries: Int = 10_000,
        l1Capacity: Int = 2_000,
        negativeTTL: TimeInterval = 24 * 60 * 60
    ) {
        let clampedMax = max(0, maxEntries)
        let clampedL1 = max(0, l1Capacity)
        let interval = clampedMax > 0 ? max(1, min(128, clampedMax / 10)) : 1
        self.db = db
        self.maxEntries = clampedMax
        self.l1Capacity = clampedL1
        self.negativeTtlMs = Int64((max(0, negativeTTL) * 1000.0).rounded())
        self.trimInterval = interval
        self.writesSinceTrim = interval - 1
    }

    /// Checks L1 memory cache and L2 SQLite table for `(connection, path)` validated against
    /// `fileSize` and (when provided) `modifiedAt`.
    public func get(
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date? = nil
    ) async -> MediaProbeLookup {
        guard maxEntries > 0 else { return .miss }
        let key = makeKey(connection: connection, path: path)
        let nowMs = currentNowMs()
        let queryModMs = Self.dateToMillis(modifiedAt)

        if case let .hit(info) = lookupL1(key: key, fileSize: fileSize, modifiedAtMs: queryModMs, nowMs: nowMs) {
            return .hit(info)
        }
        return await lookupL2(
            key: key,
            fileSize: fileSize,
            modifiedAtMs: queryModMs,
            nowMs: nowMs,
            expectedClearGen: clearGeneration
        )
    }

    /// Writes a positive (`MediaProbeInfo`) or negative (`nil`) probe result into L1 and SQLite.
    public func put(
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date? = nil,
        info: MediaProbeInfo?
    ) async {
        guard maxEntries > 0 else { return }
        if info == nil && negativeTtlMs <= 0 { return }
        let key = makeKey(connection: connection, path: path)
        await storeEntry(
            key: key,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            info: info,
            expectedClearGen: clearGeneration
        )
    }

    /// Looks up `(connection, path)` in L1 -> singleflight in-flight -> L2 SQLite -> `fetch()`,
    /// deduplicating concurrent misses for the same `(connection, path)`.
    public func probeOrLoad(
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date? = nil,
        fetch: @escaping @Sendable () async -> MediaProbeInfo?
    ) async -> MediaProbeInfo? {
        guard maxEntries > 0 else {
            return await fetch()
        }

        let key = makeKey(connection: connection, path: path)
        let nowMs = currentNowMs()
        let queryModMs = Self.dateToMillis(modifiedAt)

        if case let .hit(info) = lookupL1(key: key, fileSize: fileSize, modifiedAtMs: queryModMs, nowMs: nowMs) {
            return info
        }

        if let existing = inFlight[key] {
            return await existing.task.value
        }

        let flightId = nextFlightId
        nextFlightId &+= 1
        let startClearGen = clearGeneration

        let task = Task<MediaProbeInfo?, Never> {
            let l2NowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
            if case let .hit(cached) = await self.lookupL2(
                key: key,
                fileSize: fileSize,
                modifiedAtMs: queryModMs,
                nowMs: l2NowMs,
                expectedClearGen: startClearGen
            ) {
                self.finishFlight(key: key, flightId: flightId)
                return cached
            }

            let probed = await fetch()
            await self.storeAndFinishFlight(
                key: key,
                flightId: flightId,
                expectedClearGen: startClearGen,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                info: probed
            )
            return probed
        }

        inFlight[key] = InFlightEntry(id: flightId, task: task)
        return await task.value
    }

    /// Removes one cached entry from L1 and SQLite.
    public func invalidate(connection: ConnectionId, path: String) async {
        let key = makeKey(connection: connection, path: path)
        clearGeneration &+= 1
        l1.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)
        try? await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                DELETE FROM media_probe_cache
                WHERE connection_id = ? AND path = ?
                """)
            try stmt.bindText(1, key.connectionId)
            try stmt.bindText(2, key.path)
            try stmt.step()
        }
    }

    /// Clears all cached entries for a single connection from L1 and SQLite.
    public func clearFor(_ connection: ConnectionId) async {
        clearGeneration &+= 1
        let connVal = connection.value
        l1 = l1.filter { $0.key.connectionId != connVal }
        inFlight = inFlight.filter { $0.key.connectionId != connVal }
        try? await db.withConnection { conn in
            let stmt = try conn.prepareCached("DELETE FROM media_probe_cache WHERE connection_id = ?")
            try stmt.bindText(1, connVal)
            try stmt.step()
        }
    }

    /// Clears all L1 memory and SQLite `media_probe_cache` entries (e.g. `AppStore.clearCaches()`).
    public func clear() async {
        clearGeneration &+= 1
        l1.removeAll()
        inFlight.removeAll()
        writesSinceTrim = 0
        try? await db.withConnection { conn in
            try conn.execScript("DELETE FROM media_probe_cache")
        }
    }

    public func count() async -> Int {
        (try? await db.withConnection { conn in
            let stmt = try conn.prepareCached("SELECT COUNT(*) FROM media_probe_cache")
            guard try stmt.step() else { return 0 }
            return stmt.columnInt(0)
        }) ?? 0
    }

    // MARK: - Private L1 / L2 Helpers

    private func makeKey(connection: ConnectionId, path: String) -> CacheKey {
        CacheKey(connectionId: connection.value, path: normalizeDir(path))
    }

    private func currentNowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }

    private func nextTimestampMs(nowMs: Int64) -> Int64 {
        let next = max(nowMs, lastTimestampMs + 1)
        lastTimestampMs = next
        return next
    }

    private func nextAccessTick() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    private static func dateToMillis(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return max(0, Int64((date.timeIntervalSince1970 * 1000.0).rounded()))
    }

    private func isValid(
        storedSize: Int64,
        storedModMs: Int64,
        info: MediaProbeInfo?,
        updatedAtMs: Int64,
        querySize: Int64?,
        queryModMs: Int64?,
        nowMs: Int64
    ) -> Bool {
        if let querySize {
            guard storedSize == querySize else { return false }
        } else {
            guard storedSize == -1 else { return false }
        }
        if let queryModMs {
            guard storedModMs == queryModMs else { return false }
        }
        if info == nil {
            guard negativeTtlMs > 0 && (nowMs - updatedAtMs) <= negativeTtlMs else {
                return false
            }
        }
        return true
    }

    private func lookupL1(
        key: CacheKey,
        fileSize: Int64?,
        modifiedAtMs: Int64?,
        nowMs: Int64
    ) -> MediaProbeLookup {
        guard var entry = l1[key] else { return .miss }
        if isValid(
            storedSize: entry.fileSize,
            storedModMs: entry.modifiedAtMs,
            info: entry.info,
            updatedAtMs: entry.updatedAtMs,
            querySize: fileSize,
            queryModMs: modifiedAtMs,
            nowMs: nowMs
        ) {
            entry.accessTick = nextAccessTick()
            l1[key] = entry
            return .hit(entry.info)
        }
        l1.removeValue(forKey: key)
        return .miss
    }

    private func lookupL2(
        key: CacheKey,
        fileSize: Int64?,
        modifiedAtMs: Int64?,
        nowMs: Int64,
        expectedClearGen: UInt64
    ) async -> MediaProbeLookup {
        let negTtl = negativeTtlMs
        let rowResult: L2Row?
        do {
            rowResult = try await db.withConnection { conn -> L2Row? in
                let stmt = try conn.prepareCached("""
                    SELECT file_size, modified_at, probe_json, updated_at
                    FROM media_probe_cache
                    WHERE connection_id = ? AND path = ?
                    """)
                try stmt.bindText(1, key.connectionId)
                try stmt.bindText(2, key.path)
                guard try stmt.step() else {
                    stmt.reset()
                    return nil
                }
                let storedSize = stmt.columnInt64(0)
                let storedMod = stmt.columnInt64(1)
                let probeData = stmt.columnOptionalTextData(2)
                let updatedAt = stmt.columnInt64(3)
                stmt.reset()

                let decodedInfo: MediaProbeInfo?
                if let probeData {
                    guard let parsed = Self.decodeProbeInfo(probeData) else {
                        return nil
                    }
                    decodedInfo = parsed
                } else {
                    // Negative cache entry: delete immediately if expired.
                    if negTtl <= 0 || (nowMs - updatedAt) > negTtl {
                        let delStmt = try conn.prepareCached("""
                            DELETE FROM media_probe_cache
                            WHERE connection_id = ? AND path = ?
                            """)
                        try delStmt.bindText(1, key.connectionId)
                        try delStmt.bindText(2, key.path)
                        try delStmt.step()
                        return nil
                    }
                    decodedInfo = nil
                }

                return L2Row(
                    fileSize: storedSize,
                    modifiedAtMs: storedMod,
                    info: decodedInfo,
                    updatedAtMs: updatedAt
                )
            }
        } catch {
            rowResult = nil
        }

        guard let row = rowResult else { return .miss }
        guard isValid(
            storedSize: row.fileSize,
            storedModMs: row.modifiedAtMs,
            info: row.info,
            updatedAtMs: row.updatedAtMs,
            querySize: fileSize,
            queryModMs: modifiedAtMs,
            nowMs: nowMs
        ) else {
            return .miss
        }

        if clearGeneration == expectedClearGen && l1Capacity > 0 {
            l1[key] = MemoryEntry(
                fileSize: row.fileSize,
                modifiedAtMs: row.modifiedAtMs,
                info: row.info,
                updatedAtMs: row.updatedAtMs,
                accessTick: nextAccessTick()
            )
            trimL1IfNeeded()
        }
        return .hit(row.info)
    }

    private func finishFlight(key: CacheKey, flightId: UInt64) {
        if inFlight[key]?.id == flightId {
            inFlight.removeValue(forKey: key)
        }
    }

    private func storeAndFinishFlight(
        key: CacheKey,
        flightId: UInt64,
        expectedClearGen: UInt64,
        fileSize: Int64?,
        modifiedAt: Date?,
        info: MediaProbeInfo?
    ) async {
        if info != nil || negativeTtlMs > 0 {
            await storeEntry(
                key: key,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                info: info,
                expectedClearGen: expectedClearGen
            )
        }
        finishFlight(key: key, flightId: flightId)
    }

    private func storeEntry(
        key: CacheKey,
        fileSize: Int64?,
        modifiedAt: Date?,
        info: MediaProbeInfo?,
        expectedClearGen: UInt64
    ) async {
        guard clearGeneration == expectedClearGen else { return }

        let storedSize = fileSize ?? -1
        let storedMod = Self.dateToMillis(modifiedAt) ?? -1
        let nowMs = currentNowMs()
        let tsMs = nextTimestampMs(nowMs: nowMs)

        if l1Capacity > 0 {
            l1[key] = MemoryEntry(
                fileSize: storedSize,
                modifiedAtMs: storedMod,
                info: info,
                updatedAtMs: tsMs,
                accessTick: nextAccessTick()
            )
            trimL1IfNeeded()
        }

        writesSinceTrim += 1
        let shouldTrim = writesSinceTrim >= trimInterval
        if shouldTrim {
            writesSinceTrim = 0
        }
        let limit = maxEntries
        let negTtl = negativeTtlMs
        let probeData: Data? = info.flatMap(Self.encodeProbeInfo)

        try? await db.withConnection { conn in
            let upsertStmt = try conn.prepareCached("""
                INSERT INTO media_probe_cache (
                    connection_id, path, file_size, modified_at, probe_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(connection_id, path) DO UPDATE SET
                    file_size = excluded.file_size,
                    modified_at = excluded.modified_at,
                    probe_json = excluded.probe_json,
                    updated_at = excluded.updated_at
                """)
            try upsertStmt.bindText(1, key.connectionId)
            try upsertStmt.bindText(2, key.path)
            try upsertStmt.bindInt64(3, storedSize)
            try upsertStmt.bindInt64(4, storedMod)
            try upsertStmt.bindUTF8Data(5, probeData)
            try upsertStmt.bindInt64(6, tsMs)
            try upsertStmt.step()

            if shouldTrim {
                try Self.trimEntries(
                    conn: conn,
                    maxEntries: limit,
                    negativeTtlMs: negTtl,
                    nowMs: nowMs
                )
            }
        }
    }

    private func trimL1IfNeeded() {
        guard l1Capacity > 0 else {
            l1.removeAll()
            return
        }
        guard l1.count > l1Capacity else { return }
        let evictCount = max(l1.count - l1Capacity, l1Capacity / 10)
        let victims = l1.sorted { $0.value.accessTick < $1.value.accessTick }.prefix(evictCount)
        for (k, _) in victims {
            l1.removeValue(forKey: k)
        }
    }

    private static func trimEntries(
        conn: SQLiteConnection,
        maxEntries: Int,
        negativeTtlMs: Int64,
        nowMs: Int64
    ) throws {
        if negativeTtlMs > 0 {
            let negStmt = try conn.prepareCached("""
                DELETE FROM media_probe_cache
                WHERE probe_json IS NULL AND updated_at < ?
                """)
            try negStmt.bindInt64(1, nowMs - negativeTtlMs)
            try negStmt.step()
        }

        let countStmt = try conn.prepareCached("SELECT COUNT(*) FROM media_probe_cache")
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
            FROM media_probe_cache
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
            DELETE FROM media_probe_cache
            WHERE updated_at < ?
            """)
        try delOlderStmt.bindInt64(1, cutoffTs)
        try delOlderStmt.step()
        let deletedOlder = conn.changes()

        let remaining = total - deletedOlder
        if remaining > maxEntries {
            let excess = remaining - maxEntries
            let tieBreakStmt = try conn.prepareCached("""
                DELETE FROM media_probe_cache
                WHERE rowid IN (
                    SELECT rowid FROM media_probe_cache
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

    private static func encodeProbeInfo(_ info: MediaProbeInfo) -> Data? {
        autoreleasepool {
            try? JSONSerialization.data(withJSONObject: TidyreelCodecs.probeToDict(info))
        }
    }

    private static func decodeProbeInfo(_ data: Data) -> MediaProbeInfo? {
        autoreleasepool {
            guard !data.isEmpty,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return TidyreelCodecs.probeFromDict(dict)
        }
    }
}

// MARK: - CachingMediaProbe Decorator

/// `MediaProbe` decorator backed by `SQLiteMediaProbeCache` (L1 memory + L2 SQLite + singleflight).
public final class CachingMediaProbe: MediaProbe, Sendable {
    private let inner: any MediaProbe
    private let cache: SQLiteMediaProbeCache
    private let connection: ConnectionId

    public init(
        inner: any MediaProbe,
        cache: SQLiteMediaProbeCache,
        connection: ConnectionId = ConnectionId("default")
    ) {
        self.inner = inner
        self.cache = cache
        self.connection = connection
    }

    /// Returns a lightweight decorator sharing the same underlying probe and cache, scoped to `connection`.
    public func scoped(to connection: ConnectionId) -> CachingMediaProbe {
        CachingMediaProbe(inner: inner, cache: cache, connection: connection)
    }

    /// Standard `MediaProbe` conformance (`fileSize`-only validation fallback when `modifiedAt` is unavailable).
    public func probe(
        backend: any StorageBackend,
        path: String,
        fileSize: Int64?
    ) async -> MediaProbeInfo? {
        await probe(backend: backend, connection: connection, path: path, fileSize: fileSize, modifiedAt: nil)
    }

    /// Extended probe validating both `fileSize` and `modifiedAt`.
    public func probe(
        backend: any StorageBackend,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date?
    ) async -> MediaProbeInfo? {
        await probe(backend: backend, connection: connection, path: path, fileSize: fileSize, modifiedAt: modifiedAt)
    }

    /// Connection-explicit probe validating both `fileSize` and `modifiedAt`.
    public func probe(
        backend: any StorageBackend,
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date? = nil
    ) async -> MediaProbeInfo? {
        let innerProbe = self.inner
        return await cache.probeOrLoad(
            connection: connection,
            path: path,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        ) {
            await innerProbe.probe(backend: backend, path: path, fileSize: fileSize)
        }
    }
}
