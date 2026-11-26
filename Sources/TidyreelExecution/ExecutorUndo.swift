import Foundation
import TidyreelModels

extension DefaultExecutor {
    // MARK: - Executor Protocol (Undo)

    public func undo(
        batch: BatchId,
        backend: any StorageBackend,
        only: Set<OpId>? = nil
    ) -> AsyncThrowingStream<ExecProgress, any Error> {
        makeStream { cancelFlag, continuation in
            try await self.performUndo(
                batch: batch,
                be: self.wrap(backend),
                only: only,
                cancelFlag: cancelFlag,
                continuation: continuation
            )
        }
    }

    // MARK: - Reverse Undo

    private func performUndo(
        batch: BatchId,
        be: any StorageBackend,
        only: Set<OpId>?,
        cancelFlag: CancellationFlag,
        continuation: AsyncThrowingStream<ExecProgress, any Error>.Continuation
    ) async throws {
        let records = try await history.records(batch: batch)
        let todo = records.reversed()
            .filter { $0.status == .done && (only == nil || only!.contains($0.op.id)) }
            .map(\.op)

        var counts: [ExecPhase: Int] = [:]
        for op in todo {
            counts[op.phase, default: 0] += 1
        }
        let undoState = UndoRunState(counts: counts)
        let ensuredDirs = EnsuredDirsBox()

        @Sendable func finish(_ op: RenameOp, _ note: String?, _ failure: String?) async throws {
            let status: OpStatus = failure != nil ? .done : (note == nil ? .undone : .skipped)
            let err = failure ?? note
            try await self.history.mark(batch: batch, op: op.id, status: status, error: err)
            undoState.recordAndYield(
                op: op,
                error: err,
                cancelFlag: cancelFlag,
                continuation: continuation
            )
            await Task.yield()
        }

        @Sendable func undoOne(_ op: RenameOp) async throws -> Bool {
            var note: String?
            var failure: String?
            do {
                note = try await self.undoSingleOp(be: be, op: op, ensuredDirs: ensuredDirs)
            } catch {
                failure = executionErrorMessage(error)
            }
            try await finish(op, note, failure)
            return failure == nil
        }

        var activeFolders = records
            .filter { $0.status == .done && $0.op.phase == .folders && $0.op.kind == .relocate }
            .map(\.op)

        let cleanup = todo.filter { $0.phase == .cleanup }
        let folders = todo.filter { $0.phase == .folders }
        let files = todo.filter { $0.phase == .files && $0.kind != .mkdir }
        let mkdirs = todo.filter { $0.phase == .files && $0.kind == .mkdir }
        let conc = effectiveConcurrency

        if !cleanup.isEmpty {
            let queue = WorkQueue(cleanup)
            let cleanupWidth = min(min(conc, 4), cleanup.count)
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for _ in 0..<cleanupWidth {
                    taskGroup.addTask {
                        while !cancelFlag.isCancelled, let op = queue.next() {
                            _ = try await undoOne(op)
                        }
                    }
                }
                try await taskGroup.waitForAll()
            }
            if cancelFlag.isCancelled { return }
        }

        for op in folders {
            if cancelFlag.isCancelled { return }
            let idx = activeFolders.firstIndex { $0.id == op.id }
            let outer: [RenameOp]
            if let idx, idx + 1 < activeFolders.count {
                outer = Array(activeFolders[(idx + 1)...])
            } else {
                outer = []
            }
            let ok = try await undoOne(Self.mapOp(op, doneFolders: outer))
            if ok {
                activeFolders.removeAll { $0.id == op.id }
            }
        }

        let mappedFiles = files.map { Self.mapOp($0, doneFolders: activeFolders) }
        let mappedMkdirs = mkdirs.map { Self.mapOp($0, doneFolders: activeFolders) }

        var dirs: Set<String> = []
        for o in mappedFiles where o.kind == .relocate {
            dirs.insert(dirOf(o.src))
            dirs.insert(dirOf(o.dst))
        }
        let sortedDirs = dirs.sorted()
        var present: Set<String> = []
        var listedNames: [String: Set<String>] = [:]
        if !sortedDirs.isEmpty {
            let dirQueue = WorkQueue(sortedDirs)
            let listWidth = min(conc, sortedDirs.count)
            let listedChunks = try await withThrowingTaskGroup(
                of: [(String, [RemoteEntry])].self
            ) { taskGroup in
                for _ in 0..<listWidth {
                    taskGroup.addTask {
                        var local: [(String, [RemoteEntry])] = []
                        while !cancelFlag.isCancelled, let d = dirQueue.next() {
                            do {
                                let entries = try await be.list(d, refresh: true)
                                local.append((d, entries))
                            } catch let e as StorageError where e.code == .notFound {
                                continue
                            }
                        }
                        return local
                    }
                }
                var all: [(String, [RemoteEntry])] = []
                for try await chunk in taskGroup {
                    all.append(contentsOf: chunk)
                }
                return all
            }
            if cancelFlag.isCancelled { return }
            for (d, entries) in listedChunks {
                for e in entries { present.insert(e.path) }
                listedNames[d] = Set(entries.map(\.name))
                ensuredDirs.mark(d)
            }
        }

        func isParked(_ o: RenameOp) -> Bool {
            let tmp = Self.tmpName(o.id)
            return present.contains(joinPath(dirOf(o.dst), tmp)) ||
                present.contains(joinPath(dirOf(o.src), tmp))
        }

        let parkedIds = Set(
            mappedFiles
                .filter { $0.kind == .relocate && $0.src != $0.dst && isParked($0) }
                .map(\.id)
        )
        var cand = mappedFiles.filter {
            $0.kind == .relocate &&
                $0.src != $0.dst &&
                (present.contains($0.dst) || parkedIds.contains($0.id))
        }
        while true {
            let vacating = Set(
                cand.filter { present.contains($0.dst) && !parkedIds.contains($0.id) }.map(\.dst)
            )
            let keep = cand.filter { !present.contains($0.src) || vacating.contains($0.src) }
            if keep.count == cand.count { break }
            cand = keep
        }

        let undoing = Set(cand.map(\.id))
        var inverse: [RenameOp] = []
        var parkedInverse: [RenameOp] = []
        var byId: [OpId: RenameOp] = [:]
        var rest: [RenameOp] = []

        for o in mappedFiles {
            if o.kind != .relocate || o.src == o.dst {
                rest.append(o)
            } else if !present.contains(o.dst) && !parkedIds.contains(o.id) {
                try await finish(o, "目标已不存在：\(o.dst)", nil)
            } else if !undoing.contains(o.id) {
                try await finish(o, "原位置已被占用：\(o.src)", nil)
            } else {
                let inv = RenameOp(
                    id: o.id,
                    kind: o.kind,
                    phase: o.phase,
                    src: o.dst,
                    dst: o.src,
                    group: o.group
                )
                if parkedIds.contains(o.id) {
                    parkedInverse.append(inv)
                } else {
                    inverse.append(inv)
                }
                byId[o.id] = o
            }
        }

        let byIdSnapshot = byId

        @Sendable func landed(_ inv: RenameOp) async throws {
            undoState.markTaken(inv.dst)
            if let orig = byIdSnapshot[inv.id] {
                try await finish(orig, nil, nil)
            }
        }

        @Sendable func landedBatch(_ invOps: [RenameOp]) async throws {
            guard !invOps.isEmpty else { return }
            var updates: [(op: OpId, status: OpStatus, error: String?)] = []
            var origOps: [RenameOp] = []
            updates.reserveCapacity(invOps.count)
            origOps.reserveCapacity(invOps.count)
            for inv in invOps {
                undoState.markTaken(inv.dst)
                if let orig = byIdSnapshot[inv.id] {
                    updates.append((op: orig.id, status: .undone, error: nil))
                    origOps.append(orig)
                }
            }
            guard !updates.isEmpty else { return }
            try await self.history.markBatch(batch: batch, updates: updates)
            undoState.recordAndYieldBatch(
                ops: origOps,
                cancelFlag: cancelFlag,
                continuation: continuation
            )
            await Task.yield()
        }

        @Sendable func invOne(_ inv: RenameOp, _ retry: Bool) async throws {
            do {
                try await self.apply(
                    be: be,
                    op: inv,
                    resuming: retry,
                    srcTaken: undoState.isTaken(inv.src),
                    ensuredDirs: ensuredDirs
                )
            } catch {
                if let orig = byIdSnapshot[inv.id] {
                    try await finish(orig, nil, executionErrorMessage(error))
                }
                return
            }
            try await landed(inv)
        }

        @Sendable func invFail(_ inv: RenameOp, _ err: any Error) async throws {
            if let orig = byIdSnapshot[inv.id] {
                try await finish(orig, nil, executionErrorMessage(err))
            }
        }

        @Sendable func invStagedRetry(_ ops: [RenameOp]) async throws {
            try await self.runStaged(
                group: ops,
                be: be,
                width: conc,
                stage: true,
                resuming: true,
                isTaken: { undoState.isTaken($0) },
                isBlocked: { _ in false },
                one: { inv, _ in try await invOne(inv, true) },
                parkFailed: invFail,
                isCancelled: { cancelFlag.isCancelled }
            )
        }

        let left: [RenameOp]
        if be.supportsServerBatching {
            let prelistedBox = PrelistedBox(listedNames)
            left = try await batched(
                group: inverse,
                be: be,
                blockerOf: { _ in nil },
                recordBatch: landedBatch,
                one: invOne,
                failOp: invFail,
                retryStaged: invStagedRetry,
                isCancelled: { cancelFlag.isCancelled },
                prelisted: prelistedBox,
                ensuredDirs: ensuredDirs
            )
        } else {
            left = inverse
        }
        if cancelFlag.isCancelled { return }

        try await runStaged(
            group: left,
            be: be,
            width: conc,
            stage: true,
            resuming: false,
            isTaken: { undoState.isTaken($0) },
            isBlocked: { _ in false },
            one: invOne,
            parkFailed: invFail,
            isCancelled: { cancelFlag.isCancelled }
        )

        for inv in parkedInverse {
            if cancelFlag.isCancelled { return }
            try await invOne(inv, true)
        }

        if !rest.isEmpty {
            let restQueue = WorkQueue(rest)
            let restWidth = min(conc, rest.count)
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for _ in 0..<restWidth {
                    taskGroup.addTask {
                        while !cancelFlag.isCancelled, let op = restQueue.next() {
                            _ = try await undoOne(op)
                        }
                    }
                }
                try await taskGroup.waitForAll()
            }
        }

        for op in mappedMkdirs {
            if cancelFlag.isCancelled { return }
            _ = try await undoOne(op)
        }
    }

    private func undoSingleOp(
        be: any StorageBackend,
        op: RenameOp,
        ensuredDirs: EnsuredDirsBox? = nil
    ) async throws -> String? {
        switch op.kind {
        case .delete:
            return "删除无法撤销"
        case .mkdir:
            if !(try await be.exists(op.dst)) { return nil }
            if !(try await be.list(op.dst, refresh: true)).isEmpty {
                return "文件夹非空，已保留"
            }
            try await be.remove(dir: dirOf(op.dst), names: [baseOf(op.dst)])
            ensuredDirs?.invalidate(prefix: op.dst)
            return nil
        case .write:
            if op.overwrite { return "覆盖写入无法撤销" }
            if !(try await be.exists(op.dst)) { return nil }
            try await be.remove(dir: dirOf(op.dst), names: [baseOf(op.dst)])
            return nil
        case .relocate:
            if op.src == op.dst { return nil }
            if try await be.exists(op.src) {
                let reason = "原位置已被占用：\(op.src)"
                if op.phase == .folders {
                    throw StorageError(.alreadyExists, reason)
                }
                return reason
            }
            if !(try await be.exists(op.dst)) {
                return "目标已不存在：\(op.dst)"
            }
            try await relocate(
                be: be,
                src: op.dst,
                dst: op.src,
                id: op.id,
                resuming: false,
                ensuredDirs: ensuredDirs
            )
            if op.phase == .folders {
                ensuredDirs?.invalidate(prefix: op.dst)
            }
            return nil
        }
    }
}
