import Compression
import Foundation
import TidyreelModels

/// Pure-Swift `TaskStore` backed by `SQLiteDatabase` (schema v7), separating heavy
/// zlib-compressed review payloads into `task_reviews` while keeping `tasks` lean with
/// pre-computed `card_meta_json` for zero-blob card rendering.
public final class SQLiteTaskStore: TaskStore, Sendable {
    private static let compressedMagic: [UInt8] = [0x54, 0x52, 0x5A, 0x31] // "TRZ1"

    private let db: SQLiteDatabase

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public func saveSummary(_ summary: TaskSummary) async throws {
        try await db.withConnection { conn in
            let pathsData = try JSONSerialization.data(withJSONObject: summary.paths)

            let stmt = try conn.prepareCached("""
                INSERT INTO tasks (
                    id, connection_id, paths_json, mode, scrape, scrape_only,
                    stage, message, imported_count, video_count, folder_count,
                    subtitle_count, progress, batch_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    connection_id = excluded.connection_id,
                    paths_json = excluded.paths_json,
                    mode = excluded.mode,
                    scrape = excluded.scrape,
                    scrape_only = excluded.scrape_only,
                    stage = excluded.stage,
                    message = excluded.message,
                    imported_count = excluded.imported_count,
                    video_count = excluded.video_count,
                    folder_count = excluded.folder_count,
                    subtitle_count = excluded.subtitle_count,
                    progress = excluded.progress,
                    batch_id = excluded.batch_id,
                    created_at = excluded.created_at
                """)
            try stmt.bindText(1, summary.id.value)
            try stmt.bindText(2, summary.connection.value)
            try stmt.bindUTF8Data(3, pathsData)
            try stmt.bindText(4, summary.mode.rawValue)
            try stmt.bindBool(5, summary.scrape)
            try stmt.bindBool(6, summary.scrapeOnly)
            try stmt.bindText(7, summary.stage.rawValue)
            try stmt.bindText(8, summary.message)
            try stmt.bindInt(9, summary.importedCount)
            try stmt.bindInt(10, summary.videoCount)
            try stmt.bindInt(11, summary.folderCount)
            try stmt.bindInt(12, summary.subtitleCount)
            try stmt.bindDouble(13, summary.progress)
            try stmt.bindText(14, summary.batch?.value)
            try stmt.bindDateSeconds(15, summary.createdAt)
            try stmt.step()
        }
    }

    public func saveReview(
        id: TaskId,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool] = [:]
    ) async throws {
        try await db.withConnection { conn in
            let payload: (scanBlob: Data, decisionsData: Data, unassignedDeletesData: Data?, cardMetaData: Data) = try autoreleasepool {
                let scanJson = try TidyreelCodecs.scanToJson(scan)
                let scanBlob = Self.compressScanData(Data(scanJson.utf8))
                let decisionsJson = try TidyreelCodecs.decisionsToJson(decisions)
                let decisionsData = Data(decisionsJson.utf8)
                let unassignedDeletesData: Data?
                if unassignedDeletes.isEmpty {
                    unassignedDeletesData = nil
                } else {
                    unassignedDeletesData = try JSONSerialization.data(withJSONObject: unassignedDeletes, options: .sortedKeys)
                }
                let cardMeta = TaskCardMeta.from(scan: scan, decisions: decisions)
                let cardMetaData = try Self.encodeCardMeta(cardMeta)
                return (scanBlob, decisionsData, unassignedDeletesData, cardMetaData)
            }

            try conn.withTransaction {
                let metaStmt = try conn.prepareCached("""
                    UPDATE tasks
                    SET card_meta_json = ?
                    WHERE id = ?
                    """)
                try metaStmt.bindUTF8Data(1, payload.cardMetaData)
                try metaStmt.bindText(2, id.value)
                try metaStmt.step()

                guard conn.changes() > 0 else {
                    return
                }

                let reviewStmt = try conn.prepareCached("""
                    INSERT INTO task_reviews (
                        task_id, scan_blob, decisions_json, unassigned_deletes_json
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(task_id) DO UPDATE SET
                        scan_blob = excluded.scan_blob,
                        decisions_json = excluded.decisions_json,
                        unassigned_deletes_json = excluded.unassigned_deletes_json
                    """)
                try reviewStmt.bindText(1, id.value)
                try reviewStmt.bindBlob(2, payload.scanBlob)
                try reviewStmt.bindUTF8Data(3, payload.decisionsData)
                try reviewStmt.bindUTF8Data(4, payload.unassignedDeletesData)
                try reviewStmt.step()
            }
        }
    }

    public var supportsTargetedDecisionSave: Bool { true }

    /// Updates ONLY `decisions_json` and `unassigned_deletes_json` in `task_reviews` (and
    /// optionally `card_meta_json` on `tasks`), never rewriting `scan_blob`.
    public func saveDecisions(
        id: TaskId,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool],
        cardMeta: TaskCardMeta? = nil
    ) async throws {
        try await db.withConnection { conn in
            let payload: (decisionsData: Data, unassignedDeletesData: Data?, cardMetaData: Data?) = try autoreleasepool {
                let decisionsJson = try TidyreelCodecs.decisionsToJson(decisions)
                let decisionsData = Data(decisionsJson.utf8)
                let unassignedDeletesData: Data?
                if unassignedDeletes.isEmpty {
                    unassignedDeletesData = nil
                } else {
                    unassignedDeletesData = try JSONSerialization.data(withJSONObject: unassignedDeletes, options: .sortedKeys)
                }
                let cardMetaData = try cardMeta.map(Self.encodeCardMeta)
                return (decisionsData, unassignedDeletesData, cardMetaData)
            }

            try conn.withTransaction {
                let stmt = try conn.prepareCached("""
                    UPDATE task_reviews
                    SET decisions_json = ?, unassigned_deletes_json = ?
                    WHERE task_id = ?
                    """)
                try stmt.bindUTF8Data(1, payload.decisionsData)
                try stmt.bindUTF8Data(2, payload.unassignedDeletesData)
                try stmt.bindText(3, id.value)
                try stmt.step()

                if let cardMetaData = payload.cardMetaData {
                    let metaStmt = try conn.prepareCached("""
                        UPDATE tasks
                        SET card_meta_json = ?
                        WHERE id = ?
                        """)
                    try metaStmt.bindUTF8Data(1, cardMetaData)
                    try metaStmt.bindText(2, id.value)
                    try metaStmt.step()
                }
            }
        }
    }

    /// Clears `task_reviews.scan_blob` once a task is terminal while preserving `tasks.card_meta_json`.
    public func pruneScanBlob(id: TaskId) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                UPDATE task_reviews
                SET scan_blob = NULL
                WHERE task_id = ?
                """)
            try stmt.bindText(1, id.value)
            try stmt.step()
        }
    }

    public func clearReview(id: TaskId) async throws {
        try await db.withConnection { conn in
            try conn.withTransaction {
                let delStmt = try conn.prepareCached("""
                    DELETE FROM task_reviews
                    WHERE task_id = ?
                    """)
                try delStmt.bindText(1, id.value)
                try delStmt.step()

                let clearStmt = try conn.prepareCached("""
                    UPDATE tasks
                    SET card_meta_json = NULL,
                        scan_json = NULL,
                        decisions_json = NULL,
                        unassigned_deletes_json = NULL
                    WHERE id = ?
                    """)
                try clearStmt.bindText(1, id.value)
                try clearStmt.step()
            }
        }
    }

    /// Fast startup query: selects ONLY the 15 summary columns — never touches `task_reviews`
    /// or `card_meta_json`.
    public func loadSummaries() async throws -> [TaskSummary] {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT id, connection_id, paths_json, mode, scrape, scrape_only, stage, message,
                       imported_count, video_count, folder_count, subtitle_count, progress, batch_id, created_at
                FROM tasks
                """)
            var out: [TaskSummary] = []
            while try stmt.step() {
                if let summary = Self.decodeSummaryColumns(stmt: stmt) {
                    out.append(summary)
                }
            }
            return out
        }
    }

    /// Lazy on-demand query: reads and decodes `task_reviews` for a single `TaskId`
    /// entirely on the background SQLite actor inside an `autoreleasepool`.
    public func loadReview(id: TaskId) async throws -> StoredTaskReview? {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT scan_blob, decisions_json, unassigned_deletes_json
                FROM task_reviews
                WHERE task_id = ?
                """)
            try stmt.bindText(1, id.value)
            guard try stmt.step() else { return nil }
            let rawBlob = stmt.columnOptionalBlob(0)
            let rawDecisions = stmt.columnOptionalText(1)
            let rawUnassignedDeletes = stmt.columnOptionalTextData(2)
            stmt.reset()

            return autoreleasepool {
                guard let rawBlob,
                      let scan = Self.decodeScanBlob(rawBlob) else {
                    return nil
                }
                let decisions = Self.decodeDecisions(rawDecisions)
                let unassignedDeletes = Self.decodeUnassignedDeletes(rawUnassignedDeletes)
                return StoredTaskReview(
                    scan: scan,
                    decisions: decisions,
                    unassignedDeletes: unassignedDeletes
                )
            }
        }
    }

    public func loadAll() async throws -> [StoredTask] {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT t.id, t.connection_id, t.paths_json, t.mode, t.scrape, t.scrape_only, t.stage, t.message,
                       t.imported_count, t.video_count, t.folder_count, t.subtitle_count, t.progress, t.batch_id, t.created_at,
                       r.scan_blob, r.decisions_json, r.unassigned_deletes_json
                FROM tasks t
                LEFT JOIN task_reviews r ON r.task_id = t.id
                """)
            var out: [StoredTask] = []
            while try stmt.step() {
                guard let summary = Self.decodeSummaryColumns(stmt: stmt) else {
                    // Skip completely unreadable task rows instead of bricking startup.
                    continue
                }
                let rawBlob = stmt.columnOptionalBlob(15)
                let rawDecisions = stmt.columnOptionalText(16)
                let rawUnassignedDeletes = stmt.columnOptionalTextData(17)
                let stored: StoredTask = autoreleasepool {
                    let scan = rawBlob.flatMap(Self.decodeScanBlob)
                    let decisions = Self.decodeDecisions(rawDecisions)
                    let unassignedDeletes = Self.decodeUnassignedDeletes(rawUnassignedDeletes)
                    return StoredTask(
                        summary: summary,
                        scan: scan,
                        decisions: decisions,
                        unassignedDeletes: unassignedDeletes
                    )
                }
                out.append(stored)
            }
            return out
        }
    }

    public func delete(id: TaskId) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("DELETE FROM tasks WHERE id = ?")
            try stmt.bindText(1, id.value)
            try stmt.step()
        }
    }

    /// Background-only lightweight metadata projection: reads `tasks.card_meta_json` directly
    /// without touching `task_reviews.scan_blob`. Only if `card_meta_json` is NULL (e.g., rows
    /// migrated from schema <= v6) does it fall back to decoding `task_reviews.scan_blob` inside
    /// an `autoreleasepool` and backfill `tasks.card_meta_json` for future fast-path loads.
    public func loadCardMeta(ids: [TaskId]) async -> [TaskId: TaskCardMeta] {
        guard !ids.isEmpty else { return [:] }
        return (try? await db.withConnection { conn in
            var result: [TaskId: TaskCardMeta] = [:]
            result.reserveCapacity(ids.count)
            let fastStmt = try conn.prepareCached("SELECT card_meta_json FROM tasks WHERE id = ?")
            for id in ids {
                fastStmt.reset()
                try fastStmt.bindText(1, id.value)
                guard try fastStmt.step() else {
                    fastStmt.reset()
                    continue
                }
                let rawMetaData = fastStmt.columnOptionalTextData(0)
                fastStmt.reset()

                if let rawMetaData {
                    let fastMeta: TaskCardMeta? = autoreleasepool {
                        Self.decodeCardMeta(rawMetaData)
                    }
                    if let fastMeta {
                        result[id] = fastMeta
                        continue
                    }
                }

                // Fallback for legacy/migrated rows with NULL card_meta_json: decode scan_blob & backfill.
                let reviewStmt = try conn.prepareCached("""
                    SELECT scan_blob, decisions_json
                    FROM task_reviews
                    WHERE task_id = ?
                    """)
                try reviewStmt.bindText(1, id.value)
                guard try reviewStmt.step(),
                      let rawBlob = reviewStmt.columnOptionalBlob(0) else {
                    reviewStmt.reset()
                    continue
                }
                let rawDecisions = reviewStmt.columnOptionalText(1)
                reviewStmt.reset()

                let fallback: (meta: TaskCardMeta, encoded: Data?)? = autoreleasepool {
                    guard let scan = Self.decodeScanBlob(rawBlob) else { return nil }
                    let decisions = Self.decodeDecisions(rawDecisions)
                    let meta = TaskCardMeta.from(scan: scan, decisions: decisions)
                    let encoded = try? Self.encodeCardMeta(meta)
                    return (meta, encoded)
                }
                if let fallback {
                    result[id] = fallback.meta
                    if let encoded = fallback.encoded {
                        do {
                            let backfillStmt = try conn.prepareCached("UPDATE tasks SET card_meta_json = ? WHERE id = ?")
                            try backfillStmt.bindUTF8Data(1, encoded)
                            try backfillStmt.bindText(2, id.value)
                            try backfillStmt.step()
                            backfillStmt.reset()
                        } catch {
                            // Best-effort backfill; ignore transient write errors.
                        }
                    }
                }
            }
            return result
        }) ?? [:]
    }

    // MARK: - Zlib Compression ("TRZ1" magic prefix + COMPRESSION_ZLIB)

    static func compressScanData(_ raw: Data) -> Data {
        guard !raw.isEmpty,
              let compressed = runZlib(raw, operation: COMPRESSION_STREAM_ENCODE) else {
            return raw
        }
        var out = Data(capacity: compressedMagic.count + compressed.count)
        out.append(contentsOf: compressedMagic)
        out.append(compressed)
        return out
    }

    static func decompressScanData(_ blob: Data) -> Data? {
        guard blob.count >= compressedMagic.count,
              blob.prefix(compressedMagic.count).elementsEqual(compressedMagic) else {
            return blob
        }
        let payload = blob.dropFirst(compressedMagic.count)
        guard !payload.isEmpty else { return nil }
        return runZlib(payload, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func runZlib(_ input: Data, operation: compression_stream_operation) -> Data? {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        guard compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { _ = compression_stream_destroy(streamPtr) }

        let chunkSize = 65_536
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        var output = Data()
        if operation == COMPRESSION_STREAM_ENCODE {
            output.reserveCapacity(max(256, input.count / 4))
        } else {
            output.reserveCapacity(max(1024, input.count * 4))
        }

        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        let ok: Bool = input.withUnsafeBytes { rawBuf -> Bool in
            let srcBytes = rawBuf.bindMemory(to: UInt8.self)
            guard let base = srcBytes.baseAddress else { return false }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = srcBytes.count

            while true {
                let prevSrcSize = streamPtr.pointee.src_size
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPtr, flags)
                let produced = chunkSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && streamPtr.pointee.src_size == prevSrcSize {
                        return false
                    }
                    continue
                case COMPRESSION_STATUS_END:
                    return true
                default:
                    return false
                }
            }
        }

        return ok ? output : nil
    }

    // MARK: - Defensive Decoders & Card Meta Codec

    private static func encodeCardMeta(_ meta: TaskCardMeta) throws -> Data {
        let works: [[String: Any]] = meta.works.map { c in
            var d: [String: Any] = [
                "tmdbId": c.tmdbId,
                "kind": c.kind.rawValue,
                "title": c.title,
            ]
            if let year = c.year { d["year"] = year }
            if let posterPath = c.posterPath { d["posterPath"] = posterPath }
            return d
        }
        let obj: [String: Any] = [
            "unassignedCount": meta.unassignedCount,
            "works": works,
        ]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private static func decodeCardMeta(_ data: Data) -> TaskCardMeta? {
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let unassignedCount = (obj["unassignedCount"] as? NSNumber)?.intValue ?? 0
        let rawWorks = (obj["works"] as? [[String: Any]]) ?? []
        let works = rawWorks.compactMap(TidyreelCodecs.candidateFromDict)
        return TaskCardMeta(works: works, unassignedCount: unassignedCount)
    }

    private static func decodeScanBlob(_ blob: Data) -> ScanResult? {
        guard let rawJsonData = decompressScanData(blob), !rawJsonData.isEmpty else {
            return nil
        }
        let text = String(decoding: rawJsonData, as: UTF8.self)
        return try? TidyreelCodecs.scanFromJson(text)
    }

    private static func decodeSummaryColumns(stmt: SQLiteStatement) -> TaskSummary? {
        guard let pathsData = stmt.columnOptionalTextData(2),
              let rawPaths = (try? JSONSerialization.jsonObject(with: pathsData)) as? [Any] else {
            return nil
        }
        let paths = rawPaths.compactMap { $0 as? String }

        let id = TaskId(stmt.columnText(0))
        let connection = ConnectionId(stmt.columnText(1))
        let mode = OrganizeMode(rawValue: stmt.columnText(3)) ?? .inPlace
        let scrape = stmt.columnBool(4)
        let scrapeOnly = stmt.columnBool(5)
        let stage = TaskStage(rawValue: stmt.columnText(6)) ?? .failed
        let message = stmt.columnText(7)
        let importedCount = stmt.columnInt(8)
        let videoCount = stmt.columnInt(9)
        let folderCount = stmt.columnInt(10)
        let subtitleCount = stmt.columnInt(11)
        let progress = stmt.columnOptionalDouble(12)
        let batch = stmt.columnOptionalText(13).map { BatchId($0) }
        let createdAt = stmt.columnDateSeconds(14)

        return TaskSummary(
            id: id,
            connection: connection,
            paths: paths,
            mode: mode,
            scrape: scrape,
            scrapeOnly: scrapeOnly,
            stage: stage,
            message: message,
            importedCount: importedCount,
            videoCount: videoCount,
            folderCount: folderCount,
            subtitleCount: subtitleCount,
            progress: progress,
            batch: batch,
            createdAt: createdAt
        )
    }

    private static func decodeDecisions(_ raw: String?) -> [GroupId: GroupDecision] {
        guard let raw, !raw.isEmpty else { return [:] }
        return (try? TidyreelCodecs.decisionsFromJson(raw)) ?? [:]
    }

    private static func decodeUnassignedDeletes(_ data: Data?) -> [String: Bool] {
        guard let data, let decoded = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        if let overrides = decoded as? [String: Bool] { return overrides }
        // Older rows stored only explicitly selected deletions as an array.
        let paths = (decoded as? [Any] ?? []).compactMap { $0 as? String }
        return Dictionary(paths.map { ($0, true) }, uniquingKeysWith: { first, _ in first })
    }
}
