import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'codec.dart';
import 'database.dart';

/// [TaskStore] on drift. Summary and review columns are written separately so the
/// frequent summary updates never rewrite the (large) scan JSON.
class DriftTaskStore implements TaskStore {
  final AppDatabase db;

  DriftTaskStore(this.db);

  @override
  Future<void> saveSummary(TaskSummary s) => db
      .into(db.tasks)
      .insertOnConflictUpdate(
        TasksCompanion.insert(
          id: s.id.value,
          connectionId: s.connection.value,
          pathsJson: jsonEncode(s.paths),
          mode: s.mode.name,
          stage: s.stage.name,
          message: s.message,
          importedCount: s.importedCount,
          videoCount: s.videoCount,
          folderCount: s.folderCount,
          subtitleCount: s.subtitleCount,
          progress: Value(s.progress),
          batchId: Value(s.batch?.value),
          createdAt: s.createdAt,
        ),
      );

  @override
  Future<void> saveReview(
    TaskId id,
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
  ) => (db.update(db.tasks)..where((t) => t.id.equals(id.value))).write(
    TasksCompanion(
      scanJson: Value(scanToJson(scan)),
      decisionsJson: Value(decisionsToJson(decisions)),
    ),
  );

  @override
  Future<void> delete(TaskId id) =>
      (db.delete(db.tasks)..where((t) => t.id.equals(id.value))).go();

  @override
  Future<List<StoredTask>> loadAll() async => [
    for (final r in await db.select(db.tasks).get())
      StoredTask(
        TaskSummary(
          id: TaskId(r.id),
          connection: ConnectionId(r.connectionId),
          paths: (jsonDecode(r.pathsJson) as List).cast<String>(),
          mode: OrganizeMode.values.byName(r.mode),
          stage: TaskStage.values.byName(r.stage),
          message: r.message,
          importedCount: r.importedCount,
          videoCount: r.videoCount,
          folderCount: r.folderCount,
          subtitleCount: r.subtitleCount,
          progress: r.progress,
          batch: r.batchId == null ? null : BatchId(r.batchId!),
          createdAt: r.createdAt,
        ),
        scan: r.scanJson == null ? null : scanFromJson(r.scanJson!),
        decisions: r.decisionsJson == null
            ? const {}
            : decisionsFromJson(r.decisionsJson!),
      ),
  ];
}
