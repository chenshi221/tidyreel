import Foundation
import TidyreelModels

extension DefaultExecutor {
    /// Closed rename graphs need a durable boundary between vacating names and filling them.
    /// Once landing starts, a public source name can already belong to its predecessor.
    internal func performCycles(
        in ops: [RenameOp], batch: BatchId, backend: any StorageBackend,
        phases: [OpId: RelocationCyclePhase], undo: Bool, resuming: Bool,
        cancelled: () -> Bool, blocked: (RenameOp) -> Bool,
        landed: (RenameOp) async throws -> Void
    ) async throws -> [RenameOp] {
        let parking: RelocationCyclePhase = undo ? .undoParking : .parking
        let landing: RelocationCyclePhase = undo ? .undoLanding : .landing
        var handled = Set<OpId>()

        func stagingID(_ op: RenameOp) -> OpId {
            let direction = undo ? "undo" : "forward"
            let token = Self.writtenDigest(Data("\(batch.value)\u{0}\(direction)\u{0}\(op.id.value)".utf8))
            return OpId(token.replacingOccurrences(of: "/", with: "_"))
        }

        func finish(_ op: RenameOp) async throws {
            var stagedOp = op
            stagedOp.id = stagingID(op)
            let parked = try await findParked(be: backend, op: stagedOp)
            if parked == .none {
                guard try await backend.exists(op.dst) else { throw StorageError(.notFound, op.dst) }
            } else {
                try await relocate(be: backend, src: op.src, dst: op.dst, id: stagedOp.id,
                                   resuming: true, srcGone: true, parkedAt: parked)
            }
            try await landed(op)
            handled.insert(op.id)
        }

        for op in ops where phases[op.id] == landing {
            if cancelled() { return [] }
            try await finish(op)
        }

        let remaining = ops.filter { !handled.contains($0.id) }
        for cycle in Self.relocationCycles(in: remaining) {
            if cancelled() { return [] }
            if cycle.contains(where: blocked) {
                throw TidyreelExecutionError.invalidState("环形改名的依赖未完成，请先处理失败的操作")
            }

            let ids = cycle.map(\.id)
            let recorded = cycle.allSatisfy { phases[$0.id] == parking }
            if resuming && !recorded && !cycle.allSatisfy({ phases[$0.id] == .planned }) {
                // Older journals cannot tell a fully landed cycle from its untouched sources.
                throw TidyreelExecutionError.invalidState("旧日志无法确认环形改名进度，已保留文件，请核对后重新规划")
            }
            if !recorded { try await history.setCyclePhase(parking, batch: batch, ops: ids) }
            for op in cycle {
                if cancelled() { return [] }
                let name = Self.tmpName(stagingID(op))
                let temp = joinPath(dirOf(op.src), name)
                if try await backend.exists(temp) {
                    guard !(try await backend.exists(op.src)) else { throw StorageError(.alreadyExists, temp) }
                } else if undo && !recorded {
                    // An undo interrupted by a previous release used the operation-only staging name.
                    let legacy = joinPath(dirOf(op.src), Self.tmpName(op.id))
                    let source = try await backend.exists(op.src) ? op.src : legacy
                    try await backend.rename(source, newName: name)
                } else {
                    try await backend.rename(op.src, newName: name)
                }
            }
            // No public destination is populated until this transaction commits for the whole cycle.
            try await history.setCyclePhase(landing, batch: batch, ops: ids)
            for op in cycle {
                if cancelled() { return [] }
                try await finish(op)
            }
        }
        let rest = ops.filter { !handled.contains($0.id) }
        if rest.contains(where: { phases[$0.id] == parking }) {
            throw TidyreelExecutionError.invalidState("请整批继续未完成的环形改名")
        }
        return rest
    }

    private static func relocationCycles(in ops: [RenameOp]) -> [[RenameOp]] {
        let moves = ops.filter { $0.kind == .relocate && $0.src != $0.dst }
        let bySource = Dictionary(grouping: moves, by: \.src)
        var visited = Set<String>()
        var cycles = [[RenameOp]]()
        for start in moves where !visited.contains(start.src) {
            var chain = [RenameOp]()
            var indices = [String: Int]()
            var path = start.src
            while visited.insert(path).inserted, let next = bySource[path], next.count == 1 {
                indices[path] = chain.count
                chain.append(next[0])
                path = next[0].dst
            }
            if let index = indices[path] { cycles.append(Array(chain[index...])) }
        }
        return cycles
    }
}
