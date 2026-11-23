import 'dart:async';

import '../model/media.dart';
import '../model/ids.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../model/task.dart';
import '../plan/text.dart';
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
      scrapeOnly: t.scrapeOnly,
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
    bool scrapeOnly = false,
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
        scrape: scrape || scrapeOnly,
        scrapeOnly: scrapeOnly,
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
        scrapeOnly: t.scrapeOnly,
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
  Future<TaskReview> assignUnassigned(
    TaskId id,
    String filePath,
    GroupId targetGroup,
  ) async {
    final r = _reviews[id]!;
    final uIdx = r.scan.unassigned.indexWhere((f) => f.path == filePath);
    if (uIdx < 0) throw ArgumentError('未找到未分组文件：$filePath');
    final gIdx = r.scan.groups.indexWhere((g) => g.id == targetGroup);
    if (gIdx < 0) throw ArgumentError('未找到目标分组：${targetGroup.value}');
    final file = r.scan.unassigned[uIdx];
    final nextUnassigned = [...r.scan.unassigned]..removeAt(uIdx);
    final g = r.scan.groups[gIdx];
    final nextFiles = [...g.files, file]
      ..sort((a, b) => a.path.compareTo(b.path));
    final nextGroups = [...r.scan.groups]
      ..[gIdx] = MediaGroup(
        id: g.id,
        kind: g.kind,
        anchorTitle: g.anchorTitle,
        anchorYear: g.anchorYear,
        rootDir: g.rootDir,
        files: nextFiles,
        match: g.match,
        matchScore: g.matchScore,
        show: g.show,
        suggestedStrategy: g.suggestedStrategy,
        suggestedStrategyReason: g.suggestedStrategyReason,
      );
    final nextScan = ScanResult(
      connection: r.scan.connection,
      roots: r.scan.roots,
      groups: nextGroups,
      unassigned: nextUnassigned,
    );
    return _reviews[id] = TaskReview(
      id: id,
      scan: nextScan,
      decisions: r.decisions,
      preview: r.preview,
    );
  }

  @override
  Future<TaskReview> setUnassignedDelete(
    TaskId id,
    String filePath,
    bool delete,
  ) async {
    final r = _reviews[id]!;
    if (!r.scan.unassigned.any((f) => f.path == filePath)) {
      throw ArgumentError('未找到未分组文件：$filePath');
    }
    var found = false;
    final ops = [
      for (final o in r.preview.ops)
        if (o.kind == OpKind.delete && o.src == filePath)
          () {
            found = true;
            return RenameOp(
              id: o.id,
              kind: o.kind,
              phase: o.phase,
              src: o.src,
              dst: o.dst,
              group: o.group,
              selected: delete,
              warning: o.warning,
              overwrite: o.overwrite,
            );
          }()
        else
          o,
      if (!found && delete)
        RenameOp(
          id: OpId('d-${stableHash(filePath)}'),
          kind: OpKind.delete,
          phase: ExecPhase.cleanup,
          src: filePath,
          dst: '',
          selected: true,
        ),
    ];
    return _reviews[id] = TaskReview(
      id: id,
      scan: r.scan,
      decisions: r.decisions,
      preview: RenamePlan(
        ops: ops,
        conflicts: r.preview.conflicts,
        merges: r.preview.merges,
      ),
    );
  }

  @override
  Future<TaskReview> mergeGroups(
    TaskId id,
    GroupId keep,
    GroupId absorb,
  ) async {
    if (keep == absorb) throw ArgumentError('不能将分组与自身合并');
    final r = _reviews[id]!;
    final kIdx = r.scan.groups.indexWhere((g) => g.id == keep);
    final aIdx = r.scan.groups.indexWhere((g) => g.id == absorb);
    if (kIdx < 0 || aIdx < 0) throw ArgumentError('未找到分组');
    final kg = r.scan.groups[kIdx];
    final ag = r.scan.groups[aIdx];
    final combined = {
      for (final f in kg.files) f.path: f,
      for (final f in ag.files) f.path: f,
    }.values.toList()..sort((a, b) => a.path.compareTo(b.path));
    final nextGroups = <MediaGroup>[];
    for (final g in r.scan.groups) {
      if (g.id == absorb) continue;
      if (g.id == keep) {
        nextGroups.add(
          MediaGroup(
            id: g.id,
            kind: g.kind,
            anchorTitle: g.anchorTitle,
            anchorYear: g.anchorYear,
            rootDir: _commonParent(combined, g.rootDir),
            files: combined,
            match: g.match,
            matchScore: g.matchScore,
            show: g.show,
            suggestedStrategy: g.suggestedStrategy,
            suggestedStrategyReason: g.suggestedStrategyReason,
          ),
        );
      } else {
        nextGroups.add(g);
      }
    }
    final nextDecisions = {...r.decisions}..remove(absorb);
    return _reviews[id] = TaskReview(
      id: id,
      scan: ScanResult(
        connection: r.scan.connection,
        roots: r.scan.roots,
        groups: nextGroups,
        unassigned: r.scan.unassigned,
      ),
      decisions: nextDecisions,
      preview: r.preview,
    );
  }

  @override
  Future<TaskReview> splitGroup(
    TaskId id,
    GroupId group,
    Set<String> filePaths,
  ) async {
    final r = _reviews[id]!;
    final gIdx = r.scan.groups.indexWhere((g) => g.id == group);
    if (gIdx < 0) throw ArgumentError('未找到分组：${group.value}');
    final orig = r.scan.groups[gIdx];
    final moved = [
      for (final f in orig.files)
        if (filePaths.contains(f.path)) f,
    ];
    final kept = [
      for (final f in orig.files)
        if (!filePaths.contains(f.path)) f,
    ];
    if (moved.isEmpty || kept.isEmpty) {
      throw ArgumentError('拆分必须选择分组中的部分文件');
    }
    final existingIds = {for (final g in r.scan.groups) g.id.value};
    var newId = 'g-${stableHash('${orig.id.value}|${moved.first.path}')}';
    for (var n = 2; existingIds.contains(newId); n++) {
      newId = 'g-${stableHash('${orig.id.value}|${moved.first.path}|$n')}';
    }
    final movedRoot = _commonParent(moved, orig.rootDir);
    final keptRoot = _commonParent(kept, orig.rootDir);
    final newGroupId = GroupId(newId);
    final updatedOrig = MediaGroup(
      id: orig.id,
      kind: orig.kind,
      anchorTitle: kept.first.parsed?.title ?? orig.anchorTitle,
      anchorYear: orig.anchorYear,
      rootDir: keptRoot,
      files: kept,
      match: orig.match,
      matchScore: orig.matchScore,
      show: orig.show,
      suggestedStrategy: orig.suggestedStrategy,
      suggestedStrategyReason: orig.suggestedStrategyReason,
    );
    final newGroup = MediaGroup(
      id: newGroupId,
      kind: orig.kind,
      anchorTitle: moved.first.parsed?.title ?? stem(moved.first.name),
      rootDir: movedRoot,
      files: moved,
    );
    final nextGroups = [...r.scan.groups]
      ..[gIdx] = updatedOrig
      ..insert(gIdx + 1, newGroup);
    final nextDecisions = {...r.decisions, newGroupId: const GroupDecision()};
    return _reviews[id] = TaskReview(
      id: id,
      scan: ScanResult(
        connection: r.scan.connection,
        roots: r.scan.roots,
        groups: nextGroups,
        unassigned: r.scan.unassigned,
      ),
      decisions: nextDecisions,
      preview: r.preview,
    );
  }

  static String _commonParent(List<ScanFile> files, String fallback) {
    if (files.isEmpty) return fallback;
    List<String> segs(String d) =>
        d.split('/').where((s) => s.isNotEmpty).toList();
    var prefix = segs(
      files.first.isDiscDir ? files.first.path : dirOf(files.first.path),
    );
    for (final f in files.skip(1)) {
      final cur = segs(f.isDiscDir ? f.path : dirOf(f.path));
      var i = 0;
      while (i < prefix.length && i < cur.length && prefix[i] == cur[i]) {
        i++;
      }
      prefix = prefix.sublist(0, i);
    }
    return prefix.isEmpty ? '/' : '/${prefix.join('/')}';
  }

  @override
  Future<List<String>> findEmptyDirs(TaskId id) async => const [];

  @override
  Future<int> removeEmptyDirs(TaskId id, List<String> dirs) async => 0;

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
