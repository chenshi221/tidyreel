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
  Future<void> deleteTask(TaskId task) async {
    final ids = [
      for (final e in _batches.entries)
        if (e.value.task == task) e.key,
    ];
    for (final id in ids) {
      _batches.remove(id);
      _records.remove(id);
    }
  }

  String _mapThroughFolders(BatchId id, String path, {required bool reverse}) {
    final folders = [
      for (final r in _records[id]!)
        if (r.status == OpStatus.done &&
            r.op.phase == ExecPhase.folders &&
            r.op.kind == OpKind.relocate)
          r.op,
    ];
    var cur = path;
    for (final f in reverse ? folders.reversed : folders) {
      final from = reverse ? f.dst : f.src;
      final to = reverse ? f.src : f.dst;
      if (cur == from) {
        cur = to;
      } else if (cur.startsWith('$from/')) {
        cur = '$to${cur.substring(from.length)}';
      }
    }
    return cur;
  }

  @override
  Future<bool> isOrganized(ConnectionId connection, String path) async {
    for (final MapEntry(key: id, value: b) in _batches.entries) {
      if (b.conn != connection) continue;
      final preFolder = _mapThroughFolders(id, path, reverse: true);
      if (_records[id]!.any(
        (r) =>
            r.status == OpStatus.done &&
            (r.op.dst == path || r.op.dst == preFolder),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<Set<String>> areOrganized(
    ConnectionId connection,
    Iterable<String> paths,
  ) async {
    final target = paths.toSet();
    if (target.isEmpty) return const {};
    final out = <String>{};
    for (final MapEntry(key: id, value: b) in _batches.entries) {
      if (b.conn != connection) continue;
      for (final r in _records[id]!) {
        if (r.status != OpStatus.done || r.op.dst.isEmpty) continue;
        if (target.contains(r.op.dst)) out.add(r.op.dst);
        final postFolder = _mapThroughFolders(id, r.op.dst, reverse: false);
        if (target.contains(postFolder)) out.add(postFolder);
      }
    }
    return out;
  }
}
