import 'dart:async';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../exec/executor.dart';
import '../model/history.dart';
import '../model/ids.dart';
import '../model/media.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../model/task.dart';
import '../plan/planner.dart';
import '../plan/recognizer.dart';
import '../storage/cached_backend.dart';
import '../storage/storage_backend.dart';
import '../storage/walk.dart';
import 'task_manager.dart';

/// Per-task mutable state. Only [DefaultTaskManager] touches it.
class _Task {
  TaskSummary summary;
  ScanResult? scan;
  Map<GroupId, GroupDecision> decisions;
  RenamePlan? plan;
  bool cancelled = false;
  bool busy = false;
  StreamSubscription<ExecProgress>? exec;
  Completer<void>? execDone;
  Future<void> persistQueue = Future.value();

  _Task(this.summary, {this.scan, this.decisions = const {}});
}

/// PLAN §1 state machine on top of recognizer, planner, executor and the stores.
///
/// Construct with the real parts, then call [resumeInterrupted] once at startup:
/// ```dart
/// final tm = DefaultTaskManager(
///   backendFor: (conn) => backends[conn]!,
///   recognizer: AnchorRecognizer(parser, metadata),
///   planner: DefaultPlanner(metadata),
///   executor: DefaultExecutor(historyStore),
///   history: historyStore,
///   store: driftTaskStore,
///   options: (conn, mode) => PlanOptions(mode: mode, libraryRoot: ...),
/// );
/// await tm.resumeInterrupted();
/// ```
class DefaultTaskManager implements TaskManager {
  final StorageBackend Function(ConnectionId) backendFor;
  final Recognizer recognizer;
  final Planner planner;
  final Executor executor;
  final HistoryStore history;
  final TaskStore store;
  final PlanOptions Function(ConnectionId, OrganizeMode) options;

  /// Minimum gap between live import-count updates (~10 per second).
  final Duration importUpdateInterval;
  final Random _rng;

  final _tasks = <TaskId, _Task>{};
  final _interrupted = <TaskId>[];
  final _changes = StreamController<List<TaskSummary>>.broadcast();
  var _seq = 0;
  late final Future<void> _ready;

  DefaultTaskManager({
    required this.backendFor,
    required this.recognizer,
    required this.planner,
    required this.executor,
    required this.history,
    required this.store,
    required this.options,
    this.importUpdateInterval = const Duration(milliseconds: 100),
    Random? random,
  }) : _rng = random ?? Random() {
    _ready = _load();
  }

  // ---- startup ----------------------------------------------------------

  Future<void> _load() async {
    for (final s in await store.loadAll()) {
      _tasks[s.summary.id] = _Task(
        s.summary,
        scan: s.scan,
        decisions: s.decisions,
      );
      final n = int.tryParse(
        RegExp(r'^T(\d+)-').firstMatch(s.summary.id.value)?.group(1) ?? '',
      );
      if (n != null && n > _seq) _seq = n;
    }
    for (final t in _tasks.values.toList()) {
      switch (t.summary.stage) {
        case TaskStage.importing:
        case TaskStage.recognizing:
          // Nothing but the paths survives a mid-import crash: start over.
          t.scan = null;
          _emit(t, _with(t.summary, stage: TaskStage.importing));
          unawaited(_pipeline(t));
        case TaskStage.renamingFiles:
        case TaskStage.renamingFolders:
          _interrupted.add(t.summary.id);
        default:
      }
    }
  }

  /// Continues every task that was executing when the app died. Completes when
  /// they have all finished.
  Future<void> resumeInterrupted() async {
    await _ready;
    final ids = List.of(_interrupted);
    _interrupted.clear();
    await Future.wait(ids.map((id) => _resume(_tasks[id]!)));
  }

  Future<void> _resume(_Task t) async {
    final batch = await _batchOf(t.summary.id);
    if (batch == null) {
      // Died before the write-ahead log was written: nothing ran.
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.awaitingReview,
          message: '上次执行未开始，请重新确认',
        ),
      );
      return;
    }
    _emit(t, _with(t.summary, batch: batch));
    await _drive(
      t,
      executor.resume(batch, backendFor(t.summary.connection)),
      batch,
    );
  }

  // ---- TaskManager --------------------------------------------------------

  @override
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode, {
    bool scrape = false,
  }) async {
    await _ready;
    final cleanPaths = [
      for (final raw in paths)
        raw == '/' ? '/' : raw.replaceFirst(RegExp(r'/+$'), ''),
    ];
    final id = TaskId(
      'T${++_seq}-${_rng.nextInt(1 << 24).toRadixString(16).padLeft(6, '0')}',
    );
    final t = _Task(
      TaskSummary(
        id: id,
        connection: connection,
        paths: List.unmodifiable(cleanPaths),
        mode: mode,
        scrape: scrape,
        stage: TaskStage.importing,
        message: '正在导入文件',
        createdAt: DateTime.now(),
      ),
    );
    _tasks[id] = t;
    _changes.add(_snapshot());
    await _persist(t);
    unawaited(_pipeline(t));
    return id;
  }

  @override
  Stream<List<TaskSummary>> watchAll() async* {
    await _ready;
    yield _snapshot();
    yield* _changes.stream;
  }

  @override
  Future<TaskReview> review(TaskId id) async {
    final t = await _get(id);
    return _review(t);
  }

  @override
  Future<TaskReview> updateDecision(
    TaskId id,
    GroupId group,
    GroupDecision decision,
  ) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    t.decisions = {...t.decisions, group: decision};
    t.plan = await _plan(t);
    await store.saveReview(id, t.scan!, t.decisions);
    return _review(t);
  }

  @override
  Future<TaskReview> setMode(TaskId id, OrganizeMode mode) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    _emit(t, _with(t.summary, mode: mode, message: t.summary.message));
    t.plan = await _plan(t);
    await _persist(t);
    return _review(t);
  }

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    if (t.busy) throw StateError('任务正在处理中');
    t.busy = true;
    try {
      var plan = t.plan ??= await _plan(t);
      if (onlyConfident) plan = _confidentOnly(t, plan);
      if (!plan.canExecute) throw StateError('存在冲突，无法执行');
      // Never report "整理完成" for a run that would touch nothing.
      if (!plan.ops.any((o) => o.selected)) {
        throw StateError('没有可执行的操作：请先勾选要整理的作品');
      }
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.renamingFiles,
          message: '正在重命名文件',
          progress: () => 0,
        ),
      );
      if (t.cancelled) return;
      await _drive(
        t,
        executor.execute(
          id,
          t.summary.connection,
          plan,
          backendFor(t.summary.connection),
        ),
        null,
      );
    } finally {
      t.busy = false;
    }
  }

  @override
  Future<void> retryFailed(TaskId id) async {
    final t = await _get(id);
    final batch = t.summary.batch;
    if (batch == null || t.summary.stage != TaskStage.partiallyFailed) {
      throw StateError('任务没有失败的操作');
    }
    if (t.busy) throw StateError('任务正在处理中');
    t.busy = true;
    try {
      for (final r in await history.records(batch)) {
        if (r.status == OpStatus.failed || r.status == OpStatus.skipped) {
          await history.mark(batch, r.op.id, OpStatus.pending);
        }
      }
      t.cancelled = false;
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.renamingFiles,
          message: '正在重试失败的操作',
          progress: () => 0,
        ),
        force: true,
      );
      await _drive(
        t,
        executor.resume(batch, backendFor(t.summary.connection)),
        batch,
      );
    } finally {
      t.busy = false;
    }
  }

  @override
  Future<void> retry(TaskId id) async {
    final t = await _get(id);
    if (!canRetry(t.summary)) throw StateError('这个任务不能重试');
    if (t.busy) throw StateError('任务正在处理中');
    t
      ..cancelled = false
      ..scan = null
      ..decisions = const {}
      ..plan = null;
    await _set(
      t,
      _with(
        t.summary,
        stage: TaskStage.importing,
        message: '正在导入文件',
        imported: 0,
        progress: () => null,
      ),
      force: true,
    );
    unawaited(_pipeline(t));
  }

  @override
  Future<void> delete(TaskId id) async {
    final t = await _get(id);
    if (t.busy ||
        (t.summary.stage.isActive &&
            t.summary.stage != TaskStage.awaitingReview)) {
      throw StateError('任务正在进行，先取消再删除');
    }
    _tasks.remove(id);
    _changes.add(_snapshot());
    // Let a pending summary write land first so it can't resurrect the row.
    await t.persistQueue;
    await store.delete(id);
    await history.deleteTask(id);
  }

  @override
  Future<void> cancel(TaskId id) async {
    final t = await _get(id);
    if (!t.summary.stage.isActive) return;
    t.cancelled = true;
    // Waits for in-flight ops to be recorded; finished ops stay in history.
    await t.exec?.cancel();
    final done = t.execDone;
    if (done != null && !done.isCompleted) done.complete();
    final batch = t.summary.batch ?? await _batchOf(id);
    await _set(
      t,
      _with(
        t.summary,
        stage: TaskStage.cancelled,
        message: '已取消',
        batch: batch,
      ),
      force: true,
    );
  }

  @override
  Future<void> undo(TaskId id, {Set<OpId>? only}) async {
    final t = await _get(id);
    final batch = t.summary.batch;
    if (batch == null || t.summary.stage.isActive) {
      throw StateError('任务没有可撤销的操作');
    }
    if (t.busy) throw StateError('任务正在撤销中');
    t.busy = true;
    try {
      var skipped = 0;
      await for (final e in executor.undo(
        batch,
        backendFor(t.summary.connection),
        only: only,
      )) {
        if (e.error != null) skipped++;
        _emit(
          t,
          _with(
            t.summary,
            message: '正在撤销（${e.done}/${e.total}）',
            progress: () => e.total == 0 ? 1 : e.done / e.total,
          ),
          force: true,
        );
      }
      final remaining = (await history.records(batch))
          .any((r) => r.status == OpStatus.done);
      final note = skipped == 0 ? '' : '，$skipped 项已跳过';
      await _set(
        t,
        remaining
            ? _with(t.summary, message: '已撤销部分操作$note')
            : _with(t.summary, stage: TaskStage.undone, message: '已撤销$note'),
        force: true,
      );
    } finally {
      t.busy = false;
    }
  }

  // ---- background pipeline -----------------------------------------------

  Future<void> _pipeline(_Task t) async {
    var step = '导入';
    try {
      final s = t.summary;
      final be = backendFor(s.connection);
      await _set(
        t,
        _with(s, stage: TaskStage.importing, message: '正在导入文件', imported: 0),
      );
      final files = await _listAll(t, be);
      if (t.cancelled) return;

      step = '识别';
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.recognizing,
          message: '正在识别（共 ${files.length} 个文件）',
          imported: files.length,
        ),
      );
      final scan = await recognizer.recognize(
        s.connection,
        s.paths,
        files,
        read: be.read,
      );
      if (t.cancelled) return;
      _emit(
        t,
        _with(t.summary, message: '锚点识别完成，正在进行后续处理', imported: files.length),
      );

      step = '生成计划';
      t.scan = scan;
      t.decisions = {
        for (final g in scan.groups)
          g.id: GroupDecision(selected: g.match != null),
      };
      t.plan = await _plan(t);
      if (t.cancelled) return;

      final all = [for (final g in scan.groups) ...g.files, ...scan.unassigned];
      await store.saveReview(s.id, scan, t.decisions);
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.awaitingReview,
          message: '识别完成，请确认结果后继续执行',
          imported: files.length,
          videos: all.where((f) => f.role == FileRole.video).length,
          subtitles: all.where((f) => f.role == FileRole.subtitle).length,
          folders: {for (final f in all) p.posix.dirname(f.path)}.length,
        ),
      );
    } on Object catch (e) {
      if (t.cancelled) return;
      t.cancelled = true;
      await _set(
        t,
        _with(t.summary, stage: TaskStage.cancelled, message: '$step失败：$e'),
        force: true,
      );
    }
  }

  /// Recursive listing of every file under [t]'s paths; live count while walking.
  Future<List<RemoteEntry>> _listAll(_Task t, StorageBackend be) async {
    final out = <RemoteEntry>[];
    final seen = <String>{};
    var lastTick = DateTime.fromMillisecondsSinceEpoch(0);

    void add(RemoteEntry e) {
      if (!seen.add(e.path)) return;
      out.add(e);
      final now = DateTime.now();
      if (now.difference(lastTick) >= importUpdateInterval) {
        lastTick = now;
        _emit(
          t,
          _with(
            t.summary,
            message: '正在导入文件（已导入 ${out.length} 个）',
            imported: out.length,
          ),
        );
      }
    }

    // The backend has no stat: find each root in its parent's listing (one
    // listing per parent, shared when several roots sit side by side).
    final dirs = <String>[];
    final parents = <String, Future<List<RemoteEntry>>>{};
    for (final root in t.summary.paths) {
      if (t.cancelled) break;
      if (root == '/') {
        dirs.add(root);
        continue;
      }
      final parent = p.posix.dirname(root);
      final siblings = await parents.putIfAbsent(
        parent,
        () => listFresh(be, parent),
      );
      final entry = siblings.where((e) => e.path == root).firstOrNull;
      if (entry == null) continue;
      entry.isDir ? dirs.add(root) : add(entry);
    }
    await walkDirs(dirs, (dir) async {
      final subs = <String>[];
      for (final e in await listFresh(be, dir)) {
        e.isDir ? subs.add(e.path) : add(e);
      }
      return subs;
    }, stop: () => t.cancelled);
    // Parallel listings finish in any order; keep the result stable.
    out.sort((a, b) => a.path.compareTo(b.path));
    _emit(
      t,
      _with(
        t.summary,
        message: '正在导入文件（已导入 ${out.length} 个）',
        imported: out.length,
      ),
    );
    return out;
  }

  /// Planner output plus a conflict check against what already exists at the targets.
  Future<RenamePlan> _plan(_Task t) async {
    final s = t.summary;
    final o = options(s.connection, s.mode);
    final opts = !s.scrape
        ? o
        : PlanOptions(
            mode: o.mode,
            libraryRoot: o.libraryRoot,
            naming: o.naming,
            deleteJunk: o.deleteJunk,
            confidenceThreshold: o.confidenceThreshold,
            scrape: true,
          );
    final be = backendFor(s.connection);
    // What's already in each target folder: for conflicts (never overwrite),
    // and so a show folder already there is merged into. Planning again can
    // send files to new folders (a merge moves them), so look again until no
    // new folder turns up.
    final existing = <String>{};
    final listed = <String>{};
    var plan = await planner.build(t.scan!, t.decisions, opts);
    for (var round = 0; round < 3; round++) {
      final srcs = {
        for (final o in plan.ops)
          if (o.selected && o.src.isNotEmpty) o.src,
      };
      final dirs = {
        for (final o in plan.ops)
          if (o.selected && o.kind != OpKind.delete && !srcs.contains(o.dst))
            p.posix.dirname(o.dst),
      }.difference(listed);
      if (dirs.isEmpty) break;
      listed.addAll(dirs);
      final before = existing.length;
      await walkDirs(dirs, (dir) async {
        try {
          existing.addAll([for (final e in await listFresh(be, dir)) e.path]);
        } on StorageException catch (e) {
          if (e.code != StorageErrorCode.notFound) rethrow;
        }
        return const [];
      });
      if (existing.length == before) break;
      plan = await planner.build(
        t.scan!,
        t.decisions,
        opts,
        existing: existing,
      );
    }
    return plan;
  }

  Future<TaskReview> _review(_Task t) async {
    final scan = t.scan;
    if (scan == null) throw StateError('任务尚未识别完成');
    return TaskReview(
      id: t.summary.id,
      scan: scan,
      decisions: Map.unmodifiable(t.decisions),
      // Only a task waiting for review needs a fresh plan. A finished one is
      // read for its works (its record is the history); replanning it would
      // list folders that have moved since, and can fail.
      preview: t.summary.stage == TaskStage.awaitingReview || t.plan != null
          ? t.plan ??= await _plan(t)
          : const RenamePlan(ops: []),
    );
  }

  /// 立即执行: keep only ops with no warning in groups that matched well.
  RenamePlan _confidentOnly(_Task t, RenamePlan plan) {
    final threshold = options(
      t.summary.connection,
      t.summary.mode,
    ).confidenceThreshold;
    final good = {
      for (final g in t.scan!.groups)
        if (g.matchScore >= threshold) g.id,
    };
    final ops = [
      for (final o in plan.ops)
        o.selected &&
                o.warning == null &&
                (o.group == null || good.contains(o.group))
            ? o
            : RenameOp(
                id: o.id,
                kind: o.kind,
                phase: o.phase,
                src: o.src,
                dst: o.dst,
                group: o.group,
                selected: false,
                warning: o.warning,
              ),
    ];
    final live = {
      for (final o in ops)
        if (o.selected) o.id,
    };
    return RenamePlan(
      ops: ops,
      merges: plan.merges,
      conflicts: [
        for (final c in plan.conflicts)
          if (c.ops.isEmpty || c.ops.any(live.contains)) c,
      ],
    );
  }

  // ---- execution ---------------------------------------------------------

  /// Feeds executor progress into the summary, then settles the final stage.
  Future<void> _drive(
    _Task t,
    Stream<ExecProgress> stream,
    BatchId? batch,
  ) async {
    final done = t.execDone = Completer<void>();
    Object? failure;
    var stage = t.summary.stage;
    t.exec = stream.listen(
      (e) {
        final next = e.phase == ExecPhase.files
            ? TaskStage.renamingFiles
            : TaskStage.renamingFolders;
        final label = switch (e.phase) {
          ExecPhase.files => '正在重命名文件',
          ExecPhase.folders => '正在整理文件夹',
          ExecPhase.cleanup => '正在清理',
        };
        _emit(
          t,
          _with(
            t.summary,
            stage: next,
            message: '$label（${e.done}/${e.total}）',
            progress: () => e.total == 0 ? 1 : e.done / e.total,
          ),
        );
        if (next != stage) {
          stage = next;
          _persist(t).ignore();
        }
      },
      onError: (Object e) {
        failure = e;
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future;
    t.exec = null;
    if (t.cancelled) return; // cancel() settles the state
    final b = batch ?? await _batchOf(t.summary.id);
    final failed = b == null
        ? 0
        : (await history.records(b))
              .where((r) => r.status == OpStatus.failed)
              .length;
    if (failure != null) {
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.partiallyFailed,
          message: '执行出错：$failure',
          batch: b,
        ),
      );
    } else if (failed > 0) {
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.partiallyFailed,
          message: '部分操作失败（$failed 项），其余已完成',
          batch: b,
        ),
      );
    } else {
      await _set(
        t,
        _with(t.summary, stage: TaskStage.done, message: '整理完成', batch: b),
      );
    }
  }

  Future<BatchId?> _batchOf(TaskId id) async =>
      _tasks[id]?.summary.batch ??
      (await history.batches()).where((b) => b.task == id).firstOrNull?.id;

  // ---- plumbing ----------------------------------------------------------

  Future<_Task> _get(TaskId id) async {
    await _ready;
    return _tasks[id] ?? (throw ArgumentError('unknown task ${id.value}'));
  }

  void _requireStage(_Task t, TaskStage stage) {
    if (t.summary.stage != stage) {
      throw StateError('任务当前状态不允许此操作：${t.summary.stage.name}');
    }
  }

  List<TaskSummary> _snapshot() =>
      _tasks.values.map((t) => t.summary).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Updates in-memory state and notifies watchers. Late updates from a task
  /// that was cancelled meanwhile are dropped unless [force]d.
  void _emit(_Task t, TaskSummary s, {bool force = false}) {
    if (t.cancelled && !force) return;
    t.summary = s;
    if (!_changes.isClosed) _changes.add(_snapshot());
  }

  Future<void> _set(_Task t, TaskSummary s, {bool force = false}) {
    _emit(t, s, force: force);
    return _persist(t);
  }

  Future<void> _persist(_Task t) {
    final s = t.summary;
    final f = t.persistQueue.then((_) => store.saveSummary(s));
    t.persistQueue = f.then((_) {}, onError: (_) {});
    return f;
  }

  TaskSummary _with(
    TaskSummary s, {
    TaskStage? stage,
    String? message,
    OrganizeMode? mode,
    int? imported,
    int? videos,
    int? folders,
    int? subtitles,
    double? Function()? progress,
    BatchId? batch,
  }) => TaskSummary(
    id: s.id,
    connection: s.connection,
    paths: s.paths,
    mode: mode ?? s.mode,
    scrape: s.scrape,
    stage: stage ?? s.stage,
    message: message ?? s.message,
    importedCount: imported ?? s.importedCount,
    videoCount: videos ?? s.videoCount,
    folderCount: folders ?? s.folderCount,
    subtitleCount: subtitles ?? s.subtitleCount,
    progress: progress?.call(),
    batch: batch ?? s.batch,
    createdAt: s.createdAt,
  );

  /// Stops listening; running tasks are not interrupted. For tests and app shutdown.
  Future<void> dispose() => _changes.close();
}
