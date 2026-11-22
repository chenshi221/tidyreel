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
import '../plan/follow.dart';
import '../plan/planner.dart';
import '../plan/recognizer.dart';
import '../plan/text.dart';
import '../storage/cached_backend.dart';
import '../storage/storage_backend.dart';
import '../storage/walk.dart';
import 'task_manager.dart';

final _seasonArtRe = RegExp(
  r'^season(?:\d+|-specials|-all)-(?:poster|banner|fanart|landscape)\.(?:jpe?g|png|webp)$',
  caseSensitive: false,
);

/// Per-task mutable state. Only [DefaultTaskManager] touches it.
class _Task {
  TaskSummary summary;
  ScanResult? scan;
  Map<GroupId, GroupDecision> decisions;
  RenamePlan? plan;
  PlanOptions? planOptions;
  ({int editGen, PlanOptions options, Future<RenamePlan> future})? inFlightPlan;
  Set<BatchId> priorBatches = const {};
  int pipelineGen = 0;
  int editGen = 0;
  int pendingEdits = 0;
  bool cancelled = false;
  bool busy = false;
  Completer<void>? busyDone;
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
          final gen = ++t.pipelineGen;
          _emit(t, _with(t.summary, stage: TaskStage.importing));
          unawaited(_pipeline(t, gen));
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
    await Future.wait(ids.map(_resume));
  }

  Future<void> _resume(TaskId id) async {
    final t = _tasks[id];
    if (t == null || t.cancelled || t.busy) return;
    await _withBusy(t, () async {
      final batch = t.summary.batch ?? await _batchOf(id, includeUndone: false);
      if (t.cancelled || _tasks[id] != t) return;
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
      _emit(t, _with(t.summary, batch: () => batch));
      final hasWrites =
          t.summary.scrape ||
          (await history.records(batch)).any(
            (r) => r.status == OpStatus.pending && r.op.kind == OpKind.write,
          );
      if (t.cancelled || _tasks[id] != t) return;
      await _drive(
        t,
        executor.resume(batch, backendFor(t.summary.connection)),
        batch,
        hasWrites: hasWrites,
      );
    });
  }

  // ---- TaskManager --------------------------------------------------------

  @override
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode, {
    bool scrape = false,
    bool scrapeOnly = false,
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
        scrape: scrape || scrapeOnly,
        scrapeOnly: scrapeOnly,
        stage: TaskStage.importing,
        message: '正在导入文件',
        createdAt: DateTime.now(),
      ),
    );
    _tasks[id] = t;
    _changes.add(_snapshot());
    await _persist(t);
    unawaited(_pipeline(t, ++t.pipelineGen));
    return id;
  }

  @override
  Stream<List<TaskSummary>> watchAll() {
    late StreamController<List<TaskSummary>> out;
    StreamSubscription<List<TaskSummary>>? sub;
    out = StreamController<List<TaskSummary>>(
      onListen: () async {
        await _ready;
        if (out.isClosed) return;
        // Subscribe before emitting the initial snapshot so updates fired
        // while delivering the snapshot are never missed.
        sub = _changes.stream.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
        out.add(_snapshot());
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
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
    if (t.busy) throw StateError('任务正在处理中');
    final scan = t.scan;
    if (scan == null) throw StateError('任务尚未识别完成');
    final gen = ++t.editGen;
    final decisions = {...t.decisions, group: decision};
    t.pendingEdits++;
    try {
      final (plan, opts) = await _buildPlanWithOptions(
        t.summary,
        scan,
        decisions,
      );
      if (t.editGen == gen &&
          t.summary.stage == TaskStage.awaitingReview &&
          _tasks[id] == t) {
        t.decisions = decisions;
        t.plan = plan;
        t.planOptions = opts;
        t.inFlightPlan = null;
        await _saveReview(t, scan, decisions);
      }
      return await _review(t);
    } finally {
      t.pendingEdits--;
    }
  }

  @override
  Future<TaskReview> setMode(TaskId id, OrganizeMode mode) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    if (t.busy) throw StateError('任务正在处理中');
    final scan = t.scan;
    if (scan == null) throw StateError('任务尚未识别完成');
    if (t.summary.mode == mode && t.plan != null) return _review(t);
    final next = _with(t.summary, mode: mode, message: t.summary.message);
    final gen = ++t.editGen;
    final decisions = t.decisions;
    t.pendingEdits++;
    try {
      final (plan, opts) = await _buildPlanWithOptions(next, scan, decisions);
      if (t.editGen == gen &&
          t.summary.stage == TaskStage.awaitingReview &&
          _tasks[id] == t) {
        t.plan = plan;
        t.planOptions = opts;
        t.inFlightPlan = null;
        await _set(t, next);
      }
      return await _review(t);
    } finally {
      t.pendingEdits--;
    }
  }

  @override
  Future<TaskReview> assignUnassigned(
    TaskId id,
    String filePath,
    GroupId targetGroup,
  ) => review(id);

  @override
  Future<TaskReview> setUnassignedDelete(
    TaskId id,
    String filePath,
    bool delete,
  ) => review(id);

  @override
  Future<TaskReview> mergeGroups(TaskId id, GroupId keep, GroupId absorb) =>
      review(id);

  @override
  Future<TaskReview> splitGroup(
    TaskId id,
    GroupId group,
    Set<String> filePaths,
  ) => review(id);

  @override
  Future<List<String>> findEmptyDirs(TaskId id) async => const [];

  @override
  Future<int> removeEmptyDirs(TaskId id, List<String> dirs) async => 0;

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    if (t.busy) throw StateError('任务正在处理中');
    if (t.pendingEdits > 0) throw StateError('正在更新整理计划，请稍后再试');
    await _withBusy(t, () async {
      var plan = await _ensurePlan(t);
      if (t.cancelled || _tasks[id] != t) return;
      if (onlyConfident) plan = _confidentOnly(t, plan);
      if (!plan.canExecute) throw StateError('存在冲突，无法执行');
      // Never report "整理完成" for a run that would touch nothing.
      if (!plan.ops.any((o) => o.selected)) {
        throw StateError('没有可执行的操作：请先勾选要整理的作品');
      }
      t.priorBatches = {
        for (final b in await history.batches())
          if (b.task == id) b.id,
      };
      if (t.cancelled || _tasks[id] != t) return;
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.renamingFiles,
          message: '正在重命名文件',
          progress: () => 0,
        ),
      );
      if (t.cancelled || _tasks[id] != t) return;
      final hasWrites = plan.ops.any(
        (o) => o.selected && o.kind == OpKind.write,
      );
      await _drive(
        t,
        executor.execute(
          id,
          t.summary.connection,
          plan,
          backendFor(t.summary.connection),
        ),
        null,
        hasWrites: hasWrites,
      );
    });
  }

  @override
  Future<void> retryFailed(TaskId id) async {
    final t = await _get(id);
    final batch = t.summary.batch;
    if (batch == null || t.summary.stage != TaskStage.partiallyFailed) {
      throw StateError('任务没有失败的操作');
    }
    if (t.busy) throw StateError('任务正在处理中');
    await _withBusy(t, () async {
      var hasWrites = false;
      for (final r in await history.records(batch)) {
        if (r.status == OpStatus.failed || r.status == OpStatus.skipped) {
          if (r.op.kind == OpKind.write) hasWrites = true;
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
      if (t.cancelled || _tasks[id] != t) return;
      await _drive(
        t,
        executor.resume(batch, backendFor(t.summary.connection)),
        batch,
        hasWrites: hasWrites,
      );
    });
  }

  @override
  Future<void> retry(TaskId id) async {
    final t = await _get(id);
    if (!canRetry(t.summary)) throw StateError('这个任务不能重试');
    if (t.busy || t.pendingEdits > 0) throw StateError('任务正在处理中');
    final gen = ++t.pipelineGen;
    t.editGen++;
    t
      ..cancelled = false
      ..scan = null
      ..decisions = const {}
      ..plan = null
      ..planOptions = null
      ..inFlightPlan = null
      ..priorBatches = const {};
    await _clearReview(t);
    await _set(
      t,
      _with(
        t.summary,
        stage: TaskStage.importing,
        message: '正在导入文件',
        imported: 0,
        videos: 0,
        subtitles: 0,
        folders: 0,
        progress: () => null,
        batch: () => null,
      ),
      force: true,
    );
    unawaited(_pipeline(t, gen));
  }

  @override
  Future<void> delete(TaskId id) async {
    final t = await _get(id);
    if (t.pendingEdits > 0) {
      throw StateError('正在更新整理计划，请稍后再试');
    }
    if (t.busy ||
        (t.summary.stage.isActive &&
            t.summary.stage != TaskStage.awaitingReview)) {
      throw StateError('任务正在进行，先取消再删除');
    }
    t.pipelineGen++;
    t.editGen++;
    t.inFlightPlan = null;
    _tasks.remove(id);
    _changes.add(_snapshot());
    // Let any in-flight summary/review write finish before deleting the row.
    await t.persistQueue;
    await store.delete(id);
    await history.deleteTask(id);
  }

  @override
  Future<void> cancel(TaskId id) async {
    final t = await _get(id);
    if (!t.summary.stage.isActive) return;
    final wasExecuting =
        t.summary.stage == TaskStage.renamingFiles ||
        t.summary.stage == TaskStage.renamingFolders;
    t.cancelled = true;
    t.pipelineGen++;
    t.editGen++;
    // Waits for in-flight ops to be recorded; finished ops stay in history.
    final exec = t.exec;
    final execDone = t.execDone;
    t.exec = null;
    t.execDone = null;
    await exec?.cancel();
    if (execDone != null && !execDone.isCompleted) execDone.complete();
    // Wait for run()/retryFailed()/_resume() to release t.busy before
    // publishing cancelled so immediate delete()/retry() works cleanly.
    final busyDone = t.busyDone;
    if (busyDone != null) await busyDone.future;
    if (_tasks[id] != t) return;
    final batch =
        t.summary.batch ??
        (wasExecuting ? await _batchOf(id, exclude: t.priorBatches) : null);
    await _set(
      t,
      _with(
        t.summary,
        stage: TaskStage.cancelled,
        message: '已取消',
        batch: () => batch,
      ),
      force: true,
    );
  }

  @override
  Future<void> undo(TaskId id, {Set<OpId>? only}) async {
    final t = await _get(id);
    final batch = t.summary.batch;
    if (batch == null ||
        t.summary.stage.isActive ||
        t.summary.stage == TaskStage.undone) {
      throw StateError('任务没有可撤销的操作');
    }
    if (t.busy) throw StateError('任务正在撤销中');
    await _withBusy(t, () async {
      final beforeRecords = await history.records(batch);
      final attemptedIds = {
        for (final r in beforeRecords)
          if (r.status == OpStatus.done &&
              (only == null || only.contains(r.op.id)))
            r.op.id,
      };
      final totalOps = attemptedIds.length;
      var completed = 0;
      await for (final _ in executor.undo(
        batch,
        backendFor(t.summary.connection),
        only: only,
      )) {
        completed++;
        final shownTotal = totalOps > 0 ? totalOps : completed;
        final clamped = completed > shownTotal ? shownTotal : completed;
        _emit(
          t,
          _with(
            t.summary,
            message: '正在撤销（$clamped/$shownTotal）',
            progress: () => shownTotal == 0 ? 1 : clamped / shownTotal,
          ),
          force: true,
        );
      }
      final afterRecords = await history.records(batch);
      final remaining = afterRecords.any((r) => r.status == OpStatus.done);
      final failedCount = afterRecords
          .where(
            (r) => attemptedIds.contains(r.op.id) && r.status == OpStatus.done,
          )
          .length;
      final skippedCount = afterRecords
          .where(
            (r) =>
                attemptedIds.contains(r.op.id) && r.status == OpStatus.skipped,
          )
          .length;
      final details = <String>[
        if (failedCount > 0) '$failedCount 项失败',
        if (skippedCount > 0) '$skippedCount 项已跳过',
      ];
      final note = details.isEmpty ? '' : '，${details.join('，')}';
      await _set(
        t,
        remaining
            ? _with(t.summary, message: '已撤销部分操作$note')
            : _with(t.summary, stage: TaskStage.undone, message: '已撤销$note'),
        force: true,
      );
    });
  }

  // ---- background pipeline -----------------------------------------------

  Future<void> _pipeline(_Task t, int gen) async {
    bool stale() =>
        t.cancelled || t.pipelineGen != gen || _tasks[t.summary.id] != t;

    var step = '导入';
    try {
      if (stale()) return;
      final s = t.summary;
      final be = backendFor(s.connection);
      await _set(
        t,
        _with(s, stage: TaskStage.importing, message: '正在导入文件', imported: 0),
      );
      final files = await _listAll(t, be, stale);
      if (stale()) return;

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
      if (stale()) return;
      final scan = await recognizer.recognize(
        s.connection,
        s.paths,
        files,
        read: be.read,
      );
      if (stale()) return;
      _emit(
        t,
        _with(t.summary, message: '锚点识别完成，正在进行后续处理', imported: files.length),
      );

      step = '生成计划';
      final decisions = {
        for (final g in scan.groups)
          g.id: GroupDecision(selected: g.match != null),
      };
      final (plan, opts) = await _buildPlanWithOptions(
        t.summary,
        scan,
        decisions,
      );
      if (stale()) return;

      t
        ..scan = scan
        ..decisions = decisions
        ..plan = plan
        ..planOptions = opts;

      final all = [for (final g in scan.groups) ...g.files, ...scan.unassigned];
      await _saveReview(t, scan, decisions);
      if (stale()) return;
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
      if (stale()) return;
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.failed,
          message: '$step失败：${_friendlyError(e)}',
        ),
        force: true,
      );
    }
  }

  /// Recursive listing of every file under [t]'s paths; live count while walking.
  Future<List<RemoteEntry>> _listAll(
    _Task t,
    StorageBackend be,
    bool Function() stale,
  ) async {
    final out = <RemoteEntry>[];
    final seen = <String>{};
    var lastTick = DateTime.fromMillisecondsSinceEpoch(0);

    void add(RemoteEntry e) {
      if (stale() || !seen.add(e.path)) return;
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
    var foundAny = false;
    for (final root in t.summary.paths) {
      if (stale()) break;
      if (root == '/') {
        foundAny = true;
        dirs.add(root);
        continue;
      }
      final parent = p.posix.dirname(root);
      final siblings = await parents.putIfAbsent(
        parent,
        () => listFresh(be, parent),
      );
      if (stale()) break;
      final entry = siblings.where((e) => e.path == root).firstOrNull;
      if (entry == null) continue;
      foundAny = true;
      entry.isDir ? dirs.add(root) : add(entry);
    }
    if (stale()) return out;
    if (t.summary.paths.isNotEmpty && !foundAny) {
      throw StorageException(
        StorageErrorCode.notFound,
        '所选路径不存在：${t.summary.paths.join('、')}',
      );
    }
    if (!stale()) {
      await walkDirs(dirs, (dir) async {
        final subs = <String>[];
        for (final e in await listFresh(be, dir)) {
          if (stale()) break;
          e.isDir ? subs.add(e.path) : add(e);
        }
        return subs;
      }, stop: stale);
    }
    if (stale()) return out;
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

  PlanOptions _effectiveOptions(TaskSummary s) {
    final o = options(s.connection, s.mode);
    return !s.scrape
        ? o
        : PlanOptions(
            mode: o.mode,
            libraryRoot: o.libraryRoot,
            naming: o.naming,
            deleteJunk: o.deleteJunk,
            confidenceThreshold: o.confidenceThreshold,
            scrape: true,
          );
  }

  /// Planner output plus a conflict check against what already exists at the targets.
  Future<(RenamePlan, PlanOptions)> _buildPlanWithOptions(
    TaskSummary s,
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
  ) async {
    final opts = _effectiveOptions(s);
    final be = backendFor(s.connection);
    // What's already in each target folder: for conflicts (never overwrite),
    // and so a show folder already there is merged into. Planning again can
    // send files to new folders (a merge moves them), so look again until no
    // new folder turns up.
    final existing = <String>{};
    final listed = <String>{};
    var plan = await planner.build(scan, decisions, opts);
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
      plan = await planner.build(scan, decisions, opts, existing: existing);
    }
    return (plan, opts);
  }

  Future<RenamePlan> _ensurePlan(_Task t) {
    final scan = t.scan!;
    final opts = _effectiveOptions(t.summary);
    if (t.plan != null && t.planOptions == opts) return Future.value(t.plan!);
    final gen = t.editGen;
    final pending = t.inFlightPlan;
    if (pending != null && pending.editGen == gen && pending.options == opts) {
      return pending.future;
    }
    final decisions = t.decisions;
    final summary = t.summary;
    late final Future<RenamePlan> future;
    future = () async {
      try {
        final (plan, builtOpts) = await _buildPlanWithOptions(
          summary,
          scan,
          decisions,
        );
        if (t.editGen == gen &&
            t.summary.mode == summary.mode &&
            _tasks[t.summary.id] == t) {
          t.plan = plan;
          t.planOptions = builtOpts;
        }
        return plan;
      } finally {
        if (identical(t.inFlightPlan?.future, future)) {
          t.inFlightPlan = null;
        }
      }
    }();
    t.inFlightPlan = (editGen: gen, options: opts, future: future);
    return future;
  }

  Future<TaskReview> _review(_Task t) async {
    final scan = t.scan;
    if (scan == null) throw StateError('任务尚未识别完成');
    final preview = t.summary.stage == TaskStage.awaitingReview
        ? await _ensurePlan(t)
        : (t.plan ?? const RenamePlan(ops: []));
    return TaskReview(
      id: t.summary.id,
      scan: scan,
      decisions: Map.unmodifiable(t.decisions),
      // Only a task waiting for review needs a fresh plan. A finished one is
      // read for its works (its record is the history); replanning it would
      // list folders that have moved since, and can fail.
      preview: preview,
    );
  }

  /// 立即执行: keep confident ops plus explicitly confirmed manual choices,
  /// maintaining companion, folder, mkdir, scrape, and junk dependencies.
  RenamePlan _confidentOnly(_Task t, RenamePlan plan) {
    final threshold = _effectiveOptions(t.summary).confidenceThreshold;
    final groups = {for (final g in t.scan!.groups) g.id: g};

    bool allowedWarning(String? warning, {required bool confirmed}) {
      if (warning == null) return true;
      for (final w in warning.split('；')) {
        if (w == '超出 TMDB 总集数') continue;
        if (confirmed && (w == '识别置信度较低' || w == '片名匹配置信度较低')) {
          continue;
        }
        return false;
      }
      return true;
    }

    final keptVideoSrcs = <String>{};
    final keptFileOps = <RenameOp>[];
    final keptGroups = <GroupId>{};
    final keptIds = <OpId>{};

    // Pass 1: video relocates.
    for (final o in plan.ops) {
      if (o.phase != ExecPhase.files ||
          o.kind != OpKind.relocate ||
          !o.selected) {
        continue;
      }
      final g = o.group == null ? null : groups[o.group];
      final f = g?.files.where((x) => x.path == o.src).firstOrNull;
      if (g == null || f?.role != FileRole.video) continue;
      final d = t.decisions[g.id] ?? const GroupDecision();
      final ov = d.overrides[o.src];
      final confirmed = ov != null && !ov.ignore;
      final groupOk = d.match != null || g.matchScore >= threshold || confirmed;
      if (groupOk && allowedWarning(o.warning, confirmed: confirmed)) {
        keptIds.add(o.id);
        keptFileOps.add(o);
        keptVideoSrcs.add(o.src);
        keptGroups.add(g.id);
      }
    }

    // Precompute per-group video lists (matching planner.dart: planned videos
    // first, falling back to all videos).
    final allVideosByGroup = <GroupId, List<ScanFile>>{};
    final plannedVideosByGroup = <GroupId, List<ScanFile>>{};
    final plannedSrcsByGroup = <GroupId, Set<String>>{};
    for (final o in plan.ops) {
      if (o.phase == ExecPhase.files &&
          o.kind == OpKind.relocate &&
          o.group != null) {
        (plannedSrcsByGroup[o.group!] ??= <String>{}).add(o.src);
      }
    }
    for (final g in t.scan!.groups) {
      final allVideos = [
        for (final x in g.files)
          if (x.role == FileRole.video) x,
      ];
      allVideosByGroup[g.id] = allVideos;
      final plannedSrcs = plannedSrcsByGroup[g.id] ?? const <String>{};
      plannedVideosByGroup[g.id] = [
        for (final x in allVideos)
          if (plannedSrcs.contains(x.path)) x,
      ];
    }

    // Pass 2: subtitles / sidecars and any non-video file relocates.
    for (final o in plan.ops) {
      if (o.phase != ExecPhase.files ||
          o.kind != OpKind.relocate ||
          !o.selected) {
        continue;
      }
      final g = o.group == null ? null : groups[o.group];
      final f = g?.files.where((x) => x.path == o.src).firstOrNull;
      if (g != null && f?.role == FileRole.video) continue;
      if (g == null) {
        if (allowedWarning(o.warning, confirmed: false)) {
          keptIds.add(o.id);
          keptFileOps.add(o);
        }
        continue;
      }
      final d = t.decisions[g.id] ?? const GroupDecision();
      final ov = d.overrides[o.src];
      final confirmed = ov != null && !ov.ignore;
      final hasExplicit =
          confirmed &&
          (ov.season != null ||
              ov.episode != null ||
              ov.kind == MediaKind.extra ||
              ov.kind == MediaKind.special);
      final plannedVideos = plannedVideosByGroup[g.id] ?? const <ScanFile>[];
      final allVideos = allVideosByGroup[g.id] ?? const <ScanFile>[];
      var mItem = f == null ? null : matchVideo(f, plannedVideos);
      if (mItem == null &&
          plannedVideos.length == 1 &&
          f?.role == FileRole.subtitle) {
        mItem = FollowMatch(plannedVideos.first, '');
      }
      var mAll = mItem ?? (f == null ? null : matchVideo(f, allVideos));
      if (mAll == null &&
          allVideos.length == 1 &&
          f?.role == FileRole.subtitle) {
        mAll = FollowMatch(allVideos.first, '');
      }
      final bool keep;
      if (hasExplicit) {
        keep = allowedWarning(o.warning, confirmed: true);
      } else if (mItem != null) {
        keep =
            keptVideoSrcs.contains(mItem.video.path) &&
            allowedWarning(o.warning, confirmed: confirmed);
      } else if (mAll != null) {
        final videoIgnored = d.overrides[mAll.video.path]?.ignore ?? false;
        keep = videoIgnored
            ? confirmed && allowedWarning(o.warning, confirmed: true)
            : keptVideoSrcs.contains(mAll.video.path) &&
                  allowedWarning(o.warning, confirmed: confirmed);
      } else {
        final groupOk =
            d.match != null || g.matchScore >= threshold || confirmed;
        keep = groupOk && allowedWarning(o.warning, confirmed: confirmed);
      }
      if (keep) {
        keptIds.add(o.id);
        keptFileOps.add(o);
        keptGroups.add(g.id);
      }
    }

    // Pass 3: folder relocates needed by ANY kept file op (including merged
    // groups whose files land inside another group's renamed folder).
    final allFolderOps = [
      for (final o in plan.ops)
        if (o.phase == ExecPhase.folders &&
            o.kind == OpKind.relocate &&
            o.selected)
          o,
    ];
    final keptFolderOps = <RenameOp>[];
    for (final o in allFolderOps) {
      final isSeasonRename = o.id.value.startsWith('s-');
      final usedByAnyFile = keptFileOps.any(
        (f) =>
            f.dst.startsWith('${o.src}/') ||
            f.dst.startsWith('${o.dst}/') ||
            (isSeasonRename && f.src.startsWith('${o.src}/')),
      );
      final used = isSeasonRename
          ? usedByAnyFile
          : usedByAnyFile ||
                (o.group == null
                    ? keptFileOps.isNotEmpty
                    : keptGroups.contains(o.group));
      if (used) {
        keptIds.add(o.id);
        keptFolderOps.add(o);
      }
    }

    String applyFolders(String path, List<RenameOp> folders) {
      var cur = path;
      for (final f in folders) {
        if (cur == f.src) {
          cur = f.dst;
        } else if (cur.startsWith('${f.src}/')) {
          cur = '${f.dst}${cur.substring(f.src.length)}';
        }
      }
      return cur;
    }

    String postFolder(String path) => applyFolders(path, keptFolderOps);

    final keptVideoFinalTargets = <String>{
      for (final o in keptFileOps)
        if (keptVideoSrcs.contains(o.src))
          '${dirOf(postFolder(o.dst))}/${stem(baseOf(o.dst))}',
    };
    final keptMergeDirs = <String>{
      for (final m in plan.merges)
        if (keptGroups.contains(m.group)) m.into,
    };

    // Pass 4: scrape writes tied to kept videos / groups.
    final keptWriteOps = <RenameOp>[];
    for (final o in plan.ops) {
      if (o.kind != OpKind.write || !o.selected) continue;
      if (!allowedWarning(o.warning, confirmed: false)) continue;
      final name = baseOf(o.dst);
      final lowerName = name.toLowerCase();
      final isShowArt =
          lowerName == 'tvshow.nfo' ||
          lowerName == 'poster.jpg' ||
          lowerName == 'fanart.jpg';
      final isGroupArt = isShowArt || _seasonArtRe.hasMatch(lowerName);
      final belongsToKept =
          o.group == null ||
          keptGroups.contains(o.group) ||
          (isShowArt && keptMergeDirs.contains(dirOf(o.dst)));
      if (!belongsToKept) continue;
      if (!isGroupArt) {
        final targetStem = lowerName.endsWith('-thumb.jpg')
            ? name.substring(0, name.length - '-thumb.jpg'.length)
            : stem(name);
        final key = '${dirOf(o.dst)}/$targetStem';
        if (!keptVideoFinalTargets.contains(key)) continue;
      }
      keptIds.add(o.id);
      keptWriteOps.add(o);
    }

    // Pass 5: mkdir ops that actually receive at least one kept op.
    final targetDirs = [...keptFileOps, ...keptFolderOps, ...keptWriteOps];
    for (final o in plan.ops) {
      if (o.kind != OpKind.mkdir || !o.selected) continue;
      final needed = targetDirs.any(
        (x) =>
            x.dst == o.dst ||
            (o.dst == '/'
                ? x.dst.startsWith('/')
                : x.dst.startsWith('${o.dst}/')),
      );
      if (needed) keptIds.add(o.id);
    }

    // Pass 6: delete ops (do not delete junk inside a dropped group root,
    // matching both pre-rename and post-rename folder paths).
    final droppedFolderOps = [
      for (final f in allFolderOps)
        if (!keptIds.contains(f.id)) f,
    ];
    for (final o in plan.ops) {
      if (o.kind != OpKind.delete || !o.selected) continue;
      final underDroppedRename = droppedFolderOps.any(
        (f) => o.src.startsWith('${f.dst}/'),
      );
      if (underDroppedRename) continue;
      final insideDropped = t.scan!.groups.any((g) {
        if (keptGroups.contains(g.id)) return false;
        final plannedRoot = applyFolders(g.rootDir, allFolderOps);
        return o.src.startsWith('${g.rootDir}/') ||
            o.src.startsWith('$plannedRoot/');
      });
      final insideKept = t.scan!.groups.any((g) {
        if (!keptGroups.contains(g.id)) return false;
        final mappedRoot = postFolder(g.rootDir);
        return o.src.startsWith('${g.rootDir}/') ||
            o.src.startsWith('$mappedRoot/');
      });
      if (!insideDropped || insideKept) keptIds.add(o.id);
    }

    final ops = [
      for (final o in plan.ops)
        keptIds.contains(o.id)
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
    return RenamePlan(
      ops: ops,
      merges: plan.merges,
      conflicts: [
        for (final c in plan.conflicts)
          if (c.ops.isEmpty)
            c
          else if (c.ops.length == 1) ...[
            if (keptIds.contains(c.ops.single)) c,
          ] else if (c.ops.where(keptIds.contains).length > 1)
            PlanConflict(
              ops: [
                for (final id in c.ops)
                  if (keptIds.contains(id)) id,
              ],
              path: c.path,
              reason: c.reason,
            ),
      ],
    );
  }

  // ---- execution ---------------------------------------------------------

  /// Feeds executor progress into the summary, then settles the final stage.
  Future<void> _drive(
    _Task t,
    Stream<ExecProgress> stream,
    BatchId? batch, {
    bool hasWrites = false,
  }) async {
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
          ExecPhase.cleanup => hasWrites ? '正在刮削（写入元数据和海报）' : '正在清理',
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
    if (identical(t.execDone, done)) t.execDone = null;
    if (t.cancelled || _tasks[t.summary.id] != t) return; // cancel() settles
    final b = batch ?? await _batchOf(t.summary.id, exclude: t.priorBatches);
    final failed = b == null
        ? 0
        : (await history.records(b))
              .where((r) => r.status == OpStatus.failed)
              .length;
    if (t.cancelled || _tasks[t.summary.id] != t) return;
    if (failure != null) {
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.partiallyFailed,
          message: '执行出错：${_friendlyError(failure!)}',
          batch: () => b,
        ),
      );
    } else if (failed > 0) {
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.partiallyFailed,
          message: '部分操作失败（$failed 项），其余已完成',
          batch: () => b,
        ),
      );
    } else {
      await _set(
        t,
        _with(
          t.summary,
          stage: TaskStage.done,
          message: '整理完成',
          batch: () => b,
        ),
      );
    }
  }

  Future<BatchId?> _batchOf(
    TaskId id, {
    Set<BatchId> exclude = const {},
    bool includeUndone = true,
  }) async {
    final current = _tasks[id]?.summary.batch;
    if (current != null && !exclude.contains(current)) return current;
    return (await history.batches())
        .where(
          (b) =>
              b.task == id &&
              !exclude.contains(b.id) &&
              (includeUndone || !b.undone),
        )
        .firstOrNull
        ?.id;
  }

  // ---- plumbing ----------------------------------------------------------

  Future<void> _withBusy(_Task t, Future<void> Function() fn) async {
    t.busy = true;
    final done = Completer<void>();
    t.busyDone = done;
    try {
      await fn();
    } finally {
      t.busy = false;
      if (identical(t.busyDone, done)) t.busyDone = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<_Task> _get(TaskId id) async {
    await _ready;
    return _tasks[id] ?? (throw ArgumentError('未找到任务：${id.value}'));
  }

  static String _stageLabel(TaskStage stage) => switch (stage) {
    TaskStage.importing => '导入中',
    TaskStage.recognizing => '识别中',
    TaskStage.awaitingReview => '待确认',
    TaskStage.renamingFiles => '重命名文件中',
    TaskStage.renamingFolders => '整理文件夹中',
    TaskStage.done => '已完成',
    TaskStage.partiallyFailed => '部分失败',
    TaskStage.cancelled => '已取消',
    TaskStage.undone => '已撤销',
    TaskStage.failed => '已失败',
  };

  static String _friendlyError(Object e) {
    if (e is StorageException) {
      if (e.message.isNotEmpty) return e.message;
      return switch (e.code) {
        StorageErrorCode.notFound => '文件或目录不存在',
        StorageErrorCode.alreadyExists => '目标位置已存在同名文件或目录',
        StorageErrorCode.unauthorized => '认证失败，请检查账号或密码',
        StorageErrorCode.rateLimited => '请求过于频繁，请稍后重试',
        StorageErrorCode.network => '网络连接失败',
        StorageErrorCode.busy => '文件或目录正被占用',
        StorageErrorCode.other => '存储访问出错',
      };
    }
    if (e is StateError) return e.message;
    if (e is ArgumentError) {
      return e.message?.toString() ?? '参数无效';
    }
    final s = e.toString();
    for (final prefix in const [
      'Exception: ',
      'Bad state: ',
      'FormatException: ',
    ]) {
      if (s.startsWith(prefix)) return s.substring(prefix.length);
    }
    return s;
  }

  void _requireStage(_Task t, TaskStage stage) {
    if (t.summary.stage != stage) {
      throw StateError('任务当前状态不允许此操作（${_stageLabel(t.summary.stage)}）');
    }
  }

  List<TaskSummary> _snapshot() =>
      _tasks.values.map((t) => t.summary).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Updates in-memory state and notifies watchers. Late updates from a task
  /// that was cancelled meanwhile are dropped unless [force]d.
  bool _emit(_Task t, TaskSummary s, {bool force = false}) {
    if ((t.cancelled && !force) || _tasks[t.summary.id] != t) return false;
    t.summary = s;
    if (!_changes.isClosed) _changes.add(_snapshot());
    return true;
  }

  Future<void> _set(_Task t, TaskSummary s, {bool force = false}) {
    if (!_emit(t, s, force: force)) return Future.value();
    return _persist(t);
  }

  Future<void> _enqueuePersist(_Task t, Future<void> Function() action) {
    final f = t.persistQueue.then((_) => action());
    t.persistQueue = f.then((_) {}, onError: (_) {});
    return f;
  }

  Future<void> _persist(_Task t) {
    final id = t.summary.id;
    if (_tasks[id] != t) return Future.value();
    final s = t.summary;
    return _enqueuePersist(t, () async {
      if (_tasks[id] != t) return;
      await store.saveSummary(s);
    });
  }

  Future<void> _saveReview(
    _Task t,
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
  ) {
    final id = t.summary.id;
    if (_tasks[id] != t) return Future.value();
    final snapshot = Map<GroupId, GroupDecision>.of(decisions);
    return _enqueuePersist(t, () async {
      if (_tasks[id] != t) return;
      await store.saveReview(id, scan, snapshot);
    });
  }

  Future<void> _clearReview(_Task t) {
    final id = t.summary.id;
    if (_tasks[id] != t) return Future.value();
    return _enqueuePersist(t, () async {
      if (_tasks[id] != t) return;
      await store.clearReview(id);
    });
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
    BatchId? Function()? batch,
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
    batch: batch != null ? batch() : s.batch,
    createdAt: s.createdAt,
  );

  /// Stops listening; running tasks are not interrupted. For tests and app shutdown.
  Future<void> dispose() => _changes.close();
}
