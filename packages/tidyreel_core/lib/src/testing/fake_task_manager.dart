import 'dart:async';

import '../model/media.dart';
import '../model/ids.dart';
import '../model/plan.dart';
import '../model/task.dart';
import '../task/task_manager.dart';
import 'demo_data.dart';

/// Walks every task through the real stage sequence with [Demo] data, so the UI
/// can be built and demoed before the engine exists. [step] = delay per tick.
class FakeTaskManager implements TaskManager {
  final Duration step;
  final _tasks = <TaskId, TaskSummary>{};
  final _reviews = <TaskId, TaskReview>{};
  final _controller = StreamController<List<TaskSummary>>.broadcast();
  var _seq = 10;

  FakeTaskManager({this.step = const Duration(milliseconds: 120)});

  void _put(TaskSummary t) {
    _tasks[t.id] = t;
    _controller.add(_snapshot());
  }

  List<TaskSummary> _snapshot() =>
      _tasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  TaskSummary _with(
    TaskId id,
    TaskStage stage,
    String message, {
    int? imported,
    double? progress,
    BatchId? batch,
  }) {
    final t = _tasks[id]!;
    return TaskSummary(
      id: id,
      connection: t.connection,
      paths: t.paths,
      mode: t.mode,
      scrape: t.scrape,
      stage: stage,
      message: message,
      importedCount: imported ?? t.importedCount,
      videoCount: t.videoCount,
      folderCount: t.folderCount,
      subtitleCount: t.subtitleCount,
      progress: progress,
      batch: batch ?? t.batch,
      createdAt: t.createdAt,
    );
  }

  bool _cancelled(TaskId id) => _tasks[id]!.stage == TaskStage.cancelled;

  @override
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode, {
    bool scrape = false,
  }) async {
    final id = TaskId(
      'T${++_seq}-${DateTime.now().microsecondsSinceEpoch.toRadixString(16).substring(5, 11)}',
    );
    final review = Demo.review(id, connection, paths.first);
    _reviews[id] = review;
    final files = review.scan.groups.expand((g) => g.files).toList();
    _put(
      TaskSummary(
        id: id,
        connection: connection,
        paths: paths,
        mode: mode,
        scrape: scrape,
        stage: TaskStage.importing,
        message: '正在导入文件',
        videoCount: files.where((f) => f.role == FileRole.video).length,
        subtitleCount: files.where((f) => f.role == FileRole.subtitle).length,
        folderCount: review.scan.groups.length,
        createdAt: DateTime.now(),
      ),
    );
    unawaited(_pipeline(id, files.length + review.scan.unassigned.length));
    return id;
  }

  Future<void> _pipeline(TaskId id, int total) async {
    for (var i = 0; i <= total; i += 7) {
      await Future<void>.delayed(step);
      if (_cancelled(id)) return;
      _put(_with(id, TaskStage.importing, '正在导入文件', imported: i));
    }
    _put(_with(id, TaskStage.recognizing, '正在识别', imported: total));
    await Future<void>.delayed(step * 3);
    if (_cancelled(id)) return;
    _put(_with(id, TaskStage.recognizing, '锚点识别完成，正在进行后续处理'));
    await Future<void>.delayed(step * 3);
    if (_cancelled(id)) return;
    _put(_with(id, TaskStage.awaitingReview, '识别完成，请确认结果后继续执行'));
  }

  @override
  Stream<List<TaskSummary>> watchAll() async* {
    yield _snapshot();
    yield* _controller.stream;
  }

  @override
  Future<TaskReview> review(TaskId id) async => _reviews[id]!;

  @override
  Future<TaskReview> updateDecision(
    TaskId id,
    GroupId group,
    GroupDecision decision,
  ) async {
    final r = _reviews[id]!;
    return _reviews[id] = TaskReview(
      id: id,
      scan: r.scan,
      decisions: {...r.decisions, group: decision},
      preview: r.preview,
    );
  }

  @override
  Future<TaskReview> setMode(TaskId id, OrganizeMode mode) async {
    final t = _tasks[id]!;
    _put(
      TaskSummary(
        id: id,
        connection: t.connection,
        paths: t.paths,
        mode: mode,
        scrape: t.scrape,
        stage: t.stage,
        message: t.message,
        importedCount: t.importedCount,
        videoCount: t.videoCount,
        folderCount: t.folderCount,
        subtitleCount: t.subtitleCount,
        createdAt: t.createdAt,
      ),
    );
    return _reviews[id]!;
  }

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) async {
    final ops = _reviews[id]!.preview.ops.where((o) => o.selected).toList();
    for (final (stage, phase, label) in [
      (TaskStage.renamingFiles, ExecPhase.files, '正在重命名文件'),
      (TaskStage.renamingFolders, ExecPhase.folders, '正在整理文件夹'),
    ]) {
      final total = ops.where((o) => o.phase == phase).length;
      for (var i = 0; i <= total; i += 5) {
        if (_cancelled(id)) return;
        _put(_with(id, stage, label, progress: total == 0 ? 1 : i / total));
        await Future<void>.delayed(step);
      }
    }
    _put(
      _with(id, TaskStage.done, '整理完成', batch: BatchId('batch-${id.value}')),
    );
  }

  @override
  Future<void> cancel(TaskId id) async =>
      _put(_with(id, TaskStage.cancelled, '已取消'));

  @override
  Future<void> undo(TaskId id, {Set<OpId>? only}) async {
    await Future<void>.delayed(step);
    _put(_with(id, TaskStage.undone, '已撤销'));
  }

  @override
  Future<void> retryFailed(TaskId id) async {
    await Future<void>.delayed(step);
    _put(_with(id, TaskStage.done, '整理完成'));
  }

  @override
  Future<void> retry(TaskId id) async {
    _put(_with(id, TaskStage.importing, '正在导入文件', imported: 0));
    final r = _reviews[id]!;
    unawaited(
      _pipeline(
        id,
        r.scan.groups.expand((g) => g.files).length + r.scan.unassigned.length,
      ),
    );
  }

  @override
  Future<void> delete(TaskId id) async {
    _tasks.remove(id);
    _controller.add(_snapshot());
  }

  void dispose() => _controller.close();
}
