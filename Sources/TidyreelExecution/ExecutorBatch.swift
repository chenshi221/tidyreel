import Foundation
import TidyreelModels

extension DefaultExecutor {
    // MARK: - Batched Helpers

    internal func batched(
        group: [RenameOp],
        be: any StorageBackend,
        blockerOf: @escaping @Sendable (RenameOp) -> RenameOp?,
        recordBatch: @escaping @Sendable ([RenameOp]) async throws -> Void,
        one: @escaping @Sendable (RenameOp, Bool) async throws -> Void,
        failOp: @escaping @Sendable (RenameOp, any Error) async throws -> Void,
        retryStaged: @escaping @Sendable ([RenameOp]) async throws -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        prelisted: PrelistedBox?,
        ensuredDirs: EnsuredDirsBox?
    ) async throws -> [RenameOp] {
        var rest: [RenameOp] = []
        var dirOrder: [String] = []
        var bySrcDir: [String: [RenameOp]] = [:]

        for op in group {
            if op.kind == .relocate && op.src != op.dst && blockerOf(op) == nil {
                let d = dirOf(op.src)
                if bySrcDir[d] == nil { dirOrder.append(d) }
                bySrcDir[d, default: []].append(op)
            } else {
                rest.append(op)
            }
        }

        for dir in dirOrder {
            if isCancelled() { return [] }
            guard let ops = bySrcDir[dir] else { continue }
            if ops.count < 2 {
                rest.append(contentsOf: ops)
                continue
            }

            let taken: Set<String>
            if let cached = prelisted?.remove(dir) {
                taken = cached
            } else {
                do {
                    let entries = try await be.list(dir, refresh: true)
                    taken = Set(entries.map(\.name))
                } catch {
                    for o in ops {
                        if isCancelled() { return [] }
                        try await failOp(o, error)
                    }
                    continue
                }
            }

            var targets: [String: Int] = [:]
            for o in ops {
                let n = baseOf(o.dst)
                if baseOf(o.src) != n {
                    targets[n, default: 0] += 1
                }
            }

            var batch: [RenameOp] = []
            var viaTmp: [RenameOp] = []
            for o in ops {
                let n = baseOf(o.dst)
                let renames = baseOf(o.src) != n
                if !renames {
                    batch.append(o)
                } else if targets[n] == 1 && !taken.contains(n) {
                    batch.append(o)
                } else if targets[n] == 1 && dirOf(o.dst) == dir {
                    viaTmp.append(o)
                } else {
                    rest.append(o)
                }
            }

            while !viaTmp.isEmpty {
                var vacating = Set(batch.map { baseOf($0.src) })
                vacating.formUnion(viaTmp.map { baseOf($0.src) })
                var keep: [RenameOp] = []
                for o in viaTmp {
                    if vacating.contains(baseOf(o.dst)) {
                        keep.append(o)
                    } else {
                        rest.append(o)
                    }
                }
                if keep.count == viaTmp.count { break }
                viaTmp = keep
            }

            var retry: [RenameOp] = []
            var fresh: [RenameOp] = []
            var stagedRetry: [RenameOp] = []

            var renames: [String: String] = [:]
            for o in batch where baseOf(o.src) != baseOf(o.dst) {
                renames[baseOf(o.src)] = baseOf(o.dst)
            }
            for o in viaTmp {
                renames[baseOf(o.src)] = Self.tmpName(o.id)
            }

            do {
                if !renames.isEmpty {
                    try await be.renameMany(dir, names: renames)
                }
            } catch {
                if !viaTmp.isEmpty {
                    stagedRetry.append(contentsOf: batch)
                    stagedRetry.append(contentsOf: viaTmp)
                } else {
                    retry.append(contentsOf: batch)
                }
                batch.removeAll()
                viaTmp.removeAll()
            }

            let viaTmpTargets = Set(viaTmp.map { baseOf($0.dst) })
            var dstOrder: [String] = []
            var byDstDir: [String: [RenameOp]] = [:]
            for o in batch {
                let d = dirOf(o.dst)
                if d != dir {
                    if byDstDir[d] == nil { dstOrder.append(d) }
                    byDstDir[d, default: []].append(o)
                }
            }

            var stillOccupied: Set<String> = []
            for dst in dstOrder {
                guard let moving = byDstDir[dst] else { continue }
                _ = prelisted?.remove(dst)
                do {
                    try await ensureDir(be, dst, ensuredDirs: ensuredDirs)
                    try await be.move(srcDir: dir, dstDir: dst, names: moving.map { baseOf($0.dst) })
                } catch {
                    let movingIds = Set(moving.map(\.id))
                    batch.removeAll { movingIds.contains($0.id) }
                    do {
                        let nowInDir = Set((try await be.list(dir, refresh: true)).map(\.name))
                        var back: [String: String] = [:]
                        var rolled: [RenameOp] = []
                        var notRolled: [RenameOp] = []
                        for o in moving {
                            let srcName = baseOf(o.src)
                            let dstName = baseOf(o.dst)
                            if renames[srcName] != nil &&
                                nowInDir.contains(dstName) &&
                                !nowInDir.contains(srcName) &&
                                !viaTmpTargets.contains(srcName)
                            {
                                back[dstName] = srcName
                                rolled.append(o)
                            } else if renames[srcName] == nil && nowInDir.contains(dstName) {
                                stillOccupied.insert(srcName)
                                rolled.append(o)
                            } else {
                                if nowInDir.contains(srcName) {
                                    stillOccupied.insert(srcName)
                                }
                                notRolled.append(o)
                            }
                        }
                        if !back.isEmpty {
                            try await be.renameMany(dir, names: back)
                        }
                        fresh.append(contentsOf: rolled)
                        retry.append(contentsOf: notRolled)
                    } catch {
                        for o in moving {
                            stillOccupied.insert(baseOf(o.src))
                        }
                        retry.append(contentsOf: moving)
                    }
                }
            }

            var blockedViaTmp: [RenameOp] = []
            if !stillOccupied.isEmpty && !viaTmp.isEmpty {
                var blockedNames = stillOccupied
                var progressed = true
                while progressed {
                    progressed = false
                    var remaining: [RenameOp] = []
                    for o in viaTmp {
                        if blockedNames.contains(baseOf(o.dst)) {
                            blockedViaTmp.append(o)
                            blockedNames.insert(baseOf(o.src))
                            progressed = true
                        } else {
                            remaining.append(o)
                        }
                    }
                    viaTmp = remaining
                }
            }

            if !viaTmp.isEmpty {
                do {
                    var finalizeNames: [String: String] = [:]
                    for o in viaTmp {
                        finalizeNames[Self.tmpName(o.id)] = baseOf(o.dst)
                    }
                    try await be.renameMany(dir, names: finalizeNames)
                    batch.append(contentsOf: viaTmp)
                } catch {
                    retry.append(contentsOf: viaTmp)
                }
            }

            try await recordBatch(batch)
            for o in fresh {
                if isCancelled() { return [] }
                try await one(o, false)
            }
            for o in retry {
                if isCancelled() { return [] }
                try await one(o, true)
            }
            for o in blockedViaTmp {
                if isCancelled() { return [] }
                do {
                    if !(try await be.exists(o.dst)) {
                        try await one(o, true)
                    } else {
                        let tmpPath = joinPath(dir, Self.tmpName(o.id))
                        if try await be.exists(tmpPath), !(try await be.exists(o.src)) {
                            try? await be.rename(tmpPath, newName: baseOf(o.src))
                        }
                        try await failOp(o, StorageError(.alreadyExists, o.dst))
                    }
                } catch {
                    try await failOp(o, error)
                }
            }
            if !stagedRetry.isEmpty {
                if isCancelled() { return [] }
                try await retryStaged(stagedRetry)
            }
        }
        return rest
    }
}
