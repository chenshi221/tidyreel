import Foundation
import TidyreelModels

/// Pure-Swift `HistoryStore` backed by `SQLiteDatabase`, 100% compatible with Drift's
/// `batches` and `history_records` tables (`drift_history_store.dart`).
public final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    /// Maximum SQLite bound path placeholders per `areOrganized` chunked query (<= 400).
    private static let maxPlaceholdersPerQuery = 400

    private struct FolderMove: Sendable {
        let src: String
        let dst: String
    }

    private struct MarkUpdate: Sendable {
        let op: OpId
        let status: OpStatus
        let error: String?
    }

    private struct FolderMovesCacheState {
        var generation: UInt64 = 0
        var byConnection: [ConnectionId: [String: [FolderMove]]] = [:]
        var batchMeta: [BatchId: (connection: ConnectionId, hasFolderMoves: Bool)] = [:]
    }

    private let db: SQLiteDatabase
    private let cacheLock = NSLock()
    private var folderMovesState = FolderMovesCacheState()

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public func beginBatch(
        task: TaskId,
        connection: ConnectionId,
        ops: [RenameOp]
    ) async throws -> BatchId {
        let hasFolderMoves = ops.contains { $0.phase == .folders && $0.kind == .relocate }
        let batchId = try await db.withConnection { conn in
            let now = Date()
            let micros = Int64((now.timeIntervalSince1970 * 1_000_000).rounded())
            let rand = Int.random(in: 0..<(1 << 20))
            let batchId = BatchId("B\(String(micros, radix: 36))\(String(rand, radix: 36))")

            try conn.withTransaction {
                let batchStmt = try conn.prepareCached("""
                    INSERT INTO batches (id, task_id, connection_id, created_at)
                    VALUES (?, ?, ?, ?)
                    """)
                try batchStmt.bindText(1, batchId.value)
                try batchStmt.bindText(2, task.value)
                try batchStmt.bindText(3, connection.value)
                try batchStmt.bindDateSeconds(4, now)
                try batchStmt.step()

                if !ops.isEmpty {
                    let recStmt = try conn.prepareCached("""
                        INSERT INTO history_records (
                            batch_id, op_id, seq, kind, phase, src, dst,
                            group_id, selected, warning, overwrite, status, error, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                        """)
                    for (seq, op) in ops.enumerated() {
                        recStmt.reset()
                        try recStmt.bindText(1, batchId.value)
                        try recStmt.bindText(2, op.id.value)
                        try recStmt.bindInt(3, seq)
                        try recStmt.bindText(4, op.kind.rawValue)
                        try recStmt.bindText(5, op.phase.rawValue)
                        try recStmt.bindText(6, op.src)
                        try recStmt.bindText(7, op.dst)
                        try recStmt.bindText(8, op.group?.value)
                        try recStmt.bindBool(9, op.selected)
                        try recStmt.bindText(10, op.warning)
                        try recStmt.bindBool(11, op.overwrite)
                        try recStmt.bindText(12, OpStatus.pending.rawValue)
                        try recStmt.bindDateSeconds(13, now)
                        try recStmt.step()
                    }
                }
            }
            return batchId
        }

        cacheLock.withLock {
            folderMovesState.generation &+= 1
            folderMovesState.batchMeta[batchId] = (connection: connection, hasFolderMoves: hasFolderMoves)
            folderMovesState.byConnection.removeValue(forKey: connection)
        }

        return batchId
    }

    public func mark(
        batch: BatchId,
        op: OpId,
        status: OpStatus,
        error: String? = nil
    ) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                UPDATE history_records
                SET status = ?, error = ?, updated_at = ?
                WHERE batch_id = ? AND op_id = ?
                """)
            try stmt.bindText(1, status.rawValue)
            try stmt.bindText(2, error)
            try stmt.bindDateSeconds(3, Date())
            try stmt.bindText(4, batch.value)
            try stmt.bindText(5, op.value)
            try stmt.step()
        }
        invalidateFolderMoves(forBatch: batch)
    }

    /// Updates multiple operation statuses in a single SQLite transaction using a cached statement.
    public func markBatch(
        batch: BatchId,
        updates: [(op: OpId, status: OpStatus, error: String?)]
    ) async throws {
        guard !updates.isEmpty else { return }
        let items = updates.map { MarkUpdate(op: $0.op, status: $0.status, error: $0.error) }
        try await db.withConnection { conn in
            let now = Date()
            try conn.withTransaction {
                let stmt = try conn.prepareCached("""
                    UPDATE history_records
                    SET status = ?, error = ?, updated_at = ?
                    WHERE batch_id = ? AND op_id = ?
                    """)
                for item in items {
                    stmt.reset()
                    try stmt.bindText(1, item.status.rawValue)
                    try stmt.bindText(2, item.error)
                    try stmt.bindDateSeconds(3, now)
                    try stmt.bindText(4, batch.value)
                    try stmt.bindText(5, item.op.value)
                    try stmt.step()
                }
            }
        }
        invalidateFolderMoves(forBatch: batch)
    }

    /// Resets all `failed` and `skipped` records in `batch` back to `pending` with `error = NULL`
    /// in a single indexed SQL UPDATE.
    public func resetFailedToPending(batch: BatchId) async throws {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                UPDATE history_records
                SET status = ?, error = NULL, updated_at = ?
                WHERE batch_id = ? AND status IN (?, ?)
                """)
            try stmt.bindText(1, OpStatus.pending.rawValue)
            try stmt.bindDateSeconds(2, Date())
            try stmt.bindText(3, batch.value)
            try stmt.bindText(4, OpStatus.failed.rawValue)
            try stmt.bindText(5, OpStatus.skipped.rawValue)
            try stmt.step()
        }
        invalidateFolderMoves(forBatch: batch)
    }

    /// Fetches only the latest `BatchSummary` for `task` using `idx_batches_task_created`
    /// and `idx_history_batch_status`, avoiding a full `batches()` scan.
    public func latestBatch(task: TaskId) async throws -> BatchSummary? {
        try await db.withConnection { conn in
            let batchStmt = try conn.prepareCached("""
                SELECT id, task_id, connection_id, created_at
                FROM batches
                WHERE task_id = ?
                ORDER BY created_at DESC, rowid DESC
                LIMIT 1
                """)
            try batchStmt.bindText(1, task.value)
            guard try batchStmt.step() else {
                batchStmt.reset()
                return nil
            }
            let batchId = batchStmt.columnText(0)
            let taskId = batchStmt.columnText(1)
            let connectionId = batchStmt.columnText(2)
            let createdAt = batchStmt.columnDateSeconds(3)
            batchStmt.reset()

            let countStmt = try conn.prepareCached("""
                SELECT status, COUNT(*)
                FROM history_records
                WHERE batch_id = ?
                GROUP BY status
                """)
            try countStmt.bindText(1, batchId)
            var counts: [String: Int] = [:]
            while try countStmt.step() {
                counts[countStmt.columnText(0)] = countStmt.columnInt(1)
            }
            countStmt.reset()

            let total = counts.values.reduce(0, +)
            let done = counts[OpStatus.done.rawValue] ?? 0
            let failed = counts[OpStatus.failed.rawValue] ?? 0
            let undoneCount = counts[OpStatus.undone.rawValue] ?? 0
            let undone = (done == 0 && undoneCount > 0)
            return BatchSummary(
                id: BatchId(batchId),
                task: TaskId(taskId),
                connection: ConnectionId(connectionId),
                createdAt: createdAt,
                total: total,
                done: done,
                failed: failed,
                undone: undone
            )
        }
    }

    public func records(batch: BatchId) async throws -> [HistoryRecord] {
        try await db.withConnection { conn in
            let stmt = try conn.prepareCached("""
                SELECT batch_id, op_id, kind, phase, src, dst, group_id,
                       selected, warning, overwrite, status, error, updated_at
                FROM history_records
                WHERE batch_id = ?
                ORDER BY seq ASC
                """)
            try stmt.bindText(1, batch.value)

            var out: [HistoryRecord] = []
            while try stmt.step() {
                let batchId = BatchId(stmt.columnText(0))
                let opId = OpId(stmt.columnText(1))
                let kind = OpKind(rawValue: stmt.columnText(2)) ?? .relocate
                let phase = ExecPhase(rawValue: stmt.columnText(3)) ?? .files
                let src = stmt.columnText(4)
                let dst = stmt.columnText(5)
                let group = stmt.columnOptionalText(6).map { GroupId($0) }
                let selected = stmt.columnBool(7)
                let warning = stmt.columnOptionalText(8)
                let overwrite = stmt.columnBool(9)
                let status = OpStatus(rawValue: stmt.columnText(10)) ?? .pending
                let error = stmt.columnOptionalText(11)
                let updatedAt = stmt.columnDateSeconds(12)

                out.append(
                    HistoryRecord(
                        batch: batchId,
                        op: RenameOp(
                            id: opId,
                            kind: kind,
                            phase: phase,
                            src: src,
                            dst: dst,
                            group: group,
                            selected: selected,
                            warning: warning,
                            overwrite: overwrite
                        ),
                        status: status,
                        error: error,
                        updatedAt: updatedAt
                    )
                )
            }
            return out
        }
    }

    public func batches() async throws -> [BatchSummary] {
        try await db.withConnection { conn in
            struct RawBatch {
                let id: String
                let taskId: String
                let connectionId: String
                let createdAt: Date
            }

            let batchStmt = try conn.prepareCached("""
                SELECT id, task_id, connection_id, created_at
                FROM batches
                ORDER BY created_at DESC, rowid DESC
                """)
            var rawBatches: [RawBatch] = []
            while try batchStmt.step() {
                rawBatches.append(
                    RawBatch(
                        id: batchStmt.columnText(0),
                        taskId: batchStmt.columnText(1),
                        connectionId: batchStmt.columnText(2),
                        createdAt: batchStmt.columnDateSeconds(3)
                    )
                )
            }
            batchStmt.reset()
            if rawBatches.isEmpty { return [] }

            let countStmt = try conn.prepareCached("""
                SELECT batch_id, status, COUNT(op_id)
                FROM history_records
                GROUP BY batch_id, status
                """)
            var counts: [String: [String: Int]] = [:]
            while try countStmt.step() {
                let bId = countStmt.columnText(0)
                let status = countStmt.columnText(1)
                let cnt = countStmt.columnInt(2)
                counts[bId, default: [:]][status] = cnt
            }
            countStmt.reset()

            return rawBatches.map { b in
                let c = counts[b.id] ?? [:]
                let total = c.values.reduce(0, +)
                let done = c[OpStatus.done.rawValue] ?? 0
                let failed = c[OpStatus.failed.rawValue] ?? 0
                let undoneCount = c[OpStatus.undone.rawValue] ?? 0
                let undone = (done == 0 && undoneCount > 0)
                return BatchSummary(
                    id: BatchId(b.id),
                    task: TaskId(b.taskId),
                    connection: ConnectionId(b.connectionId),
                    createdAt: b.createdAt,
                    total: total,
                    done: done,
                    failed: failed,
                    undone: undone
                )
            }
        }
    }

    public func isOrganized(connection: ConnectionId, path: String) async throws -> Bool {
        let found = try await areOrganized(connection: connection, paths: [path])
        return found.contains(path)
    }

    public func areOrganized(connection: ConnectionId, paths: [String]) async throws -> Set<String> {
        let uniquePaths = Array(Set(paths))
        if uniquePaths.isEmpty { return [] }

        let (cachedMoves, startGeneration) = cacheLock.withLock {
            (folderMovesState.byConnection[connection], folderMovesState.generation)
        }

        let folderMoves: [String: [FolderMove]]
        if let cachedMoves {
            folderMoves = cachedMoves
        } else {
            let loaded = try await db.withConnection { conn in
                try Self.loadFolderMoves(conn: conn, connection: connection)
            }
            cacheLock.withLock {
                if folderMovesState.generation == startGeneration {
                    folderMovesState.byConnection[connection] = loaded
                }
            }
            folderMoves = loaded
        }

        return try await db.withConnection { conn in
            // Candidate pre-folder-rename paths for each batch that renamed folders:
            // preFolderDst -> [(requiredBatchId, originalQueriedPath)]
            var preFolderToOrig: [String: [(String?, String)]] = [:]
            preFolderToOrig.reserveCapacity(uniquePaths.count)

            for path in uniquePaths {
                preFolderToOrig[path, default: []].append((nil, path))
                for (batchId, moves) in folderMoves {
                    let pre = Self.reverseMap(path: path, moves: moves)
                    if pre != path {
                        preFolderToOrig[pre, default: []].append((batchId, path))
                    }
                }
            }

            let queryList = Array(preFolderToOrig.keys)
            var out: Set<String> = []
            let chunkSize = Self.maxPlaceholdersPerQuery

            var index = 0
            while index < queryList.count {
                let end = min(index + chunkSize, queryList.count)
                let chunk = queryList[index..<end]
                index = end

                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let sql = """
                    SELECT history_records.batch_id, history_records.dst
                    FROM history_records
                    INNER JOIN batches ON batches.id = history_records.batch_id
                    WHERE batches.connection_id = ?
                      AND history_records.dst IN (\(placeholders))
                      AND history_records.status = ?
                    """
                let stmt = try conn.prepare(sql)
                try stmt.bindText(1, connection.value)
                var bindIdx: Int32 = 2
                for candidatePath in chunk {
                    try stmt.bindText(bindIdx, candidatePath)
                    bindIdx += 1
                }
                try stmt.bindText(bindIdx, OpStatus.done.rawValue)

                while try stmt.step() {
                    let batchId = stmt.columnText(0)
                    let dst = stmt.columnText(1)
                    if let mappings = preFolderToOrig[dst] {
                        for (reqBatch, origPath) in mappings {
                            if reqBatch == nil || reqBatch == batchId {
                                out.insert(origPath)
                            }
                        }
                    }
                }
            }

            return out
        }
    }

    public func deleteTask(_ task: TaskId) async throws {
        try await db.withConnection { conn in
            try conn.withTransaction {
                let delRecords = try conn.prepareCached("""
                    DELETE FROM history_records
                    WHERE batch_id IN (SELECT id FROM batches WHERE task_id = ?)
                    """)
                try delRecords.bindText(1, task.value)
                try delRecords.step()

                let delBatches = try conn.prepareCached("""
                    DELETE FROM batches
                    WHERE task_id = ?
                    """)
                try delBatches.bindText(1, task.value)
                try delBatches.step()
            }
        }
        cacheLock.withLock {
            folderMovesState.generation &+= 1
            folderMovesState.byConnection.removeAll()
            folderMovesState.batchMeta.removeAll()
        }
    }

    // MARK: - Helpers

    private func invalidateFolderMoves(forBatch batch: BatchId) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let meta = folderMovesState.batchMeta[batch] {
            if meta.hasFolderMoves {
                folderMovesState.generation &+= 1
                folderMovesState.byConnection.removeValue(forKey: meta.connection)
            }
        } else {
            folderMovesState.generation &+= 1
            folderMovesState.byConnection.removeAll()
        }
    }

    private static func loadFolderMoves(
        conn: SQLiteConnection,
        connection: ConnectionId
    ) throws -> [String: [FolderMove]] {
        let stmt = try conn.prepareCached("""
            SELECT history_records.batch_id, history_records.src, history_records.dst
            FROM history_records
            INNER JOIN batches ON batches.id = history_records.batch_id
            WHERE batches.connection_id = ?
              AND history_records.phase = ?
              AND history_records.kind = ?
              AND history_records.status = ?
            ORDER BY history_records.seq ASC
            """)
        try stmt.bindText(1, connection.value)
        try stmt.bindText(2, ExecPhase.folders.rawValue)
        try stmt.bindText(3, OpKind.relocate.rawValue)
        try stmt.bindText(4, OpStatus.done.rawValue)

        var byBatch: [String: [FolderMove]] = [:]
        while try stmt.step() {
            let batchId = stmt.columnText(0)
            let src = stmt.columnText(1)
            let dst = stmt.columnText(2)
            byBatch[batchId, default: []].append(FolderMove(src: src, dst: dst))
        }
        stmt.reset()
        return byBatch
    }

    private static func reverseMap(path: String, moves: [FolderMove]) -> String {
        var cur = path
        for move in moves.reversed() {
            if cur == move.dst {
                cur = move.src
            } else if cur.hasPrefix(move.dst + "/") {
                cur = move.src + String(cur.dropFirst(move.dst.count))
            }
        }
        return cur
    }
}
