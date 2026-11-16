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

/// Per-task mutable state. Only [DefaultTaskManager] touches it.
class _Task {
  TaskSummary summary;
  ScanResult? scan;
  Map<GroupId, GroupDecision> decisions;
  RenamePlan? plan;
  PlanOptions? planOptions;
  Set<BatchId> priorBatches = const {};
  int pipelineGen = 0;
  int editGen = 0;
  int pendingEdits = 0;
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
    await Future.wait(ids.map((id) => _resume(_tasks[id]!)));
  }

  Future<void> _resume(_Task t) async {
    final batch =
        t.summary.batch ?? await _batchOf(t.summary.id, includeUndone: false);
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
    unawaited(_pipeline(t, ++t.pipelineGen));
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
    final scan = t.scan;
    if (scan == null) throw StateError('任务尚未识别完成');
    final gen = ++t.editGen;
    final decisions = {...t.decisions, group: decision};
    t.decisions = decisions;
    t.plan = null;
    t.planOptions = null;
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
        t.plan = plan;
        t.planOptions = opts;
        await store.saveReview(id, scan, decisions);
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
        await _set(t, next);
      }
      return await _review(t);
    } finally {
      t.pendingEdits--;
    }
  }

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) async {
    final t = await _get(id);
    _requireStage(t, TaskStage.awaitingReview);
    if (t.busy) throw StateError('任务正在处理中');
    if (t.pendingEdits > 0) throw StateError('正在更新整理计划，请稍后再试');
    t.busy = true;
    try {
      var plan = await _ensurePlan(t);
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
    final gen = ++t.pipelineGen;
    t.editGen++;
    t
      ..cancelled = false
      ..scan = null
      ..decisions = const {}
      ..plan = null
      ..planOptions = null
      ..priorBatches = const {};
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
    if (t.busy ||
        (t.summary.stage.isActive &&
            t.summary.stage != TaskStage.awaitingReview)) {
      throw StateError('任务正在进行，先取消再删除');
    }
    t.pipelineGen++;
    t.editGen++;
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
    final wasExecuting =
        t.summary.stage == TaskStage.renamingFiles ||
        t.summary.stage == TaskStage.renamingFolders;
    t.cancelled = true;
    t.pipelineGen++;
    t.editGen++;
    // Waits for in-flight ops to be recorded; finished ops stay in history.
    await t.exec?.cancel();
    final done = t.execDone;
    if (done != null && !done.isCompleted) done.complete();
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
      await store.saveReview(s.id, scan, decisions);
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
      t.cancelled = true;
      await _set(
        t,
        _with(t.summary, stage: TaskStage.cancelled, message: '$step失败：$e'),
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
    for (final root in t.summary.paths) {
      if (stale()) break;
      if (root == '/') {
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
      entry.isDir ? dirs.add(root) : add(entry);
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

  Future<RenamePlan> _ensurePlan(_Task t) async {
    final scan = t.scan!;
    final opts = _effectiveOptions(t.summary);
    if (t.plan != null && t.planOptions == opts) return t.plan!;
    final gen = t.editGen;
    final decisions = t.decisions;
    final summary = t.summary;
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
      final allVideos = [
        for (final x in g.files)
          if (x.role == FileRole.video) x,
      ];
      var m = f == null ? null : matchVideo(f, allVideos);
      if (m == null && allVideos.length == 1 && f?.role == FileRole.subtitle) {
        m = FollowMatch(allVideos.first, '');
      }
      final bool keep;
      if (hasExplicit) {
        keep = allowedWarning(o.warning, confirmed: true);
      } else if (m != null) {
        final videoIgnored = d.overrides[m.video.path]?.ignore ?? false;
        keep = videoIgnored
            ? confirmed && allowedWarning(o.warning, confirmed: true)
            : keptVideoSrcs.contains(m.video.path) &&
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

    // Pass 3: folder relocates needed by kept file ops.
    final keptFolderOps = <RenameOp>[];
    for (final o in plan.ops) {
      if (o.phase != ExecPhase.folders ||
          o.kind != OpKind.relocate ||
          !o.selected) {
        continue;
      }
      final groupFiles = [
        for (final f in keptFileOps)
          if (o.group == null || f.group == o.group) f,
      ];
      if (groupFiles.isEmpty) continue;
      final isSeasonRename = o.id.value.startsWith('s-');
      final used =
          !isSeasonRename ||
          groupFiles.any(
            (f) =>
                f.src.startsWith('${o.src}/') ||
                f.dst.startsWith('${o.src}/') ||
                f.dst.startsWith('${o.dst}/'),
          );
      if (used) {
        keptIds.add(o.id);
        keptFolderOps.add(o);
      }
    }

    String postFolder(String path) {
      var cur = path;
      for (final f in keptFolderOps) {
        if (cur == f.src) {
          cur = f.dst;
        } else if (cur.startsWith('${f.src}/')) {
          cur = '${f.dst}${cur.substring(f.src.length)}';
        }
      }
      return cur;
    }

    final keptVideoFinalTargets = <String>{
      for (final o in keptFileOps)
        if (keptVideoSrcs.contains(o.src))
          '${dirOf(postFolder(o.dst))}/${stem(baseOf(o.dst))}',
    };

    // Pass 4: scrape writes tied to kept videos / groups.
    final keptWriteOps = <RenameOp>[];
    for (final o in plan.ops) {
      if (o.kind != OpKind.write || !o.selected) continue;
      if (!allowedWarning(o.warning, confirmed: false)) continue;
      if (o.group != null && !keptGroups.contains(o.group)) continue;
      final name = baseOf(o.dst);
      final isGroupArt =
          name == 'tvshow.nfo' ||
          name == 'poster.jpg' ||
          name == 'fanart.jpg' ||
          name.startsWith('season');
      if (!isGroupArt) {
        final targetStem = name.endsWith('-thumb.jpg')
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

    // Pass 6: delete ops (do not delete junk inside a dropped group root).
    for (final o in plan.ops) {
      if (o.kind != OpKind.delete || !o.selected) continue;
      final insideDropped = t.scan!.groups.any((g) {
        if (keptGroups.contains(g.id)) return false;
        return o.src.startsWith('${g.rootDir}/');
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
          if (c.ops.isEmpty || c.ops.any(keptIds.contains)) c,
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
    final b = batch ?? await _batchOf(t.summary.id, exclude: t.priorBatches);
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
    if ((t.cancelled && !force) || _tasks[t.summary.id] != t) return;
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
