import CryptoKit
import Foundation
import TidyreelModels

internal enum ParkedAt: Sendable {
    case none
    case srcTmp
    case dstTmp
}

private final class ForwardRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: Set<String>
    private var hasFailed = false
    private var failedMkdirByDst: [String: RenameOp] = [:]
    private var failedRelocateBySrc: [String: RenameOp] = [:]
    private var failedFolderBySrc: [String: RenameOp] = [:]
    private var failedFolderByDst: [String: RenameOp] = [:]
    private var doneByPhase: [ExecPhase: Int] = [:]

    init(landed: Set<String>, initialFailed: [RenameOp]) {
        self.taken = landed
        for op in initialFailed {
            indexFailed(op)
        }
    }

    private func indexFailed(_ op: RenameOp) {
        if op.kind == .mkdir {
            if !op.dst.isEmpty && failedMkdirByDst[op.dst] == nil {
                failedMkdirByDst[op.dst] = op
                hasFailed = true
            }
            return
        }
        guard op.kind == .relocate else { return }
        if !op.src.isEmpty && failedRelocateBySrc[op.src] == nil {
            failedRelocateBySrc[op.src] = op
            hasFailed = true
        }
        if op.phase == .folders {
            if !op.src.isEmpty && failedFolderBySrc[op.src] == nil {
                failedFolderBySrc[op.src] = op
                hasFailed = true
            }
            if !op.dst.isEmpty && failedFolderByDst[op.dst] == nil {
                failedFolderByDst[op.dst] = op
                hasFailed = true
            }
        }
    }

    func isTaken(_ path: String) -> Bool {
        lock.withLock { taken.contains(path) }
    }

    func markTaken(_ path: String) {
        _ = lock.withLock { taken.insert(path) }
    }

    func addFailed(_ op: RenameOp) {
        lock.withLock { indexFailed(op) }
    }

    func blocker(of op: RenameOp) -> RenameOp? {
        lock.withLock {
            guard hasFailed else { return nil }

            if op.kind != .delete && !failedMkdirByDst.isEmpty && !op.dst.isEmpty {
                if let hit = failedMkdirByDst[op.dst] { return hit }
                var cur = dirOf(op.dst)
                while cur != "/" && cur != op.dst {
                    if let hit = failedMkdirByDst[cur] { return hit }
                    let next = dirOf(cur)
                    if next == cur { break }
                    cur = next
                }
            }

            if op.kind == .write {
                if (!failedFolderByDst.isEmpty || !failedFolderBySrc.isEmpty) && !op.dst.isEmpty {
                    if let hit = failedFolderByDst[op.dst] ?? failedFolderBySrc[op.dst] {
                        return hit
                    }
                    var cur = dirOf(op.dst)
                    while cur != "/" && cur != op.dst {
                        if let hit = failedFolderByDst[cur] ?? failedFolderBySrc[cur] {
                            return hit
                        }
                        let next = dirOf(cur)
                        if next == cur { break }
                        cur = next
                    }
                }
                return nil
            }

            guard !op.src.isEmpty, (!failedRelocateBySrc.isEmpty || !failedFolderByDst.isEmpty) else {
                return nil
            }
            var cur = dirOf(op.src)
            while cur != "/" && cur != op.src {
                if let hit = failedRelocateBySrc[cur] ?? failedFolderByDst[cur] {
                    return hit
                }
                let next = dirOf(cur)
                if next == cur { break }
                cur = next
            }
            return nil
        }
    }

    func recordAndYield(
        op: RenameOp,
        phase: ExecPhase,
        total: Int,
        status: OpStatus,
        error: String?,
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
    ) {
        lock.withLock {
            if status == .done && op.kind == .relocate {
                taken.insert(op.dst)
            }
            let currentDone = (doneByPhase[phase] ?? 0) + 1
            doneByPhase[phase] = currentDone
            if !cancelFlag.isCancelled {
                continuation.yield(
                    ExecProgress(
                        phase: phase,
                        done: currentDone,
                        total: total,
                        current: op.id,
                        error: error
                    )
                )
            }
        }
    }

    func recordAndYieldBatch(
        ops: [RenameOp],
        phase: ExecPhase,
        total: Int,
        status: OpStatus,
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
    ) {
        guard !ops.isEmpty else { return }
        lock.withLock {
            var currentDone = doneByPhase[phase] ?? 0
            let cancelled = cancelFlag.isCancelled
            for op in ops {
                if status == .done && op.kind == .relocate {
                    taken.insert(op.dst)
                }
                currentDone += 1
                if !cancelled {
                    continuation.yield(
                        ExecProgress(
                            phase: phase,
                            done: currentDone,
                            total: total,
                            current: op.id,
                            error: nil
                        )
                    )
                }
            }
            doneByPhase[phase] = currentDone
        }
    }
}

internal final class UndoRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let counts: [ExecPhase: Int]
    private var seen: [ExecPhase: Int] = [:]
    private var taken: Set<String> = []

    init(counts: [ExecPhase: Int]) {
        self.counts = counts
    }

    func isTaken(_ path: String) -> Bool {
        lock.withLock { taken.contains(path) }
    }

    func markTaken(_ path: String) {
        _ = lock.withLock { taken.insert(path) }
    }

    func recordAndYield(
        op: RenameOp,
        error: String?,
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
    ) {
        lock.withLock {
            let currentDone = (seen[op.phase] ?? 0) + 1
            seen[op.phase] = currentDone
            let total = counts[op.phase] ?? currentDone
            if !cancelFlag.isCancelled {
                continuation.yield(
                    ExecProgress(
                        phase: op.phase,
                        done: currentDone,
                        total: total,
                        current: op.id,
                        error: error
                    )
                )
            }
        }
    }

    func recordAndYieldBatch(
        ops: [RenameOp],
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
    ) {
        guard !ops.isEmpty else { return }
        lock.withLock {
            let cancelled = cancelFlag.isCancelled
            for op in ops {
                let currentDone = (seen[op.phase] ?? 0) + 1
                seen[op.phase] = currentDone
                let total = counts[op.phase] ?? currentDone
                if !cancelled {
                    continuation.yield(
                        ExecProgress(
                            phase: op.phase,
                            done: currentDone,
                            total: total,
                            current: op.id,
                            error: nil
                        )
                    )
                }
            }
        }
    }
}

internal final class EnsuredDirsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dirs: Set<String> = ["/"]

    func contains(_ dir: String) -> Bool {
        lock.withLock { dirs.contains(dir) }
    }

    func mark(_ dir: String) {
        lock.withLock {
            var cur = dir
            while !cur.isEmpty && cur != "/" {
                if !dirs.insert(cur).inserted { break }
                let next = dirOf(cur)
                if next == cur { break }
                cur = next
            }
        }
    }

    func invalidate(prefix path: String) {
        guard !path.isEmpty else { return }
        lock.withLock {
            if path == "/" {
                dirs = ["/"]
                return
            }
            let p = path + "/"
            dirs = dirs.filter { $0 != path && !$0.hasPrefix(p) }
            dirs.insert("/")
        }
    }
}

internal final class PrelistedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: Set<String>]

    init(_ map: [String: Set<String>]) {
        self.map = map
    }

    func remove(_ dir: String) -> Set<String>? {
        lock.withLock { map.removeValue(forKey: dir) }
    }
}

public final class DefaultExecutor: Executor, Sendable {
    public let history: any HistoryStore
    public let concurrencyProvider: @Sendable () -> Int
    public let minIntervalMs: Int
    public let backoffMs: [Int]
    public let sleepMs: @Sendable (Int) async -> Void
    public let fetchUrl: @Sendable (URL) async throws -> Data

    private let activeJobs = ActiveJobTracker()

    public init(
        history: any HistoryStore,
        concurrencyProvider: @escaping @Sendable () -> Int = { 4 },
        minIntervalMs: Int = 0,
        backoffMs: [Int] = [1000, 2000, 4000],
        sleepMs: (@Sendable (Int) async -> Void)? = nil,
        fetchUrl: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.history = history
        self.concurrencyProvider = concurrencyProvider
        self.minIntervalMs = minIntervalMs
        self.backoffMs = backoffMs
        self.sleepMs = sleepMs ?? { ms in await Self.defaultSleepMs(ms) }
        self.fetchUrl = fetchUrl ?? { url in try await Self.defaultFetchUrl(url) }
    }

    internal var effectiveConcurrency: Int {
        min(16, max(1, concurrencyProvider()))
    }

    internal func waitForSettled(owner: ExecutionOwner? = nil) async {
        while true {
            let jobs = activeJobs.snapshot(owner: owner)
            if jobs.isEmpty { return }
            for job in jobs {
                await job.value
            }
        }
    }

    private static func defaultSleepMs(_ ms: Int) async {
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    static func writtenDigest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func defaultFetchUrl(_ url: URL) async throws -> Data {
        try await ArtworkDownload.fetchBytes(url, session: downloadSession)
    }

    private func fetchWithRetry(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw StorageError(.other, "无效下载链接：\(urlString)")
        }
        var attempt = 0
        while true {
            do {
                return try await fetchUrl(url)
            } catch let e as StorageError {
                let retryable = e.code == .network || e.code == .rateLimited || e.code == .busy
                if !retryable || attempt >= backoffMs.count { throw e }
                await sleepMs(backoffMs[attempt])
                attempt += 1
            } catch let e as URLError {
                if attempt >= backoffMs.count {
                    throw StorageError(.network, "下载 \(url.absoluteString)：\(e.localizedDescription)")
                }
                await sleepMs(backoffMs[attempt])
                attempt += 1
            }
        }
    }

    internal func wrap(_ backend: any StorageBackend) -> any StorageBackend {
        if ExecutionThrottledBackend.isAlreadyThrottled(backend) {
            return backend
        }
        return ExecutionThrottledBackend(
            inner: backend,
            minIntervalMs: minIntervalMs,
            backoffMs: backoffMs,
            sleepMs: sleepMs
        )
    }

    // MARK: - Executor Protocol

    public func execute(
        task: TaskId,
        connection: ConnectionId,
        plan: RenamePlan,
        backend: any StorageBackend
    ) -> AsyncThrowingStream<ExecProgress, any Error> {
        if !plan.canExecute {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: TidyreelExecutionError.invalidState("plan has conflicts, refusing to execute")
                )
            }
        }
        let ops = Self.ordered(plan.ops.filter(\.selected))
        return makeStream(owner: .task(task)) { cancelFlag, continuation in
            let batch = try await self.history.beginBatch(task: task, connection: connection, ops: ops)
            try await self.forward(
                ops: ops,
                batch: batch,
                be: self.wrap(backend),
                cancelFlag: cancelFlag,
                continuation: continuation,
                resuming: false,
                initialFailed: [],
                landed: []
            )
        }
    }

    public func resume(
        batch: BatchId,
        backend: any StorageBackend
    ) -> AsyncThrowingStream<ExecProgress, any Error> {
        makeStream(owner: .batch(batch)) { cancelFlag, continuation in
            let records = try await self.history.records(batch: batch)
            let doneFolders = records
                .filter { $0.status == .done && $0.op.phase == .folders && $0.op.kind == .relocate }
                .map(\.op)
            let pendingOps = records
                .filter { $0.status == .pending }
                .map { $0.op.phase == .files ? Self.mapOp($0.op, doneFolders: doneFolders) : $0.op }
            let failedOps = records
                .filter { $0.status == .failed }
                .map(\.op)
            let landed = Set(
                records
                    .filter { $0.status == .done && $0.op.phase == .files && $0.op.kind == .relocate }
                    .map { Self.mapPath($0.op.dst, doneFolders: doneFolders) }
            )
            try await self.forward(
                ops: pendingOps,
                batch: batch,
                be: self.wrap(backend),
                cancelFlag: cancelFlag,
                continuation: continuation,
                resuming: true,
                initialFailed: failedOps,
                landed: landed
            )
        }
    }

    // MARK: - Stream Driver

    internal func makeStream(
        owner: ExecutionOwner,
        _ body: @escaping @Sendable (
            _ cancelFlag: CancellationFlag,
            _ continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
        ) async throws -> Void
    ) -> AsyncThrowingStream<ExecProgress, any Error> {
        AsyncThrowingStream { continuation in
            let cancelFlag = CancellationFlag()
            let jobId = UUID()
            let worker = Task<Void, Never> { [activeJobs] in
                defer { activeJobs.unregister(jobId) }
                do {
                    try await body(cancelFlag, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeJobs.register(jobId, owner: owner, task: worker)
            continuation.onTermination = { _ in
                cancelFlag.cancel()
            }
        }
    }

    // MARK: - Path & Ordering Helpers

    private static func phaseIndex(_ phase: ExecPhase) -> Int {
        switch phase {
        case .files: return 0
        case .folders: return 1
        case .cleanup: return 2
        }
    }

    private static func ordered(_ ops: [RenameOp]) -> [RenameOp] {
        func rank(_ op: RenameOp) -> Int {
            phaseIndex(op.phase) * 2 + (op.kind == .mkdir ? 0 : 1)
        }
        return ops.enumerated().sorted { a, b in
            let ra = rank(a.element)
            let rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private static func mapPath(_ path: String, doneFolders: [RenameOp]) -> String {
        guard !path.isEmpty, !doneFolders.isEmpty else { return path }
        var cur = path
        for f in doneFolders {
            if cur == f.src {
                cur = f.dst
            } else if cur.hasPrefix(f.src + "/") {
                cur = f.dst + String(cur.dropFirst(f.src.count))
            }
        }
        return cur
    }

    internal static func mapOp(_ op: RenameOp, doneFolders: [RenameOp]) -> RenameOp {
        guard !doneFolders.isEmpty else { return op }
        return RenameOp(
            id: op.id,
            kind: op.kind,
            phase: op.phase,
            src: mapPath(op.src, doneFolders: doneFolders),
            dst: mapPath(op.dst, doneFolders: doneFolders),
            group: op.group,
            selected: op.selected,
            warning: op.warning,
            overwrite: op.overwrite
        )
    }

    private static func safeOpToken(_ id: OpId) -> String {
        if !id.value.contains("/") && !id.value.contains("\\") {
            return id.value
        }
        return id.value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    internal static func tmpName(_ id: OpId) -> String {
        ".tidyreel-tmp-\(safeOpToken(id))"
    }

    internal static func blocks(_ f: RenameOp, _ op: RenameOp) -> Bool {
        if f.kind == .mkdir {
            return op.kind != .delete && (op.dst == f.dst || op.dst.hasPrefix(f.dst + "/"))
        }
        if f.kind != .relocate { return false }
        if op.kind == .write {
            if f.phase != .folders { return false }
            let hitDst = !f.dst.isEmpty && (op.dst == f.dst || op.dst.hasPrefix(f.dst + "/"))
            let hitSrc = !f.src.isEmpty && (op.dst == f.src || op.dst.hasPrefix(f.src + "/"))
            return hitDst || hitSrc
        }
        if op.src.isEmpty { return false }
        if op.src.hasPrefix(f.src + "/") { return true }
        return f.phase == .folders && !f.dst.isEmpty && op.src.hasPrefix(f.dst + "/")
    }

    private static func occupiedByPeer(_ ops: [RenameOp]) -> [RenameOp] {
        let sources = Set(ops.filter { $0.kind == .relocate }.map(\.src))
        return ops.filter { $0.kind == .relocate && $0.src != $0.dst && sources.contains($0.dst) }
    }

    private func findParked(be: any StorageBackend, op: RenameOp) async throws -> ParkedAt {
        let srcDir = dirOf(op.src)
        let dstDir = dirOf(op.dst)
        let tmp = Self.tmpName(op.id)
        if try await be.exists(joinPath(srcDir, tmp)) { return .srcTmp }
        if srcDir != dstDir, try await be.exists(joinPath(dstDir, tmp)) {
            return .dstTmp
        }
        return .none
    }

    // MARK: - Forward Execution

    private func forward(
        ops: [RenameOp],
        batch: BatchId,
        be: any StorageBackend,
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation,
        resuming: Bool,
        initialFailed: [RenameOp],
        landed: Set<String>
    ) async throws {
        let orderedOps = Self.ordered(ops)
        let state = ForwardRunState(landed: landed, initialFailed: initialFailed)
        let ensuredDirs = EnsuredDirsBox()

        for phase in ExecPhase.allCases {
            let inPhase = orderedOps.filter { $0.phase == phase }
            if inPhase.isEmpty { continue }
            let phaseTotal = inPhase.count

            @Sendable func record(_ op: RenameOp, _ status: OpStatus, _ error: String?) async throws {
                try await self.history.mark(batch: batch, op: op.id, status: status, error: error)
                state.recordAndYield(
                    op: op,
                    phase: phase,
                    total: phaseTotal,
                    status: status,
                    error: error,
                    cancelFlag: cancelFlag,
                    continuation: continuation
                )
                await Task.yield()
            }

            @Sendable func recordDoneBatch(_ batchOps: [RenameOp]) async throws {
                guard !batchOps.isEmpty else { return }
                let updates: [(op: OpId, status: OpStatus, error: String?)] = batchOps.map {
                    (op: $0.id, status: .done, error: nil)
                }
                try await self.history.markBatch(batch: batch, updates: updates)
                state.recordAndYieldBatch(
                    ops: batchOps,
                    phase: phase,
                    total: phaseTotal,
                    status: .done,
                    cancelFlag: cancelFlag,
                    continuation: continuation
                )
                await Task.yield()
            }

            @Sendable func failOp(_ op: RenameOp, _ err: any Error) async throws {
                state.addFailed(op)
                try await record(op, .failed, executionErrorMessage(err))
            }

            @Sendable func one(_ op: RenameOp, _ retry: Bool) async throws {
                var errStr: String?
                var status: OpStatus = .done
                if let blocker = state.blocker(of: op) {
                    status = .skipped
                    errStr = "依赖的操作失败：\(blocker.kind == .mkdir ? blocker.dst : blocker.src)"
                } else {
                    do {
                        try await self.apply(
                            be: be,
                            op: op,
                            writeBatch: batch,
                            resuming: resuming || retry,
                            srcTaken: state.isTaken(op.src),
                            ensuredDirs: ensuredDirs
                        )
                    } catch {
                        status = .failed
                        errStr = executionErrorMessage(error)
                        state.addFailed(op)
                    }
                }
                try await record(op, status, errStr)
            }

            let conc = effectiveConcurrency

            @Sendable func retryStaged(_ retryOps: [RenameOp]) async throws {
                try await self.runStaged(
                    group: retryOps,
                    be: be,
                    width: conc,
                    stage: true,
                    resuming: true,
                    isTaken: { state.isTaken($0) },
                    isBlocked: { state.blocker(of: $0) != nil },
                    one: { o, _ in try await one(o, true) },
                    parkFailed: failOp,
                    isCancelled: { cancelFlag.isCancelled }
                )
            }

            let writeWidth = min(conc, 4)
            let groups: [([RenameOp], Int)]
            if phase == .cleanup {
                groups = [
                    (inPhase.filter { $0.kind == .write }, writeWidth),
                    (inPhase.filter { $0.kind != .write }, 1),
                ]
            } else {
                let phaseWidth = phase == .files ? conc : 1
                groups = [
                    (inPhase.filter { $0.kind == .mkdir }, phaseWidth),
                    (inPhase.filter { $0.kind != .mkdir }, phaseWidth),
                ]
            }

            for (rawGroup, width) in groups where !rawGroup.isEmpty {
                var group = rawGroup
                if phase == .files && !resuming && be.supportsServerBatching {
                    group = try await batched(
                        group: group,
                        be: be,
                        blockerOf: { state.blocker(of: $0) },
                        recordBatch: recordDoneBatch,
                        one: one,
                        failOp: failOp,
                        retryStaged: retryStaged,
                        isCancelled: { cancelFlag.isCancelled },
                        prelisted: nil,
                        ensuredDirs: ensuredDirs
                    )
                }
                try await runStaged(
                    group: group,
                    be: be,
                    width: width,
                    stage: phase == .files,
                    resuming: resuming,
                    isTaken: { state.isTaken($0) },
                    isBlocked: { state.blocker(of: $0) != nil },
                    one: one,
                    parkFailed: failOp,
                    isCancelled: { cancelFlag.isCancelled }
                )
            }
            if cancelFlag.isCancelled { return }
        }
    }

    // MARK: - Staged Helpers

    internal func runStaged(
        group initialGroup: [RenameOp],
        be: any StorageBackend,
        width: Int,
        stage: Bool,
        resuming: Bool,
        isTaken: @escaping @Sendable (String) -> Bool,
        isBlocked: @escaping @Sendable (RenameOp) -> Bool,
        one: @escaping @Sendable (RenameOp, Bool) async throws -> Void,
        parkFailed: @escaping @Sendable (RenameOp, any Error) async throws -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        var group = initialGroup
        let staged = stage ? Self.occupiedByPeer(group) : []
        var parked: [RenameOp] = []
        var didPark: Set<OpId> = []

        if !staged.isEmpty {
            let stagedIds = Set(staged.map(\.id))
            group = group.filter { !stagedIds.contains($0.id) }
            for o in staged {
                if isCancelled() { return }
                if isBlocked(o) {
                    parked.append(o)
                    continue
                }
                do {
                    let tmp = joinPath(dirOf(o.src), Self.tmpName(o.id))
                    let shouldPark: Bool
                    if !resuming {
                        shouldPark = true
                    } else if isTaken(o.src) {
                        shouldPark = false
                    } else if try await be.exists(tmp) {
                        shouldPark = false
                    } else {
                        shouldPark = try await be.exists(o.src)
                    }
                    if shouldPark {
                        try await be.rename(o.src, newName: Self.tmpName(o.id))
                        didPark.insert(o.id)
                    }
                    parked.append(o)
                } catch {
                    try await parkFailed(o, error)
                }
            }
        }

        if !group.isEmpty {
            let queue = WorkQueue(group)
            let workerCount = min(max(1, width), group.count)
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for _ in 0..<workerCount {
                    taskGroup.addTask {
                        while !isCancelled(), let op = queue.next() {
                            try await one(op, false)
                        }
                    }
                }
                try await taskGroup.waitForAll()
            }
        }

        for o in parked {
            if isCancelled() { return }
            try await one(o, true)
            if didPark.contains(o.id) {
                let tmp = joinPath(dirOf(o.src), Self.tmpName(o.id))
                do {
                    if try await be.exists(tmp), !(try await be.exists(o.src)) {
                        try await be.rename(tmp, newName: baseOf(o.src))
                    }
                } catch {
                    // best effort rollback
                }
            }
        }
    }

    // MARK: - Single Op Application

    internal func ensureDir(
        _ be: any StorageBackend,
        _ dir: String,
        ensuredDirs: EnsuredDirsBox?
    ) async throws {
        guard !dir.isEmpty && dir != "/" else { return }
        if let ensuredDirs, ensuredDirs.contains(dir) {
            return
        }
        try await be.mkdirs(dir)
        ensuredDirs?.mark(dir)
    }

    internal func apply(
        be: any StorageBackend,
        op: RenameOp,
        writeBatch: BatchId? = nil,
        resuming: Bool,
        srcTaken: Bool,
        ensuredDirs: EnsuredDirsBox? = nil
    ) async throws {
        switch op.kind {
        case .mkdir:
            try await ensureDir(be, op.dst, ensuredDirs: ensuredDirs)

        case .delete:
            if resuming, !(try await be.exists(op.src)) { return }
            try await be.remove(dir: dirOf(op.src), names: [baseOf(op.src)])

        case .write:
            if op.overwrite {
                let bytes: Data
                if op.src.hasPrefix(writeTextPrefix) {
                    bytes = Data(op.src.dropFirst(writeTextPrefix.count).utf8)
                } else {
                    bytes = try await fetchWithRetry(op.src)
                }
                let dir = dirOf(op.dst)
                let name = baseOf(op.dst)
                let tok = Self.safeOpToken(op.id)
                let tmpFileName = ".tidyreel-tmp-\(tok)-\(name)"
                let tmpPath = joinPath(dir, tmpFileName)
                let bakFileName = ".tidyreel-bak-\(tok)-\(name)"
                let bakPath = joinPath(dir, bakFileName)
                if try await be.exists(tmpPath) {
                    try await be.remove(dir: dir, names: [tmpFileName])
                }
                try await be.write(tmpPath, bytes: bytes)
                var backedUp = false
                do {
                    if try await be.exists(op.dst) {
                        if try await be.exists(bakPath) {
                            try await be.remove(dir: dir, names: [bakFileName])
                        }
                        try await be.rename(op.dst, newName: bakFileName)
                        backedUp = true
                    }
                    try await be.rename(tmpPath, newName: name)
                } catch {
                    if backedUp {
                        if (try? await be.exists(bakPath)) == true,
                           (try? await be.exists(op.dst)) == false
                        {
                            try? await be.rename(bakPath, newName: name)
                        }
                    }
                    if (try? await be.exists(tmpPath)) == true {
                        try? await be.remove(dir: dir, names: [tmpFileName])
                    }
                    throw error
                }
                if backedUp {
                    try? await be.remove(dir: dir, names: [bakFileName])
                }
                return
            }

            if resuming, try await be.exists(op.dst) {
                throw StorageError(.alreadyExists, "目标已存在，无法确认是否由本任务创建，已保留：\(op.dst)")
            }
            let bytes: Data
            if op.src.hasPrefix(writeTextPrefix) {
                bytes = Data(op.src.dropFirst(writeTextPrefix.count).utf8)
            } else {
                bytes = try await fetchWithRetry(op.src)
            }
            if let writeBatch {
                try await history.saveWrittenDigest(Self.writtenDigest(bytes), batch: writeBatch, op: op.id)
            }
            try await be.write(op.dst, bytes: bytes)

        case .relocate:
            let parkedAt = resuming ? try await findParked(be: be, op: op) : .none
            let parked = parkedAt != .none
            let srcGone: Bool
            if parked {
                srcGone = true
            } else if resuming {
                if srcTaken {
                    srcGone = true
                } else {
                    srcGone = !(try await be.exists(op.src))
                }
            } else {
                srcGone = false
            }
            if srcGone && !parked, try await be.exists(op.dst) {
                return
            }
            try await relocate(
                be: be,
                src: op.src,
                dst: op.dst,
                id: op.id,
                resuming: resuming,
                srcGone: srcGone,
                parkedAt: parkedAt,
                ensuredDirs: ensuredDirs
            )
            if op.phase == .folders {
                ensuredDirs?.invalidate(prefix: op.src)
            }
        }
    }

    internal func relocate(
        be: any StorageBackend,
        src: String,
        dst: String,
        id: OpId,
        resuming: Bool,
        srcGone: Bool = false,
        parkedAt: ParkedAt = .none,
        ensuredDirs: EnsuredDirsBox? = nil
    ) async throws {
        if src == dst { return }
        let srcDir = dirOf(src)
        let dstDir = dirOf(dst)
        let name = baseOf(dst)
        let tmp = Self.tmpName(id)

        if srcDir == dstDir {
            if resuming && srcGone {
                if parkedAt == .srcTmp {
                    try await be.rename(joinPath(srcDir, tmp), newName: name)
                    return
                }
                throw StorageError(.notFound, src)
            }
            try await be.rename(src, newName: name)
            return
        }

        if resuming && srcGone {
            let dstTmp = joinPath(dstDir, tmp)
            let srcNamed = joinPath(srcDir, name)
            if parkedAt == .dstTmp {
                try await be.rename(dstTmp, newName: name)
                return
            }
            if parkedAt == .srcTmp {
                if be.supportsAtomicRelocate {
                    try await be.atomicRelocate(from: joinPath(srcDir, tmp), to: dst)
                    ensuredDirs?.mark(dstDir)
                    return
                }
                if try await be.exists(dst) {
                    throw StorageError(.alreadyExists, dst)
                }
                try await ensureDir(be, dstDir, ensuredDirs: ensuredDirs)
                try await be.move(srcDir: srcDir, dstDir: dstDir, names: [tmp])
                do {
                    try await be.rename(dstTmp, newName: name)
                    return
                } catch {
                    try? await be.move(srcDir: dstDir, dstDir: srcDir, names: [tmp])
                    throw error
                }
            }
            if try await be.exists(srcNamed) {
                try await ensureDir(be, dstDir, ensuredDirs: ensuredDirs)
                try await be.move(srcDir: srcDir, dstDir: dstDir, names: [name])
                return
            }
            throw StorageError(.notFound, src)
        }

        if be.supportsAtomicRelocate {
            try await be.atomicRelocate(from: src, to: dst)
            ensuredDirs?.mark(dstDir)
            return
        }

        let srcName = baseOf(src)
        var cur = srcName
        if srcName != name {
            cur = tmp
            try await be.rename(src, newName: cur)
        }
        do {
            if try await be.exists(dst) {
                throw StorageError(.alreadyExists, dst)
            }
            try await ensureDir(be, dstDir, ensuredDirs: ensuredDirs)
            try await be.move(srcDir: srcDir, dstDir: dstDir, names: [cur])
        } catch {
            if cur != srcName {
                try? await be.rename(joinPath(srcDir, cur), newName: srcName)
            }
            throw error
        }
        if cur != name {
            do {
                try await be.rename(joinPath(dstDir, cur), newName: name)
            } catch {
                do {
                    try await be.move(srcDir: dstDir, dstDir: srcDir, names: [cur])
                    try await be.rename(joinPath(srcDir, cur), newName: srcName)
                } catch {
                    // best effort rollback
                }
                throw error
            }
        }
    }
}
