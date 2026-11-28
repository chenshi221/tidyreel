import Foundation
import Testing
@testable import TidyreelExecution
import TidyreelFakes
import TidyreelModels

private final class OpIdGen: @unchecked Sendable {
    private let box = LockedBox(0)

    func next() -> OpId {
        let n = box.withValue { v -> Int in
            v += 1
            return v
        }
        return OpId("op\(n)")
    }
}

private let idGen = OpIdGen()
private let testTask = TaskId("T1-aaaaaa")
private let testConn = ConnectionId("c1")

private func reloc(
    _ src: String,
    _ dst: String,
    phase: ExecPhase = .files,
    selected: Bool = true
) -> RenameOp {
    RenameOp(
        id: idGen.next(),
        kind: .relocate,
        phase: phase,
        src: src,
        dst: dst,
        selected: selected
    )
}

private func mkdirOp(_ dir: String) -> RenameOp {
    RenameOp(
        id: idGen.next(),
        kind: .mkdir,
        phase: .files,
        src: "",
        dst: dir
    )
}

private func delOp(_ path: String) -> RenameOp {
    RenameOp(
        id: idGen.next(),
        kind: .delete,
        phase: .cleanup,
        src: path,
        dst: "",
        deleteIdentity: "seed:" + path
    )
}

private func sampleTree() -> [String: Int] {
    [
        "/d/Show.S01/a.mkv": 1,
        "/d/Show.S01/b.mkv": 2,
        "/d/Show.S01/a.srt": 3,
        "/d/Movie.mkv": 4,
        "/d/junk.txt": 5,
    ]
}

private func samplePlanOps() -> [RenameOp] {
    [
        reloc("/d/Show.S01", "/d/Show (2020)", phase: .folders),
        mkdirOp("/d/Movie (2010)"),
        reloc("/d/Show.S01/a.mkv", "/d/Show.S01/Season 01/Show.S01E01.mkv"),
        reloc("/d/Show.S01/b.mkv", "/d/Show.S01/Season 01/Show.S01E02.mkv"),
        reloc("/d/Show.S01/a.srt", "/d/Show.S01/Season 01/Show.S01E01.zh-Hans.srt"),
        reloc("/d/Movie.mkv", "/d/Movie (2010)/Movie.2010.mkv"),
        delOp("/d/junk.txt"),
    ]
}

private let expectedFinalFiles = [
    "/d/Movie (2010)/Movie.2010.mkv",
    "/d/Show (2020)/Season 01/Show.S01E01.mkv",
    "/d/Show (2020)/Season 01/Show.S01E01.zh-Hans.srt",
    "/d/Show (2020)/Season 01/Show.S01E02.mkv",
]

private func makeExecutor(
    _ history: any HistoryStore,
    delays: LockedBox<[Int]>? = nil
) -> DefaultExecutor {
    DefaultExecutor(
        history: history,
        minIntervalMs: 0,
        sleepMs: { ms in delays?.withValue { $0.append(ms) } }
    )
}

private func firstBatch(_ history: any HistoryStore) async throws -> BatchId {
    try await history.batches()[0].id
}

private actor CountingHistoryStore: HistoryStore {
    let inner = MemoryHistoryStore()
    var recordQueries = 0
    var markCalls = 0
    var markBatchCalls = 0

    func resetQueries() {
        recordQueries = 0
        markCalls = 0
        markBatchCalls = 0
    }

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
        markCalls += 1
        try await inner.mark(batch: batch, op: op, status: status, error: error)
    }

    func markBatch(batch: BatchId, updates: [(op: OpId, status: OpStatus, error: String?)]) async throws {
        markBatchCalls += 1
        try await inner.markBatch(batch: batch, updates: updates)
    }

    func records(batch: BatchId) async throws -> [HistoryRecord] {
        recordQueries += 1
        return try await inner.records(batch: batch)
    }

    func batches() async throws -> [BatchSummary] {
        try await inner.batches()
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

/// Wrapper named `ThrottledBackend` + outer `CachedBackend` to test double-wrap avoidance.
private final class ThrottledBackend: StorageBackend, @unchecked Sendable {
    let inner: any StorageBackend
    init(_ inner: any StorageBackend) { self.inner = inner }
    var supportsServerBatching: Bool { inner.supportsServerBatching }
    var supportsAtomicRelocate: Bool { inner.supportsAtomicRelocate }
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { try await inner.list(dir, refresh: refresh) }
    func mkdirs(_ dir: String) async throws { try await inner.mkdirs(dir) }
    func rename(_ path: String, newName: String) async throws { try await inner.rename(path, newName: newName) }
    func atomicRelocate(from src: String, to dst: String) async throws { try await inner.atomicRelocate(from: src, to: dst) }
    func renameMany(_ dir: String, names: [String: String]) async throws { try await inner.renameMany(dir, names: names) }
    func move(srcDir: String, dstDir: String, names: [String]) async throws { try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names) }
    func removeScannedFile(_ path: String, identity: String?) async throws { try await inner.removeScannedFile(path, identity: identity) }
    func remove(dir: String, names: [String]) async throws { try await inner.remove(dir: dir, names: names) }
    func exists(_ path: String) async throws -> Bool { try await inner.exists(path) }
    func read(_ path: String) async throws -> Data { try await inner.read(path) }
    func write(_ path: String, bytes: Data) async throws { try await inner.write(path, bytes: bytes) }
    func ping() async throws { try await inner.ping() }
    func close() async { await inner.close() }
}

private final class CachedBackend: StorageBackend, @unchecked Sendable {
    let inner: any StorageBackend
    init(_ inner: any StorageBackend) { self.inner = inner }
    var supportsServerBatching: Bool { inner.supportsServerBatching }
    var supportsAtomicRelocate: Bool { inner.supportsAtomicRelocate }
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { try await inner.list(dir, refresh: refresh) }
    func mkdirs(_ dir: String) async throws { try await inner.mkdirs(dir) }
    func rename(_ path: String, newName: String) async throws { try await inner.rename(path, newName: newName) }
    func atomicRelocate(from src: String, to dst: String) async throws { try await inner.atomicRelocate(from: src, to: dst) }
    func renameMany(_ dir: String, names: [String: String]) async throws { try await inner.renameMany(dir, names: names) }
    func move(srcDir: String, dstDir: String, names: [String]) async throws { try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names) }
    func removeScannedFile(_ path: String, identity: String?) async throws { try await inner.removeScannedFile(path, identity: identity) }
    func remove(dir: String, names: [String]) async throws { try await inner.remove(dir: dir, names: names) }
    func exists(_ path: String) async throws -> Bool { try await inner.exists(path) }
    func read(_ path: String) async throws -> Data { try await inner.read(path) }
    func write(_ path: String, bytes: Data) async throws { try await inner.write(path, bytes: bytes) }
    func ping() async throws { try await inner.ping() }
    func close() async { await inner.close() }
}

@Suite("DefaultExecutor Tests")
struct ExecutorTests {
    @Test("Settling a finished task does not wait for a different task blocked on storage")
    func independentExecutionWorkers() async throws {
        let executor = makeExecutor(MemoryHistoryStore())
        let entered = AsyncGate()
        let release = AsyncGate()
        let slow = executor.makeStream(owner: .task("slow")) { _, _ in
            entered.open()
            await release.wait()
        }
        let consumer = Task { try await collectStream(slow) }
        await entered.wait()
        // Release a broken global wait too, so a regression fails without hanging the suite.
        let timedOut = LockedBox(false)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            timedOut.value = true
            release.open()
        }
        let fast = executor.makeStream(owner: .task("fast")) { _, _ in }
        _ = try await collectStream(fast)
        await executor.waitForSettled(owner: .task("fast"))
        #expect(!timedOut.value)
        timeout.cancel()
        release.open()
        _ = try await consumer.value
    }

    @Test("Happy path runs files, then folders, then cleanup")
    func happyPathPhaseOrder() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let events = try await collectStream(
            makeExecutor(history).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: samplePlanOps()),
                backend: fs
            )
        )
        #expect(await fs.allFilePaths() == expectedFinalFiles)
        let b = try await firstBatch(history)
        #expect(statusCounts(try await history.records(batch: b)) == [.done: 7])
        #expect(Set(events.map(\.phase)) == Set(ExecPhase.allCases))
        let rankMap: [ExecPhase: Int] = [.files: 0, .folders: 1, .cleanup: 2]
        let ranks = events.map { rankMap[$0.phase]! }
        #expect(ranks == ranks.sorted())
        let filesEvents = events.filter { $0.phase == .files }
        #expect(filesEvents.last?.done == 5)
        #expect(filesEvents.last?.total == 5)
        #expect(try await history.isOrganized(connection: testConn, path: "/d/Movie (2010)/Movie.2010.mkv"))
    }

    @Test("Same-name op is done, organized, and undoes to nothing")
    func sameNameOp() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let f = "/d/Movie.mkv"
        let before = await fs.allFilePaths()
        _ = try await collectStream(
            makeExecutor(history).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [reloc(f, f)]),
                backend: fs
            )
        )
        let b = try await firstBatch(history)
        #expect(statusCounts(try await history.records(batch: b)) == [.done: 1])
        #expect(try await history.isOrganized(connection: testConn, path: f))
        #expect(await fs.allFilePaths() == before)
        _ = try await collectStream(makeExecutor(history).undo(batch: b, backend: fs))
        #expect(await fs.allFilePaths() == before)
    }

    @Test("Refuses plans with conflicts and skips unselected ops")
    func refusesConflictsAndUnselected() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let bad = RenamePlan(
            ops: samplePlanOps(),
            conflicts: [PlanConflict(ops: [], path: "/x", reason: "dup")]
        )
        await #expect(throws: TidyreelExecutionError.self) {
            try await collectStream(
                makeExecutor(history).execute(task: testTask, connection: testConn, plan: bad, backend: fs)
            )
        }
        #expect((try await history.batches()).isEmpty)
        #expect(await fs.allFilePaths() == sampleTree().keys.sorted())

        _ = try await collectStream(
            makeExecutor(history).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [reloc("/d/Movie.mkv", "/d/M.mkv", selected: false)]),
                backend: fs
            )
        )
        #expect(await fs.allFilePaths() == sampleTree().keys.sorted())
        let b = try await firstBatch(history)
        #expect((try await history.records(batch: b)).isEmpty)
    }

    @Test("An interrupted health confirmation cannot auto-resume through the organizer")
    func healthBatchCannotResume() async throws {
        let fs = MemoryStorageBackend(initialSizes: ["/a": 1])
        let history = MemoryHistoryStore()
        let op = RenameOp(id: "a", kind: .healthDeleteFile, phase: .cleanup,
                          src: "/a", dst: "", deleteIdentity: "seed:/a")
        let batch = try await history.beginBatch(task: "health-confirmation", connection: testConn, ops: [op])
        await #expect(throws: TidyreelExecutionError.self) {
            _ = try await collectStream(makeExecutor(history).resume(batch: batch, backend: fs))
        }
        #expect(try await fs.exists("/a"))
        #expect(try await history.records(batch: batch).first?.status == .pending)
    }

    @Test("Resume preserves replacements and files named by legacy delete records")
    func conditionalDeleteRecovery() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: ["/a": 1, "/b": 2])
        let identity = try #require(try await fs.list("/").first(where: { $0.name == "a" })?.deleteIdentity)
        let ops = [
            RenameOp(id: "a", kind: .delete, phase: .cleanup, src: "/a", dst: "", deleteIdentity: identity),
            RenameOp(id: "b", kind: .delete, phase: .cleanup, src: "/b", dst: ""),
        ]
        let batch = try await history.beginBatch(task: testTask, connection: testConn, ops: ops)
        try await fs.removeScannedFile("/a", identity: identity)
        try await fs.write("/a", bytes: Data([7]))
        _ = try await collectStream(makeExecutor(history).resume(batch: batch, backend: fs))
        #expect(try await fs.read("/a") == Data([7]))
        #expect(try await fs.exists("/b"))
        #expect(try await history.records(batch: batch).allSatisfy { $0.status == .failed })
    }

    @Test("Write-ahead log is written before storage is touched")
    func walBeforeStorage() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let seenBatchCounts = LockedBox<[Int]>([])
        let be = HookBackend(fs) { m, _ in
            if m != "exists" {
                let count = (try? await history.batches().count) ?? 0
                seenBatchCounts.withValue { $0.append(count) }
            }
        }
        _ = try await collectStream(
            makeExecutor(history).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: samplePlanOps()),
                backend: be
            )
        )
        #expect(!seenBatchCounts.value.isEmpty)
        #expect(seenBatchCounts.value.allSatisfy { $0 == 1 })
    }

    @Test("Failed op does not stop independent ops; dependants are skipped and failed file rolls back")
    func failedOpIsolationAndDependencySkip() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let ops = [
            reloc("/d/Show.S01/a.mkv", "/d/Show.S01/Season 01/Show.S01E01.mkv"),
            reloc("/d/Show.S01/b.mkv", "/d/Show.S01/Season 01/Show.S01E02.mkv"),
            reloc("/d/Movie.mkv", "/d/Movie (2010)/Movie.2010.mkv"),
            reloc("/d/Show.S01", "/d/Show (2020)", phase: .folders),
            reloc("/d/Show.S01/Season 01", "/d/Show.S01/S1", phase: .folders),
        ]
        let bId = ops[1].id.value
        let be = HookBackend(fs) { m, a in
            if m == "move" && (a.contains("Show.S01E02.mkv") || a.contains(".tidyreel-tmp-\(bId)")) {
                throw StorageError(.other, "boom")
            }
            if m == "rename" && a.first == "/d/Show.S01" {
                throw StorageError(.other, "folder boom")
            }
        }
        let events = try await collectStream(
            makeExecutor(history).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: ops),
                backend: be
            )
        )
        let recs = try await history.records(batch: firstBatch(history))
        let counts = statusCounts(recs)
        #expect(counts[.done] == 2)
        #expect(counts[.failed] == 2)
        #expect(counts[.skipped] == 1)
        #expect(events.filter { $0.error != nil }.count == 3)
        #expect((await fs.allFilePaths()).contains("/d/Show.S01/b.mkv"))
    }

    @Test("Crash after N ops then resume ends in exact final tree")
    func crashAndResume() async throws {
        for n in [1, 3, 5] {
            let h = MemoryHistoryStore()
            let f = MemoryStorageBackend(initialSizes: sampleTree())
            let ex = DefaultExecutor(
                history: h,
                concurrencyProvider: { 1 },
                minIntervalMs: 0,
                sleepMs: { _ in }
            )
            let p = RenamePlan(ops: samplePlanOps())
            var seen = 0
            for try await _ in ex.execute(task: testTask, connection: testConn, plan: p, backend: f) {
                seen += 1
                if seen == n { break }
            }
            await ex.waitForSettled()

            let b = try await firstBatch(h)
            let left = (try await h.records(batch: b)).filter { $0.status == .pending }
            #expect(!left.isEmpty)

            // Simulate a crash right between storage mutation and history.mark
            if let pendingOp = left.first?.op,
               pendingOp.kind == .relocate,
               pendingOp.phase == .files
            {
                let dstName = baseOf(pendingOp.dst)
                let dstDir = dirOf(pendingOp.dst)
                let srcDir = dirOf(pendingOp.src)
                try await f.rename(pendingOp.src, newName: dstName)
                try await f.mkdirs(dstDir)
                try await f.move(srcDir: srcDir, dstDir: dstDir, names: [dstName])
            }

            _ = try await collectStream(ex.resume(batch: b, backend: f))
            #expect(await f.allFilePaths() == expectedFinalFiles)
            #expect(statusCounts(try await h.records(batch: b)) == [.done: 7])
        }
    }

    @Test("Resume continues from half-finished cross-directory relocate (dstTmp and srcTmp)")
    func resumeHalfFinishedCrossDirRelocate() async throws {
        // 1. Parked in dstDir
        let history1 = MemoryHistoryStore()
        let op1 = reloc("/d/x/a.mkv", "/d/y/b.mkv")
        let f1 = MemoryStorageBackend(initialSizes: ["/d/x/a.mkv": 1, "/d/x/b.mkv": 2])
        let b1 = try await history1.beginBatch(task: testTask, connection: testConn, ops: [op1])
        try await f1.rename("/d/x/a.mkv", newName: ".tidyreel-tmp-\(op1.id.value)")
        try await f1.mkdirs("/d/y")
        try await f1.move(srcDir: "/d/x", dstDir: "/d/y", names: [".tidyreel-tmp-\(op1.id.value)"])
        _ = try await collectStream(makeExecutor(history1).resume(batch: b1, backend: f1))
        #expect(await f1.allFilePaths() == ["/d/x/b.mkv", "/d/y/b.mkv"])
        #expect(statusCounts(try await history1.records(batch: b1)) == [.done: 1])

        // 2. Parked in srcDir with missing dstDir
        let history2 = MemoryHistoryStore()
        let op2 = reloc("/d/x/a.mkv", "/d/missing_dst/b.mkv")
        let f2 = MemoryStorageBackend(initialSizes: ["/d/x/a.mkv": 1])
        let b2 = try await history2.beginBatch(task: testTask, connection: testConn, ops: [op2])
        try await f2.rename("/d/x/a.mkv", newName: ".tidyreel-tmp-\(op2.id.value)")
        _ = try await collectStream(makeExecutor(history2).resume(batch: b2, backend: f2))
        #expect(await f2.allFilePaths() == ["/d/missing_dst/b.mkv"])
        #expect(statusCounts(try await history2.records(batch: b2)) == [.done: 1])
    }

    @Test("Retrying an interrupted write undo keeps the replacement at the original path")
    func interruptedWriteUndo() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend()
        let executor = makeExecutor(history)
        let op = RenameOp(id: idGen.next(), kind: .write, phase: .cleanup,
                          src: "\(writeTextPrefix)original", dst: "/poster.nfo")
        _ = try await collectStream(executor.execute(task: testTask, connection: testConn,
                                                     plan: RenamePlan(ops: [op]), backend: fs))
        let batch = try await firstBatch(history)
        let interrupted = HookBackend(fs) { method, _ in
            if method == "remove" {
                try await fs.write(op.dst, bytes: Data("replacement".utf8))
                throw StorageError(.other, "interrupted")
            }
        }
        _ = try await collectStream(executor.undo(batch: batch, backend: interrupted))
        #expect(try await history.records(batch: batch).first?.status == .done)
        _ = try await collectStream(executor.undo(batch: batch, backend: fs))
        #expect(await fs.textOf(op.dst) == "replacement")
        #expect(await fs.allFilePaths() == [op.dst])
        #expect(try await history.records(batch: batch).first?.status == .undone)

        let legacy = try await history.beginBatch(task: testTask, connection: testConn, ops: [op])
        try await history.mark(batch: legacy, op: op.id, status: .done)
        _ = try await collectStream(executor.undo(batch: legacy, backend: fs))
        #expect(await fs.textOf(op.dst) == "replacement")
        #expect(try await history.records(batch: legacy).first?.status == .skipped)
    }

    @Test("Write ops create text and downloaded files; overwrite swaps safely; undo behaves safely")
    func writeAndOverwriteSafety() async throws {
        let history = MemoryHistoryStore()
        let fs = MemoryStorageBackend(initialSizes: sampleTree())
        let fetched = LockedBox<[URL]>([])
        let ex = DefaultExecutor(
            history: history,
            minIntervalMs: 0,
            sleepMs: { _ in },
            fetchUrl: { url in
                fetched.withValue { $0.append(url) }
                return Data([1, 2, 3])
            }
        )
        func writeOp(_ dst: String, _ src: String, overwrite: Bool = false) -> RenameOp {
            RenameOp(id: idGen.next(), kind: .write, phase: .cleanup, src: src, dst: dst, overwrite: overwrite)
        }

        _ = try await collectStream(
            ex.execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [
                    writeOp("/d/Show.S01/tvshow.nfo", "\(writeTextPrefix)<tvshow>中</tvshow>"),
                    writeOp("/d/Show.S01/poster.jpg", "https://image.tmdb.org/t/p/w780/p.jpg"),
                    writeOp("/d/junk.txt", "\(writeTextPrefix)x"), // existing -> refused
                ]),
                backend: fs
            )
        )
        #expect(await fs.textOf("/d/Show.S01/tvshow.nfo") == "<tvshow>中</tvshow>")
        #expect(try await fs.read("/d/Show.S01/poster.jpg") == Data([1, 2, 3]))
        #expect(fetched.value.count == 1)
        #expect(fetched.value[0].path == "/t/p/w780/p.jpg")

        let b = try await firstBatch(history)
        #expect(statusCounts(try await history.records(batch: b)) == [.done: 2, .failed: 1])
        #expect(try await fs.read("/d/junk.txt") == Data(count: 5))

        _ = try await collectStream(ex.undo(batch: b, backend: fs))
        #expect(!(try await fs.exists("/d/Show.S01/tvshow.nfo")))
        #expect(!(try await fs.exists("/d/Show.S01/poster.jpg")))

        let modified = writeOp("/d/user-edited.nfo", "\(writeTextPrefix)original")
        _ = try await collectStream(ex.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: [modified]), backend: fs))
        try await fs.remove(dir: "/d", names: ["user-edited.nfo"])
        try await fs.write(modified.dst, bytes: Data("user edit".utf8))
        let modifiedBatch = try await firstBatch(history)
        _ = try await collectStream(ex.undo(batch: modifiedBatch, backend: fs))
        #expect(await fs.textOf(modified.dst) == "user edit")
        #expect(try await history.records(batch: modifiedBatch).first?.status == .skipped)

        // Overwrite: true backs up original before swap and undo skips deletion
        let fOver = MemoryStorageBackend()
        try await fOver.write("/d/movie.nfo", bytes: Data("<movie>old</movie>".utf8))
        let hook = HookBackend(fOver)
        let hOver = MemoryHistoryStore()
        let exOver = makeExecutor(hOver)
        let overOp = RenameOp(
            id: OpId("w-over"),
            kind: .write,
            phase: .cleanup,
            src: "\(writeTextPrefix)<movie>new</movie>",
            dst: "/d/movie.nfo",
            overwrite: true
        )
        _ = try await collectStream(
            exOver.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: [overOp]), backend: hook)
        )
        #expect(await fOver.textOf("/d/movie.nfo") == "<movie>new</movie>")
        #expect(await fOver.allFilePaths() == ["/d/movie.nfo"])

        let calls = hook.calls
        let writeIdx = calls.firstIndex { $0.hasPrefix("write /d/.tidyreel-tmp-w-over-movie.nfo") }!
        let backupIdx = calls.firstIndex { $0 == "rename /d/movie.nfo .tidyreel-bak-w-over-movie.nfo" }!
        let renameIdx = calls.firstIndex { $0 == "rename /d/.tidyreel-tmp-w-over-movie.nfo movie.nfo" }!
        let removeBakIdx = calls.firstIndex { $0 == "remove /d .tidyreel-bak-w-over-movie.nfo" }!
        #expect(backupIdx > writeIdx)
        #expect(renameIdx > backupIdx)
        #expect(removeBakIdx > renameIdx)

        let bOver = try await firstBatch(hOver)
        let undoEvents = try await collectStream(exOver.undo(batch: bOver, backend: fOver))
        #expect(await fOver.textOf("/d/movie.nfo") == "<movie>new</movie>")
        #expect(statusCounts(try await hOver.records(batch: bOver)) == [.skipped: 1])
        #expect(undoEvents.first?.error == "覆盖写入无法撤销")

        // Overwrite: true restores backup on final rename failure
        let hookFail = HookBackend(fOver) { m, a in
            if m == "rename" && a.first == "/d/.tidyreel-tmp-w-fail-ren-movie.nfo" && a.last == "movie.nfo" {
                throw StorageError(.other, "rename fail")
            }
        }
        _ = try await collectStream(
            exOver.execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [
                    RenameOp(
                        id: OpId("w-fail-ren"),
                        kind: .write,
                        phase: .cleanup,
                        src: "\(writeTextPrefix)<movie>broken</movie>",
                        dst: "/d/movie.nfo",
                        overwrite: true
                    ),
                ]),
                backend: hookFail
            )
        )
        #expect(await fOver.textOf("/d/movie.nfo") == "<movie>new</movie>")
        #expect(await fOver.allFilePaths() == ["/d/movie.nfo"])
    }

    @Test("Undo restores exact original tree, skips deletes/non-empty mkdirs, and never overwrites occupied paths")
    func undoSafetyAndBatching() async throws {
        // 1. Exact restore
        let history1 = MemoryHistoryStore()
        let fs1 = MemoryStorageBackend(initialSizes: sampleTree())
        let ex1 = makeExecutor(history1)
        let sixOps = Array(samplePlanOps().prefix(6))
        _ = try await collectStream(
            ex1.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: sixOps), backend: fs1)
        )
        #expect(await fs1.allFilePaths() != sampleTree().keys.sorted())
        let b1 = try await firstBatch(history1)
        let events1 = try await collectStream(ex1.undo(batch: b1, backend: fs1))
        #expect(await fs1.allFilePaths() == sampleTree().keys.sorted())
        #expect(statusCounts(try await history1.records(batch: b1)) == [.undone: 6])
        #expect(events1.count == 6)
        #expect(events1.allSatisfy { $0.error == nil })
        #expect((try await history1.batches())[0].undone)

        // 2. Batch undo avoids per-file exists() and redundant records() queries
        let countingHistory = CountingHistoryStore()
        var twelveSizes: [String: Int] = [:]
        for i in 1...12 { twelveSizes["/s/raw/ep\(i).mkv"] = i }
        let mem = MemoryStorageBackend(initialSizes: twelveSizes)
        let beforeMem = await mem.allFilePaths()
        var batchOps = [mkdirOp("/s/raw/Season 01")]
        for i in 1...12 {
            batchOps.append(reloc("/s/raw/ep\(i).mkv", "/s/raw/Season 01/Show.S01E\(i).mkv"))
        }
        batchOps.append(reloc("/s/raw", "/s/Show (2026)", phase: .folders))
        let ex2 = makeExecutor(countingHistory)
        _ = try await collectStream(
            ex2.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: batchOps), backend: mem)
        )
        let b2 = try await firstBatch(countingHistory)
        await countingHistory.resetQueries()
        let hook2 = HookBackend(mem)
        let alist2 = AlistBackend(hook2)
        _ = try await collectStream(ex2.undo(batch: b2, backend: alist2))
        #expect(await mem.allFilePaths() == beforeMem)
        #expect(await countingHistory.recordQueries == 1)
        #expect(await countingHistory.markBatchCalls == 1)
        #expect(hook2.calls.filter { $0.hasPrefix("move ") }.count == 1)
        #expect(hook2.calls.filter { $0.hasPrefix("exists") }.count < 4)

        // 3. Skips delete and non-empty mkdir
        let history3 = MemoryHistoryStore()
        let fs3 = MemoryStorageBackend(initialSizes: sampleTree())
        let ex3 = makeExecutor(history3)
        _ = try await collectStream(
            ex3.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: samplePlanOps()), backend: fs3)
        )
        let b3 = try await firstBatch(history3)
        await fs3.addFile("/d/Movie (2010)/extra.txt")
        let events3 = try await collectStream(ex3.undo(batch: b3, backend: fs3))
        let byKind = Dictionary(
            (try await history3.records(batch: b3)).map { ($0.op.kind, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        #expect(byKind[.delete]?.status == .skipped)
        #expect(byKind[.mkdir]?.status == .skipped)
        #expect(events3.filter { $0.error != nil }.count == 2)
        #expect((await fs3.allFilePaths()).contains("/d/Movie (2010)/extra.txt"))
        #expect((await fs3.allFilePaths()).contains("/d/Movie.mkv"))

        // 4. Never overwrites occupied original path
        let history4 = MemoryHistoryStore()
        let fs4 = MemoryStorageBackend(initialSizes: sampleTree())
        let ex4 = makeExecutor(history4)
        _ = try await collectStream(
            ex4.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: Array(samplePlanOps().prefix(6))), backend: fs4)
        )
        let b4 = try await firstBatch(history4)
        await fs4.addFile("/d/Movie.mkv", size: 99)
        _ = try await collectStream(ex4.undo(batch: b4, backend: fs4))
        let skippedKinds = Set((try await history4.records(batch: b4)).filter { $0.status == .skipped }.map { $0.op.kind })
        #expect(skippedKinds == [.relocate, .mkdir])
        #expect((await fs4.allFilePaths()).contains("/d/Movie (2010)/Movie.2010.mkv"))
        #expect((try await fs4.read("/d/Movie.mkv")).count == 99)
    }

    @Test("A landed cycle with pending journal rows is reconciled without replaying the swap")
    func landedCycleRecovery() async throws {
        let ops = [reloc("/d/a", "/d/b"), reloc("/d/b", "/d/a")]
        let h = MemoryHistoryStore()
        let b = try await h.beginBatch(task: testTask, connection: testConn, ops: ops)
        let f = MemoryStorageBackend(initialSizes: ["/d/a": 2, "/d/b": 1])
        let executor = makeExecutor(h)
        try await h.setCyclePhase(.landing, batch: b, ops: ops.map(\.id))
        _ = try await collectStream(executor.resume(batch: b, backend: f))
        func sizes() async throws -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: (try await f.list("/d", refresh: true)).map { ($0.name, $0.size) })
        }
        #expect(try await sizes() == ["a": 2, "b": 1])
        #expect(statusCounts(try await h.records(batch: b)) == [.done: 2])

        // Reverse-direction landing can lose its acknowledgement as well.
        try await h.setCyclePhase(.undoLanding, batch: b, ops: ops.map(\.id))
        try await f.rename("/d/a", newName: "hold")
        try await f.rename("/d/b", newName: "a")
        try await f.rename("/d/hold", newName: "b")
        _ = try await collectStream(executor.undo(batch: b, backend: f))
        #expect(try await sizes() == ["a": 1, "b": 2])
        #expect(statusCounts(try await h.records(batch: b)) == [.undone: 2])
    }

    @Test("A lost landing acknowledgement resumes from the committed parking boundary")
    func cycleWithLostAcknowledgement() async throws {
        let ops = [reloc("/d/a", "/d/b"), reloc("/d/b", "/d/a")]
        let files = MemoryStorageBackend(initialSizes: ["/d/a": 1, "/d/b": 2])
        let history = MemoryHistoryStore()
        let executor = makeExecutor(history)
        let backend = HookBackend(files, supportsServerBatching: true) { method, args in
            guard method == "rename", args.count == 2, args[1] == "b" else { return }
            try await files.rename(args[0], newName: args[1])
            throw StorageError(.other, "lost reply")
        }
        await #expect(throws: StorageError.self) {
            _ = try await collectStream(executor.execute(
                task: testTask, connection: testConn, plan: RenamePlan(ops: ops), backend: backend
            ))
        }
        let batch = try await firstBatch(history)
        let interrupted = try await history.records(batch: batch)
        #expect(interrupted.allSatisfy { $0.cyclePhase == .landing && $0.status == .pending })
        _ = try await collectStream(executor.resume(batch: batch, backend: files))
        #expect(statusCounts(try await history.records(batch: batch)) == [.done: 2])
        let entries = try await files.list("/d", refresh: true)
        #expect(Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.size) }) == ["a": 2, "b": 1])
    }

    @Test("Legacy cycle without a durable phase is preserved for review")
    func legacyCycleIsAmbiguous() async throws {
        let ops = [reloc("/d/a", "/d/b"), reloc("/d/b", "/d/a")]
        let h = MemoryHistoryStore()
        let b = try await h.beginBatch(task: testTask, connection: testConn, ops: ops)
        let f = MemoryStorageBackend(initialSizes: ["/d/a": 2, "/d/b": 1])
        await #expect(throws: TidyreelExecutionError.self) {
            _ = try await makeExecutor(h).performCycles(
                in: ops, batch: b, backend: f, phases: [:], undo: false, resuming: true,
                cancelled: { false }, blocked: { _ in false }, landed: { _ in Issue.record("unexpected landing") }
            )
        }
        let entries = try await f.list("/d", refresh: true)
        #expect(Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.size) }) == ["a": 2, "b": 1])
    }

    @Test("Swaps, chains, partial undo, half-applied batch undo, and parked undo recovery")
    func swapsChainsAndPartialUndo() async throws {
        func sizes(_ f: MemoryStorageBackend, _ dir: String) async throws -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: (try await f.list(dir, refresh: true)).map { ($0.name, $0.size) })
        }

        // 1. Swap and 3-cycle forward + undo + resume
        let history = MemoryHistoryStore()
        let f = MemoryStorageBackend(initialSizes: [
            "/d/01.mkv": 1,
            "/d/02.mkv": 2,
            "/d/x/a.mkv": 3,
            "/d/x/b.mkv": 4,
            "/d/x/c.mkv": 5,
        ])
        let beforeD = try await sizes(f, "/d")
        let beforeX = try await sizes(f, "/d/x")
        let ops = [
            reloc("/d/01.mkv", "/d/02.mkv"),
            reloc("/d/02.mkv", "/d/01.mkv"),
            reloc("/d/x/a.mkv", "/d/x/b.mkv"),
            reloc("/d/x/b.mkv", "/d/x/c.mkv"),
            reloc("/d/x/c.mkv", "/d/x/a.mkv"),
        ]
        let ex = makeExecutor(history)
        _ = try await collectStream(ex.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: ops), backend: f))
        #expect(try await sizes(f, "/d/x") == ["a.mkv": 5, "b.mkv": 3, "c.mkv": 4])
        let b = try await firstBatch(history)
        _ = try await collectStream(ex.undo(batch: b, backend: f))
        #expect(try await sizes(f, "/d") == beforeD)
        #expect(try await sizes(f, "/d/x") == beforeX)
        #expect(statusCounts(try await history.records(batch: b)) == [.undone: 5])

        // 2. Single-file partial undo after in-place folder rename
        let fSingle = MemoryStorageBackend(initialSizes: ["/d/raw/01.mkv": 1, "/d/raw/02.mkv": 2])
        let hSingle = MemoryHistoryStore()
        let exSingle = makeExecutor(hSingle)
        let singleOps = [
            mkdirOp("/d/raw/Season 01"),
            reloc("/d/raw/01.mkv", "/d/raw/Season 01/Show.S01E01.mkv"),
            reloc("/d/raw/02.mkv", "/d/raw/Season 01/Show.S01E02.mkv"),
            reloc("/d/raw", "/d/Show (2020)", phase: .folders),
        ]
        _ = try await collectStream(
            exSingle.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: singleOps), backend: fSingle)
        )
        let bSingle = try await firstBatch(hSingle)
        _ = try await collectStream(exSingle.undo(batch: bSingle, backend: fSingle, only: [singleOps[1].id]))
        #expect(await fSingle.allFilePaths() == [
            "/d/Show (2020)/01.mkv",
            "/d/Show (2020)/Season 01/Show.S01E02.mkv",
        ])

        // 3. Half-applied batch rename on undo finishes cleanly via retry
        let mem = MemoryStorageBackend(initialSizes: ["/s/raw/ep1.mkv": 1, "/s/raw/ep2.mkv": 2, "/s/raw/ep3.mkv": 3])
        let beforeMem = await mem.allFilePaths()
        let hHalf = MemoryHistoryStore()
        let exHalf = makeExecutor(hHalf)
        let halfOps = [
            mkdirOp("/s/raw/Season 01"),
            reloc("/s/raw/ep1.mkv", "/s/raw/Season 01/E1.mkv"),
            reloc("/s/raw/ep2.mkv", "/s/raw/Season 01/E2.mkv"),
            reloc("/s/raw/ep3.mkv", "/s/raw/Season 01/E3.mkv"),
        ]
        _ = try await collectStream(
            exHalf.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: halfOps), backend: mem)
        )
        let bHalf = try await firstBatch(hHalf)
        let hit = LockedBox(false)
        let hookHalf = HookBackend(mem, supportsServerBatching: true) { m, _ in
            if m == "renameMany" && !hit.value {
                hit.value = true
                try await mem.rename("/s/raw/Season 01/E1.mkv", newName: "ep1.mkv")
                throw StorageError(.other, "boom")
            }
        }
        _ = try await collectStream(exHalf.undo(batch: bHalf, backend: hookHalf))
        #expect(hit.value)
        #expect(await mem.allFilePaths() == beforeMem)
        #expect(statusCounts(try await hHalf.records(batch: bHalf)) == [.undone: 4])

        // 4. Retrying undo recovers files parked under .tidyreel-tmp-<id>
        let fPark = MemoryStorageBackend(initialSizes: ["/d/a.mkv": 1, "/d/b.mkv": 2, "/src/c.mkv": 3])
        let hPark = MemoryHistoryStore()
        let exPark = makeExecutor(hPark)
        let opA = reloc("/d/a.mkv", "/d/b.mkv")
        let opB = reloc("/d/b.mkv", "/d/a.mkv")
        let opC = reloc("/src/c.mkv", "/dst/c_renamed.mkv")
        _ = try await collectStream(
            exPark.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: [opA, opB, opC]), backend: fPark)
        )
        let bPark = try await firstBatch(hPark)
        try await fPark.rename("/d/b.mkv", newName: ".tidyreel-tmp-\(opA.id.value)")
        try await fPark.rename("/dst/c_renamed.mkv", newName: ".tidyreel-tmp-\(opC.id.value)")
        try await fPark.mkdirs("/src")
        try await fPark.move(srcDir: "/dst", dstDir: "/src", names: [".tidyreel-tmp-\(opC.id.value)"])
        _ = try await collectStream(exPark.undo(batch: bPark, backend: fPark))
        #expect(statusCounts(try await hPark.records(batch: bPark)) == [.undone: 3])
        #expect(await fPark.allFilePaths() == ["/d/a.mkv", "/d/b.mkv", "/src/c.mkv"])
    }

    @Test("Cross-directory collision swap, backoff retries, concurrencyProvider, Alist batching, and regressions")
    func collisionBackoffConcurrencyAndRegressions() async throws {
        // 1. Source dir sibling collision goes through .tidyreel-tmp-<id>
        let fCol = MemoryStorageBackend(initialSizes: ["/d/x/a.mkv": 1, "/d/x/b.mkv": 2])
        let hookCol = HookBackend(fCol)
        let hCol = MemoryHistoryStore()
        let opCol = reloc("/d/x/a.mkv", "/d/y/b.mkv")
        _ = try await collectStream(
            makeExecutor(hCol).execute(task: testTask, connection: testConn, plan: RenamePlan(ops: [opCol]), backend: hookCol)
        )
        let tmp = ".tidyreel-tmp-\(opCol.id.value)"
        #expect(hookCol.calls.contains("rename /d/x/a.mkv \(tmp)"))
        #expect(hookCol.calls.contains("move /d/x /d/y \(tmp)"))
        #expect(await fCol.allFilePaths() == ["/d/x/b.mkv", "/d/y/b.mkv"])
        _ = try await collectStream(makeExecutor(hCol).undo(batch: firstBatch(hCol), backend: fCol))
        #expect(await fCol.allFilePaths() == ["/d/x/a.mkv", "/d/x/b.mkv"])

        // 2. Exponential backoff 1s/2s/4s on rateLimited, network, busy; gives up after 3 retries
        let delays = LockedBox<[Int]>([])
        let fails = LockedBox(0)
        let fsRetry = MemoryStorageBackend(initialSizes: sampleTree())
        let hRetry = MemoryHistoryStore()
        let beRetry = HookBackend(fsRetry) { m, _ in
            if m == "rename" {
                let n = fails.withValue { v -> Int in
                    let cur = v
                    v += 1
                    return cur
                }
                if n < 3 {
                    let code: StorageErrorCode = n == 0 ? .rateLimited : (n == 1 ? .network : .busy)
                    throw StorageError(code, "transient")
                }
            }
        }
        _ = try await collectStream(
            makeExecutor(hRetry, delays: delays).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [reloc("/d/Movie.mkv", "/d/M2.mkv")]),
                backend: beRetry
            )
        )
        #expect(delays.value == [1000, 2000, 4000])
        #expect((await fsRetry.allFilePaths()).contains("/d/M2.mkv"))

        // Non-retryable error fails immediately without backoff
        delays.value = []
        let renames = LockedBox(0)
        let beNoRetry = HookBackend(fsRetry) { m, _ in
            if m == "rename" {
                renames.withValue { $0 += 1 }
                throw StorageError(.notFound, "missing")
            }
        }
        _ = try await collectStream(
            makeExecutor(hRetry, delays: delays).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [reloc("/d/junk.txt", "/d/J2.txt")]),
                backend: beNoRetry
            )
        )
        #expect(renames.value == 1)
        #expect(delays.value.isEmpty)

        // 3. Dynamic concurrencyProvider bounds max in-flight ops
        let limit = LockedBox(1)
        let hConc = MemoryHistoryStore()
        let exConc = DefaultExecutor(
            history: hConc,
            concurrencyProvider: { limit.value },
            minIntervalMs: 0,
            sleepMs: { _ in }
        )
        func measurePeak(_ prefix: String) async throws -> Int {
            let state = LockedBox((inFlight: 0, peak: 0))
            var sizes: [String: Int] = [:]
            var ops: [RenameOp] = []
            for i in 0..<6 {
                sizes["/\(prefix)\(i)/f"] = 1
                ops.append(reloc("/\(prefix)\(i)/f", "/\(prefix)\(i)/g"))
            }
            let mem = MemoryStorageBackend(initialSizes: sizes)
            let be = HookBackend(mem) { m, _ in
                guard m == "rename" else { return }
                state.withValue {
                    $0.inFlight += 1
                    if $0.inFlight > $0.peak { $0.peak = $0.inFlight }
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
                state.withValue { $0.inFlight -= 1 }
            }
            _ = try await collectStream(
                exConc.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: ops), backend: be)
            )
            return state.value.peak
        }
        #expect(try await measurePeak("a") == 1)
        limit.value = 4
        #expect(try await measurePeak("b") == 4)

        // 4. AlistBackend gets 1 renameMany + 1 move; CachedBackend(ThrottledBackend) is not double-wrapped
        let fAlist = MemoryStorageBackend(initialSizes: ["/s/4K/01.mkv": 1, "/s/4K/02.mkv": 1, "/s/4K/03.mkv": 1])
        let hookAlist = HookBackend(fAlist)
        let alist = AlistBackend(hookAlist)
        let hAlist = MemoryHistoryStore()
        let alistOps = (1...3).map { reloc("/s/4K/0\($0).mkv", "/s/Season 01/S.S01E0\($0).mkv") }
        _ = try await collectStream(
            makeExecutor(hAlist).execute(task: testTask, connection: testConn, plan: RenamePlan(ops: alistOps), backend: alist)
        )
        #expect(hookAlist.calls.filter { $0.hasPrefix("renameMany ") }.count == 1)
        #expect(hookAlist.calls.filter { $0.hasPrefix("move ") }.count == 1)

        let execDelays = LockedBox<[Int]>([])
        let fWrap = MemoryStorageBackend(initialSizes: ["/d/a.mkv": 1, "/d/b.mkv": 1])
        let wrapped = CachedBackend(ThrottledBackend(fWrap))
        let exWrap = DefaultExecutor(
            history: hAlist,
            minIntervalMs: 500,
            sleepMs: { ms in execDelays.withValue { $0.append(ms) } }
        )
        _ = try await collectStream(
            exWrap.execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: [reloc("/d/a.mkv", "/d/a2.mkv"), reloc("/d/b.mkv", "/d/b2.mkv")]),
                backend: wrapped
            )
        )
        #expect(execDelays.value.isEmpty)

        // 5. Blocked folder undo stays done with error and retries cleanly once cleared
        let fBlock = MemoryStorageBackend(initialSizes: ["/old/a.mkv": 1])
        let hBlock = MemoryHistoryStore()
        let exBlock = makeExecutor(hBlock)
        let blockOps = [
            reloc("/old/a.mkv", "/old/b.mkv"),
            reloc("/old", "/new", phase: .folders),
        ]
        _ = try await collectStream(
            exBlock.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: blockOps), backend: fBlock)
        )
        let bBlock = try await firstBatch(hBlock)
        await fBlock.addFile("/old/unrelated.txt", size: 2)
        _ = try await collectStream(exBlock.undo(batch: bBlock, backend: fBlock))
        var byOpId = Dictionary(uniqueKeysWithValues: (try await hBlock.records(batch: bBlock)).map { ($0.op.id, $0) })
        #expect(byOpId[blockOps[1].id]?.status == .done)
        #expect(byOpId[blockOps[1].id]?.error != nil)
        #expect(byOpId[blockOps[0].id]?.status == .undone)
        #expect(try await fBlock.exists("/new/a.mkv"))

        try await fBlock.remove(dir: "/", names: ["old"])
        _ = try await collectStream(exBlock.undo(batch: bBlock, backend: fBlock))
        byOpId = Dictionary(uniqueKeysWithValues: (try await hBlock.records(batch: bBlock)).map { ($0.op.id, $0) })
        #expect(byOpId[blockOps[1].id]?.status == .undone)
        #expect(await fBlock.allFilePaths() == ["/old/a.mkv"])

        // 6. Resume never claims pre-existing user file on write collision
        let fSafe = MemoryStorageBackend()
        try await fSafe.write("/poster.jpg", bytes: Data([9, 9, 9]))
        let hSafe = MemoryHistoryStore()
        let exSafe = DefaultExecutor(
            history: hSafe,
            minIntervalMs: 0,
            sleepMs: { _ in },
            fetchUrl: { _ in Data([1, 2, 3]) }
        )
        let wUser = RenameOp(
            id: OpId("w-user"),
            kind: .write,
            phase: .cleanup,
            src: "https://example.invalid/poster.jpg",
            dst: "/poster.jpg"
        )
        _ = try await collectStream(
            exSafe.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: [wUser]), backend: fSafe)
        )
        let bSafe = try await firstBatch(hSafe)
        #expect((try await hSafe.records(batch: bSafe))[0].status == .failed)
        try await hSafe.mark(batch: bSafe, op: wUser.id, status: .pending)
        _ = try await collectStream(exSafe.resume(batch: bSafe, backend: fSafe))
        #expect((try await hSafe.records(batch: bSafe))[0].status == .failed)
        _ = try await collectStream(exSafe.undo(batch: bSafe, backend: fSafe))
        #expect(try await fSafe.read("/poster.jpg") == Data([9, 9, 9]))
    }

    @Test("Cancelling execute stream stops before starting remaining ops while recording in-flight ones")
    func streamCancellation() async throws {
        var sizes: [String: Int] = [:]
        var ops: [RenameOp] = []
        for i in 0..<10 {
            sizes["/d\(i)/f"] = 1
            ops.append(reloc("/d\(i)/f", "/d\(i)/g"))
        }
        let f = MemoryStorageBackend(initialSizes: sizes)
        let be = HookBackend(f) { m, _ in
            if m == "rename" {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let history = MemoryHistoryStore()
        let ex = makeExecutor(history)
        var seen = 0
        for try await _ in ex.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: ops), backend: be) {
            seen += 1
            if seen == 1 { break }
        }
        await ex.waitForSettled()

        let b = try await firstBatch(history)
        let recs = try await history.records(batch: b)
        let done = recs.filter { $0.status == .done }.count
        #expect((1...9).contains(done))
        let renamedOnDisk = (await f.allFilePaths()).filter { $0.hasSuffix("/g") }.count
        #expect(renamedOnDisk == done)
    }

    @Test("Batch edge cases: mid-cycle crash resume, failed folder blocking write/delete, list failure isolation, viaTmp deferral and rollback, artwork download retry")
    func batchAndCycleSafetyRegressions() async throws {
        // 1. Mid-cycle crash: landed but unmarked op does not grab next op's source
        let fCycle = MemoryStorageBackend(initialSizes: ["/d/a.mkv": 1, "/d/b.mkv": 2, "/d/c.mkv": 3])
        let hCycle = MemoryHistoryStore()
        let ab = reloc("/d/a.mkv", "/d/b.mkv")
        let bc = reloc("/d/b.mkv", "/d/c.mkv")
        let ca = reloc("/d/c.mkv", "/d/a.mkv")
        let bCycle = try await hCycle.beginBatch(task: testTask, connection: testConn, ops: [ab, bc, ca])
        try await fCycle.rename("/d/a.mkv", newName: ".tidyreel-tmp-\(ab.id.value)")
        try await fCycle.rename("/d/b.mkv", newName: ".tidyreel-tmp-\(bc.id.value)")
        try await fCycle.rename("/d/c.mkv", newName: ".tidyreel-tmp-\(ca.id.value)")
        try await fCycle.rename("/d/.tidyreel-tmp-\(ab.id.value)", newName: "b.mkv")
        try await hCycle.mark(batch: bCycle, op: ab.id, status: .done)
        try await fCycle.rename("/d/.tidyreel-tmp-\(bc.id.value)", newName: "c.mkv")
        _ = try await collectStream(makeExecutor(hCycle).resume(batch: bCycle, backend: fCycle))
        #expect(statusCounts(try await hCycle.records(batch: bCycle)) == [.done: 3])
        let cycleSizes = Dictionary(uniqueKeysWithValues: (try await fCycle.list("/d", refresh: true)).map { ($0.name, $0.size) })
        #expect(cycleSizes == ["a.mkv": 3, "b.mkv": 1, "c.mkv": 2])

        // 2. Failed folder rename blocks cleanup delete AND OpKind.write targeting post-rename path
        let fDep = MemoryStorageBackend(initialSizes: ["/d/raw/a.mkv": 1, "/d/raw/ad.txt": 1])
        let hDep = MemoryHistoryStore()
        let depOps = [
            reloc("/d/raw/a.mkv", "/d/raw/Show.S01E01.mkv"),
            reloc("/d/raw", "/d/Show (2020)", phase: .folders),
            RenameOp(id: OpId("del-post"), kind: .delete, phase: .cleanup, src: "/d/Show (2020)/ad.txt", dst: ""),
            RenameOp(id: OpId("w-post"), kind: .write, phase: .cleanup, src: "text:<tvshow/>", dst: "/d/Show (2020)/tvshow.nfo"),
        ]
        let hookDep = HookBackend(fDep) { m, a in
            if m == "rename" && a.first == "/d/raw" {
                throw StorageError(.other, "locked")
            }
        }
        _ = try await collectStream(
            makeExecutor(hDep).execute(task: testTask, connection: testConn, plan: RenamePlan(ops: depOps), backend: hookDep)
        )
        let depRecs = Dictionary(uniqueKeysWithValues: (try await hDep.records(batch: firstBatch(hDep))).map { ($0.op.id, $0.status) })
        #expect(depRecs[OpId("del-post")] == .skipped)
        #expect(depRecs[OpId("w-post")] == .skipped)

        // 3. _batched list failure marks only that folder's ops failed without aborting batch
        let fList = MemoryStorageBackend(initialSizes: ["/bad/a.mkv": 1, "/bad/b.mkv": 2, "/good/c.mkv": 3])
        let hList = MemoryHistoryStore()
        let listOps = [
            reloc("/bad/a.mkv", "/bad/a2.mkv"),
            reloc("/bad/b.mkv", "/bad/b2.mkv"),
            reloc("/good/c.mkv", "/good/c2.mkv"),
        ]
        let hookList = HookBackend(fList, supportsServerBatching: true) { m, a in
            if m == "list" && a.first == "/bad" {
                throw StorageError(.unauthorized, "denied")
            }
        }
        _ = try await collectStream(
            makeExecutor(hList).execute(task: testTask, connection: testConn, plan: RenamePlan(ops: listOps), backend: hookList)
        )
        #expect(statusCounts(try await hList.records(batch: firstBatch(hList))) == [.failed: 2, .done: 1])
        #expect((await fList.allFilePaths()).contains("/good/c2.mkv"))

        // 4. _batched fixed-point deferral & step-2 move failure rollback without stranding tmp files
        let fDefer = MemoryStorageBackend(initialSizes: ["/d/a.mkv": 1, "/d/b.mkv": 2, "/d/c.mkv": 3])
        let hDefer = MemoryHistoryStore()
        let deferOps = [
            reloc("/d/a.mkv", "/dst1/x.mkv"),
            reloc("/d/b.mkv", "/d/a.mkv"),
            reloc("/d/c.mkv", "/dst2/x.mkv"),
        ]
        _ = try await collectStream(
            makeExecutor(hDefer).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: deferOps),
                backend: AlistBackend(HookBackend(fDefer))
            )
        )
        #expect(statusCounts(try await hDefer.records(batch: firstBatch(hDefer))) == [.done: 3])
        #expect(await fDefer.allFilePaths() == ["/d/a.mkv", "/dst1/x.mkv", "/dst2/x.mkv"])

        let fRoll = MemoryStorageBackend(initialSizes: ["/d/a.mkv": 1, "/d/b.mkv": 2, "/d/c.mkv": 3, "/other/a.mkv": 9])
        let hRoll = MemoryHistoryStore()
        let rollOps = [
            reloc("/d/a.mkv", "/other/a.mkv"),
            reloc("/d/b.mkv", "/d/a.mkv"),
            reloc("/d/c.mkv", "/d/b.mkv"),
        ]
        _ = try await collectStream(
            makeExecutor(hRoll).execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: rollOps),
                backend: AlistBackend(HookBackend(fRoll))
            )
        )
        #expect(statusCounts(try await hRoll.records(batch: firstBatch(hRoll))) == [.failed: 3])
        #expect(await fRoll.allFilePaths() == ["/d/a.mkv", "/d/b.mkv", "/d/c.mkv", "/other/a.mkv"])

        // 5. Artwork download retries with backoff and runs writes concurrently
        let attempts = LockedBox(0)
        let artDelays = LockedBox<[Int]>([])
        let peakBox = LockedBox((inFlight: 0, peak: 0))
        let hArt = MemoryHistoryStore()
        let fArt = MemoryStorageBackend()
        let exArt = DefaultExecutor(
            history: hArt,
            minIntervalMs: 0,
            sleepMs: { ms in artDelays.withValue { $0.append(ms) } },
            fetchUrl: { url in
                if url.path == "/retry.jpg" {
                    let cur = attempts.withValue { v -> Int in defer { v += 1 }; return v }
                    if cur < 2 { throw StorageError(.network, "timeout") }
                }
                peakBox.withValue {
                    $0.inFlight += 1
                    if $0.inFlight > $0.peak { $0.peak = $0.inFlight }
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
                peakBox.withValue { $0.inFlight -= 1 }
                return Data([7, 8, 9])
            }
        )
        let artOps = (0..<4).map { i in
            RenameOp(
                id: OpId("art-\(i)"),
                kind: .write,
                phase: .cleanup,
                src: i == 0 ? "https://example.invalid/retry.jpg" : "https://example.invalid/p\(i).jpg",
                dst: "/d/p\(i).jpg"
            )
        }
        _ = try await collectStream(
            exArt.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: artOps), backend: fArt)
        )
        #expect(artDelays.value == [1000, 2000])
        #expect(peakBox.value.peak > 1)
        #expect(statusCounts(try await hArt.records(batch: firstBatch(hArt))) == [.done: 4])
    }

    @Test("Atomic relocate runs single-op parallel moves, skips redundant mkdirs, and batching uses markBatch")
    func atomicRelocateParallelismAndMarkBatch() async throws {
        var sizes: [String: Int] = [:]
        var ops: [RenameOp] = [mkdirOp("/s/raw/Season 01")]
        for i in 1...8 {
            sizes["/s/raw/ep\(i).mkv"] = i
            ops.append(reloc("/s/raw/ep\(i).mkv", "/s/raw/Season 01/Show.S01E0\(i).mkv"))
        }
        let fs = MemoryStorageBackend(initialSizes: sizes)
        let peakBox = LockedBox((inFlight: 0, peak: 0))
        let hook = HookBackend(fs, supportsAtomicRelocate: true) { m, _ in
            if m == "atomicRelocate" {
                peakBox.withValue {
                    $0.inFlight += 1
                    if $0.inFlight > $0.peak { $0.peak = $0.inFlight }
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
                peakBox.withValue { $0.inFlight -= 1 }
            }
        }
        let history = CountingHistoryStore()
        let ex = DefaultExecutor(
            history: history,
            concurrencyProvider: { 4 },
            minIntervalMs: 0,
            sleepMs: { _ in }
        )
        _ = try await collectStream(
            ex.execute(task: testTask, connection: testConn, plan: RenamePlan(ops: ops), backend: hook)
        )
        #expect(hook.calls.filter { $0.hasPrefix("atomicRelocate ") }.count == 8)
        #expect(hook.calls.filter { $0.hasPrefix("rename ") }.isEmpty)
        #expect(hook.calls.filter { $0.hasPrefix("move ") }.isEmpty)
        #expect(hook.calls.filter { $0.hasPrefix("mkdirs ") }.count == 1)
        #expect(peakBox.value.peak > 1)

        // Undo on atomicRelocate backend also avoids per-file exists() and uses atomicRelocate
        let b = try await firstBatch(history)
        let undoHook = HookBackend(fs, supportsAtomicRelocate: true)
        _ = try await collectStream(ex.undo(batch: b, backend: undoHook))
        #expect(undoHook.calls.filter { $0.hasPrefix("atomicRelocate ") }.count == 8)
        #expect(undoHook.calls.filter { $0.hasPrefix("exists ") }.count < 4)
        #expect(await fs.allFilePaths() == sizes.keys.sorted())

        // Server-batching backend records forward batch completion via markBatch
        let alistFs = MemoryStorageBackend(initialSizes: sizes)
        let alistHistory = CountingHistoryStore()
        let alistEx = makeExecutor(alistHistory)
        _ = try await collectStream(
            alistEx.execute(
                task: testTask,
                connection: testConn,
                plan: RenamePlan(ops: ops),
                backend: AlistBackend(HookBackend(alistFs))
            )
        )
        #expect(await alistHistory.markBatchCalls == 1)
        #expect(statusCounts(try await alistHistory.records(batch: firstBatch(alistHistory))) == [.done: 9])
    }
}
