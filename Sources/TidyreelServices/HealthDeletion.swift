import Foundation
import TidyreelModels

public enum HealthDeletion {
    /// The confirmation owns a history batch, without a resumable organizer task.
    /// All selected paths are durable before the first storage mutation.
    @MainActor
    public static func run(
        confirmation: UUID, connection: ConnectionId, root: String,
        files: [(path: String, identity: String?)], directories: [String] = [],
        keepers: [DuplicateMediaCopy]? = nil,
        history: any HistoryStore, backend: any StorageBackend,
        willAttempt: (RenameOp) -> Void, didRemove: (RenameOp) -> Void
    ) async throws {
        let protectedRoots: Set<String> = ["/", normalizeDir(root)]
        var ops = files.map {
            RenameOp(id: OpId($0.path), kind: .healthDeleteFile, phase: .cleanup,
                     src: $0.path, dst: "", deleteIdentity: $0.identity)
        }
        ops += directories.filter { !protectedRoots.contains(normalizeDir($0)) }.map {
            RenameOp(id: OpId($0), kind: .healthDeleteEmptyDirectory, phase: .cleanup, src: $0, dst: "")
        }
        guard !ops.isEmpty else { return }
        let owner = TaskId("health-\(confirmation.uuidString)")
        let batch = try await history.beginBatch(task: owner, connection: connection, ops: ops)
        for op in ops {
            try Task.checkCancellation()
            if let keepers, try await !HealthScannerActor.hasSurvivingCopy(keepers, backend: backend) {
                let message = "无法确认仍有保留副本，已停止删除"
                try await history.mark(batch: batch, op: op.id, status: .skipped, error: message)
                throw StorageError(.other, message)
            }

            if op.kind == .healthDeleteFile && op.deleteIdentity == nil {
                let message = "缺少文件标识，已保留：\(op.src)"
                try await history.mark(batch: batch, op: op.id, status: .skipped, error: message)
                throw StorageError(.other, message)
            }
            willAttempt(op)
            let removed: Bool
            do {
                if op.kind == .healthDeleteEmptyDirectory {
                    removed = try await backend.removeDirectoryIfEmpty(op.src, removingSystemFiles: true)
                } else {
                    try await backend.removeScannedFile(op.src, identity: op.deleteIdentity)
                    removed = true
                }
            } catch let error as StorageError where error.code == .notFound {
                try await history.mark(batch: batch, op: op.id, status: .skipped, error: error.localizedDescription)
                continue
            } catch {
                // A transport error can arrive after the server committed the deletion.
                // Preserve the uncertainty in the log; only a new confirmation may try again.
                try await history.mark(batch: batch, op: op.id, status: .pending, error: error.localizedDescription)
                throw error
            }
            if removed { didRemove(op) }
            try await history.mark(batch: batch, op: op.id, status: removed ? .done : .skipped,
                                   error: removed ? nil : "目录非空或存储端不支持安全删除")
        }
    }
}
