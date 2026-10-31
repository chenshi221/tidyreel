import '../exec/executor.dart';
import '../model/history.dart';
import '../model/ids.dart';
import '../model/plan.dart';

class MemoryHistoryStore implements HistoryStore {
  final _batches = <BatchId, ({TaskId task, ConnectionId conn, DateTime at})>{};
  final _records = <BatchId, List<HistoryRecord>>{};
  var _seq = 0;

  @override
  Future<BatchId> beginBatch(
    TaskId task,
    ConnectionId connection,
    List<RenameOp> ops,
  ) async {
    final id = BatchId('b${++_seq}');
    final now = DateTime.now();
    _batches[id] = (task: task, conn: connection, at: now);
    _records[id] = [
      for (final op in ops)
        HistoryRecord(
          batch: id,
          op: op,
          status: OpStatus.pending,
          updatedAt: now,
        ),
    ];
    return id;
  }

  @override
  Future<void> mark(
    BatchId batch,
    OpId op,
    OpStatus status, {
    String? error,
  }) async {
    final list = _records[batch]!;
    final i = list.indexWhere((r) => r.op.id == op);
    list[i] = HistoryRecord(
      batch: batch,
      op: list[i].op,
      status: status,
      error: error,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<List<HistoryRecord>> records(BatchId batch) async =>
      List.of(_records[batch] ?? []);

  @override
  Future<List<BatchSummary>> batches() async => [
    for (final MapEntry(key: id, value: b) in _batches.entries)
      BatchSummary(
        id: id,
        task: b.task,
        connection: b.conn,
        createdAt: b.at,
        total: _records[id]!.length,
        done: _records[id]!.where((r) => r.status == OpStatus.done).length,
        failed: _records[id]!.where((r) => r.status == OpStatus.failed).length,
        undone:
            _records[id]!.every((r) => r.status != OpStatus.done) &&
            _records[id]!.any((r) => r.status == OpStatus.undone),
      ),
  ].reversed.toList();

  @override
  Future<bool> isOrganized(ConnectionId connection, String path) async {
    for (final MapEntry(key: id, value: b) in _batches.entries) {
      if (b.conn != connection) continue;
      if (_records[id]!.any(
        (r) => r.status == OpStatus.done && r.op.dst == path,
      )) {
        return true;
      }
    }
    return false;
  }
}
