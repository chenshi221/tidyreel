import Foundation
import TidyreelModels

private let seasonArtRegex = try! NSRegularExpression(
    pattern: #"^season(?:\d+|-specials|-all)-(?:poster|banner|fanart|landscape)\.(?:jpe?g|png|webp)$"#,
    options: [.caseInsensitive]
)

private let taskSeqRegex = try! NSRegularExpression(pattern: #"^T(\d+)-"#)

private let discMetaDirs: Set<String> = [
    "BDMV", "VIDEO_TS", "AUDIO_TS", "CERTIFICATE", "AACS", "ANY!", "JACKET_P", "ADV_OBJ",
]

private let undoSkipPrefixes: [String] = [
    "删除无法撤销",
    "文件夹非空，已保留",
    "原位置已被占用",
    "目标已不存在",
    "覆盖写入无法撤销",
]

// MARK: - Thread-safe Generation Tracker & Walk Helpers

private final class TaskGenerationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deleted = false
    private var pipelineGen = 0

    func isStale(gen: Int) -> Bool {
        lock.withLock { cancelled || deleted || pipelineGen != gen }
    }

    var isCancelled: Bool {
        get { lock.withLock { cancelled } }
        set { lock.withLock { cancelled = newValue } }
    }

    func markDeleted() {
        lock.withLock {
            deleted = true
            pipelineGen += 1
        }
    }

    @discardableResult
    func bumpPipelineGen() -> Int {
        lock.withLock {
            pipelineGen += 1
            return pipelineGen
        }
    }
}

private final class ImportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RemoteEntry] = []
    private var seen: Set<String> = []
    private var lastTick: TimeInterval = 0
    private let minIntervalSec: TimeInterval

    init(minIntervalMs: Int) {
        self.minIntervalSec = Double(max(0, minIntervalMs)) / 1000.0
    }

    /// Inserts `entry` if unseen and returns current count when a live progress emit is due.
    func add(_ entry: RemoteEntry) -> Int? {
        lock.withLock {
            guard seen.insert(entry.path).inserted else { return nil }
            entries.append(entry)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTick >= minIntervalSec {
                lastTick = now
                return entries.count
            }
            return nil
        }
    }

    func sortedSnapshot() -> [RemoteEntry] {
        lock.withLock {
            entries.sorted { $0.path < $1.path }
        }
    }
}

private final class ExistingPathsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var existing: Set<String>
    private var existingDirs: Set<String>

    init(existing: Set<String>, existingDirs: Set<String>) {
        self.existing = existing
        self.existingDirs = existingDirs
    }

    func record(dir: String, entries: [RemoteEntry]) {
        lock.withLock {
            existingDirs.insert(dir)
            for e in entries {
                existing.insert(e.path)
                if e.isDir { existingDirs.insert(e.path) }
            }
        }
    }

    func snapshot() -> (existing: Set<String>, existingDirs: Set<String>) {
        lock.withLock { (existing, existingDirs) }
    }
}

private enum OptionalBatchUpdate {
    case keep
    case set(BatchId?)
}

private final class TaskEntry {
    var summary: TaskSummary
    let orderIndex: Int
    var scan: ScanResult?
    var decisions: [GroupId: GroupDecision] = [:]
    var unassignedDeletes: [String: Bool] = [:]
    var plan: RenamePlan?
    var planOptions: PlanOptions?
    var planExisting: Set<String> = []
    var cachedExisting: Set<String> = []
    var cachedExistingDirs: Set<String> = []
    var cachedListedDirs: Set<String> = []
    var inFlightPlan: (token: UUID, editGen: Int, options: PlanOptions, task: Task<RenamePlan, any Error>)?
    var inFlightReviewLoad: (token: UUID, task: Task<StoredTaskReview?, any Error>)?
    var pipelineTask: (gen: Int, task: Task<Void, Never>)?
    var priorBatches: Set<BatchId> = []
    let tracker = TaskGenerationTracker()
    var editGen = 0
    var pendingEdits = 0
    var reviewDirty = false
    var scanDirty = false
    var summaryDirty = false
    var busy = false
    var busyWaiters: [CheckedContinuation<Void, Never>] = []
    var execTask: Task<Void, Never>?
    var execFailure: (any Error)?
    var lastPersistTask: Task<Void, Never>?
    var lastProgressEmitAt: TimeInterval = 0

    var cancelled: Bool {
        get { tracker.isCancelled }
        set { tracker.isCancelled = newValue }
    }

    init(summary: TaskSummary, orderIndex: Int) {
        self.summary = summary
        self.orderIndex = orderIndex
    }
}

// MARK: - DefaultTaskManager

public actor DefaultTaskManager: TaskManager {
    private let backendFor: @Sendable (ConnectionId) throws -> any StorageBackend
    private let recognizer: any Recognizer
    private let parser: any FilenameParser
    private let planner: any Planner
    private let executor: any Executor
    private let history: any HistoryStore
    private let store: any TaskStore
    private let options: @Sendable (ConnectionId, OrganizeMode) -> PlanOptions
    private let onPathsMutated: (@Sendable (ConnectionId, [String]) async -> Void)?
    private let importUpdateIntervalMs: Int

    private var tasks: [TaskId: TaskEntry] = [:]
    private var interrupted: [TaskId] = []
    private var watchers: [UUID: AsyncStream<[TaskSummary]>.Continuation] = [:]
    private var seq = 0
    private var nextOrderIndex = 0
    private var isLoaded = false
    private var loadTask: Task<Void, any Error>?
    private var isDisposed = false

    public init(
        backendFor: @escaping @Sendable (ConnectionId) throws -> any StorageBackend,
        recognizer: any Recognizer,
        planner: any Planner,
        executor: any Executor,
        history: any HistoryStore,
        store: any TaskStore,
        options: @escaping @Sendable (ConnectionId, OrganizeMode) -> PlanOptions,
        onPathsMutated: (@Sendable (ConnectionId, [String]) async -> Void)? = nil
    ) {
        self.backendFor = backendFor
        self.recognizer = recognizer
        self.parser = extractFilenameParser(from: recognizer)
        self.planner = planner
        self.executor = executor
        self.history = history
        self.store = store
        self.options = options
        self.onPathsMutated = onPathsMutated
        self.importUpdateIntervalMs = 100
        Task { try? await self.ensureLoaded() }
    }

    internal init(
        backendFor: @escaping @Sendable (ConnectionId) throws -> any StorageBackend,
        recognizer: any Recognizer,
        planner: any Planner,
        executor: any Executor,
        history: any HistoryStore,
        store: any TaskStore,
        options: @escaping @Sendable (ConnectionId, OrganizeMode) -> PlanOptions,
        importUpdateIntervalMs: Int,
        onPathsMutated: (@Sendable (ConnectionId, [String]) async -> Void)? = nil
    ) {
        self.backendFor = backendFor
        self.recognizer = recognizer
        self.parser = extractFilenameParser(from: recognizer)
        self.planner = planner
        self.executor = executor
        self.history = history
        self.store = store
        self.options = options
        self.onPathsMutated = onPathsMutated
        self.importUpdateIntervalMs = max(0, importUpdateIntervalMs)
        Task { try? await self.ensureLoaded() }
    }

    /// Test inspection helper verifying lazy review memory eviction.
    internal func hasCachedReview(_ id: TaskId) async -> Bool {
        try? await ensureLoaded()
        return tasks[id]?.scan != nil
    }

    public func dispose() {
        isDisposed = true
        loadTask?.cancel()
        loadTask = nil
        for t in tasks.values {
            t.tracker.bumpPipelineGen()
            t.pipelineTask?.task.cancel()
            t.pipelineTask = nil
            t.execTask?.cancel()
            t.execTask = nil
            evictReviewFromMemory(t)
        }
        for c in watchers.values {
            c.finish()
        }
        watchers.removeAll()
    }

    // MARK: - Startup & Lazy Review Cache

    private func ensureLoaded() async throws {
        if isLoaded { return }
        if let existing = loadTask {
            try await existing.value
            return
        }
        let task = Task {
            try await self.performInitialLoad()
        }
        loadTask = task
        do {
            try await task.value
            isLoaded = true
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func performInitialLoad() async throws {
        // CRITICAL MEMORY FIX: Load ONLY TaskSummary columns — never loadAll() or historical ScanResults!
        let loadedSummaries = try await store.loadSummaries()
        let sorted = loadedSummaries.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.value < b.id.value
        }

        for s in sorted {
            nextOrderIndex += 1
            let entry = TaskEntry(summary: s, orderIndex: nextOrderIndex)
            tasks[s.id] = entry

            let ns = NSRange(s.id.value.startIndex..<s.id.value.endIndex, in: s.id.value)
            if let m = taskSeqRegex.firstMatch(in: s.id.value, range: ns),
               let r = Range(m.range(at: 1), in: s.id.value),
               let n = Int(s.id.value[r]),
               n > seq
            {
                seq = n
            }
        }

        for t in Array(tasks.values) {
            switch t.summary.stage {
            case .importing, .recognizing:
                evictReviewFromMemory(t)
                let gen = t.tracker.bumpPipelineGen()
                _ = emitSummary(t, withSummary(t.summary, stage: .importing))
                t.pipelineTask?.task.cancel()
                t.pipelineTask = (gen: gen, task: Task { await self.pipeline(t, gen: gen) })
            case .renamingFiles, .renamingFolders:
                interrupted.append(t.summary.id)
            default:
                break
            }
        }
    }

    private func evictReviewFromMemory(_ t: TaskEntry) {
        t.inFlightPlan?.task.cancel()
        t.inFlightReviewLoad?.task.cancel()
        t.scan = nil
        t.decisions = [:]
        t.unassignedDeletes = [:]
        t.plan = nil
        t.planOptions = nil
        t.planExisting = []
        t.cachedExisting = []
        t.cachedExistingDirs = []
        t.cachedListedDirs = []
        t.inFlightPlan = nil
        t.inFlightReviewLoad = nil
        t.scanDirty = false
    }

    private func evictOtherCachedReviews(keeping keepId: TaskId) {
        for (otherId, other) in tasks where otherId != keepId {
            if other.summary.stage == .awaitingReview &&
                other.scan != nil &&
                !other.busy &&
                other.pendingEdits == 0 &&
                !other.reviewDirty &&
                other.inFlightPlan == nil &&
                other.inFlightReviewLoad == nil
            {
                evictReviewFromMemory(other)
            }
        }
    }

    private func loadReviewState(
        _ t: TaskEntry
    ) async throws -> (scan: ScanResult, decisions: [GroupId: GroupDecision], unassignedDeletes: [String: Bool]) {
        if let scan = t.scan {
            return (scan, t.decisions, t.unassignedDeletes)
        }
        if t.summary.stage == .importing || t.summary.stage == .recognizing {
            throw TidyreelExecutionError.invalidState("任务尚未识别完成")
        }

        let id = t.summary.id
        let loadTaskToAwait: Task<StoredTaskReview?, any Error>
        let token: UUID
        if let inflight = t.inFlightReviewLoad {
            token = inflight.token
            loadTaskToAwait = inflight.task
        } else {
            let newToken = UUID()
            let newTask = Task { [store] in
                try await store.loadReview(id: id)
            }
            token = newToken
            loadTaskToAwait = newTask
            t.inFlightReviewLoad = (newToken, newTask)
        }

        let storedOpt: StoredTaskReview?
        do {
            storedOpt = try await loadTaskToAwait.value
        } catch {
            if t.inFlightReviewLoad?.token == token {
                t.inFlightReviewLoad = nil
            }
            throw error
        }
        if t.inFlightReviewLoad?.token == token {
            t.inFlightReviewLoad = nil
        }

        // Another concurrent edit may have already populated t.scan while awaiting.
        if let scan = t.scan {
            return (scan, t.decisions, t.unassignedDeletes)
        }

        guard let stored = storedOpt else {
            throw TidyreelExecutionError.invalidState("任务尚未识别完成")
        }
        let deletesMap = Dictionary(uniqueKeysWithValues: stored.unassignedDeletes.map { ($0, true) })

        // Cache in RAM ONLY while awaitingReview or actively executing/editing (LRU of 1 awaitingReview task).
        if t.summary.stage == .awaitingReview ||
            t.summary.stage == .renamingFiles ||
            t.summary.stage == .renamingFolders
        {
            if t.summary.stage == .awaitingReview {
                evictOtherCachedReviews(keeping: t.summary.id)
            }
            t.scan = stored.scan
            t.decisions = stored.decisions
            t.unassignedDeletes = deletesMap
        }
        return (stored.scan, stored.decisions, deletesMap)
    }

    // MARK: - Resume Interrupted

    public func resumeInterrupted() async throws {
        try await ensureLoaded()
        let ids = interrupted
        interrupted.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await self.resumeTask(id)
                }
            }
            await group.waitForAll()
        }
    }

    private func resumeTask(_ id: TaskId) async {
        guard let t = tasks[id], !t.cancelled, !t.busy else { return }
        await withBusy(t) {
            var batch: BatchId?
            do {
                if let existingBatch = t.summary.batch {
                    batch = existingBatch
                } else {
                    batch = try await self.batchOf(id, includeUndone: false)
                }
                if t.cancelled || self.tasks[id] !== t { return }
                guard let validBatch = batch else {
                    try await self.setSummary(
                        t,
                        self.withSummary(
                            t.summary,
                            stage: .awaitingReview,
                            message: "上次执行未开始，请重新确认"
                        )
                    )
                    return
                }
                _ = self.emitSummary(t, self.withSummary(t.summary, progress: t.summary.progress, batch: .set(validBatch)))
                let records = try await self.history.records(batch: validBatch)
                let hasWrites = t.summary.scrape || records.contains { $0.status == .pending && $0.op.kind == .write }
                if t.cancelled || self.tasks[id] !== t { return }
                let be = try self.backendFor(t.summary.connection)
                await self.drive(
                    t,
                    stream: self.executor.resume(batch: validBatch, backend: be),
                    batch: validBatch,
                    hasWrites: hasWrites
                )
            } catch {
                if t.cancelled || self.tasks[id] !== t { return }
                self.evictReviewFromMemory(t)
                await self.setSummarySafe(
                    t,
                    self.withSummary(
                        t.summary,
                        stage: batch == nil ? .failed : .partiallyFailed,
                        message: "恢复执行失败：\(Self.friendlyError(error))",
                        progress: nil,
                        batch: .set(batch)
                    ),
                    force: true
                )
            }
        }
    }

    // MARK: - Watch & Submit

    nonisolated public func watchAll() -> AsyncStream<[TaskSummary]> {
        let watcherId = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { _ in
                Task { await self.removeWatcher(watcherId) }
            }
            Task {
                await self.addWatcher(watcherId, continuation: continuation)
            }
        }
    }

    private func addWatcher(_ id: UUID, continuation: AsyncStream<[TaskSummary]>.Continuation) async {
        try? await ensureLoaded()
        if isDisposed {
            continuation.finish()
            return
        }
        watchers[id] = continuation
        continuation.yield(snapshot())
    }

    private func removeWatcher(_ id: UUID) {
        watchers.removeValue(forKey: id)
    }

    public func currentSummaries() async -> [TaskSummary] {
        try? await ensureLoaded()
        return snapshot()
    }

    public func submit(
        connection: ConnectionId,
        paths: [String],
        mode: OrganizeMode,
        scrape: Bool = false,
        scrapeOnly: Bool = false
    ) async throws -> TaskId {
        try await ensureLoaded()
        let cleanPaths = paths.map { raw -> String in
            if raw == "/" { return "/" }
            var s = raw
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        seq += 1
        let randHex = String(format: "%06x", Int.random(in: 0..<(1 << 24)))
        let id = TaskId("T\(seq)-\(randHex)")
        nextOrderIndex += 1
        let t = TaskEntry(
            summary: TaskSummary(
                id: id,
                connection: connection,
                paths: cleanPaths,
                mode: mode,
                scrape: scrape || scrapeOnly,
                scrapeOnly: scrapeOnly,
                stage: .importing,
                message: "正在导入文件",
                createdAt: Date()
            ),
            orderIndex: nextOrderIndex
        )
        tasks[id] = t
        broadcastSnapshot()
        try await persistSummary(t)
        let gen = t.tracker.bumpPipelineGen()
        t.pipelineTask = (gen: gen, task: Task { await self.pipeline(t, gen: gen) })
        return id
    }

    // MARK: - Review & Interactive Edits

    public func review(_ id: TaskId) async throws -> TaskReview {
        let t = try await getTask(id)
        return try await buildReview(t)
    }

    private func buildReview(_ t: TaskEntry) async throws -> TaskReview {
        let (scan, decisions, _) = try await loadReviewState(t)
        let preview: RenamePlan
        if t.summary.stage == .awaitingReview {
            preview = try await ensurePlan(t)
        } else if let cachedPlan = t.plan {
            preview = cachedPlan
        } else {
            let resolvedBatch: BatchId?
            if let existingBatch = t.summary.batch {
                resolvedBatch = existingBatch
            } else {
                resolvedBatch = try? await batchOf(t.summary.id, includeUndone: true)
            }
            if let b = resolvedBatch {
                let recs = (try? await history.records(batch: b)) ?? []
                preview = RenamePlan(ops: recs.map(\.op))
            } else {
                preview = RenamePlan(ops: [])
            }
        }
        return TaskReview(
            id: t.summary.id,
            scan: scan,
            decisions: decisions,
            preview: preview
        )
    }

    private func commitReviewEdit(
        _ t: TaskEntry,
        nextSummary: TaskSummary,
        nextScan: ScanResult,
        nextDecisions: [GroupId: GroupDecision],
        nextUnassignedDeletes: [String: Bool],
        emitSummaryFlag: Bool = false,
        scanMutated: Bool
    ) async throws -> TaskReview {
        let id = t.summary.id
        let prevSummary = t.summary
        let prevScan = t.scan
        let prevDecisions = t.decisions
        let prevDeletes = t.unassignedDeletes
        let prevDirty = t.reviewDirty
        let prevScanDirty = t.scanDirty
        let prevSummaryDirty = t.summaryDirty

        let summaryChanged = emitSummaryFlag || nextSummary != prevSummary
        t.summary = nextSummary
        t.scan = nextScan
        t.decisions = nextDecisions
        t.unassignedDeletes = nextUnassignedDeletes
        t.reviewDirty = true
        t.scanDirty = prevScanDirty || scanMutated
        t.summaryDirty = prevSummaryDirty || summaryChanged

        t.editGen += 1
        let gen = t.editGen
        t.pendingEdits += 1
        defer { t.pendingEdits -= 1 }

        let initialExisting = t.cachedExisting
        let initialExistingDirs = t.cachedExistingDirs
        let initialListedDirs = t.cachedListedDirs

        do {
            let built = try await buildPlanWithOptions(
                summary: nextSummary,
                scan: nextScan,
                decisions: nextDecisions,
                unassignedDeletes: nextUnassignedDeletes,
                initialExisting: initialExisting,
                initialExistingDirs: initialExistingDirs,
                initialListedDirs: initialListedDirs,
                refreshRemote: false
            )
            if t.editGen == gen && t.summary.stage == .awaitingReview && tasks[id] === t {
                let shouldEmitSummary = t.summaryDirty
                let needFullScanSave = t.scanDirty || !store.supportsTargetedDecisionSave
                t.plan = built.plan
                t.planOptions = built.options
                t.planExisting = built.existing
                t.cachedExisting = built.existing
                t.cachedExistingDirs = built.existingDirs
                t.cachedListedDirs = built.listedDirs
                t.inFlightPlan = nil
                t.reviewDirty = false
                t.scanDirty = false
                t.summaryDirty = false
                if needFullScanSave {
                    try await saveReview(
                        t,
                        scan: nextScan,
                        decisions: nextDecisions,
                        unassignedDeletes: nextUnassignedDeletes
                    )
                } else {
                    try await saveDecisionsOnly(
                        t,
                        scan: nextScan,
                        decisions: nextDecisions,
                        unassignedDeletes: nextUnassignedDeletes
                    )
                }
                if shouldEmitSummary {
                    try await setSummary(t, nextSummary)
                }
            }
            return try await buildReview(t)
        } catch {
            if t.editGen == gen && t.summary.stage == .awaitingReview && tasks[id] === t {
                t.summary = prevSummary
                t.scan = prevScan
                t.decisions = prevDecisions
                t.unassignedDeletes = prevDeletes
                t.inFlightPlan = nil
                t.reviewDirty = prevDirty
                t.scanDirty = prevScanDirty
                t.summaryDirty = prevSummaryDirty
                if prevDirty {
                    t.plan = nil
                    t.planOptions = nil
                    t.planExisting = []
                    if let prevScan {
                        if prevScanDirty || !store.supportsTargetedDecisionSave {
                            try? await saveReview(
                                t,
                                scan: prevScan,
                                decisions: prevDecisions,
                                unassignedDeletes: prevDeletes
                            )
                        } else {
                            try? await saveDecisionsOnly(
                                t,
                                scan: prevScan,
                                decisions: prevDecisions,
                                unassignedDeletes: prevDeletes
                            )
                        }
                    }
                    if prevSummaryDirty {
                        try? await setSummary(t, prevSummary)
                    }
                    t.reviewDirty = false
                    t.scanDirty = false
                    t.summaryDirty = false
                } else if t.planOptions != effectiveOptions(prevSummary, taskUnassignedDeletes: prevDeletes) {
                    t.plan = nil
                    t.planOptions = nil
                    t.planExisting = []
                }
            }
            throw error
        }
    }

    public func updateDecision(
        _ id: TaskId,
        group: GroupId,
        decision: GroupDecision
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        var decisions = currentDecisions
        decisions[group] = decision
        return try await commitReviewEdit(
            t,
            nextSummary: t.summary,
            nextScan: scan,
            nextDecisions: decisions,
            nextUnassignedDeletes: currentDeletes,
            scanMutated: false
        )
    }

    public func updateDecisions(
        _ id: TaskId,
        updates: [(group: GroupId, decision: GroupDecision)]
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        if updates.isEmpty {
            return try await buildReview(t)
        }

        var decisions = currentDecisions
        for item in updates {
            decisions[item.group] = item.decision
        }
        return try await commitReviewEdit(
            t,
            nextSummary: t.summary,
            nextScan: scan,
            nextDecisions: decisions,
            nextUnassignedDeletes: currentDeletes,
            scanMutated: false
        )
    }

    public func setMode(_ id: TaskId, mode: OrganizeMode) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        if t.summary.mode == mode && t.plan != nil && t.pendingEdits == 0 {
            return try await buildReview(t)
        }
        let next = withSummary(t.summary, mode: mode)
        return try await commitReviewEdit(
            t,
            nextSummary: next,
            nextScan: scan,
            nextDecisions: currentDecisions,
            nextUnassignedDeletes: currentDeletes,
            emitSummaryFlag: true,
            scanMutated: false
        )
    }

    public func assignUnassigned(
        _ id: TaskId,
        filePath: String,
        targetGroup: GroupId
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        guard let uIdx = scan.unassigned.firstIndex(where: { $0.path == filePath }) else {
            throw TidyreelExecutionError.invalidArgument("未找到未分组文件：\(filePath)")
        }
        guard let gIdx = scan.groups.firstIndex(where: { $0.id == targetGroup }) else {
            throw TidyreelExecutionError.invalidArgument("未找到目标分组：\(targetGroup.value)")
        }

        let p = parser
        let orig = scan.unassigned[uIdx]
        let parsed = orig.parsed ?? p.parse(orig.name, parentDirs: Self.parentDirNames(path: orig.path, roots: scan.roots))
        var role = orig.role
        if role == .junk || role == .other {
            let classified = p.classify(orig.name)
            if classified != .junk && classified != .other {
                role = classified
            }
        }
        let assigned = ScanFile(
            path: orig.path,
            name: orig.name,
            size: orig.size,
            role: role,
            parsed: parsed,
            isDiscDir: orig.isDiscDir
        )
        var nextUnassigned = scan.unassigned
        nextUnassigned.remove(at: uIdx)

        var target = scan.groups[gIdx]
        target.files = (target.files + [assigned]).sorted { $0.path < $1.path }
        var nextGroups = scan.groups
        nextGroups[gIdx] = target

        let nextScan = ScanResult(
            connection: scan.connection,
            roots: scan.roots,
            groups: nextGroups,
            unassigned: nextUnassigned
        )
        var nextDeletes = currentDeletes
        nextDeletes.removeValue(forKey: filePath)

        return try await commitReviewEdit(
            t,
            nextSummary: withCounts(t.summary, scan: nextScan),
            nextScan: nextScan,
            nextDecisions: currentDecisions,
            nextUnassignedDeletes: nextDeletes,
            emitSummaryFlag: true,
            scanMutated: true
        )
    }

    public func setUnassignedDelete(
        _ id: TaskId,
        filePath: String,
        delete: Bool
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        guard scan.unassigned.contains(where: { $0.path == filePath }) else {
            throw TidyreelExecutionError.invalidArgument("未找到未分组文件：\(filePath)")
        }
        var nextDeletes = currentDeletes
        nextDeletes[filePath] = delete
        return try await commitReviewEdit(
            t,
            nextSummary: t.summary,
            nextScan: scan,
            nextDecisions: currentDecisions,
            nextUnassignedDeletes: nextDeletes,
            emitSummaryFlag: true,
            scanMutated: false
        )
    }

    public func setUnassignedDeletes(
        _ id: TaskId,
        updates: [String: Bool]
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        if updates.isEmpty {
            return try await buildReview(t)
        }

        let validUnassigned = Set(scan.unassigned.map(\.path))
        for path in updates.keys {
            guard validUnassigned.contains(path) else {
                throw TidyreelExecutionError.invalidArgument("未找到未分组文件：\(path)")
            }
        }
        var nextDeletes = currentDeletes
        for (path, delete) in updates {
            nextDeletes[path] = delete
        }
        return try await commitReviewEdit(
            t,
            nextSummary: t.summary,
            nextScan: scan,
            nextDecisions: currentDecisions,
            nextUnassignedDeletes: nextDeletes,
            emitSummaryFlag: true,
            scanMutated: false
        )
    }

    public func mergeGroups(
        _ id: TaskId,
        keep: GroupId,
        absorb: GroupId
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        if keep == absorb {
            throw TidyreelExecutionError.invalidArgument("不能将分组与自身合并")
        }
        guard let keepIdx = scan.groups.firstIndex(where: { $0.id == keep }) else {
            throw TidyreelExecutionError.invalidArgument("未找到保留分组：\(keep.value)")
        }
        guard let absorbIdx = scan.groups.firstIndex(where: { $0.id == absorb }) else {
            throw TidyreelExecutionError.invalidArgument("未找到被合并分组：\(absorb.value)")
        }

        let keepGroup = scan.groups[keepIdx]
        let absorbGroup = scan.groups[absorbIdx]
        var byPath: [String: ScanFile] = [:]
        for f in keepGroup.files { byPath[f.path] = f }
        for f in absorbGroup.files { byPath[f.path] = f }
        let combined = byPath.values.sorted { $0.path < $1.path }
        let nextRoot = Self.commonParentDir(files: combined, fallback: keepGroup.rootDir)

        var nextGroups: [MediaGroup] = []
        for g in scan.groups {
            if g.id == absorb { continue }
            if g.id == keep {
                var updated = g
                updated.rootDir = nextRoot
                updated.files = combined
                nextGroups.append(updated)
            } else {
                nextGroups.append(g)
            }
        }
        let nextScan = ScanResult(
            connection: scan.connection,
            roots: scan.roots,
            groups: nextGroups,
            unassigned: scan.unassigned
        )

        var nextDecisions = currentDecisions
        if let absorbedDecision = nextDecisions.removeValue(forKey: absorb), !absorbedDecision.overrides.isEmpty {
            var keepDecision = nextDecisions[keep] ?? GroupDecision()
            var mergedOverrides = absorbedDecision.overrides
            for (k, v) in keepDecision.overrides { mergedOverrides[k] = v }
            keepDecision.overrides = mergedOverrides
            nextDecisions[keep] = keepDecision
        }

        return try await commitReviewEdit(
            t,
            nextSummary: withCounts(t.summary, scan: nextScan),
            nextScan: nextScan,
            nextDecisions: nextDecisions,
            nextUnassignedDeletes: currentDeletes,
            emitSummaryFlag: true,
            scanMutated: true
        )
    }

    public func splitGroup(
        _ id: TaskId,
        group: GroupId,
        filePaths: Set<String>
    ) async throws -> TaskReview {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        let (scan, currentDecisions, currentDeletes) = try await loadReviewState(t)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        guard let gIdx = scan.groups.firstIndex(where: { $0.id == group }) else {
            throw TidyreelExecutionError.invalidArgument("未找到分组：\(group.value)")
        }

        let orig = scan.groups[gIdx]
        var moved: [ScanFile] = []
        var kept: [ScanFile] = []
        for f in orig.files {
            if filePaths.contains(f.path) {
                moved.append(f)
            } else {
                kept.append(f)
            }
        }
        if moved.isEmpty || kept.isEmpty {
            throw TidyreelExecutionError.invalidArgument("拆分必须选择分组中的部分文件，且至少保留 1 个文件")
        }

        let keptRoot = Self.commonParentDir(files: kept, fallback: orig.rootDir)
        let movedRoot = Self.commonParentDir(files: moved, fallback: orig.rootDir)
        let keptAnchor = anchorTitleFor(files: kept, rootDir: keptRoot, fallback: orig.anchorTitle)
        let movedAnchor = anchorTitleFor(files: moved, rootDir: movedRoot, fallback: orig.anchorTitle)

        let movedVideos = moved.filter { $0.role == .video && $0.parsed?.kind != .extra }
        let movedTvVotes = movedVideos.filter { v in
            guard let p = v.parsed else { return false }
            return p.kind == .episode || p.kind == .special || p.season != nil || !p.episodes.isEmpty || p.absolute != nil
        }.count
        let movedKind: MediaKind
        if movedVideos.isEmpty {
            movedKind = orig.kind
        } else {
            movedKind = movedTvVotes * 2 > movedVideos.count ? .episode : .movie
        }
        let movedYear = movedVideos.compactMap { $0.parsed?.year }.first

        let existingIds = Set(scan.groups.map { $0.id.value })
        let baseKey = "\(movedRoot)|\(movedKind.rawValue)|\(normTitle(movedAnchor))|split"
        var newId = "g-\(stableHash(baseKey))"
        var n = 2
        while existingIds.contains(newId) {
            newId = "g-\(stableHash("\(baseKey)|\(n)"))"
            n += 1
        }
        let newGroupId = GroupId(newId)

        var updatedOrig = orig
        updatedOrig.rootDir = keptRoot
        updatedOrig.anchorTitle = keptAnchor
        updatedOrig.files = kept

        let newGroup = MediaGroup(
            id: newGroupId,
            kind: movedKind,
            anchorTitle: movedAnchor,
            anchorYear: movedYear,
            rootDir: movedRoot,
            files: moved
        )

        var nextGroups = scan.groups
        nextGroups[gIdx] = updatedOrig
        nextGroups.insert(newGroup, at: gIdx + 1)

        let nextScan = ScanResult(
            connection: scan.connection,
            roots: scan.roots,
            groups: nextGroups,
            unassigned: scan.unassigned
        )

        var nextDecisions = currentDecisions
        if var origDecision = nextDecisions[group], !origDecision.overrides.isEmpty {
            let movedSet = Set(moved.map(\.path))
            origDecision.overrides = origDecision.overrides.filter { !movedSet.contains($0.key) }
            nextDecisions[group] = origDecision
        }
        nextDecisions[newGroupId] = GroupDecision()

        return try await commitReviewEdit(
            t,
            nextSummary: withCounts(t.summary, scan: nextScan),
            nextScan: nextScan,
            nextDecisions: nextDecisions,
            nextUnassignedDeletes: currentDeletes,
            emitSummaryFlag: true,
            scanMutated: true
        )
    }

    // MARK: - Empty Directories

    public func findEmptyDirs(_ id: TaskId) async throws -> [String] {
        let t = try await getTask(id)
        let batchOpt: BatchId?
        if let existingBatch = t.summary.batch {
            batchOpt = existingBatch
        } else {
            batchOpt = try await batchOf(id, includeUndone: false)
        }
        guard let batch = batchOpt else { return [] }
        let records = try await history.records(batch: batch)
        let doneFolders = records
            .filter { $0.status == .done && $0.op.phase == .folders && $0.op.kind == .relocate }
            .map(\.op)

        var normTaskRootsSet: Set<String> = []
        var normTaskRoots: [String] = []
        for r in t.summary.paths where !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let nr = Self.normDirPath(r)
            if normTaskRootsSet.insert(nr).inserted { normTaskRoots.append(nr) }
            let mapped = Self.applyFolderRenames(nr, folders: doneFolders)
            if normTaskRootsSet.insert(mapped).inserted { normTaskRoots.append(mapped) }
        }
        let protectedRoots = protectedRootsFor(t).union(normTaskRootsSet)
        var candidates: Set<String> = []

        func addWithAncestors(_ rawDir: String) {
            let start = Self.normDirPath(rawDir)
            if start.isEmpty || start == "/" || protectedRoots.contains(start) { return }
            var bound: String?
            for r in normTaskRoots {
                let isWithin = start == r || start.hasPrefix(r == "/" ? "/" : r + "/")
                if isWithin && (bound == nil || r.count > bound!.count) {
                    bound = r
                }
            }
            guard let bound else {
                candidates.insert(start)
                return
            }
            var d = start
            while d != "/" && d != bound && !protectedRoots.contains(d) {
                candidates.insert(d)
                d = dirOf(d)
            }
        }

        for r in records where r.status == .done {
            let op = r.op
            if op.kind == .relocate && op.src != op.dst {
                let srcParent = dirOf(op.src)
                if op.phase == .files || dirOf(op.src) != dirOf(op.dst) {
                    addWithAncestors(srcParent)
                    let mapped = Self.applyFolderRenames(srcParent, folders: doneFolders)
                    if mapped != srcParent { addWithAncestors(mapped) }
                }
            } else if op.kind == .delete && !op.src.isEmpty {
                addWithAncestors(dirOf(op.src))
            }
        }
        if candidates.isEmpty { return [] }
        let be = try backendFor(t.summary.connection)
        return try await findEmptySourceDirs(
            backend: be,
            candidateDirs: Array(candidates),
            protectedRoots: protectedRoots
        )
    }

    public func removeEmptyDirs(_ id: TaskId, dirs: [String]) async throws -> Int {
        let t = try await getTask(id)
        let be = try backendFor(t.summary.connection)
        var protectedRoots = protectedRootsFor(t)
        let resolvedBatch: BatchId?
        if let existingBatch = t.summary.batch {
            resolvedBatch = existingBatch
        } else {
            resolvedBatch = try await batchOf(id, includeUndone: false)
        }
        if let batch = resolvedBatch {
            let doneFolders = (try await history.records(batch: batch))
                .filter { $0.status == .done && $0.op.phase == .folders && $0.op.kind == .relocate }
                .map(\.op)
            for r in t.summary.paths where !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                protectedRoots.insert(Self.applyFolderRenames(Self.normDirPath(r), folders: doneFolders))
            }
        }

        let unique = Set(
            dirs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(Self.normDirPath)
        ).filter { !$0.isEmpty && $0 != "/" && !protectedRoots.contains($0) }

        var byDepth: [Int: [String]] = [:]
        for dir in unique {
            let depth = dir.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }
            byDepth[depth, default: []].append(dir)
        }
        let depthsDesc = byDepth.keys.sorted(by: >)
        let maxConcurrency = 6
        var removed = 0
        var removedParents: Set<String> = []

        for depth in depthsDesc {
            let levelDirs = (byDepth[depth] ?? []).sorted()
            if levelDirs.isEmpty { continue }

            let levelRemoved: [String]
            if levelDirs.count == 1 {
                let dir = levelDirs[0]
                let ok = try await Self.tryRemoveEmptyDir(dir, backend: be)
                levelRemoved = ok ? [dir] : []
            } else {
                levelRemoved = try await withThrowingTaskGroup(of: String?.self) { group in
                    var nextIdx = 0
                    var inFlight = 0
                    var removedDirs: [String] = []

                    while inFlight < maxConcurrency && nextIdx < levelDirs.count {
                        let dir = levelDirs[nextIdx]
                        nextIdx += 1
                        inFlight += 1
                        group.addTask {
                            let ok = try await Self.tryRemoveEmptyDir(dir, backend: be)
                            return ok ? dir : nil
                        }
                    }

                    while let result = try await group.next() {
                        inFlight -= 1
                        if let dir = result {
                            removedDirs.append(dir)
                        }
                        if nextIdx < levelDirs.count {
                            let dir = levelDirs[nextIdx]
                            nextIdx += 1
                            inFlight += 1
                            group.addTask {
                                let ok = try await Self.tryRemoveEmptyDir(dir, backend: be)
                                return ok ? dir : nil
                            }
                        }
                    }
                    return removedDirs
                }
            }

            removed += levelRemoved.count
            for dir in levelRemoved {
                removedParents.insert(dirOf(dir))
            }
        }

        if !removedParents.isEmpty, let onPathsMutated {
            await onPathsMutated(t.summary.connection, removedParents.sorted())
        }
        return removed
    }

    private static func tryRemoveEmptyDir(_ dir: String, backend be: any StorageBackend) async throws -> Bool {
        do {
            let entries = try await be.list(dir, refresh: true)
            let hasReal = entries.contains { e in
                e.isDir || !ignorableEmptyDirFiles.contains(e.name.lowercased())
            }
            if hasReal { return false }
            if !entries.isEmpty {
                try await be.remove(dir: dir, names: entries.map(\.name))
            }
            try await be.remove(dir: dirOf(dir), names: [baseOf(dir)])
            return true
        } catch is StorageError {
            return false
        }
    }

    // MARK: - Execution, Undo, Retry, Cancel, Delete

    private static func isForwardSkipped(_ r: HistoryRecord) -> Bool {
        guard r.status == .skipped, let err = r.error, !err.isEmpty else { return false }
        if undoSkipPrefixes.contains(where: { err.hasPrefix($0) }) { return false }
        return err.hasPrefix("依赖的操作失败")
    }

    public func run(_ id: TaskId, onlyConfident: Bool = false) async throws {
        let t = try await getTask(id)
        try requireStage(t, .awaitingReview)
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }
        if t.pendingEdits > 0 { throw TidyreelExecutionError.invalidState("正在更新整理计划，请稍后再试") }

        try await withBusyThrowing(t) {
            var enteredExecuting = false
            do {
                _ = try await self.loadReviewState(t)
                if t.cancelled || self.tasks[id] !== t { return }
                var plan = try await self.refreshPlanForExecution(t)
                if t.cancelled || self.tasks[id] !== t { return }
                if onlyConfident {
                    plan = self.confidentOnly(t, plan: plan)
                }
                if !plan.canExecute {
                    throw TidyreelExecutionError.invalidState("存在冲突，无法执行")
                }
                if !plan.ops.contains(where: \.selected) {
                    throw TidyreelExecutionError.invalidState("没有可执行的操作：请先勾选要整理的作品")
                }
                t.priorBatches.removeAll()
                if let latest = try await self.history.latestBatch(task: id) {
                    t.priorBatches.insert(latest.id)
                }
                if t.cancelled || self.tasks[id] !== t { return }

                try await self.setSummary(
                    t,
                    self.withSummary(
                        t.summary,
                        stage: .renamingFiles,
                        message: "正在重命名文件",
                        progress: 0
                    )
                )
                enteredExecuting = true
                if t.cancelled || self.tasks[id] !== t { return }

                let hasWrites = plan.ops.contains { $0.selected && $0.kind == .write }
                let be = try self.backendFor(t.summary.connection)
                await self.drive(
                    t,
                    stream: self.executor.execute(
                        task: id,
                        connection: t.summary.connection,
                        plan: plan,
                        backend: be
                    ),
                    batch: nil,
                    hasWrites: hasWrites
                )
            } catch {
                if !enteredExecuting { throw error }
                if t.cancelled || self.tasks[id] !== t { return }
                let b = (try? await self.batchOf(id, exclude: t.priorBatches)) ?? t.summary.batch
                t.priorBatches.removeAll()
                self.evictReviewFromMemory(t)
                await self.setSummarySafe(
                    t,
                    self.withSummary(
                        t.summary,
                        stage: b == nil ? .failed : .partiallyFailed,
                        message: "执行出错：\(Self.friendlyError(error))",
                        progress: nil,
                        batch: .set(b)
                    ),
                    force: true
                )
            }
        }
    }

    public func retryFailed(_ id: TaskId) async throws {
        let t = try await getTask(id)
        guard let batch = t.summary.batch, t.summary.stage == .partiallyFailed else {
            throw TidyreelExecutionError.invalidState("任务没有失败的操作")
        }
        if t.busy { throw TidyreelExecutionError.invalidState("任务正在处理中") }

        await withBusy(t) {
            do {
                let recs = try await self.history.records(batch: batch)
                var hasWrites = false
                var hasUndoSkipped = false
                var toReset: [(op: OpId, status: OpStatus, error: String?)] = []
                for r in recs {
                    if r.status == .failed || Self.isForwardSkipped(r) {
                        if r.op.kind == .write { hasWrites = true }
                        toReset.append((op: r.op.id, status: .pending, error: nil))
                    } else if r.status == .skipped {
                        hasUndoSkipped = true
                    }
                }
                if !toReset.isEmpty {
                    if !hasUndoSkipped {
                        try await self.history.resetFailedToPending(batch: batch)
                    } else {
                        try await self.history.markBatch(batch: batch, updates: toReset)
                    }
                }
                t.cancelled = false
                try await self.setSummary(
                    t,
                    self.withSummary(
                        t.summary,
                        stage: .renamingFiles,
                        message: "正在重试失败的操作",
                        progress: 0
                    ),
                    force: true
                )
                if t.cancelled || self.tasks[id] !== t { return }
                let be = try self.backendFor(t.summary.connection)
                await self.drive(
                    t,
                    stream: self.executor.resume(batch: batch, backend: be),
                    batch: batch,
                    hasWrites: hasWrites
                )
            } catch {
                if t.cancelled || self.tasks[id] !== t { return }
                self.evictReviewFromMemory(t)
                await self.setSummarySafe(
                    t,
                    self.withSummary(
                        t.summary,
                        stage: .partiallyFailed,
                        message: "重试失败：\(Self.friendlyError(error))",
                        progress: nil,
                        batch: .set(batch)
                    ),
                    force: true
                )
            }
        }
    }

    public func retry(_ id: TaskId) async throws {
        let t = try await getTask(id)
        if !canRetry(t.summary) {
            throw TidyreelExecutionError.invalidState("这个任务不能重试")
        }
        if t.busy || t.pendingEdits > 0 {
            throw TidyreelExecutionError.invalidState("任务正在处理中")
        }
        let gen = t.tracker.bumpPipelineGen()
        t.pipelineTask?.task.cancel()
        t.pipelineTask = nil
        t.editGen += 1
        t.cancelled = false
        evictReviewFromMemory(t)
        t.reviewDirty = false
        t.scanDirty = false
        t.summaryDirty = false
        t.priorBatches = []

        try await clearStoredReview(t)
        try await setSummary(
            t,
            withSummary(
                t.summary,
                stage: .importing,
                message: "正在导入文件",
                imported: 0,
                videos: 0,
                folders: 0,
                subtitles: 0,
                progress: nil,
                batch: .set(nil)
            ),
            force: true
        )
        t.pipelineTask = (gen: gen, task: Task { await self.pipeline(t, gen: gen, forceRefresh: true) })
    }

    public func delete(_ id: TaskId) async throws {
        let t = try await getTask(id)
        if t.pendingEdits > 0 {
            throw TidyreelExecutionError.invalidState("正在更新整理计划，请稍后再试")
        }
        if t.busy || (t.summary.stage.isActive && t.summary.stage != .awaitingReview) {
            throw TidyreelExecutionError.invalidState("任务正在进行，先取消再删除")
        }
        t.tracker.markDeleted()
        t.pipelineTask?.task.cancel()
        t.pipelineTask = nil
        t.editGen += 1
        t.priorBatches.removeAll()
        evictReviewFromMemory(t)
        let pendingPersist = t.lastPersistTask
        tasks.removeValue(forKey: id)
        broadcastSnapshot()
        await pendingPersist?.value
        try await store.delete(id: id)
        try await history.deleteTask(id)
    }

    public func cancel(_ id: TaskId) async {
        guard let t = try? await getTask(id) else { return }
        if !t.summary.stage.isActive { return }
        let wasExecuting = t.summary.stage == .renamingFiles || t.summary.stage == .renamingFolders
        t.cancelled = true
        t.tracker.bumpPipelineGen()
        t.editGen += 1
        t.pipelineTask?.task.cancel()
        t.pipelineTask = nil
        t.inFlightPlan?.task.cancel()
        t.inFlightPlan = nil
        t.inFlightReviewLoad?.task.cancel()
        t.inFlightReviewLoad = nil

        if let execTask = t.execTask {
            t.execTask = nil
            execTask.cancel()
            await execTask.value
            if let defExec = executor as? DefaultExecutor {
                await defExec.waitForSettled()
            }
        }

        if t.busy {
            await withCheckedContinuation { cont in
                t.busyWaiters.append(cont)
            }
        }
        guard tasks[id] === t else { return }

        let batch: BatchId?
        if let existingBatch = t.summary.batch {
            batch = existingBatch
        } else if wasExecuting {
            batch = try? await batchOf(id, exclude: t.priorBatches)
        } else {
            batch = nil
        }
        t.priorBatches.removeAll()

        evictReviewFromMemory(t)
        await setSummarySafe(
            t,
            withSummary(
                t.summary,
                stage: .cancelled,
                message: "已取消",
                progress: nil,
                batch: .set(batch)
            ),
            force: true
        )
    }

    public func undo(_ id: TaskId, only: Set<OpId>? = nil) async throws {
        let t = try await getTask(id)
        guard let batch = t.summary.batch,
              !t.summary.stage.isActive,
              t.summary.stage != .undone
        else {
            throw TidyreelExecutionError.invalidState("任务没有可撤销的操作")
        }
        if t.busy {
            throw TidyreelExecutionError.invalidState("任务正在撤销中")
        }

        await withBusy(t) {
            do {
                let beforeRecords = try await self.history.records(batch: batch)
                let attemptedIds = Set(
                    beforeRecords
                        .filter { $0.status == .done && (only == nil || only!.contains($0.op.id)) }
                        .map { $0.op.id }
                )
                let totalOps = attemptedIds.count
                var completed = 0
                t.lastProgressEmitAt = 0
                let be = try self.backendFor(t.summary.connection)
                for try await ev in self.executor.undo(batch: batch, backend: be, only: only) {
                    completed += 1
                    let shownTotal = totalOps > 0 ? totalOps : completed
                    let clamped = min(completed, shownTotal)
                    let prog = shownTotal == 0 ? 1.0 : Double(clamped) / Double(shownTotal)
                    let nextSummary = self.withSummary(
                        t.summary,
                        message: "正在撤销（\(clamped)/\(shownTotal)）",
                        progress: prog
                    )
                    let now = ProcessInfo.processInfo.systemUptime
                    let isFinal = clamped >= shownTotal
                    let hasError = ev.error != nil
                    if hasError || isFinal || (now - t.lastProgressEmitAt) >= 0.1 {
                        t.lastProgressEmitAt = now
                        _ = self.emitSummary(t, nextSummary, force: true)
                    } else if self.tasks[id] === t {
                        t.summary = nextSummary
                    }
                }

                let afterRecords = try await self.history.records(batch: batch)
                let remaining = afterRecords.contains { $0.status == .done }
                let failedCount = afterRecords.filter { attemptedIds.contains($0.op.id) && $0.status == .done }.count
                let skippedCount = afterRecords.filter { attemptedIds.contains($0.op.id) && $0.status == .skipped }.count
                if let onPathsMutated = self.onPathsMutated {
                    let undoneRecords = afterRecords.filter { attemptedIds.contains($0.op.id) && $0.status == .undone }
                    let mutatedDirs = Self.mutatedParentDirs(from: undoneRecords, statuses: [.undone])
                    if !mutatedDirs.isEmpty {
                        await onPathsMutated(t.summary.connection, mutatedDirs)
                    }
                }
                var details: [String] = []
                if failedCount > 0 { details.append("\(failedCount) 项失败") }
                if skippedCount > 0 { details.append("\(skippedCount) 项已跳过") }
                let note = details.isEmpty ? "" : "，\(details.joined(separator: "，"))"

                self.evictReviewFromMemory(t)
                try await self.setSummary(
                    t,
                    remaining
                        ? self.withSummary(t.summary, message: "已撤销部分操作\(note)", progress: nil)
                        : self.withSummary(t.summary, stage: .undone, message: "已撤销\(note)", progress: nil),
                    force: true
                )
            } catch {
                guard self.tasks[id] === t else { return }
                self.evictReviewFromMemory(t)
                await self.setSummarySafe(
                    t,
                    self.withSummary(
                        t.summary,
                        message: "撤销失败：\(Self.friendlyError(error))",
                        progress: nil
                    ),
                    force: true
                )
            }
        }
    }

    // MARK: - Background Pipeline

    private func pipeline(_ t: TaskEntry, gen: Int, forceRefresh: Bool = false) async {
        defer {
            if t.pipelineTask?.gen == gen {
                t.pipelineTask = nil
            }
        }
        func isStale() -> Bool {
            t.tracker.isStale(gen: gen) || tasks[t.summary.id] !== t
        }

        var step = "导入"
        do {
            if isStale() { return }
            let s = t.summary
            let be = try backendFor(s.connection)
            try await setSummary(
                t,
                withSummary(s, stage: .importing, message: "正在导入文件", imported: 0)
            )
            let files = try await listAll(t, backend: be, gen: gen, refresh: forceRefresh)
            if isStale() { return }

            step = "识别"
            try await setSummary(
                t,
                withSummary(
                    t.summary,
                    stage: .recognizing,
                    message: "正在识别（共 \(files.count) 个文件）",
                    imported: files.count
                )
            )
            if isStale() { return }

            let scan = try await recognizer.recognize(
                connection: s.connection,
                roots: s.paths,
                files: files,
                read: { try await be.read($0) },
                backend: be
            )
            if isStale() { return }

            _ = emitSummary(
                t,
                withSummary(t.summary, message: "锚点识别完成，正在进行后续处理", imported: files.count)
            )

            step = "生成计划"
            var decisions: [GroupId: GroupDecision] = [:]
            for g in scan.groups {
                decisions[g.id] = GroupDecision(selected: g.match != nil)
            }
            let built = try await buildPlanWithOptions(
                summary: t.summary,
                scan: scan,
                decisions: decisions,
                unassignedDeletes: t.unassignedDeletes,
                refreshRemote: false
            )
            if isStale() { return }

            t.scan = scan
            t.decisions = decisions
            t.plan = built.plan
            t.planOptions = built.options
            t.planExisting = built.existing
            t.cachedExisting = built.existing
            t.cachedExistingDirs = built.existingDirs
            t.cachedListedDirs = built.listedDirs

            let allFiles = scan.groups.flatMap(\.files) + scan.unassigned
            try await saveReview(t, scan: scan, decisions: decisions, unassignedDeletes: t.unassignedDeletes)
            if isStale() { return }

            evictOtherCachedReviews(keeping: t.summary.id)

            try await setSummary(
                t,
                withSummary(
                    t.summary,
                    stage: .awaitingReview,
                    message: "识别完成，请确认结果后继续执行",
                    imported: files.count,
                    videos: allFiles.filter { $0.role == .video }.count,
                    folders: Set(allFiles.map { dirOf($0.path) }).count,
                    subtitles: allFiles.filter { $0.role == .subtitle }.count
                )
            )
        } catch {
            if isStale() { return }
            evictReviewFromMemory(t)
            await setSummarySafe(
                t,
                withSummary(
                    t.summary,
                    stage: .failed,
                    message: "\(step)失败：\(Self.friendlyError(error))"
                ),
                force: true
            )
        }
    }

    private func emitImportTick(id: TaskId, oid: ObjectIdentifier, count: Int, gen: Int) {
        guard let t = tasks[id], ObjectIdentifier(t) == oid, !t.tracker.isStale(gen: gen) else { return }
        _ = emitSummary(
            t,
            withSummary(
                t.summary,
                message: "正在导入文件（已导入 \(count) 个）",
                imported: count
            )
        )
    }

    private func listAll(
        _ t: TaskEntry,
        backend be: any StorageBackend,
        gen: Int,
        refresh: Bool = false
    ) async throws -> [RemoteEntry] {
        let taskId = t.summary.id
        let oid = ObjectIdentifier(t)
        let tracker = t.tracker
        let collector = ImportCollector(minIntervalMs: importUpdateIntervalMs)
        let localParser = parser

        @Sendable func addEntry(_ e: RemoteEntry) async {
            if tracker.isStale(gen: gen) { return }
            if let dueCount = collector.add(e) {
                await self.emitImportTick(id: taskId, oid: oid, count: dueCount, gen: gen)
            }
        }

        var dirs: [String] = []
        var parentCache: [String: [RemoteEntry]] = [:]
        var foundAny = false

        for root in t.summary.paths {
            if tracker.isStale(gen: gen) { break }
            if root == "/" {
                foundAny = true
                dirs.append(root)
                continue
            }
            let parent = dirOf(root)
            let siblings: [RemoteEntry]
            if let cached = parentCache[parent] {
                siblings = cached
            } else {
                let listed = try await be.list(parent, refresh: refresh)
                parentCache[parent] = listed
                siblings = listed
            }
            if tracker.isStale(gen: gen) { break }
            guard let entry = siblings.first(where: { $0.path == root }) else { continue }
            foundAny = true
            if entry.isDir {
                dirs.append(root)
            } else {
                await addEntry(entry)
            }
        }

        if tracker.isStale(gen: gen) { return collector.sortedSnapshot() }
        if !t.summary.paths.isEmpty && !foundAny {
            throw StorageError(.notFound, "所选路径不存在：\(t.summary.paths.joined(separator: "、"))")
        }

        if !tracker.isStale(gen: gen) && !dirs.isEmpty {
            try await walkDirs(
                roots: dirs,
                parallel: 6,
                stop: { tracker.isStale(gen: gen) },
                visit: { dir in
                    let children = try await be.list(dir, refresh: refresh)
                    if tracker.isStale(gen: gen) { return [] }

                    let discMarkers = children.filter { e in
                        e.isDir && (e.name.uppercased() == "BDMV" || e.name.uppercased() == "VIDEO_TS")
                    }
                    if !discMarkers.isEmpty {
                        let hasSiblingMedia = children.contains { e in
                            if e.isDir {
                                return !discMetaDirs.contains(e.name.uppercased())
                            }
                            return !e.name.lowercased().hasSuffix(".nfo") &&
                                !e.name.hasPrefix(".") &&
                                localParser.classify(e.name) == .video
                        }
                        if dir != "/" && !hasSiblingMedia {
                            await addEntry(RemoteEntry(path: dir, name: baseOf(dir), isDir: true))
                            for m in discMarkers {
                                await addEntry(m)
                            }
                            for e in children {
                                if tracker.isStale(gen: gen) { break }
                                if !e.isDir && e.name.lowercased().hasSuffix(".nfo") {
                                    await addEntry(e)
                                }
                            }
                            return []
                        }
                        var subs: [String] = []
                        for e in children {
                            if tracker.isStale(gen: gen) { break }
                            if e.isDir {
                                let upper = e.name.uppercased()
                                if upper == "BDMV" || upper == "VIDEO_TS" { continue }
                                subs.append(e.path)
                            } else {
                                await addEntry(e)
                            }
                        }
                        return subs
                    }

                    var subs: [String] = []
                    for e in children {
                        if tracker.isStale(gen: gen) { break }
                        if e.isDir {
                            subs.append(e.path)
                        } else {
                            await addEntry(e)
                        }
                    }
                    return subs
                }
            )
        }

        let sorted = collector.sortedSnapshot()
        if !tracker.isStale(gen: gen) && tasks[t.summary.id] === t {
            _ = emitSummary(
                t,
                withSummary(
                    t.summary,
                    message: "正在导入文件（已导入 \(sorted.count) 个）",
                    imported: sorted.count
                )
            )
        }
        return sorted
    }

    // MARK: - Planning & Confident-Only Filter

    private func effectiveOptions(
        _ s: TaskSummary,
        taskUnassignedDeletes: [String: Bool] = [:]
    ) -> PlanOptions {
        var o = options(s.connection, s.mode)
        if !taskUnassignedDeletes.isEmpty {
            for (k, v) in taskUnassignedDeletes {
                o.unassignedDeletes[k] = v
            }
        }
        o.scrape = o.scrape || s.scrape || s.scrapeOnly
        o.scrapeOnly = o.scrapeOnly || s.scrapeOnly
        return o
    }

    private func buildPlanWithOptions(
        summary s: TaskSummary,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool] = [:],
        initialExisting: Set<String> = [],
        initialExistingDirs: Set<String> = [],
        initialListedDirs: Set<String> = [],
        refreshRemote: Bool = false
    ) async throws -> (
        plan: RenamePlan,
        options: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>,
        listedDirs: Set<String>
    ) {
        let opts = effectiveOptions(s, taskUnassignedDeletes: unassignedDeletes)
        let be = try backendFor(s.connection)

        var existing = initialExisting
        var existingDirs = initialExistingDirs
        var listed = initialListedDirs
        var plan = try await planner.build(
            scan: scan,
            decisions: decisions,
            options: opts,
            existing: existing,
            existingDirs: listed.isEmpty ? nil : existingDirs
        )

        for _ in 0..<3 {
            let dirs = Set(
                plan.ops.filter { $0.selected && $0.kind != .delete }.map { dirOf($0.dst) }
            ).subtracting(listed)
            if dirs.isEmpty { break }
            listed.formUnion(dirs)

            let beforeExisting = existing.count
            let beforeDirs = existingDirs.count
            let collector = ExistingPathsCollector(existing: existing, existingDirs: existingDirs)

            try await walkDirs(roots: Array(dirs), parallel: 6) { dir in
                do {
                    let entries = try await be.list(dir, refresh: refreshRemote)
                    collector.record(dir: dir, entries: entries)
                } catch let e as StorageError where e.code == .notFound {
                    // non-existent target dir is normal
                }
                return []
            }

            let snap = collector.snapshot()
            existing = snap.existing
            existingDirs = snap.existingDirs
            if existing.count == beforeExisting && existingDirs.count == beforeDirs {
                break
            }
            plan = try await planner.build(
                scan: scan,
                decisions: decisions,
                options: opts,
                existing: existing,
                existingDirs: existingDirs
            )
        }
        return (plan, opts, existing, existingDirs, listed)
    }

    private func ensurePlan(_ t: TaskEntry) async throws -> RenamePlan {
        let (scan, decisions, unassignedDeletes) = try await loadReviewState(t)
        let opts = effectiveOptions(t.summary, taskUnassignedDeletes: unassignedDeletes)
        if let cached = t.plan, t.planOptions == opts {
            return cached
        }
        let gen = t.editGen
        if let pending = t.inFlightPlan, pending.editGen == gen, pending.options == opts {
            return try await pending.task.value
        }

        let summary = t.summary
        let initialExisting = t.cachedExisting
        let initialExistingDirs = t.cachedExistingDirs
        let initialListedDirs = t.cachedListedDirs
        let token = UUID()
        let task = Task<RenamePlan, any Error> {
            let built = try await self.buildPlanWithOptions(
                summary: summary,
                scan: scan,
                decisions: decisions,
                unassignedDeletes: unassignedDeletes,
                initialExisting: initialExisting,
                initialExistingDirs: initialExistingDirs,
                initialListedDirs: initialListedDirs,
                refreshRemote: false
            )
            self.storeBuiltPlanIfCurrent(
                t,
                token: token,
                gen: gen,
                mode: summary.mode,
                plan: built.plan,
                builtOpts: built.options,
                existing: built.existing,
                existingDirs: built.existingDirs,
                listedDirs: built.listedDirs
            )
            return built.plan
        }
        t.inFlightPlan = (token: token, editGen: gen, options: opts, task: task)
        do {
            let result = try await task.value
            if t.inFlightPlan?.token == token { t.inFlightPlan = nil }
            return result
        } catch {
            if t.inFlightPlan?.token == token { t.inFlightPlan = nil }
            throw error
        }
    }

    private func refreshPlanForExecution(_ t: TaskEntry) async throws -> RenamePlan {
        let (scan, decisions, unassignedDeletes) = try await loadReviewState(t)
        let summary = t.summary
        let gen = t.editGen
        let built = try await buildPlanWithOptions(
            summary: summary,
            scan: scan,
            decisions: decisions,
            unassignedDeletes: unassignedDeletes,
            refreshRemote: true
        )
        if t.editGen == gen && t.summary.mode == summary.mode && tasks[summary.id] === t {
            t.plan = built.plan
            t.planOptions = built.options
            t.planExisting = built.existing
            t.cachedExisting = built.existing
            t.cachedExistingDirs = built.existingDirs
            t.cachedListedDirs = built.listedDirs
            t.inFlightPlan = nil
        }
        return built.plan
    }

    private func storeBuiltPlanIfCurrent(
        _ t: TaskEntry,
        token: UUID,
        gen: Int,
        mode: OrganizeMode,
        plan: RenamePlan,
        builtOpts: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>,
        listedDirs: Set<String>
    ) {
        if t.editGen == gen && t.summary.mode == mode && tasks[t.summary.id] === t {
            t.plan = plan
            t.planOptions = builtOpts
            t.planExisting = existing
            t.cachedExisting = existing
            t.cachedExistingDirs = existingDirs
            t.cachedListedDirs = listedDirs
        }
        if t.inFlightPlan?.token == token {
            t.inFlightPlan = nil
        }
    }

    private func confidentOnly(_ t: TaskEntry, plan: RenamePlan) -> RenamePlan {
        guard let scan = t.scan else { return plan }
        let threshold = effectiveOptions(t.summary).confidenceThreshold

        var groups: [GroupId: MediaGroup] = Dictionary(minimumCapacity: scan.groups.count)
        var filesByGroupAndPath: [GroupId: [String: ScanFile]] = Dictionary(minimumCapacity: scan.groups.count)
        for g in scan.groups {
            groups[g.id] = g
            var byPath: [String: ScanFile] = Dictionary(minimumCapacity: g.files.count)
            for f in g.files {
                if byPath[f.path] == nil {
                    byPath[f.path] = f
                }
            }
            filesByGroupAndPath[g.id] = byPath
        }

        func allowedWarning(_ warning: String?, confirmed: Bool) -> Bool {
            guard let warning else { return true }
            for w in warning.components(separatedBy: "；") {
                if w == "超出 TMDB 总集数" { continue }
                if confirmed && (w == "识别置信度较低" || w == "片名匹配置信度较低") {
                    continue
                }
                return false
            }
            return true
        }

        func addStrictAncestors(of path: String, to set: inout Set<String>) {
            guard !path.isEmpty else { return }
            var cur = dirOf(path)
            while cur != "/" {
                if !set.insert(cur).inserted { break }
                let next = dirOf(cur)
                if next == cur { break }
                cur = next
            }
        }

        func hasStrictAncestor(of path: String, in set: Set<String>) -> Bool {
            guard !set.isEmpty, !path.isEmpty else { return false }
            var cur = dirOf(path)
            while cur != "/" {
                if set.contains(cur) { return true }
                let next = dirOf(cur)
                if next == cur { break }
                cur = next
            }
            return false
        }

        var keptVideoSrcs: Set<String> = []
        var keptFileOps: [RenameOp] = []
        var keptGroups: Set<GroupId> = []
        var keptIds: Set<OpId> = []

        // Pass 1: video relocates (including BDMV/VIDEO_TS disc folder relocates)
        for o in plan.ops {
            guard o.kind == .relocate, o.selected else { continue }
            guard o.phase == .files || o.phase == .folders else { continue }
            guard let gid = o.group, let g = groups[gid],
                  let f = filesByGroupAndPath[gid]?[o.src],
                  f.role == .video
            else { continue }
            if o.phase == .folders && !f.isDiscDir { continue }

            let d = t.decisions[g.id] ?? GroupDecision()
            let ov = d.overrides[o.src]
            let confirmed = ov != nil && !(ov!.ignore)
            let groupOk = d.match != nil || g.matchScore >= threshold || confirmed
            if groupOk && allowedWarning(o.warning, confirmed: confirmed) {
                keptIds.insert(o.id)
                keptFileOps.append(o)
                keptVideoSrcs.insert(o.src)
                keptGroups.insert(g.id)
            }
        }

        let isScrapeOnlyPlan = t.summary.scrapeOnly ||
            !plan.ops.contains { $0.selected && $0.kind == .relocate }
        if isScrapeOnlyPlan {
            for g in scan.groups {
                let d = t.decisions[g.id] ?? GroupDecision()
                if !d.selected || (d.match ?? g.match) == nil { continue }
                if d.match != nil || g.matchScore >= threshold {
                    keptGroups.insert(g.id)
                }
            }
        }

        var plannedSrcsByGroup: [GroupId: Set<String>] = [:]
        for o in plan.ops {
            if (o.phase == .files || o.phase == .folders), o.kind == .relocate, let gid = o.group {
                plannedSrcsByGroup[gid, default: []].insert(o.src)
            }
        }

        var allVideosByGroup: [GroupId: [ScanFile]] = [:]
        var plannedVideosByGroup: [GroupId: [ScanFile]] = [:]
        var allIndexByGroup: [GroupId: VideoMatchIndex] = [:]
        var plannedIndexByGroup: [GroupId: VideoMatchIndex] = [:]

        func allVideos(for gid: GroupId) -> [ScanFile] {
            if let cached = allVideosByGroup[gid] { return cached }
            let vids = (groups[gid]?.files ?? []).filter { $0.role == .video }
            allVideosByGroup[gid] = vids
            return vids
        }

        func plannedVideos(for gid: GroupId) -> [ScanFile] {
            if let cached = plannedVideosByGroup[gid] { return cached }
            let plannedSrcs = plannedSrcsByGroup[gid] ?? []
            let vids = allVideos(for: gid).filter { plannedSrcs.contains($0.path) }
            plannedVideosByGroup[gid] = vids
            return vids
        }

        func plannedIndex(for gid: GroupId) -> VideoMatchIndex {
            if let cached = plannedIndexByGroup[gid] { return cached }
            let idx = VideoMatchIndex(plannedVideos(for: gid))
            plannedIndexByGroup[gid] = idx
            return idx
        }

        func allIndex(for gid: GroupId) -> VideoMatchIndex {
            if let cached = allIndexByGroup[gid] { return cached }
            let idx = VideoMatchIndex(allVideos(for: gid))
            allIndexByGroup[gid] = idx
            return idx
        }

        // Pass 2: subtitles / sidecars and any non-video file relocates
        for o in plan.ops {
            guard o.phase == .files, o.kind == .relocate, o.selected else { continue }
            let g = o.group.flatMap { groups[$0] }
            let f = o.group.flatMap { filesByGroupAndPath[$0]?[o.src] }
            if g != nil && f?.role == .video { continue }
            guard let g else {
                if allowedWarning(o.warning, confirmed: false) {
                    keptIds.insert(o.id)
                    keptFileOps.append(o)
                }
                continue
            }

            let d = t.decisions[g.id] ?? GroupDecision()
            let ov = d.overrides[o.src]
            let confirmed = ov != nil && !(ov!.ignore)
            let hasExplicit = confirmed && (
                ov?.season != nil ||
                ov?.episode != nil ||
                ov?.kind == .extra ||
                ov?.kind == .special
            )

            let keep: Bool
            if hasExplicit {
                keep = allowedWarning(o.warning, confirmed: true)
            } else {
                var mItem: FollowMatch?
                var mAll: FollowMatch?
                if let f {
                    mItem = plannedIndex(for: g.id).match(f)
                    if mItem == nil, f.role == .subtitle {
                        let plannedVids = plannedVideos(for: g.id)
                        if plannedVids.count == 1, !followConflicts(f, plannedVids[0]) {
                            mItem = FollowMatch(
                                video: plannedVids[0],
                                remainder: extractSubRemainder(stem(f.name), stem(plannedVids[0].name))
                            )
                        }
                    }
                    mAll = mItem ?? allIndex(for: g.id).match(f)
                    if mAll == nil, f.role == .subtitle {
                        let allVids = allVideos(for: g.id)
                        if allVids.count == 1, !followConflicts(f, allVids[0]) {
                            mAll = FollowMatch(
                                video: allVids[0],
                                remainder: extractSubRemainder(stem(f.name), stem(allVids[0].name))
                            )
                        }
                    }
                }

                if let mItem {
                    keep = keptVideoSrcs.contains(mItem.video.path) && allowedWarning(o.warning, confirmed: confirmed)
                } else if let mAll {
                    let videoIgnored = d.overrides[mAll.video.path]?.ignore ?? false
                    keep = videoIgnored
                        ? (confirmed && allowedWarning(o.warning, confirmed: true))
                        : (keptVideoSrcs.contains(mAll.video.path) && allowedWarning(o.warning, confirmed: confirmed))
                } else {
                    let groupOk = d.match != nil || g.matchScore >= threshold || confirmed
                    keep = groupOk && allowedWarning(o.warning, confirmed: confirmed)
                }
            }
            if keep {
                keptIds.insert(o.id)
                keptFileOps.append(o)
                keptGroups.insert(g.id)
            }
        }

        // Pass 3: folder relocates needed by ANY kept file op (O(1) ancestor lookup)
        var keptFileDstAncestors: Set<String> = []
        var keptFileSrcAncestors: Set<String> = []
        for f in keptFileOps {
            addStrictAncestors(of: f.dst, to: &keptFileDstAncestors)
            addStrictAncestors(of: f.src, to: &keptFileSrcAncestors)
        }

        let allFolderOps = plan.ops.filter { $0.phase == .folders && $0.kind == .relocate && $0.selected }
        var keptFolderOps: [RenameOp] = []
        for o in allFolderOps {
            if let gid = o.group, let f = filesByGroupAndPath[gid]?[o.src], f.isDiscDir {
                if keptIds.contains(o.id) { keptFolderOps.append(o) }
                continue
            }
            let isSeasonRename = o.id.value.hasPrefix("s-")
            let usedByAnyFile = keptFileDstAncestors.contains(o.src) ||
                keptFileDstAncestors.contains(o.dst) ||
                (isSeasonRename && keptFileSrcAncestors.contains(o.src))
            let used: Bool
            if isSeasonRename {
                used = usedByAnyFile
            } else if usedByAnyFile {
                used = true
            } else if let gid = o.group {
                used = keptGroups.contains(gid)
            } else {
                used = !keptFileOps.isEmpty
            }
            if used {
                keptIds.insert(o.id)
                keptFolderOps.append(o)
            }
        }

        func postFolder(_ path: String) -> String {
            Self.applyFolderRenames(path, folders: keptFolderOps)
        }

        var keptVideoFinalTargets: Set<String> = []
        for o in keptFileOps where keptVideoSrcs.contains(o.src) {
            keptVideoFinalTargets.insert("\(dirOf(postFolder(o.dst)))/\(stem(baseOf(o.dst)))")
        }
        if isScrapeOnlyPlan {
            for g in scan.groups where keptGroups.contains(g.id) {
                for f in g.files where f.role == .video {
                    let key = f.isDiscDir ? "\(f.path)/movie" : "\(dirOf(f.path))/\(stem(f.name))"
                    keptVideoFinalTargets.insert(key)
                }
            }
        }
        let keptMergeDirs = Set(plan.merges.filter { keptGroups.contains($0.group) }.map(\.into))

        // Pass 4: scrape writes tied to kept videos / groups
        var keptWriteOps: [RenameOp] = []
        for o in plan.ops where o.kind == .write && o.selected {
            if !allowedWarning(o.warning, confirmed: false) { continue }
            let name = baseOf(o.dst)
            let lowerName = name.lowercased()
            let isShowArt = lowerName == "tvshow.nfo" ||
                lowerName == "movie.nfo" ||
                lowerName == "poster.jpg" ||
                lowerName == "fanart.jpg" ||
                lowerName == "clearlogo.png" ||
                lowerName == "landscape.jpg"
            let rLower = NSRange(lowerName.startIndex..<lowerName.endIndex, in: lowerName)
            let isGroupArt = isShowArt || seasonArtRegex.firstMatch(in: lowerName, range: rLower) != nil
            let belongsToKept = o.group == nil ||
                keptGroups.contains(o.group!) ||
                (isShowArt && keptMergeDirs.contains(dirOf(o.dst)))
            if !belongsToKept { continue }
            if !isGroupArt {
                let targetStem: String
                if lowerName.hasSuffix("-thumb.jpg") {
                    targetStem = String(name.dropLast("-thumb.jpg".count))
                } else {
                    targetStem = stem(name)
                }
                let key = "\(dirOf(o.dst))/\(targetStem)"
                if !keptVideoFinalTargets.contains(key) { continue }
            }
            keptIds.insert(o.id)
            keptWriteOps.append(o)
        }

        // Pass 5: mkdir ops that actually receive at least one kept op (O(1) ancestor lookup)
        var allTargetAncestors: Set<String> = []
        func addTargetAndAncestors(_ dst: String) {
            guard !dst.isEmpty else { return }
            if dst.hasPrefix("/") {
                allTargetAncestors.insert("/")
            }
            var cur = dst
            while true {
                if !allTargetAncestors.insert(cur).inserted { break }
                if cur == "/" { break }
                let next = dirOf(cur)
                if next == cur { break }
                cur = next
            }
        }
        for x in keptFileOps { addTargetAndAncestors(x.dst) }
        for x in keptFolderOps { addTargetAndAncestors(x.dst) }
        for x in keptWriteOps { addTargetAndAncestors(x.dst) }

        for o in plan.ops where o.kind == .mkdir && o.selected {
            if allTargetAncestors.contains(o.dst) {
                keptIds.insert(o.id)
            }
        }

        // Pass 6: delete ops (O(G * F + D * depth) via precomputed dropped/kept root sets)
        let droppedFolderDsts = Set(
            allFolderOps.lazy.filter { !keptIds.contains($0.id) }.map(\.dst)
        )
        var droppedRoots: Set<String> = []
        var keptRoots: Set<String> = []
        for g in scan.groups {
            if keptGroups.contains(g.id) {
                keptRoots.insert(g.rootDir)
                keptRoots.insert(postFolder(g.rootDir))
            } else {
                droppedRoots.insert(g.rootDir)
                droppedRoots.insert(Self.applyFolderRenames(g.rootDir, folders: allFolderOps))
            }
        }
        for o in plan.ops where o.kind == .delete && o.selected {
            if hasStrictAncestor(of: o.src, in: droppedFolderDsts) { continue }
            let insideDropped = hasStrictAncestor(of: o.src, in: droppedRoots)
            if !insideDropped || hasStrictAncestor(of: o.src, in: keptRoots) {
                keptIds.insert(o.id)
            }
        }

        let ops = plan.ops.map { o -> RenameOp in
            if keptIds.contains(o.id) { return o }
            var deselected = o
            deselected.selected = false
            return deselected
        }
        let globalConflicts = plan.conflicts.filter { $0.ops.isEmpty }
        return RenamePlan(
            ops: ops,
            conflicts: globalConflicts + detectPlanConflicts(ops: ops, existing: t.planExisting),
            merges: plan.merges
        )
    }

    // MARK: - Stream Execution Driver

    private func drive(
        _ t: TaskEntry,
        stream: AsyncThrowingStream<ExecProgress, any Error>,
        batch: BatchId?,
        hasWrites: Bool = false
    ) async {
        t.execFailure = nil
        t.lastProgressEmitAt = 0
        var stage = t.summary.stage
        let streamTask = Task<Void, Never> {
            do {
                for try await e in stream {
                    let changedStage = self.handleExecProgress(
                        t,
                        progress: e,
                        currentStage: stage,
                        hasWrites: hasWrites
                    )
                    stage = changedStage
                }
            } catch is CancellationError {
                // Handled by cancel()
            } catch {
                self.recordExecFailure(t, error: error)
            }
        }
        t.execTask = streamTask
        await streamTask.value
        if let defExec = executor as? DefaultExecutor {
            await defExec.waitForSettled()
        }
        t.execTask = nil

        if t.cancelled || tasks[t.summary.id] !== t {
            t.priorBatches.removeAll()
            return
        }
        let b: BatchId?
        if let batch {
            b = batch
        } else {
            b = try? await batchOf(t.summary.id, exclude: t.priorBatches)
        }
        t.priorBatches.removeAll()

        let batchRecords: [HistoryRecord]
        if let b {
            batchRecords = (try? await history.records(batch: b)) ?? []
        } else {
            batchRecords = []
        }
        let failedCount = batchRecords.filter { $0.status == .failed }.count
        if t.cancelled || tasks[t.summary.id] !== t { return }

        if let onPathsMutated {
            let mutatedDirs = Self.mutatedParentDirs(from: batchRecords, statuses: [.done])
            if !mutatedDirs.isEmpty {
                await onPathsMutated(t.summary.connection, mutatedDirs)
            }
        }
        if t.cancelled || tasks[t.summary.id] !== t { return }

        let failure = t.execFailure
        t.execFailure = nil
        evictReviewFromMemory(t)

        if let failure {
            await setSummarySafe(
                t,
                withSummary(
                    t.summary,
                    stage: b == nil ? .failed : .partiallyFailed,
                    message: "执行出错：\(Self.friendlyError(failure))",
                    progress: nil,
                    batch: .set(b)
                )
            )
        } else if failedCount > 0 {
            await setSummarySafe(
                t,
                withSummary(
                    t.summary,
                    stage: .partiallyFailed,
                    message: "部分操作失败（\(failedCount) 项），其余已完成",
                    progress: nil,
                    batch: .set(b)
                )
            )
        } else {
            await setSummarySafe(
                t,
                withSummary(
                    t.summary,
                    stage: .done,
                    message: "整理完成",
                    progress: nil,
                    batch: .set(b)
                )
            )
        }
    }

    private func handleExecProgress(
        _ t: TaskEntry,
        progress e: ExecProgress,
        currentStage: TaskStage,
        hasWrites: Bool
    ) -> TaskStage {
        let nextStage: TaskStage = e.phase == .files ? .renamingFiles : .renamingFolders
        let label: String
        switch e.phase {
        case .files: label = "正在重命名文件"
        case .folders: label = "正在整理文件夹"
        case .cleanup: label = hasWrites ? "正在刮削（写入元数据和海报）" : "正在清理"
        }
        let prog = e.total == 0 ? 1.0 : Double(e.done) / Double(e.total)
        let nextSummary = withSummary(
            t.summary,
            stage: nextStage,
            message: "\(label)（\(e.done)/\(e.total)）",
            progress: prog
        )
        let stageChanged = nextStage != currentStage
        let isPhaseEnd = e.total == 0 || e.done >= e.total
        let hasError = e.error != nil
        let now = ProcessInfo.processInfo.systemUptime
        if stageChanged || hasError || isPhaseEnd || (now - t.lastProgressEmitAt) >= 0.1 {
            t.lastProgressEmitAt = now
            _ = emitSummary(t, nextSummary)
        } else if !t.cancelled && tasks[t.summary.id] === t {
            t.summary = nextSummary
        }
        if stageChanged {
            persistSummaryDetached(t)
        }
        return nextStage
    }

    private func recordExecFailure(_ t: TaskEntry, error: any Error) {
        t.execFailure = error
    }

    // MARK: - Plumbing & Persistence

    private func batchOf(
        _ id: TaskId,
        exclude: Set<BatchId> = [],
        includeUndone: Bool = true
    ) async throws -> BatchId? {
        if let current = tasks[id]?.summary.batch, !exclude.contains(current) {
            return current
        }
        guard let latest = try await history.latestBatch(task: id) else {
            return nil
        }
        if !exclude.contains(latest.id) && (includeUndone || !latest.undone) {
            return latest.id
        }
        if exclude.contains(latest.id) && includeUndone {
            return nil
        }
        let all = try await history.batches()
        return all.first {
            $0.task == id && !exclude.contains($0.id) && (includeUndone || !$0.undone)
        }?.id
    }

    private func withBusy(_ t: TaskEntry, _ fn: () async -> Void) async {
        t.busy = true
        defer {
            t.busy = false
            let waiters = t.busyWaiters
            t.busyWaiters.removeAll()
            for w in waiters { w.resume() }
        }
        await fn()
    }

    private func withBusyThrowing(_ t: TaskEntry, _ fn: () async throws -> Void) async throws {
        t.busy = true
        defer {
            t.busy = false
            let waiters = t.busyWaiters
            t.busyWaiters.removeAll()
            for w in waiters { w.resume() }
        }
        try await fn()
    }

    private func getTask(_ id: TaskId) async throws -> TaskEntry {
        try await ensureLoaded()
        guard let t = tasks[id] else {
            throw TidyreelExecutionError.invalidArgument("未找到任务：\(id.value)")
        }
        return t
    }

    private static func stageLabel(_ stage: TaskStage) -> String {
        switch stage {
        case .importing: return "导入中"
        case .recognizing: return "识别中"
        case .awaitingReview: return "待确认"
        case .renamingFiles: return "重命名文件中"
        case .renamingFolders: return "整理文件夹中"
        case .done: return "已完成"
        case .partiallyFailed: return "部分失败"
        case .cancelled: return "已取消"
        case .undone: return "已撤销"
        case .failed: return "已失败"
        }
    }

    private static func friendlyError(_ error: any Error) -> String {
        if let se = error as? StorageError {
            if !se.message.isEmpty { return se.message }
            switch se.code {
            case .notFound: return "文件或目录不存在"
            case .alreadyExists: return "目标位置已存在同名文件或目录"
            case .unauthorized: return "认证失败，请检查账号或密码"
            case .rateLimited: return "请求过于频繁，请稍后重试"
            case .network: return "网络连接失败"
            case .busy: return "文件或目录正被占用"
            case .other: return "存储访问出错"
            }
        }
        if let te = error as? TidyreelExecutionError {
            return te.message
        }
        if let tmdb = error as? TmdbError, !tmdb.message.isEmpty {
            return tmdb.message
        }
        if let le = error as? any LocalizedError, let desc = le.errorDescription, !desc.isEmpty {
            return desc
        }
        let s = String(describing: error)
        for prefix in ["Exception: ", "Bad state: ", "FormatException: "] {
            if s.hasPrefix(prefix) {
                return String(s.dropFirst(prefix.count))
            }
        }
        return s
    }

    private func requireStage(_ t: TaskEntry, _ stage: TaskStage) throws {
        if t.summary.stage != stage {
            throw TidyreelExecutionError.invalidState("任务当前状态不允许此操作（\(Self.stageLabel(t.summary.stage))）")
        }
    }

    private func snapshot() -> [TaskSummary] {
        tasks.values
            .sorted { a, b in
                if a.summary.createdAt != b.summary.createdAt {
                    return a.summary.createdAt > b.summary.createdAt
                }
                return a.orderIndex > b.orderIndex
            }
            .map(\.summary)
    }

    private func broadcastSnapshot() {
        guard !isDisposed, !watchers.isEmpty else { return }
        let snap = snapshot()
        for c in watchers.values {
            c.yield(snap)
        }
    }

    private func emitSummary(_ t: TaskEntry, _ s: TaskSummary, force: Bool = false) -> Bool {
        if (t.cancelled && !force) || tasks[t.summary.id] !== t { return false }
        t.summary = s
        broadcastSnapshot()
        return true
    }

    private func setSummary(_ t: TaskEntry, _ s: TaskSummary, force: Bool = false) async throws {
        guard emitSummary(t, s, force: force) else { return }
        try await persistSummary(t)
    }

    private func setSummarySafe(_ t: TaskEntry, _ s: TaskSummary, force: Bool = false) async {
        do {
            try await setSummary(t, s, force: force)
        } catch {
            // In-memory state was already updated by emitSummary.
        }
    }

    private func isStillCurrentTask(_ id: TaskId, _ entry: ObjectIdentifier) -> Bool {
        guard let cur = tasks[id] else { return false }
        return ObjectIdentifier(cur) == entry
    }

    private func enqueuePersist(_ t: TaskEntry, _ action: @escaping @Sendable () async throws -> Void) async throws {
        let prev = t.lastPersistTask
        let work = Task<Void, any Error> {
            await prev?.value
            try await action()
        }
        t.lastPersistTask = Task {
            _ = try? await work.value
        }
        try await work.value
    }

    private func persistSummary(_ t: TaskEntry) async throws {
        let id = t.summary.id
        guard tasks[id] === t else { return }
        let s = t.summary
        let oid = ObjectIdentifier(t)
        let storeRef = store
        try await enqueuePersist(t) { [weak self] in
            guard let self, await self.isStillCurrentTask(id, oid) else { return }
            try await storeRef.saveSummary(s)
        }
    }

    private func persistSummaryDetached(_ t: TaskEntry) {
        let id = t.summary.id
        guard tasks[id] === t else { return }
        let s = t.summary
        let oid = ObjectIdentifier(t)
        let storeRef = store
        let prev = t.lastPersistTask
        t.lastPersistTask = Task { [weak self] in
            await prev?.value
            guard let self, await self.isStillCurrentTask(id, oid) else { return }
            try? await storeRef.saveSummary(s)
        }
    }

    private func saveReview(
        _ t: TaskEntry,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool]
    ) async throws {
        let id = t.summary.id
        guard tasks[id] === t else { return }
        let decisionsSnap = decisions
        let deletesSet = Set(unassignedDeletes.compactMap { $0.value ? $0.key : nil })
        let oid = ObjectIdentifier(t)
        let storeRef = store
        try await enqueuePersist(t) { [weak self] in
            guard let self, await self.isStillCurrentTask(id, oid) else { return }
            try await storeRef.saveReview(
                id: id,
                scan: scan,
                decisions: decisionsSnap,
                unassignedDeletes: deletesSet
            )
        }
    }

    private func saveDecisionsOnly(
        _ t: TaskEntry,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool]
    ) async throws {
        let id = t.summary.id
        guard tasks[id] === t else { return }
        let decisionsSnap = decisions
        let deletesSet = Set(unassignedDeletes.compactMap { $0.value ? $0.key : nil })
        let cardMeta = TaskCardMeta.from(scan: scan, decisions: decisionsSnap)
        let oid = ObjectIdentifier(t)
        let storeRef = store
        try await enqueuePersist(t) { [weak self] in
            guard let self, await self.isStillCurrentTask(id, oid) else { return }
            try await storeRef.saveDecisions(
                id: id,
                decisions: decisionsSnap,
                unassignedDeletes: deletesSet,
                cardMeta: cardMeta
            )
        }
    }

    private static func mutatedParentDirs(
        from records: [HistoryRecord],
        statuses: Set<OpStatus>
    ) -> [String] {
        var dirs: Set<String> = []
        for r in records where statuses.contains(r.status) {
            let op = r.op
            if (op.kind == .relocate || op.kind == .delete), !op.src.isEmpty {
                dirs.insert(dirOf(op.src))
            }
            if (op.kind == .relocate || op.kind == .write || op.kind == .mkdir), !op.dst.isEmpty {
                dirs.insert(dirOf(op.dst))
                if op.kind == .mkdir || (op.phase == .folders && op.kind == .relocate) {
                    dirs.insert(op.dst)
                }
            }
        }
        return dirs.sorted()
    }

    private func clearStoredReview(_ t: TaskEntry) async throws {
        let id = t.summary.id
        guard tasks[id] === t else { return }
        let oid = ObjectIdentifier(t)
        let storeRef = store
        try await enqueuePersist(t) { [weak self] in
            guard let self, await self.isStillCurrentTask(id, oid) else { return }
            try await storeRef.clearReview(id: id)
        }
    }

    // MARK: - Group & Path Utilities

    private static func normDirPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func applyFolderRenames(_ path: String, folders: [RenameOp]) -> String {
        var cur = path
        for f in folders {
            if cur == f.src {
                cur = f.dst
            } else if cur.hasPrefix(f.src + "/") {
                cur = f.dst + String(cur.dropFirst(f.src.count))
            }
        }
        return cur
    }

    private func protectedRootsFor(_ t: TaskEntry) -> Set<String> {
        let opts = effectiveOptions(t.summary, taskUnassignedDeletes: t.unassignedDeletes)
        var roots: Set<String> = ["/"]
        for r in t.summary.paths where !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.insert(Self.normDirPath(r))
        }
        if let lib = opts.libraryRoot, !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.insert(Self.normDirPath(lib))
        }
        return roots
    }

    private static func commonParentDir(files: [ScanFile], fallback: String) -> String {
        guard let first = files.first else { return fallback }
        func segs(_ d: String) -> [String] { d.split(separator: "/").map(String.init) }
        func dirFor(_ f: ScanFile) -> String { f.isDiscDir ? f.path : dirOf(f.path) }
        var prefix = segs(dirFor(first))
        for f in files.dropFirst() {
            let cur = segs(dirFor(f))
            var i = 0
            while i < prefix.count && i < cur.count && prefix[i] == cur[i] { i += 1 }
            prefix = Array(prefix.prefix(i))
        }
        return prefix.isEmpty ? "/" : "/" + prefix.joined(separator: "/")
    }

    private static func parentDirNames(path: String, roots: [String]) -> [String] {
        let dir = dirOf(path)
        let normRoots = roots.map(normDirPath)
        var matchedRoot: String?
        for r in normRoots {
            let within = dir == r || dir.hasPrefix(r == "/" ? "/" : r + "/")
            if within && (matchedRoot == nil || r.count > matchedRoot!.count) {
                matchedRoot = r
            }
        }
        var names: [String] = []
        var d = dir
        while true {
            if d != "/" { names.append(baseOf(d)) }
            if matchedRoot == nil || d == matchedRoot || d == "/" { break }
            d = dirOf(d)
        }
        return names
    }

    private func anchorTitleFor(files: [ScanFile], rootDir: String, fallback: String) -> String {
        var counts: [String: Int] = [:]
        var firstSeen: [String: String] = [:]
        var order: [String] = []
        for f in files where f.role == .video {
            guard let t = f.parsed?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
            let k = normTitle(t)
            if k.isEmpty { continue }
            if counts[k] == nil {
                order.append(k)
                firstSeen[k] = t
            }
            counts[k, default: 0] += 1
        }
        if !order.isEmpty {
            var bestKey = order[0]
            for k in order.dropFirst() where (counts[k] ?? 0) > (counts[bestKey] ?? 0) {
                bestKey = k
            }
            if let title = firstSeen[bestKey] { return title }
        }
        if rootDir != "/" {
            if let parsed = parser.parse(baseOf(rootDir)).title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !parsed.isEmpty
            {
                return parsed
            }
        }
        return files.first.map { stem($0.name) } ?? fallback
    }

    private func withCounts(_ s: TaskSummary, scan: ScanResult) -> TaskSummary {
        let all = scan.groups.flatMap(\.files) + scan.unassigned
        return withSummary(
            s,
            videos: all.filter { $0.role == .video }.count,
            folders: Set(all.map { dirOf($0.path) }).count,
            subtitles: all.filter { $0.role == .subtitle }.count
        )
    }

    private func withSummary(
        _ s: TaskSummary,
        stage: TaskStage? = nil,
        message: String? = nil,
        mode: OrganizeMode? = nil,
        imported: Int? = nil,
        videos: Int? = nil,
        folders: Int? = nil,
        subtitles: Int? = nil,
        progress: Double? = nil,
        batch: OptionalBatchUpdate = .keep
    ) -> TaskSummary {
        let nextBatch: BatchId?
        switch batch {
        case .keep: nextBatch = s.batch
        case .set(let b): nextBatch = b
        }
        return TaskSummary(
            id: s.id,
            connection: s.connection,
            paths: s.paths,
            mode: mode ?? s.mode,
            scrape: s.scrape,
            scrapeOnly: s.scrapeOnly,
            stage: stage ?? s.stage,
            message: message ?? s.message,
            importedCount: imported ?? s.importedCount,
            videoCount: videos ?? s.videoCount,
            folderCount: folders ?? s.folderCount,
            subtitleCount: subtitles ?? s.subtitleCount,
            progress: progress,
            batch: nextBatch,
            createdAt: s.createdAt
        )
    }
}
