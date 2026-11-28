import Foundation
import Testing
@testable import TidyreelExecution
import TidyreelFakes
import TidyreelModels

// MARK: - Fakes & Spies for TaskManagerTests

private let testConn = ConnectionId("c1")

private func sampleLibrary() -> [String: Int] {
    [
        "/in/Good/a.mkv": 1,
        "/in/Good/a.srt": 1,
        "/in/Good/readme.txt": 1,
        "/in/Mixed/b.mkv": 1,
        "/in/Mixed/warn.mkv": 1,
        "/in/low/c.mkv": 1,
    ]
}

private final class FakeRecognizer: Recognizer, @unchecked Sendable {
    let callsBox = LockedBox(0)
    let gateBox = LockedBox<AsyncGate?>(nil)
    let enteredGate = AsyncGate()
    let failOnceBox = LockedBox<(any Error)?>(nil)
    let seenBackendBox = LockedBox<(any StorageBackend)?>(nil)

    var calls: Int { callsBox.value }

    func recognize(
        connection: ConnectionId,
        roots: [String],
        files: [RemoteEntry],
        read: (@Sendable (String) async throws -> Data)?,
        backend: (any StorageBackend)?
    ) async throws -> ScanResult {
        callsBox.withValue { $0 += 1 }
        seenBackendBox.value = backend
        enteredGate.open()
        if let gate = gateBox.value {
            await gate.wait()
        }
        if let err = failOnceBox.withValue({ v -> (any Error)? in
            defer { v = nil }
            return v
        }) {
            throw err
        }

        // Detect BDMV / VIDEO_TS disc directories
        var discDirs: Set<String> = []
        for e in files where e.isDir && (e.name.uppercased() == "BDMV" || e.name.uppercased() == "VIDEO_TS") {
            discDirs.insert(dirOf(e.path))
        }

        var dirOrder: [String] = []
        var byDir: [String: [ScanFile]] = [:]
        var junk: [ScanFile] = []

        for f in files {
            if discDirs.contains(f.path) && f.isDir {
                let d = dirOf(f.path)
                if byDir[d] == nil { dirOrder.append(d) }
                byDir[d, default: []].append(
                    ScanFile(path: f.path, name: f.name, size: f.size, role: .video, isDiscDir: true)
                )
                continue
            }
            if f.isDir { continue }
            if discDirs.contains(dirOf(f.path)) { continue }

            let role: FileRole
            if f.name.hasSuffix(".mkv") {
                role = .video
            } else if f.name.hasSuffix(".srt") {
                role = .subtitle
            } else {
                role = .junk
            }
            let sf = ScanFile(path: f.path, name: f.name, size: f.size, role: role, deleteIdentity: f.deleteIdentity)
            if role == .junk {
                junk.append(sf)
            } else {
                let d = dirOf(f.path)
                if byDir[d] == nil { dirOrder.append(d) }
                byDir[d, default: []].append(sf)
            }
        }

        let groups = dirOrder.map { dir -> MediaGroup in
            let fs = byDir[dir] ?? []
            return MediaGroup(
                id: GroupId("g:\(dir)"),
                kind: .movie,
                anchorTitle: baseOf(dir),
                rootDir: dir,
                files: fs,
                match: dir.contains("nomatch") ? nil : Candidate(tmdbId: 1, kind: .movie, title: "盗梦空间", year: 2010),
                matchScore: dir.contains("low") ? 0.3 : 0.95
            )
        }
        return ScanResult(connection: connection, roots: roots, groups: groups, unassigned: junk)
    }
}

private final class FakePlanner: Planner, @unchecked Sendable {
    let seenExistingBox = LockedBox<[Set<String>]>([])
    let seenScrapeBox = LockedBox<[Bool]>([])
    let callsBox = LockedBox(0)
    let delayMsBox = LockedBox(0)
    let failOnMoveToLibraryBox = LockedBox(false)
    let throwOnceBox = LockedBox(false)
    let gateBox = LockedBox<AsyncGate?>(nil)
    let enteredGate = AsyncGate()

    func build(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        options: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>?
    ) async throws -> RenamePlan {
        if existing.isEmpty {
            callsBox.withValue { $0 += 1 }
        }
        let delay = delayMsBox.value
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        if let gate = gateBox.value {
            enteredGate.open()
            await gate.wait()
        }
        if throwOnceBox.withValue({ v -> Bool in
            if v { v = false; return true }
            return false
        }) {
            throw TidyreelExecutionError.invalidState("plan boom")
        }
        if failOnMoveToLibraryBox.value && options.mode == .moveToLibrary && (options.libraryRoot ?? "").isEmpty {
            throw TidyreelExecutionError.invalidArgument("缺少媒体库根目录")
        }

        seenExistingBox.withValue { $0.append(existing) }
        seenScrapeBox.withValue { $0.append(options.scrape) }

        var ops: [RenameOp] = []
        var conflicts: [PlanConflict] = []
        let customTv = options.naming.tv.customTemplate

        for g in scan.groups {
            let dec = decisions[g.id] ?? GroupDecision()
            let sel = dec.selected

            if options.scrapeOnly {
                for f in g.files where f.role == .video {
                    let nfoDst = "\(dirOf(f.path))/\(stem(f.name)).nfo"
                    ops.append(
                        RenameOp(
                            id: OpId("w:\(f.path)"),
                            kind: .write,
                            phase: .cleanup,
                            src: "\(writeTextPrefix)<movie/>",
                            dst: nfoDst,
                            group: g.id,
                            selected: sel
                        )
                    )
                }
                continue
            }

            let outDir = options.mode == .moveToLibrary && options.libraryRoot != nil
                ? "\(options.libraryRoot!)/\(g.anchorTitle)_done"
                : g.rootDir

            for f in g.files {
                if f.isDiscDir {
                    ops.append(
                        RenameOp(
                            id: OpId("disc:\(f.path)"),
                            kind: .relocate,
                            phase: .folders,
                            src: f.path,
                            dst: "\(dirOf(f.path))/盗梦空间 (2010)",
                            group: g.id,
                            selected: sel
                        )
                    )
                    continue
                }
                let epNum = (f.parsed?.episodes.first ?? 1) + dec.episodeOffset
                let baseName: String
                if let tpl = customTv, g.kind == .episode {
                    let epTag = String(format: "%02d", max(1, epNum))
                    let snTag = String(format: "%02d", f.parsed?.season ?? 1)
                    let rendered = tpl
                        .replacingOccurrences(of: "{season:02}", with: snTag)
                        .replacingOccurrences(of: "{episode:02}", with: epTag)
                    baseName = "\(rendered).\(extOf(f.name))"
                } else if g.kind == .episode {
                    let epTag = String(format: "S%02dE%02d", f.parsed?.season ?? 1, max(1, epNum))
                    baseName = "\(g.anchorTitle).\(epTag).\(extOf(f.name))"
                } else {
                    baseName = "ok_\(f.name)"
                }
                let dst = options.mode == .moveToLibrary && options.libraryRoot != nil
                    ? "\(outDir)/\(baseName)"
                    : (g.kind == .episode ? "\(g.rootDir)/Season 01/\(baseName)" : "\(g.rootDir)/\(baseName)")
                let warn: String?
                if f.name.contains("warn") {
                    warn = "需要确认"
                } else if (f.parsed?.confidence ?? 1.0) < options.confidenceThreshold || g.matchScore < options.confidenceThreshold {
                    warn = "识别置信度较低"
                } else {
                    warn = nil
                }
                let op = RenameOp(
                    id: OpId("f:\(f.path)"),
                    kind: .relocate,
                    phase: .files,
                    src: f.path,
                    dst: dst,
                    group: g.id,
                    selected: sel,
                    warning: warn
                )
                ops.append(op)
                if existing.contains(dst) && dst != f.path {
                    conflicts.append(PlanConflict(ops: [op.id], path: dst, reason: "已存在"))
                }
            }

            if options.mode == .inPlace && !g.files.contains(where: \.isDiscDir) {
                let dstFolder = g.kind == .episode ? "\(dirOf(g.rootDir))/\(g.anchorTitle) (2020)" : "\(g.rootDir)_done"
                if dstFolder != g.rootDir {
                    ops.append(
                        RenameOp(
                            id: OpId("d:\(g.rootDir)"),
                            kind: .relocate,
                            phase: .folders,
                            src: g.rootDir,
                            dst: dstFolder,
                            group: g.id,
                            selected: sel
                        )
                    )
                }
            }
        }

        for u in scan.unassigned where u.role == .junk {
            let shouldDel = options.unassignedDeletes[u.path] ?? options.deleteJunk
            ops.append(
                RenameOp(
                    id: OpId("del:\(u.path)"),
                    kind: .delete,
                    phase: .cleanup,
                    src: u.path,
                    dst: "",
                    selected: shouldDel,
                    deleteIdentity: u.deleteIdentity
                )
            )
        }

        return RenamePlan(ops: ops, conflicts: conflicts)
    }
}

private final class FixedPlanner: Planner, Sendable {
    let plan: RenamePlan
    init(_ plan: RenamePlan) { self.plan = plan }
    func build(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        options: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>?
    ) async throws -> RenamePlan {
        plan
    }
}

private final class ErrorExecutor: Executor, Sendable {
    func execute(task: TaskId, connection: ConnectionId, plan: RenamePlan, backend: any StorageBackend) -> AsyncThrowingStream<ExecProgress, any Error> {
        AsyncThrowingStream { $0.finish(throwing: TidyreelExecutionError.invalidState("pre-batch failure")) }
    }
    func resume(batch: BatchId, backend: any StorageBackend) -> AsyncThrowingStream<ExecProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func undo(batch: BatchId, backend: any StorageBackend, only: Set<OpId>?) -> AsyncThrowingStream<ExecProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Spy TaskStore tracking `loadSummaries`, `loadReview`, `loadAll`, `saveReview`, and `saveDecisions` call counts!
private actor SpyTaskStore: TaskStore {
    let inner = MemoryTaskStore()
    nonisolated let supportsTargetedDecisionSave: Bool
    var loadSummariesCalls = 0
    var loadAllCalls = 0
    var loadReviewCalls: [TaskId] = []
    var rejectNextSummary = false
    func failNextSummarySave() { rejectNextSummary = true }
    var saveReviewCalls = 0
    var saveDecisionsCalls = 0
    var lastCardMeta: TaskCardMeta?

    init(supportsTargetedDecisionSave: Bool = false) {
        self.supportsTargetedDecisionSave = supportsTargetedDecisionSave
    }

    func saveSummary(_ summary: TaskSummary) async throws {
        if rejectNextSummary {
            rejectNextSummary = false
            throw TidyreelExecutionError.invalidState("summary store unavailable")
        }
        try await inner.saveSummary(summary)
    }

    func saveReview(
        id: TaskId,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool]
    ) async throws {
        saveReviewCalls += 1
        try await inner.saveReview(id: id, scan: scan, decisions: decisions, unassignedDeletes: unassignedDeletes)
    }

    func saveDecisions(
        id: TaskId,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool],
        cardMeta: TaskCardMeta?
    ) async throws {
        saveDecisionsCalls += 1
        lastCardMeta = cardMeta
        if let existing = try await inner.loadReview(id: id) {
            try await inner.saveReview(
                id: id,
                scan: existing.scan,
                decisions: decisions,
                unassignedDeletes: unassignedDeletes
            )
        }
    }

    func clearReview(id: TaskId) async throws {
        try await inner.clearReview(id: id)
    }

    func loadSummaries() async throws -> [TaskSummary] {
        loadSummariesCalls += 1
        return try await inner.loadSummaries()
    }

    func loadReview(id: TaskId) async throws -> StoredTaskReview? {
        loadReviewCalls.append(id)
        return try await inner.loadReview(id: id)
    }

    func loadAll() async throws -> [StoredTask] {
        loadAllCalls += 1
        return try await inner.loadAll()
    }

    func delete(id: TaskId) async throws {
        try await inner.delete(id: id)
    }

    func rawLoadAll() async throws -> [StoredTask] {
        try await inner.loadAll()
    }
}

private actor GatedBatchHistory: HistoryStore {
    let inner = MemoryHistoryStore()
    var hold = false
    let entered = AsyncGate()
    let release = AsyncGate()

    func setHold(_ v: Bool) { hold = v }

    func setCyclePhase(_ phase: RelocationCyclePhase, batch: BatchId, ops: [OpId]) async throws {
        try await inner.setCyclePhase(phase, batch: batch, ops: ops)
    }

    func saveWrittenDigest(_ digest: String, batch: BatchId, op: OpId) async throws {
        try await inner.saveWrittenDigest(digest, batch: batch, op: op)
    }

    func beginBatch(task: TaskId, connection: ConnectionId, ops: [RenameOp]) async throws -> BatchId {
        try await inner.beginBatch(task: task, connection: connection, ops: ops)
    }

    func mark(batch: BatchId, op: OpId, status: OpStatus, error: String?) async throws {
        try await inner.mark(batch: batch, op: op, status: status, error: error)
    }

    func records(batch: BatchId) async throws -> [HistoryRecord] {
        try await inner.records(batch: batch)
    }

    func batches() async throws -> [BatchSummary] {
        if hold {
            entered.open()
            await release.wait()
        }
        return try await inner.batches()
    }

    func isOrganized(connection: ConnectionId, path: String) async throws -> Bool {
        try await inner.isOrganized(connection: connection, path: path)
    }

    func areOrganized(connection: ConnectionId, paths: [String]) async throws -> Set<String> {
        try await inner.areOrganized(connection: connection, paths: paths)
    }

    func deleteTask(_ task: TaskId) async throws {
        try await inner.deleteTask(task)
    }
}

private final class LockedFolderBackend: StorageBackend, @unchecked Sendable {
    let inner: MemoryStorageBackend
    let lockedPath: String
    let isLockedBox = LockedBox(true)
    let listedBox = LockedBox<[String]>([])
    let listGateBox = LockedBox<AsyncGate?>(nil)

    init(_ inner: MemoryStorageBackend, lockedPath: String = "") {
        self.inner = inner
        self.lockedPath = lockedPath
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] {
        if let g = listGateBox.value { await g.wait() }
        listedBox.withValue { $0.append(dir) }
        return try await inner.list(dir, refresh: refresh)
    }

    func mkdirs(_ dir: String) async throws { try await inner.mkdirs(dir) }

    func rename(_ path: String, newName: String) async throws {
        if !lockedPath.isEmpty && isLockedBox.value && path == lockedPath {
            throw StorageError(.other, "Access is denied: \(path)")
        }
        try await inner.rename(path, newName: newName)
    }

    func renameMany(_ dir: String, names: [String: String]) async throws { try await inner.renameMany(dir, names: names) }
    func move(srcDir: String, dstDir: String, names: [String]) async throws { try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names) }
    func removeScannedFile(_ path: String, identity: String?) async throws { try await inner.removeScannedFile(path, identity: identity) }
    func remove(dir: String, names: [String]) async throws { try await inner.remove(dir: dir, names: names) }
    func exists(_ path: String) async throws -> Bool { try await inner.exists(path) }
    func read(_ path: String) async throws -> Data { try await inner.read(path) }
    func write(_ path: String, bytes: Data) async throws { try await inner.write(path, bytes: bytes) }
    func ping() async throws {}
    func close() async { await inner.close() }
}

private func waitForTask(
    _ tm: DefaultTaskManager,
    id: TaskId,
    matching predicate: @escaping @Sendable (TaskSummary) -> Bool
) async throws -> TaskSummary {
    for await list in tm.watchAll() {
        if let found = list.first(where: { $0.id == id }), predicate(found) {
            return found
        }
    }
    throw TidyreelExecutionError.invalidState("Stream ended before predicate matched")
}

// MARK: - Suite

@Suite("DefaultTaskManager Tests")
struct TaskManagerTests {
    @Test("Failed submissions stay unpublished and execution honors the reviewed deletion set")
    func submissionAndDeletionConsent() async throws {
        let fs = MemoryStorageBackend(initialSizes: ["/a/v.mkv": 1, "/a/ad.txt": 1, "/b/v.mkv": 1])
        let store = SpyTaskStore(supportsTargetedDecisionSave: true)
        let history = MemoryHistoryStore()
        let tm = DefaultTaskManager(
            backendFor: { _ in fs }, recognizer: FakeRecognizer(), planner: FakePlanner(),
            executor: DefaultExecutor(history: history, sleepMs: { _ in }), history: history,
            store: store, options: { _, mode in PlanOptions(mode: mode, libraryRoot: "/lib", deleteJunk: true) }
        )
        await store.failNextSummarySave()
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.submit(connection: testConn, paths: ["/a"], mode: .moveToLibrary)
        }
        #expect(await tm.currentSummaries().isEmpty)

        let id = try await tm.submit(connection: testConn, paths: ["/a"], mode: .moveToLibrary)
        _ = try await waitForTask(tm, id: id) { $0.stage == .awaitingReview }
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.run(id, confirmedDeletePaths: ["/a/another.txt"])
        }
        #expect(try await history.latestBatch(task: id) == nil)
        _ = try await tm.setUnassignedDelete(id, filePath: "/a/ad.txt", delete: false)
        let other = try await tm.submit(connection: testConn, paths: ["/b"], mode: .moveToLibrary)
        _ = try await waitForTask(tm, id: other) { $0.stage == .awaitingReview }
        #expect(await tm.hasCachedReview(id) == false)
        try await tm.run(id)
        #expect(try await fs.exists("/a/ad.txt"))
        await tm.dispose()
    }

    @Test("CRITICAL MEMORY FIX: Startup uses loadSummaries only, loads review lazily on demand, and evicts ScanResult when finished")
    func lazyReviewLoadAndMemoryEviction() async throws {
        let fs = MemoryStorageBackend(initialSizes: sampleLibrary())
        let store = SpyTaskStore()
        let history = MemoryHistoryStore()

        // Seed 50 historical tasks (done, failed, cancelled, undone) + 1 awaitingReview task
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1...50 {
            let tid = TaskId("T\(i)-000000")
            let stage: TaskStage = [.done, .failed, .cancelled, .undone][i % 4]
            try await store.saveSummary(
                TaskSummary(
                    id: tid,
                    connection: testConn,
                    paths: ["/in"],
                    mode: .inPlace,
                    stage: stage,
                    createdAt: baseDate.addingTimeInterval(Double(i))
                )
            )
            try await store.saveReview(
                id: tid,
                scan: ScanResult(
                    connection: testConn,
                    roots: ["/in"],
                    groups: [
                        MediaGroup(
                            id: GroupId("g-\(i)"),
                            kind: .movie,
                            anchorTitle: "Movie \(i)",
                            rootDir: "/in/Good",
                            files: [ScanFile(path: "/in/Good/a.mkv", name: "a.mkv", size: 1, role: .video)],
                            match: Candidate(tmdbId: i, kind: .movie, title: "Movie \(i)"),
                            matchScore: 0.95
                        ),
                    ]
                ),
                decisions: [GroupId("g-\(i)"): GroupDecision()],
                unassignedDeletes: [:]
            )
        }

        let awaitingId = TaskId("T51-abcdef")
        try await store.saveSummary(
            TaskSummary(
                id: awaitingId,
                connection: testConn,
                paths: ["/in/Good"],
                mode: .inPlace,
                stage: .awaitingReview,
                createdAt: baseDate.addingTimeInterval(100)
            )
        )
        try await store.saveReview(
            id: awaitingId,
            scan: ScanResult(
                connection: testConn,
                roots: ["/in/Good"],
                groups: [
                    MediaGroup(
                        id: GroupId("g:/in/Good"),
                        kind: .movie,
                        anchorTitle: "Good",
                        rootDir: "/in/Good",
                        files: [ScanFile(path: "/in/Good/a.mkv", name: "a.mkv", size: 1, role: .video)],
                        match: Candidate(tmdbId: 99, kind: .movie, title: "Good"),
                        matchScore: 0.95
                    ),
                ]
            ),
            decisions: [GroupId("g:/in/Good"): GroupDecision()],
            unassignedDeletes: [:]
        )

        let tm = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) }
        )

        // 1. Startup + resumeInterrupted ONLY calls loadSummaries(), NEVER loadAll() or loadReview()!
        try await tm.resumeInterrupted()
        let summaries = await tm.currentSummaries()
        #expect(summaries.count == 51)
        #expect(await store.loadSummariesCalls == 1)
        #expect(await store.loadAllCalls == 0)
        #expect((await store.loadReviewCalls).isEmpty)
        for s in summaries {
            #expect(await tm.hasCachedReview(s.id) == false)
        }

        // 2. Requesting review(awaitingId) loads lazily on demand and caches while in awaitingReview
        let rev1 = try await tm.review(awaitingId)
        #expect(rev1.scan.groups.count == 1)
        #expect(await store.loadReviewCalls == [awaitingId])
        #expect(await tm.hasCachedReview(awaitingId) == true)

        // Second review() hits in-memory cache without touching store.loadReview again
        _ = try await tm.review(awaitingId)
        #expect(await store.loadReviewCalls == [awaitingId])

        // 3. Running task to .done immediately evicts heavy ScanResult from RAM
        try await tm.run(awaitingId)
        let doneSummary = try await waitForTask(tm, id: awaitingId) { $0.stage == .done }
        #expect(doneSummary.stage == .done)
        #expect(await tm.hasCachedReview(awaitingId) == false)

        // 4. Inspecting a finished task loads on demand from TaskStore without retaining in RAM!
        let doneHistoricalId = TaskId("T4-000000")
        let histRev = try await tm.review(doneHistoricalId)
        #expect(histRev.scan.groups.first?.anchorTitle == "Movie 4")
        #expect(await tm.hasCachedReview(doneHistoricalId) == false)

        await tm.dispose()
    }

    @Test("Full lifecycle: submit, import, recognize, review, run, undo, and stage progression")
    func fullLifecycle() async throws {
        let fs = MemoryStorageBackend(initialSizes: sampleLibrary())
        let recognizer = FakeRecognizer()
        let planner = FakePlanner()
        let history = MemoryHistoryStore()
        let store = SpyTaskStore()

        let tm = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: recognizer,
            planner: planner,
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )

        let seenStages = LockedBox<[TaskStage]>([])
        let watcher = Task {
            for await list in tm.watchAll() {
                if let first = list.first {
                    seenStages.withValue { stages in
                        if stages.last != first.stage {
                            stages.append(first.stage)
                        }
                    }
                }
            }
        }

        let id = try await tm.submit(connection: testConn, paths: ["/in"], mode: .inPlace)
        #expect(id.value.range(of: #"^T\d+-[0-9a-f]{6}$"#, options: .regularExpression) != nil)

        let ready = try await waitForTask(tm, id: id) { $0.stage == .awaitingReview }
        #expect(ready.message == "识别完成，请确认结果后继续执行")
        #expect(ready.importedCount == 6)
        #expect(ready.videoCount == 4)
        #expect(ready.subtitleCount == 1)
        #expect(ready.folderCount == 3)
        #expect(await tm.hasCachedReview(id) == true)

        let rev = try await tm.review(id)
        #expect(rev.scan.groups.count == 3)

        try await tm.run(id)
        let done = try await waitForTask(tm, id: id) { $0.stage == .done }
        #expect(done.batch != nil)
        #expect((await fs.allFilePaths()).contains("/in/Good_done/ok_a.mkv"))
        #expect((await fs.allFilePaths()).contains("/in/Mixed_done/ok_warn.mkv"))
        #expect(await tm.hasCachedReview(id) == false)

        try await tm.undo(id)
        let undone = try await waitForTask(tm, id: id) { $0.stage == .undone }
        #expect(undone.message == "已撤销")
        #expect(await fs.allFilePaths() == sampleLibrary().keys.sorted())
        #expect(await tm.hasCachedReview(id) == false)

        await tm.dispose()
        await watcher.value

        #expect(seenStages.value.contains(.awaitingReview))
        #expect(seenStages.value.contains(.done))
        #expect(seenStages.value.last == .undone)
        let persisted = try await store.rawLoadAll()
        #expect(persisted.first?.summary.stage == .undone)
    }

    @Test("Interactive edits: updateDecision, setMode rollback, assignUnassigned, setUnassignedDelete, mergeGroups, splitGroup, and concurrent composition")
    func interactiveReviewEditsAndConcurrency() async throws {
        let fs = MemoryStorageBackend(initialSizes: [
            "/in/A/a.mkv": 1,
            "/in/A/ad.txt": 1,
            "/in/B/b.mkv": 1,
            "/in/loose/S01E02.chs.srt": 1,
        ])
        let recognizer = FakeRecognizer()
        let planner = FakePlanner()
        planner.delayMsBox.value = 10
        let history = MemoryHistoryStore()
        let store = SpyTaskStore()

        let tm = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: recognizer,
            planner: planner,
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )

        let id = try await tm.submit(connection: testConn, paths: ["/in"], mode: .inPlace)
        _ = try await waitForTask(tm, id: id) { $0.stage == .awaitingReview }

        let gA = GroupId("g:/in/A")
        let gB = GroupId("g:/in/B")
        let gLoose = GroupId("g:/in/loose")

        // Concurrent edits compose without lost updates
        async let e1 = tm.updateDecision(id, group: gA, decision: GroupDecision(selected: false))
        async let e2 = tm.updateDecision(id, group: gB, decision: GroupDecision(episodeOffset: 3))
        async let e3 = tm.setUnassignedDelete(id, filePath: "/in/A/ad.txt", delete: true)
        _ = try await (e1, e2, e3)

        let revAfterConcurrent = try await tm.review(id)
        #expect(revAfterConcurrent.decisions[gA]?.selected == false)
        #expect(revAfterConcurrent.decisions[gB]?.episodeOffset == 3)
        #expect(revAfterConcurrent.preview.ops.first { $0.kind == .delete && $0.src == "/in/A/ad.txt" }?.selected == true)

        // Failed setMode rolls back mode & summary atomically
        planner.failOnMoveToLibraryBox.value = true
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.setMode(id, mode: .moveToLibrary)
        }
        #expect((await tm.currentSummaries()).first?.mode == .inPlace)
        planner.failOnMoveToLibraryBox.value = false

        // Merge gLoose and gB into gA, then split
        _ = try await tm.mergeGroups(id, keep: gA, absorb: gLoose)
        let merged = try await tm.mergeGroups(id, keep: gA, absorb: gB)
        #expect(merged.scan.groups.count == 1)
        #expect(merged.scan.groups[0].rootDir == "/in")
        #expect(merged.decisions[gB] == nil)

        // Invalid split rejected
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.splitGroup(id, group: gA, filePaths: [])
        }

        let split = try await tm.splitGroup(id, group: gA, filePaths: ["/in/B/b.mkv"])
        #expect(split.scan.groups.count == 2)

        // Assign unassigned file to group
        let afterAssign = try await tm.assignUnassigned(id, filePath: "/in/A/ad.txt", targetGroup: gA)
        #expect(afterAssign.scan.unassigned.isEmpty)

        await tm.dispose()
    }

    @Test("Execution preparation blocks edits; cancel waits for busy release so immediate delete succeeds")
    func busyGuardsAndCancelDelete() async throws {
        let fs = MemoryStorageBackend(initialSizes: ["/in/Good/a.mkv": 1])
        let history = GatedBatchHistory()
        let store = SpyTaskStore()
        let tm = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )

        let id = try await tm.submit(connection: testConn, paths: ["/in/Good"], mode: .inPlace)
        _ = try await waitForTask(tm, id: id) { $0.stage == .awaitingReview }

        await history.setHold(true)
        let runTask = Task { try await tm.run(id) }
        await history.entered.wait()

        // Rejects updateDecision & setMode while busy preparing execution
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.updateDecision(id, group: GroupId("g:/in/Good"), decision: GroupDecision(selected: false))
        }
        await #expect(throws: TidyreelExecutionError.self) {
            try await tm.setMode(id, mode: .moveToLibrary)
        }

        let cancelTask = Task { await tm.cancel(id) }
        history.release.open()
        _ = try? await runTask.value
        await cancelTask.value

        // Immediate delete succeeds right after cancel returns!
        try await tm.delete(id)
        #expect((await tm.currentSummaries()).isEmpty)
        await tm.dispose()
    }

    @Test("RetryFailed, retry, crash restart recovery, BDMV short-circuit, onlyConfident, and empty dirs")
    func retryResumeBdmvConfidentAndEmptyDirs() async throws {
        // 1. retryFailed resets failed & forward-skipped ops while preserving undo-skipped ops
        let fs1 = MemoryStorageBackend(initialSizes: ["/in/a.mkv": 1, "/in/b.mkv": 1])
        let store1 = SpyTaskStore()
        let h1 = MemoryHistoryStore()
        let tid1 = TaskId("t-retry-skip")
        let ops1 = [
            RenameOp(id: OpId("op-fail"), kind: .relocate, phase: .files, src: "/in/a.mkv", dst: "/in/a_new.mkv"),
            RenameOp(id: OpId("op-fwd-skip"), kind: .relocate, phase: .files, src: "/in/b.mkv", dst: "/in/b_new.mkv"),
            RenameOp(id: OpId("op-undo-del"), kind: .delete, phase: .cleanup, src: "/in/gone.txt", dst: ""),
            RenameOp(id: OpId("op-undo-ow"), kind: .write, phase: .cleanup, src: "text:<m/>", dst: "/in/m.nfo", overwrite: true),
        ]
        let bid1 = try await h1.beginBatch(task: tid1, connection: testConn, ops: ops1)
        try await h1.mark(batch: bid1, op: OpId("op-fail"), status: .failed, error: "boom")
        try await h1.mark(batch: bid1, op: OpId("op-fwd-skip"), status: .skipped, error: "依赖的操作失败：/in/a.mkv")
        try await h1.mark(batch: bid1, op: OpId("op-undo-del"), status: .skipped, error: "删除无法撤销")
        try await h1.mark(batch: bid1, op: OpId("op-undo-ow"), status: .skipped, error: "覆盖写入无法撤销")
        try await store1.saveSummary(
            TaskSummary(
                id: tid1,
                connection: testConn,
                paths: ["/in"],
                mode: .inPlace,
                stage: .partiallyFailed,
                batch: bid1,
                createdAt: Date()
            )
        )
        let tm1 = DefaultTaskManager(
            backendFor: { _ in fs1 },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: h1, sleepMs: { _ in }),
            history: h1,
            store: store1,
            options: { _, mode in PlanOptions(mode: mode) }
        )
        try await tm1.retryFailed(tid1)
        let recs1 = Dictionary(uniqueKeysWithValues: (try await h1.records(batch: bid1)).map { ($0.op.id, $0.status) })
        #expect(recs1[OpId("op-fail")] == .done)
        #expect(recs1[OpId("op-fwd-skip")] == .done)
        #expect(recs1[OpId("op-undo-del")] == .skipped)
        #expect(recs1[OpId("op-undo-ow")] == .skipped)
        await tm1.dispose()

        // 2. BDMV short-circuit never lists inside BDMV or CERTIFICATE
        let fsBdmvInner = MemoryStorageBackend(initialSizes: [
            "/in/Inception.2010.BluRay/BDMV/STREAM/00001.m2ts": 50000,
            "/in/Inception.2010.BluRay/BDMV/index.bdmv": 100,
            "/in/Inception.2010.BluRay/CERTIFICATE/id.bdmv": 50,
        ])
        let fsBdmv = LockedFolderBackend(fsBdmvInner)
        let recBdmv = FakeRecognizer()
        let hBdmv = MemoryHistoryStore()
        let tmBdmv = DefaultTaskManager(
            backendFor: { _ in fsBdmv },
            recognizer: recBdmv,
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hBdmv, sleepMs: { _ in }),
            history: hBdmv,
            store: SpyTaskStore(),
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )
        let bdmvId = try await tmBdmv.submit(connection: testConn, paths: ["/in"], mode: .inPlace)
        _ = try await waitForTask(tmBdmv, id: bdmvId) { $0.stage == .awaitingReview }
        #expect(!fsBdmv.listedBox.value.contains { $0.contains("BDMV") || $0.contains("CERTIFICATE") })
        try await tmBdmv.run(bdmvId)
        #expect((await fsBdmvInner.allFilePaths()).contains("/in/盗梦空间 (2010)/BDMV/STREAM/00001.m2ts"))
        await tmBdmv.dispose()

        // 3. findEmptyDirs and removeEmptyDirs clean OS metadata junk while protecting roots
        let fsEmpty = MemoryStorageBackend(initialSizes: [
            "/in/Show/Season 1/a.mkv": 1,
            "/in/Show/Season 1/.DS_Store": 1,
            "/in/Show/Thumbs.db": 1,
        ])
        let hEmpty = MemoryHistoryStore()
        let tmEmpty = DefaultTaskManager(
            backendFor: { _ in fsEmpty },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hEmpty, sleepMs: { _ in }),
            history: hEmpty,
            store: SpyTaskStore(),
            options: { _, mode in PlanOptions(mode: mode, libraryRoot: "/lib") },
            importUpdateIntervalMs: 0
        )
        let emptyTaskId = try await tmEmpty.submit(connection: testConn, paths: ["/in"], mode: .moveToLibrary)
        _ = try await waitForTask(tmEmpty, id: emptyTaskId) { $0.stage == .awaitingReview }
        try await tmEmpty.run(emptyTaskId)
        let emptyDirs = try await tmEmpty.findEmptyDirs(emptyTaskId)
        #expect(emptyDirs == ["/in/Show/Season 1", "/in/Show"])
        let removedCount = try await tmEmpty.removeEmptyDirs(emptyTaskId, dirs: emptyDirs + ["/in", "/"])
        #expect(removedCount == 2)
        #expect(!(try await fsEmpty.exists("/in/Show")))
        #expect(try await fsEmpty.exists("/in"))
        await tmEmpty.dispose()

        // 4. onlyConfident filters warnings & low-score groups and detects broken vacate-chain conflicts
        let fsConf = MemoryStorageBackend(initialSizes: sampleLibrary())
        let hConf = MemoryHistoryStore()
        let tmConf = DefaultTaskManager(
            backendFor: { _ in fsConf },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hConf, sleepMs: { _ in }),
            history: hConf,
            store: SpyTaskStore(),
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )
        let confId = try await tmConf.submit(connection: testConn, paths: ["/in"], mode: .inPlace)
        _ = try await waitForTask(tmConf, id: confId) { $0.stage == .awaitingReview }
        try await tmConf.run(confId, onlyConfident: true)
        #expect(await fsConf.allFilePaths() == [
            "/in/Good_done/ok_a.mkv",
            "/in/Good_done/ok_a.srt",
            "/in/Good_done/readme.txt",
            "/in/Mixed_done/ok_b.mkv",
            "/in/Mixed_done/warn.mkv",
            "/in/low/c.mkv",
        ])
        await tmConf.dispose()

        // Broken vacate-chain conflict detected in onlyConfident
        let dirChain = "/d/Show"
        let gidChain = GroupId("g-chain")
        let tidChain = TaskId("t-vacate")
        let fsChain = MemoryStorageBackend(initialSizes: ["\(dirChain)/a.mkv": 1, "\(dirChain)/c.mkv": 1])
        let storeChain = SpyTaskStore()
        try await storeChain.saveSummary(
            TaskSummary(id: tidChain, connection: testConn, paths: ["/d"], mode: .inPlace, stage: .awaitingReview, createdAt: Date())
        )
        try await storeChain.saveReview(
            id: tidChain,
            scan: ScanResult(
                connection: testConn,
                roots: ["/d"],
                groups: [
                    MediaGroup(
                        id: gidChain,
                        kind: .movie,
                        anchorTitle: "Show",
                        rootDir: dirChain,
                        files: [
                            ScanFile(path: "\(dirChain)/a.mkv", name: "a.mkv", size: 1, role: .video),
                            ScanFile(path: "\(dirChain)/c.mkv", name: "c.mkv", size: 1, role: .video),
                        ],
                        match: Candidate(tmdbId: 1, kind: .movie, title: "Show"),
                        matchScore: 0.95
                    ),
                ]
            ),
            decisions: [gidChain: GroupDecision()],
            unassignedDeletes: [:]
        )
        let chainPlan = RenamePlan(ops: [
            RenameOp(id: OpId("low-vacate"), kind: .relocate, phase: .files, src: "\(dirChain)/a.mkv", dst: "\(dirChain)/b.mkv", group: gidChain, warning: "识别置信度较低"),
            RenameOp(id: OpId("high-take"), kind: .relocate, phase: .files, src: "\(dirChain)/c.mkv", dst: "\(dirChain)/a.mkv", group: gidChain),
        ])
        let tmChain = DefaultTaskManager(
            backendFor: { _ in fsChain },
            recognizer: FakeRecognizer(),
            planner: FixedPlanner(chainPlan),
            executor: DefaultExecutor(history: MemoryHistoryStore(), sleepMs: { _ in }),
            history: MemoryHistoryStore(),
            store: storeChain,
            options: { _, mode in PlanOptions(mode: mode) }
        )
        await #expect(throws: TidyreelExecutionError.self) {
            try await tmChain.run(tidChain, onlyConfident: true)
        }
        await tmChain.dispose()

        // 5. Stream error before batch creation transitions to .failed (not stuck)
        let storeErr = SpyTaskStore()
        let tidErr = TaskId("t-err")
        try await storeErr.saveSummary(
            TaskSummary(id: tidErr, connection: testConn, paths: ["/in/Good"], mode: .inPlace, stage: .awaitingReview, createdAt: Date())
        )
        try await storeErr.saveReview(
            id: tidErr,
            scan: ScanResult(
                connection: testConn,
                roots: ["/in/Good"],
                groups: [
                    MediaGroup(
                        id: GroupId("g"),
                        kind: .movie,
                        anchorTitle: "Good",
                        rootDir: "/in/Good",
                        files: [ScanFile(path: "/in/Good/a.mkv", name: "a.mkv", size: 1, role: .video)],
                        match: Candidate(tmdbId: 1, kind: .movie, title: "Good"),
                        matchScore: 0.95
                    ),
                ]
            ),
            decisions: [GroupId("g"): GroupDecision()],
            unassignedDeletes: [:]
        )
        let tmErr = DefaultTaskManager(
            backendFor: { _ in MemoryStorageBackend(initialSizes: ["/in/Good/a.mkv": 1]) },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: ErrorExecutor(),
            history: MemoryHistoryStore(),
            store: storeErr,
            options: { _, mode in PlanOptions(mode: mode) }
        )
        try await tmErr.run(tidErr)
        let errSum = (await tmErr.currentSummaries()).first { $0.id == tidErr }
        #expect(errSum?.stage == .failed)
        #expect(errSum?.batch == nil)
        await tmErr.dispose()
    }

    @Test("Crash restart: interrupted execution resumes to final tree; unlogged execution falls back to awaitingReview")
    func crashRestartResumeAndFallback() async throws {
        // 1. Interrupted execution resumes and completes
        let fs = MemoryStorageBackend(initialSizes: ["/in/Good/a.mkv": 1, "/in/Good/a.srt": 1])
        let store = SpyTaskStore()
        let history = MemoryHistoryStore()
        let tm1 = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: history, concurrencyProvider: { 1 }, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )
        let id = try await tm1.submit(connection: testConn, paths: ["/in/Good"], mode: .inPlace)
        _ = try await waitForTask(tm1, id: id) { $0.stage == .awaitingReview }
        let plan = (try await tm1.review(id)).preview
        await tm1.dispose()

        // Simulate crash after 1 op in DefaultExecutor
        let exCrash = DefaultExecutor(history: history, concurrencyProvider: { 1 }, sleepMs: { _ in })
        var seen = 0
        for try await _ in exCrash.execute(task: id, connection: testConn, plan: plan, backend: fs) {
            seen += 1
            if seen == 1 { break }
        }
        await exCrash.waitForSettled()

        let existingSummary = (try await store.loadSummaries()).first { $0.id == id }!
        try await store.saveSummary(
            TaskSummary(
                id: id,
                connection: testConn,
                paths: existingSummary.paths,
                mode: existingSummary.mode,
                stage: .renamingFiles,
                createdAt: existingSummary.createdAt
            )
        )

        // Also seed a second task in .renamingFolders that never created a WAL batch
        let unloggedId = TaskId("T9-000000")
        try await store.saveSummary(
            TaskSummary(
                id: unloggedId,
                connection: testConn,
                paths: ["/in/Good"],
                mode: .inPlace,
                stage: .renamingFolders,
                createdAt: Date()
            )
        )

        let tm2 = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode) }
        )
        try await tm2.resumeInterrupted()
        let summaries = Dictionary(uniqueKeysWithValues: (await tm2.currentSummaries()).map { ($0.id, $0) })
        #expect(summaries[id]?.stage == .done)
        #expect(summaries[id]?.batch != nil)
        #expect(summaries[unloggedId]?.stage == .awaitingReview)
        #expect(await fs.allFilePaths() == ["/in/Good_done/ok_a.mkv", "/in/Good_done/ok_a.srt"])

        // Resumed task can still be undone cleanly
        try await tm2.undo(id)
        #expect(await fs.allFilePaths() == ["/in/Good/a.mkv", "/in/Good/a.srt"])
        await tm2.dispose()
    }

    @Test("ScrapeOnly, concurrent tasks, retry lifecycle, naming profile refresh, plan coalescing, and missing connection resilience")
    func scrapeOnlyConcurrentRetryCoalescingAndErrors() async throws {
        // 1. scrapeOnly writes NFO without moving files
        let fsScrape = MemoryStorageBackend(initialSizes: ["/in/Movie/Inception.2010.mkv": 1])
        let hScrape = MemoryHistoryStore()
        let tmScrape = DefaultTaskManager(
            backendFor: { _ in fsScrape },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hScrape, sleepMs: { _ in }),
            history: hScrape,
            store: SpyTaskStore(),
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )
        let sId = try await tmScrape.submit(connection: testConn, paths: ["/in/Movie/"], mode: .inPlace, scrapeOnly: true)
        let sReady = try await waitForTask(tmScrape, id: sId) { $0.stage == .awaitingReview }
        #expect(sReady.scrapeOnly)
        #expect(sReady.scrape)
        try await tmScrape.run(sId)
        #expect(await fsScrape.allFilePaths() == [
            "/in/Movie/Inception.2010.mkv",
            "/in/Movie/Inception.2010.nfo",
        ])
        await tmScrape.dispose()

        // 2. Two tasks run concurrently; watchAll orders newest first; retry clears stale review & ignores cancelled gen
        let fsConc = MemoryStorageBackend(initialSizes: sampleLibrary())
        let recConc = FakeRecognizer()
        let gate = AsyncGate()
        recConc.gateBox.value = gate
        let storeConc = SpyTaskStore()
        let hConc = MemoryHistoryStore()
        let tmConc = DefaultTaskManager(
            backendFor: { _ in fsConc },
            recognizer: recConc,
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hConc, sleepMs: { _ in }),
            history: hConc,
            store: storeConc,
            options: { _, mode in PlanOptions(mode: mode) },
            importUpdateIntervalMs: 0
        )
        let idA = try await tmConc.submit(connection: testConn, paths: ["/in/Good"], mode: .inPlace)
        let idB = try await tmConc.submit(connection: testConn, paths: ["/in/Mixed/b.mkv"], mode: .inPlace)
        _ = try await waitForTask(tmConc, id: idA) { $0.stage == .recognizing }
        _ = try await waitForTask(tmConc, id: idB) { $0.stage == .recognizing }

        // Cancel idA mid-recognition, add a new file, and retry idA BEFORE old recognizer completes
        await tmConc.cancel(idA)
        recConc.gateBox.value = nil
        await fsConc.addFile("/in/Good/b.mkv")
        try await tmConc.retry(idA)
        _ = try await waitForTask(tmConc, id: idA) { $0.stage == .awaitingReview }
        gate.open()
        _ = try await waitForTask(tmConc, id: idB) { $0.stage == .awaitingReview }

        let orderedIds = (await tmConc.currentSummaries()).map(\.id)
        #expect(orderedIds == [idB, idA])
        let revA = try await tmConc.review(idA)
        #expect(revA.scan.groups.first?.files.map(\.path) == ["/in/Good/a.mkv", "/in/Good/a.srt", "/in/Good/b.mkv"])
        let revB = try await tmConc.review(idB)
        #expect(revB.scan.groups.first?.files.count == 1)
        await tmConc.dispose()

        // 3. Reopening awaitingReview reflects updated naming profile without rescan; concurrent review coalesces
        let namingBox = LockedBox(NamingProfile.vidhub)
        let storeNaming = SpyTaskStore()
        let tidNaming = TaskId("t-naming")
        let gidNaming = GroupId("g1")
        try await storeNaming.saveSummary(
            TaskSummary(id: tidNaming, connection: testConn, paths: ["/d"], mode: .inPlace, stage: .awaitingReview, createdAt: Date())
        )
        try await storeNaming.saveReview(
            id: tidNaming,
            scan: ScanResult(
                connection: testConn,
                roots: ["/d"],
                groups: [
                    MediaGroup(
                        id: gidNaming,
                        kind: .episode,
                        anchorTitle: "Show",
                        rootDir: "/d/Show",
                        files: [
                            ScanFile(
                                path: "/d/Show/a.mkv",
                                name: "a.mkv",
                                size: 1,
                                role: .video,
                                parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9)
                            ),
                        ],
                        match: Candidate(tmdbId: 1, kind: .episode, title: "Show"),
                        matchScore: 0.95
                    ),
                ]
            ),
            decisions: [gidNaming: GroupDecision()],
            unassignedDeletes: [:]
        )
        let fsNaming = MemoryStorageBackend(initialSizes: ["/d/Show/a.mkv": 1])
        let plannerNaming = FakePlanner()
        plannerNaming.delayMsBox.value = 10
        let recNaming = FakeRecognizer()
        let hNaming = MemoryHistoryStore()
        let tmNaming = DefaultTaskManager(
            backendFor: { _ in fsNaming },
            recognizer: recNaming,
            planner: plannerNaming,
            executor: DefaultExecutor(history: hNaming, sleepMs: { _ in }),
            history: hNaming,
            store: storeNaming,
            options: { _, mode in PlanOptions(mode: mode, naming: namingBox.value) }
        )
        async let c1 = tmNaming.review(tidNaming)
        async let c2 = tmNaming.review(tidNaming)
        async let c3 = tmNaming.review(tidNaming)
        let coalesced = try await [c1, c2, c3]
        #expect(coalesced.count == 3)
        #expect(plannerNaming.callsBox.value == 1)
        #expect(await storeNaming.loadReviewCalls == [tidNaming])

        namingBox.withValue { $0.tv.customTemplate = "CHANGED.S{season:02}E{episode:02}" }
        let updatedRev = try await tmNaming.review(tidNaming)
        #expect(updatedRev.preview.ops.first { $0.src == "/d/Show/a.mkv" }?.dst.contains("CHANGED.S01E01") == true)
        #expect(recNaming.calls == 0)

        try await tmNaming.run(tidNaming)
        #expect(await fsNaming.allFilePaths() == ["/d/Show (2020)/Season 01/CHANGED.S01E01.mkv"])
        namingBox.value = .vidhub
        let finishedRev = try await tmNaming.review(tidNaming)
        #expect(finishedRev.preview.ops.first { $0.src == "/d/Show/a.mkv" }?.dst.contains("CHANGED.S01E01") == true)
        await tmNaming.dispose()

        // 4. Missing connection in resumeInterrupted / retryFailed / undo settles cleanly without sticking
        let missingConn = ConnectionId("missing")
        let storeMiss = SpyTaskStore()
        let hMiss = MemoryHistoryStore()
        let badId = TaskId("t-bad-conn")
        try await storeMiss.saveSummary(
            TaskSummary(
                id: badId,
                connection: missingConn,
                paths: ["/in"],
                mode: .inPlace,
                stage: .renamingFiles,
                batch: BatchId("b-miss"),
                createdAt: Date()
            )
        )
        let tmMiss = DefaultTaskManager(
            backendFor: { c in
                if c == missingConn { throw TidyreelExecutionError.invalidState("连接已删除") }
                return MemoryStorageBackend()
            },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: hMiss, sleepMs: { _ in }),
            history: hMiss,
            store: storeMiss,
            options: { _, mode in PlanOptions(mode: mode) }
        )
        try await tmMiss.resumeInterrupted()
        let s1 = (await tmMiss.currentSummaries()).first { $0.id == badId }!
        #expect(s1.stage == .partiallyFailed)
        #expect(s1.message.contains("恢复执行失败"))

        try await tmMiss.retryFailed(badId)
        let s2 = (await tmMiss.currentSummaries()).first { $0.id == badId }!
        #expect(s2.stage == .partiallyFailed)
        #expect(s2.message.contains("重试失败"))

        try await tmMiss.undo(badId)
        let s3 = (await tmMiss.currentSummaries()).first { $0.id == badId }!
        #expect(s3.message.contains("撤销失败"))
        #expect(s3.progress == nil)
        await tmMiss.dispose()
    }

    @Test("Batch edits use targeted saveDecisions, LRU evicts inactive awaitingReview tasks, and onPathsMutated fires")
    func targetedDecisionSaveLruEvictionAndMutatedCallback() async throws {
        let fs = MemoryStorageBackend(initialSizes: [
            "/in/A/a.mkv": 1,
            "/in/A/ad1.txt": 1,
            "/in/A/ad2.txt": 1,
            "/in/B/sub/b.mkv": 1,
        ])
        let store = SpyTaskStore(supportsTargetedDecisionSave: true)
        let history = MemoryHistoryStore()
        let mutatedEvents = LockedBox<[(ConnectionId, [String])]>([])

        let tm = DefaultTaskManager(
            backendFor: { _ in fs },
            recognizer: FakeRecognizer(),
            planner: FakePlanner(),
            executor: DefaultExecutor(history: history, sleepMs: { _ in }),
            history: history,
            store: store,
            options: { _, mode in PlanOptions(mode: mode, libraryRoot: "/lib") },
            importUpdateIntervalMs: 0,
            onPathsMutated: { conn, dirs in
                mutatedEvents.withValue { $0.append((conn, dirs)) }
            }
        )

        let id1 = try await tm.submit(connection: testConn, paths: ["/in"], mode: .inPlace)
        _ = try await waitForTask(tm, id: id1) { $0.stage == .awaitingReview }
        #expect(await store.saveReviewCalls == 1)
        #expect(await store.saveDecisionsCalls == 0)

        // Batch updateDecisions & setUnassignedDeletes use targeted saveDecisions (no full scan_blob rewrite)
        let gA = GroupId("g:/in/A")
        let gB = GroupId("g:/in/B/sub")
        let revBatch = try await tm.updateDecisions(id1, updates: [
            (group: gA, decision: GroupDecision(selected: false)),
            (group: gB, decision: GroupDecision(episodeOffset: 2)),
        ])
        #expect(revBatch.decisions[gA]?.selected == false)
        #expect(revBatch.decisions[gB]?.episodeOffset == 2)
        #expect(await store.saveReviewCalls == 1)
        #expect(await store.saveDecisionsCalls == 1)
        #expect(await store.lastCardMeta?.unassignedCount == 2)

        let revDeletes = try await tm.setUnassignedDeletes(id1, updates: [
            "/in/A/ad1.txt": true,
            "/in/A/ad2.txt": true,
        ])
        let delSelected = revDeletes.preview.ops.filter { $0.kind == .delete && $0.selected }
        #expect(delSelected.count == 2)
        #expect(await store.saveReviewCalls == 1)
        #expect(await store.saveDecisionsCalls == 2)

        // Second awaitingReview task evicts first inactive awaitingReview task from RAM (LRU = 1)
        let id2 = try await tm.submit(connection: testConn, paths: ["/in/B"], mode: .moveToLibrary)
        _ = try await waitForTask(tm, id: id2) { $0.stage == .awaitingReview }
        #expect(await tm.hasCachedReview(id2) == true)
        #expect(await tm.hasCachedReview(id1) == false)

        // Run, removeEmptyDirs, and undo each fire onPathsMutated
        try await tm.run(id2)
        #expect(mutatedEvents.value.count == 1)
        #expect(mutatedEvents.value[0].0 == testConn)
        #expect(mutatedEvents.value[0].1.contains("/in/B/sub"))

        let emptyDirs = try await tm.findEmptyDirs(id2)
        #expect(emptyDirs == ["/in/B/sub"])
        let removedCount = try await tm.removeEmptyDirs(id2, dirs: emptyDirs)
        #expect(removedCount == 1)
        #expect(mutatedEvents.value.count == 2)
        #expect(mutatedEvents.value[1].1 == ["/in/B"])

        try await tm.undo(id2)
        #expect(mutatedEvents.value.count == 3)
        #expect(mutatedEvents.value[2].1.contains("/in/B/sub"))
        await tm.dispose()
    }
}
