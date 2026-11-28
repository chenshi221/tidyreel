import Foundation

public protocol FilenameParser: Sendable {
    func parse(_ fileName: String, parentDirs: [String]) -> ParsedName
    func classify(_ fileName: String) -> FileRole
}

public extension FilenameParser {
    func parse(_ fileName: String) -> ParsedName {
        parse(fileName, parentDirs: [])
    }
}

public protocol StorageBackend: Sendable {
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry]
    func mkdirs(_ dir: String) async throws
    func rename(_ path: String, newName: String) async throws
    func renameMany(_ dir: String, names: [String: String]) async throws
    func move(srcDir: String, dstDir: String, names: [String]) async throws
    /// Returns true only when the directory was removed. Backends without a conditional delete retain it.
    func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool
    func remove(dir: String, names: [String]) async throws
    func exists(_ path: String) async throws -> Bool
    func read(_ path: String) async throws -> Data
    func write(_ path: String, bytes: Data) async throws
    func ping() async throws
    func close() async
    /// True when the backend implements a native multi-item server RPC for `renameMany`/`move` (e.g. Alist).
    var supportsServerBatching: Bool { get }
    /// True when `atomicRelocate(from:to:)` performs a single-step cross-directory rename+move without overwriting `to`.
    var supportsAtomicRelocate: Bool { get }
    /// Moves and/or renames `src` directly to `dst` in one backend operation when `supportsAtomicRelocate` is true.
    func atomicRelocate(from src: String, to dst: String) async throws
}

public extension StorageBackend {
    func list(_ dir: String) async throws -> [RemoteEntry] {
        try await list(dir, refresh: false)
    }

    func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool { false }

    var supportsServerBatching: Bool { false }
    var supportsAtomicRelocate: Bool { false }

    func atomicRelocate(from src: String, to dst: String) async throws {
        let srcDir = dirOf(src)
        let dstDir = dirOf(dst)
        let srcName = baseOf(src)
        let dstName = baseOf(dst)
        if srcDir == dstDir {
            try await rename(src, newName: dstName)
        } else {
            try await mkdirs(dstDir)
            try await move(srcDir: srcDir, dstDir: dstDir, names: [srcName])
            if srcName != dstName {
                try await rename(joinPath(dstDir, srcName), newName: dstName)
            }
        }
    }
}

public protocol RangeReadableBackend: StorageBackend {
    func readRange(path: String, start: Int64, length: Int) async throws -> Data
}

public func readRangeIfSupported(
    backend: any StorageBackend,
    path: String,
    start: Int64,
    length: Int
) async throws -> Data? {
    guard let readable = backend as? any RangeReadableBackend else { return nil }
    return try await readable.readRange(path: path, start: start, length: length)
}

public protocol MediaProbe: Sendable {
    func probe(backend: any StorageBackend, path: String, fileSize: Int64?) async -> MediaProbeInfo?
    func probe(
        backend: any StorageBackend,
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date?
    ) async -> MediaProbeInfo?
}

public extension MediaProbe {
    func probe(
        backend: any StorageBackend,
        connection: ConnectionId,
        path: String,
        fileSize: Int64?,
        modifiedAt: Date?
    ) async -> MediaProbeInfo? {
        await probe(backend: backend, path: path, fileSize: fileSize)
    }
}

public protocol MetadataProvider: Sendable {
    func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate]
    func show(_ tmdbId: Int) async throws -> ShowDetail
    func season(_ tmdbId: Int, season: Int) async throws -> [Episode]
    func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup]
    func movie(_ tmdbId: Int) async throws -> MovieDetail
}

public extension MetadataProvider {
    func search(_ query: String) async throws -> [Candidate] {
        try await search(query, kind: nil, year: nil)
    }
}

public protocol ExternalIdLookup: Sendable {
    func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate?
}

public protocol AltTitleSource: Sendable {
    func altTitles(_ query: String) async -> [String]
}

public protocol TmdbResponseCache: Sendable {
    func get(_ key: String) async -> String?
    func put(_ key: String, json: String) async
}

public protocol Recognizer: Sendable {
    func recognize(
        connection: ConnectionId,
        roots: [String],
        files: [RemoteEntry],
        read: (@Sendable (String) async throws -> Data)?,
        backend: (any StorageBackend)?
    ) async throws -> ScanResult
}

public protocol Planner: Sendable {
    func build(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        options: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>?
    ) async throws -> RenamePlan
}

public extension Planner {
    func build(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        options: PlanOptions
    ) async throws -> RenamePlan {
        try await build(scan: scan, decisions: decisions, options: options, existing: [], existingDirs: nil)
    }
}

public protocol HistoryStore: Sendable {
    func saveWrittenDigest(_ digest: String, batch: BatchId, op: OpId) async throws
    func beginBatch(task: TaskId, connection: ConnectionId, ops: [RenameOp]) async throws -> BatchId
    func mark(batch: BatchId, op: OpId, status: OpStatus, error: String?) async throws
    func markBatch(batch: BatchId, updates: [(op: OpId, status: OpStatus, error: String?)]) async throws
    func resetFailedToPending(batch: BatchId) async throws
    func records(batch: BatchId) async throws -> [HistoryRecord]
    func batches() async throws -> [BatchSummary]
    func latestBatch(task: TaskId) async throws -> BatchSummary?
    func isOrganized(connection: ConnectionId, path: String) async throws -> Bool
    func areOrganized(connection: ConnectionId, paths: [String]) async throws -> Set<String>
    func deleteTask(_ task: TaskId) async throws
}

public extension HistoryStore {
    func markBatch(batch: BatchId, updates: [(op: OpId, status: OpStatus, error: String?)]) async throws {
        for update in updates {
            try await mark(batch: batch, op: update.op, status: update.status, error: update.error)
        }
    }

    func resetFailedToPending(batch: BatchId) async throws {
        let recs = try await records(batch: batch)
        var updates: [(op: OpId, status: OpStatus, error: String?)] = []
        for r in recs where r.status == .failed || r.status == .skipped {
            updates.append((op: r.op.id, status: .pending, error: nil))
        }
        try await markBatch(batch: batch, updates: updates)
    }

    func latestBatch(task: TaskId) async throws -> BatchSummary? {
        let all = try await batches()
        return all.first { $0.task == task }
    }
}

public protocol TaskStore: Sendable {
    func saveSummary(_ summary: TaskSummary) async throws
    func saveReview(
        id: TaskId,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: Set<String>
    ) async throws
    var supportsTargetedDecisionSave: Bool { get }
    func saveDecisions(
        id: TaskId,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: Set<String>,
        cardMeta: TaskCardMeta?
    ) async throws
    func pruneScanBlob(id: TaskId) async throws
    func clearReview(id: TaskId) async throws
    /// Fast startup query: loads ONLY TaskSummary columns (never reads or decodes scan_json).
    func loadSummaries() async throws -> [TaskSummary]
    /// Lazy on-demand query: loads scan_json & decisions_json for one task off the main thread.
    func loadReview(id: TaskId) async throws -> StoredTaskReview?
    func loadAll() async throws -> [StoredTask]
    func delete(id: TaskId) async throws
}

public extension TaskStore {
    var supportsTargetedDecisionSave: Bool { false }

    func saveDecisions(
        id: TaskId,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: Set<String>,
        cardMeta: TaskCardMeta?
    ) async throws {
        if let existing = try await loadReview(id: id) {
            try await saveReview(
                id: id,
                scan: existing.scan,
                decisions: decisions,
                unassignedDeletes: unassignedDeletes
            )
        }
    }

    func pruneScanBlob(id: TaskId) async throws {}
}

public protocol FolderStatsCacheStore: Sendable {
    func loadFor(_ connection: ConnectionId) async throws -> [String: CachedFolderRecord]
    func saveBatch(connection: ConnectionId, records: [CachedFolderRecord]) async throws
    func clearFor(_ connection: ConnectionId) async throws
}

public protocol Executor: Sendable {
    func execute(
        task: TaskId,
        connection: ConnectionId,
        plan: RenamePlan,
        backend: any StorageBackend
    ) -> AsyncThrowingStream<ExecProgress, Error>

    func resume(
        batch: BatchId,
        backend: any StorageBackend
    ) -> AsyncThrowingStream<ExecProgress, Error>

    func undo(
        batch: BatchId,
        backend: any StorageBackend,
        only: Set<OpId>?
    ) -> AsyncThrowingStream<ExecProgress, Error>
}

public protocol TaskManager: Sendable {
    func submit(
        connection: ConnectionId,
        paths: [String],
        mode: OrganizeMode,
        scrape: Bool,
        scrapeOnly: Bool
    ) async throws -> TaskId
    func watchAll() -> AsyncStream<[TaskSummary]>
    func currentSummaries() async -> [TaskSummary]
    func review(_ id: TaskId) async throws -> TaskReview
    func updateDecision(_ id: TaskId, group: GroupId, decision: GroupDecision) async throws -> TaskReview
    func updateDecisions(_ id: TaskId, updates: [(group: GroupId, decision: GroupDecision)]) async throws -> TaskReview
    func setMode(_ id: TaskId, mode: OrganizeMode) async throws -> TaskReview
    func assignUnassigned(_ id: TaskId, filePath: String, targetGroup: GroupId) async throws -> TaskReview
    func setUnassignedDelete(_ id: TaskId, filePath: String, delete: Bool) async throws -> TaskReview
    func setUnassignedDeletes(_ id: TaskId, updates: [String: Bool]) async throws -> TaskReview
    func mergeGroups(_ id: TaskId, keep: GroupId, absorb: GroupId) async throws -> TaskReview
    func splitGroup(_ id: TaskId, group: GroupId, filePaths: Set<String>) async throws -> TaskReview
    func run(_ id: TaskId, onlyConfident: Bool) async throws
    func cancel(_ id: TaskId) async
    func undo(_ id: TaskId, only: Set<OpId>?) async throws
    func findEmptyDirs(_ id: TaskId) async throws -> [String]
    func removeEmptyDirs(_ id: TaskId, dirs: [String]) async throws -> Int
    func retryFailed(_ id: TaskId) async throws
    func retry(_ id: TaskId) async throws
    func delete(_ id: TaskId) async throws
    func resumeInterrupted() async throws
}

public extension TaskManager {
    func updateDecisions(
        _ id: TaskId,
        updates: [(group: GroupId, decision: GroupDecision)]
    ) async throws -> TaskReview {
        guard !updates.isEmpty else { return try await review(id) }
        var last: TaskReview?
        for item in updates {
            last = try await updateDecision(id, group: item.group, decision: item.decision)
        }
        if let last { return last }
        return try await review(id)
    }

    func setUnassignedDeletes(_ id: TaskId, updates: [String: Bool]) async throws -> TaskReview {
        guard !updates.isEmpty else { return try await review(id) }
        var last: TaskReview?
        for (path, delete) in updates {
            last = try await setUnassignedDelete(id, filePath: path, delete: delete)
        }
        if let last { return last }
        return try await review(id)
    }
}
