import 'dart:math';

import 'package:drift/drift.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'database.dart';

/// [HistoryStore] on drift. Ops are written as `pending` in one transaction.
class DriftHistoryStore implements HistoryStore {
  final AppDatabase db;
  final _rng = Random();

  DriftHistoryStore(this.db);

  @override
  Future<BatchId> beginBatch(
    TaskId task,
    ConnectionId connection,
    List<RenameOp> ops,
  ) async {
    final now = DateTime.now();
    final id = BatchId(
      'B${now.microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 20).toRadixString(36)}',
    );
    await db.transaction(() async {
      await db
          .into(db.batches)
          .insert(
            BatchesCompanion.insert(
              id: id.value,
              taskId: task.value,
              connectionId: connection.value,
              createdAt: now,
            ),
          );
      await db.batch((b) {
        b.insertAll(db.historyRecords, [
          for (var i = 0; i < ops.length; i++)
            HistoryRecordsCompanion.insert(
              batchId: id.value,
              opId: ops[i].id.value,
              seq: i,
              kind: ops[i].kind.name,
              phase: ops[i].phase.name,
              src: ops[i].src,
              dst: ops[i].dst,
              groupId: Value(ops[i].group?.value),
              selected: ops[i].selected,
              warning: Value(ops[i].warning),
              status: OpStatus.pending.name,
              updatedAt: now,
            ),
        ]);
      });
    });
    return id;
  }

  @override
  Future<void> mark(BatchId batch, OpId op, OpStatus status, {String? error}) =>
      (db.update(db.historyRecords)..where(
            (r) => r.batchId.equals(batch.value) & r.opId.equals(op.value),
          ))
          .write(
            HistoryRecordsCompanion(
              status: Value(status.name),
              error: Value(error),
              updatedAt: Value(DateTime.now()),
            ),
          );

  @override
  Future<List<HistoryRecord>> records(BatchId batch) async {
    final rows =
        await (db.select(db.historyRecords)
              ..where((r) => r.batchId.equals(batch.value))
              ..orderBy([(r) => OrderingTerm.asc(r.seq)]))
            .get();
    return [for (final r in rows) _record(r)];
  }

  HistoryRecord _record(HistoryRow r) => HistoryRecord(
    batch: BatchId(r.batchId),
    op: RenameOp(
      id: OpId(r.opId),
      kind: OpKind.values.byName(r.kind),
      phase: ExecPhase.values.byName(r.phase),
      src: r.src,
      dst: r.dst,
      group: r.groupId == null ? null : GroupId(r.groupId!),
      selected: r.selected,
      warning: r.warning,
    ),
    status: OpStatus.values.byName(r.status),
    error: r.error,
    updatedAt: r.updatedAt,
  );

  @override
  Future<List<BatchSummary>> batches() async {
    final batches =
        await (db.select(db.batches)..orderBy([
              (b) => OrderingTerm.desc(b.createdAt),
              // createdAt has 1 s resolution; rowid breaks ties by insertion order.
              (b) => OrderingTerm.desc(CustomExpression<int>('rowid')),
            ]))
            .get();
    final counts = <String, Map<String, int>>{};
    final status = db.historyRecords.status;
    final n = db.historyRecords.opId.count();
    final q = db.selectOnly(db.historyRecords)
      ..addColumns([db.historyRecords.batchId, status, n])
      ..groupBy([db.historyRecords.batchId, status]);
    for (final row in await q.get()) {
      counts.putIfAbsent(row.read(db.historyRecords.batchId)!, () => {})[row
          .read(status)!] = row.read(
        n,
      )!;
    }
    return [
      for (final b in batches)
        () {
          final c = counts[b.id] ?? const {};
          int of(OpStatus s) => c[s.name] ?? 0;
          return BatchSummary(
            id: BatchId(b.id),
            task: TaskId(b.taskId),
            connection: ConnectionId(b.connectionId),
            createdAt: b.createdAt,
            total: c.values.fold(0, (a, b) => a + b),
            done: of(OpStatus.done),
            failed: of(OpStatus.failed),
            undone: of(OpStatus.done) == 0 && of(OpStatus.undone) > 0,
          );
        }(),
    ];
  }

  @override
  Future<bool> isOrganized(ConnectionId connection, String path) async {
    final q =
        db.selectOnly(db.historyRecords).join([
            innerJoin(
              db.batches,
              db.batches.id.equalsExp(db.historyRecords.batchId),
            ),
          ])
          ..addColumns([db.historyRecords.opId])
          ..where(
            db.batches.connectionId.equals(connection.value) &
                db.historyRecords.dst.equals(path) &
                db.historyRecords.status.equals(OpStatus.done.name),
          )
          ..limit(1);
    return (await q.get()).isNotEmpty;
  }
}
