import '../model/history.dart';
import '../model/ids.dart';
import '../model/plan.dart';
import '../storage/storage_backend.dart';

/// Owner: Agent E. Persistence of executed ops; the app implements it with drift.
abstract interface class HistoryStore {
  /// Records all selected ops as [OpStatus.pending] before anything runs.
  Future<BatchId> beginBatch(
    TaskId task,
    ConnectionId connection,
    List<RenameOp> ops,
  );
  Future<void> mark(BatchId batch, OpId op, OpStatus status, {String? error});
  Future<List<HistoryRecord>> records(BatchId batch);
  Future<List<BatchSummary>> batches();

  /// For the 只看未整理的 filter: was [path] produced by a done op on [connection]?
  Future<bool> isOrganized(ConnectionId connection, String path);
}

/// Owner: Agent E. PLAN §4.3 (write-ahead log, ordering, throttling, undo).
abstract interface class Executor {
  Stream<ExecProgress> execute(
    TaskId task,
    ConnectionId connection,
    RenamePlan plan,
    StorageBackend backend,
  );

  /// Continue a batch that has pending ops (after a crash).
  Stream<ExecProgress> resume(BatchId batch, StorageBackend backend);

  /// Reverse done ops in reverse order; [only] limits to some ops. Never overwrites.
  Stream<ExecProgress> undo(
    BatchId batch,
    StorageBackend backend, {
    Set<OpId>? only,
  });
}

class DefaultExecutor implements Executor {
  final HistoryStore history;

  DefaultExecutor(this.history);

  @override
  Stream<ExecProgress> execute(
    TaskId task,
    ConnectionId connection,
    RenamePlan plan,
    StorageBackend backend,
  ) => throw UnimplementedError('Agent E');

  @override
  Stream<ExecProgress> resume(BatchId batch, StorageBackend backend) =>
      throw UnimplementedError('Agent E');

  @override
  Stream<ExecProgress> undo(
    BatchId batch,
    StorageBackend backend, {
    Set<OpId>? only,
  }) => throw UnimplementedError('Agent E');
}
