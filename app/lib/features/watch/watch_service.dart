import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/watch_rules_store.dart';

/// Partial-download extensions ignored by lightweight watch mode (lowercase).
const partialDownloadSuffixes = <String>[
  '.td.cfg',
  '.aria2',
  '.part',
  '.!qb',
  '.crdownload',
  '.downloading',
  '.tmp',
  '.bc!',
  '.utpart',
  '.td',
];

/// Returns true when [name] is an unfinished download artifact or a hidden
/// temporary file (dot-prefixed). Case-insensitive.
bool isPartialDownload(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final base = trimmed.replaceAll('\\', '/').split('/').last;
  if (base.isEmpty || base.startsWith('.')) return true;
  final lower = base.toLowerCase();
  for (final suffix in partialDownloadSuffixes) {
    if (lower.endsWith(suffix)) return true;
  }
  return false;
}

/// Returns true when a sibling partial sidecar exists in the same directory for
/// [fileName], e.g. `episode.mkv` paired with `episode.mkv.aria2` or `episode.mkv.!qB`.
bool hasSiblingPartialDownload(String fileName, Set<String> siblingNamesLower) {
  final lower = fileName.toLowerCase();
  for (final suffix in partialDownloadSuffixes) {
    if (siblingNamesLower.contains('$lower$suffix')) return true;
  }
  return false;
}

/// Snapshot of one file currently being tracked across stability checks.
@immutable
class ObservedFile {
  final int size;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int stableChecks;

  /// True only when observed with `size > 0` and no sibling partial-download
  /// file present (e.g. preallocated aria2/qB files must complete two clean
  /// checks after the `.aria2`/`.!qB` sidecar disappears).
  final bool clean;

  const ObservedFile({
    required this.size,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.stableChecks,
    this.clean = true,
  });
}

/// Output of one [StabilityTracker.evaluate] pass.
@immutable
class StabilityResult {
  /// Stable video (and companion stable subtitle) paths ready to submit.
  final List<String> readyPaths;

  /// Number of video files in [readyPaths].
  final int readyVideoCount;

  /// Candidate media files still waiting for size stability or partial cleanup.
  final List<String> pendingPaths;

  /// Subset of [pendingPaths] blocked specifically by a sibling partial file.
  final List<String> blockedByPartialPaths;

  const StabilityResult({
    this.readyPaths = const [],
    this.readyVideoCount = 0,
    this.pendingPaths = const [],
    this.blockedByPartialPaths = const [],
  });
}

/// Two-check file-size stability tracker for lightweight watch mode.
///
/// A newly discovered video/subtitle file is recorded on its first sighting and
/// only promoted to ready when a subsequent check observes the exact same
/// `size > 0` with no sibling partial-download file in the same directory.
class StabilityTracker {
  final FilenameParser parser;

  StabilityTracker({this.parser = const RuleBasedParser()});

  final _observed = <String, Map<String, ObservedFile>>{};
  final _submitted = <String, Set<String>>{};

  /// Read-only view of currently tracked unstable files for [ruleId].
  Map<String, ObservedFile> observedFor(String ruleId) =>
      Map.unmodifiable(_observed[ruleId] ?? const {});

  /// Read-only view of paths already submitted for [ruleId].
  Set<String> submittedFor(String ruleId) =>
      Set.unmodifiable(_submitted[ruleId] ?? const {});

  /// Evaluates [files] for [ruleId] at [now], skipping [alreadyHandledPaths].
  StabilityResult evaluate({
    required String ruleId,
    required List<RemoteEntry> files,
    required Set<String> alreadyHandledPaths,
    required DateTime now,
  }) {
    final tracked = _observed.putIfAbsent(ruleId, () => {});
    final submitted = _submitted.putIfAbsent(ruleId, () => {});
    final handled = {...alreadyHandledPaths, ...submitted};

    // Index all sibling filenames per directory (lowercased) for partial checks.
    final siblingsByDir = <String, Set<String>>{};
    final presentPaths = <String>{};
    for (final e in files) {
      if (e.isDir) continue;
      presentPaths.add(e.path);
      final dir = normalizeDir(p.posix.dirname(e.path));
      (siblingsByDir[dir] ??= {}).add(e.name.toLowerCase());
    }

    // Prune entries that disappeared or have since been handled externally.
    tracked.removeWhere(
      (path, _) => !presentPaths.contains(path) || handled.contains(path),
    );

    final stableVideos = <String>[];
    final stableSubsByDir = <String, List<String>>{};
    final pendingPaths = <String>[];
    final blockedByPartial = <String>[];

    final sortedFiles = [
      for (final e in files)
        if (!e.isDir) e,
    ]..sort((a, b) => a.path.compareTo(b.path));

    for (final e in sortedFiles) {
      if (handled.contains(e.path)) continue;
      if (isPartialDownload(e.name)) continue;

      final role = parser.classify(e.name);
      if (role != FileRole.video && role != FileRole.subtitle) continue;

      final dir = normalizeDir(p.posix.dirname(e.path));
      final siblings = siblingsByDir[dir] ?? const <String>{};
      final blocked = hasSiblingPartialDownload(e.name, siblings);
      final prev = tracked[e.path];

      if (e.size <= 0 || blocked) {
        tracked[e.path] = ObservedFile(
          size: e.size,
          firstSeenAt: prev?.firstSeenAt ?? now,
          lastSeenAt: now,
          stableChecks: 0,
          clean: false,
        );
        pendingPaths.add(e.path);
        if (blocked) blockedByPartial.add(e.path);
        continue;
      }

      if (prev != null && prev.clean && prev.size == e.size) {
        final nextChecks = prev.stableChecks + 1;
        tracked[e.path] = ObservedFile(
          size: e.size,
          firstSeenAt: prev.firstSeenAt,
          lastSeenAt: now,
          stableChecks: nextChecks,
          clean: true,
        );
        if (role == FileRole.video) {
          stableVideos.add(e.path);
        } else {
          (stableSubsByDir[dir] ??= []).add(e.path);
        }
      } else {
        // First clean observation or file size is still growing: wait for next check.
        tracked[e.path] = ObservedFile(
          size: e.size,
          firstSeenAt: prev?.firstSeenAt ?? now,
          lastSeenAt: now,
          stableChecks: 0,
          clean: true,
        );
        pendingPaths.add(e.path);
      }
    }

    if (stableVideos.isEmpty) {
      return StabilityResult(
        readyPaths: const [],
        readyVideoCount: 0,
        pendingPaths: pendingPaths,
        blockedByPartialPaths: blockedByPartial,
      );
    }

    // Submit ready videos together with any stable subtitles in the same dirs.
    final videoDirs = {
      for (final vp in stableVideos) normalizeDir(p.posix.dirname(vp)),
    };
    final readyPaths = <String>[
      ...stableVideos,
      for (final d in videoDirs) ...(stableSubsByDir[d] ?? const <String>[]),
    ]..sort();

    return StabilityResult(
      readyPaths: readyPaths,
      readyVideoCount: stableVideos.length,
      pendingPaths: pendingPaths,
      blockedByPartialPaths: blockedByPartial,
    );
  }

  /// Marks [paths] as already submitted so subsequent scans never resubmit them.
  void markSubmitted(String ruleId, Iterable<String> paths) {
    final tracked = _observed[ruleId];
    final submitted = _submitted.putIfAbsent(ruleId, () => {});
    for (final path in paths) {
      submitted.add(path);
      tracked?.remove(path);
    }
  }

  /// Drops all tracked state for [ruleId] (when rule is removed or path changed).
  void clearRule(String ruleId) {
    _observed.remove(ruleId);
    _submitted.remove(ruleId);
  }
}

/// Live in-memory runtime status for one [WatchRule], shown on [WatchPage].
@immutable
class WatchRuleRuntimeState {
  final bool checking;
  final int pendingUnstableCount;
  final bool localWatching;

  const WatchRuleRuntimeState({
    this.checking = false,
    this.pendingUnstableCount = 0,
    this.localWatching = false,
  });

  WatchRuleRuntimeState copyWith({
    bool? checking,
    int? pendingUnstableCount,
    bool? localWatching,
  }) => WatchRuleRuntimeState(
    checking: checking ?? this.checking,
    pendingUnstableCount: pendingUnstableCount ?? this.pendingUnstableCount,
    localWatching: localWatching ?? this.localWatching,
  );
}

class _RuleBinding {
  final WatchRule rule;
  Timer? periodicTimer;
  Timer? debounceTimer;
  Timer? verifyTimer;
  StreamSubscription<FileSystemEvent>? fsSub;

  _RuleBinding(this.rule);

  void cancelAll() {
    periodicTimer?.cancel();
    periodicTimer = null;
    debounceTimer?.cancel();
    debounceTimer = null;
    verifyTimer?.cancel();
    verifyTimer = null;
    final sub = fsSub;
    fsSub = null;
    if (sub != null) unawaited(sub.cancel());
  }
}

/// Lightweight watch mode service: local `Directory.watch` (debounced) + remote
/// polling on top of [StorageBackend] (`ThrottledBackend`), with partial-file
/// filtering and a two-check size-stability window. No webhooks.
class WatchService {
  final StorageBackend Function(ConnectionId) backendFor;
  final ConnectionConfig? Function(ConnectionId) connectionFor;
  final TaskManager taskManager;
  final HistoryStore history;
  final WatchRulesStore rulesStore;

  /// False in demo mode so widget tests never leak periodic background timers.
  final bool autoStartTimers;
  final DateTime Function() now;
  final Duration localDebounce;
  final Duration remoteVerifyDelay;
  final StabilityTracker stability;
  final FilenameParser parser;

  final _rules = <String, WatchRule>{};
  final _bindings = <String, _RuleBinding>{};
  final _inFlight = <String>{};
  final _runtime = <String, WatchRuleRuntimeState>{};
  final _runtimeController =
      StreamController<Map<String, WatchRuleRuntimeState>>.broadcast();
  final _autoRunSubs = <TaskId, StreamSubscription<List<TaskSummary>>>{};
  final _autoRunHandled = <TaskId>{};
  var _disposed = false;

  WatchService({
    required this.backendFor,
    required this.connectionFor,
    required this.taskManager,
    required this.history,
    required this.rulesStore,
    this.autoStartTimers = true,
    DateTime Function()? now,
    this.localDebounce = const Duration(seconds: 12),
    this.remoteVerifyDelay = const Duration(seconds: 15),
    StabilityTracker? stability,
    this.parser = const RuleBasedParser(),
  }) : now = now ?? DateTime.now,
       stability = stability ?? StabilityTracker(parser: parser);

  Map<String, WatchRuleRuntimeState> get runtimeSnapshot =>
      Map.unmodifiable(_runtime);

  Stream<Map<String, WatchRuleRuntimeState>> watchRuntime() async* {
    yield runtimeSnapshot;
    yield* _runtimeController.stream;
  }

  /// Reconciles active watchers/timers against persisted [rules].
  void syncRules(List<WatchRule> rules) {
    if (_disposed) return;

    final nextById = {for (final r in rules) r.id: r};

    // Cancel and clean up removed rules.
    final removedIds = [
      for (final id in _rules.keys)
        if (!nextById.containsKey(id)) id,
    ];
    for (final id in removedIds) {
      _rules.remove(id);
      _bindings.remove(id)?.cancelAll();
      stability.clearRule(id);
      _runtime.remove(id);
    }

    for (final rule in rules) {
      final prev = _rules[rule.id];
      _rules[rule.id] = rule;

      if (prev != null &&
          (prev.connection != rule.connection ||
              normalizeDir(prev.path) != normalizeDir(rule.path))) {
        stability.clearRule(rule.id);
      }

      if (!rule.enabled) {
        _bindings.remove(rule.id)?.cancelAll();
        _setRuntime(
          rule.id,
          (_runtime[rule.id] ?? const WatchRuleRuntimeState()).copyWith(
            localWatching: false,
          ),
        );
        continue;
      }

      if (!autoStartTimers) {
        continue;
      }

      final existing = _bindings[rule.id];
      final configChanged =
          existing == null ||
          existing.rule.connection != rule.connection ||
          normalizeDir(existing.rule.path) != normalizeDir(rule.path) ||
          existing.rule.intervalMinutes != rule.intervalMinutes ||
          !existing.rule.enabled;

      if (configChanged) {
        existing?.cancelAll();
        _bindings[rule.id] = _startBinding(rule);
      }
    }

    _emitRuntime();
  }

  _RuleBinding _startBinding(WatchRule rule) {
    final binding = _RuleBinding(rule);
    final conn = connectionFor(rule.connection);
    final interval = Duration(minutes: rule.intervalMinutes.clamp(1, 1440));

    if (conn != null && conn.type == ConnectionType.local) {
      _attachLocalWatcher(binding, conn, rule);
    }

    binding.periodicTimer = Timer.periodic(interval, (_) {
      if (_disposed || !(_rules[rule.id]?.enabled ?? false)) return;
      unawaited(scanRuleNow(rule.id));
    });

    return binding;
  }

  void _attachLocalWatcher(
    _RuleBinding binding,
    ConnectionConfig conn,
    WatchRule rule,
  ) {
    final realDir = _resolveLocalDir(conn.endpoint, rule.path);
    if (realDir == null) {
      unawaited(_safeUpdateStatus(rule.id, '本地路径无效：${rule.path}'));
      return;
    }
    final dir = Directory(realDir);
    if (!dir.existsSync()) {
      unawaited(_safeUpdateStatus(rule.id, '目录不存在：$realDir'));
      return;
    }

    try {
      binding.fsSub = dir
          .watch(recursive: true)
          .listen(
            (event) {
              if (_disposed) return;
              final base = p.basename(event.path);
              if (isPartialDownload(base)) return;
              binding.debounceTimer?.cancel();
              binding.debounceTimer = Timer(localDebounce, () {
                if (_disposed || !(_rules[rule.id]?.enabled ?? false)) return;
                unawaited(scanRuleNow(rule.id));
              });
            },
            onError: (Object err) {
              if (_disposed) return;
              _setRuntime(
                rule.id,
                (_runtime[rule.id] ?? const WatchRuleRuntimeState()).copyWith(
                  localWatching: false,
                ),
              );
              _emitRuntime();
              unawaited(_safeUpdateStatus(rule.id, '本地监听异常：$err'));
            },
          );
      _setRuntime(
        rule.id,
        (_runtime[rule.id] ?? const WatchRuleRuntimeState()).copyWith(
          localWatching: true,
        ),
      );
    } on Object catch (e) {
      unawaited(_safeUpdateStatus(rule.id, '无法监听本地目录：$e'));
    }
  }

  /// Manual trigger for the UI's 「立即检查」 button.
  Future<void> triggerNow(String ruleId) => scanRuleNow(ruleId);

  /// Runs one scan-and-stability check for [ruleId] right now.
  Future<void> scanRuleNow(String ruleId) async {
    if (_disposed) return;
    if (!_inFlight.add(ruleId)) return;

    var rule = _rules[ruleId];
    if (rule == null) {
      try {
        final all = await rulesStore.loadAll();
        rule = all.where((r) => r.id == ruleId).firstOrNull;
        if (rule != null) _rules[ruleId] = rule;
      } on Object {
        // Ignore store error if closing.
      }
    }
    if (rule == null) {
      _inFlight.remove(ruleId);
      return;
    }

    _setRuntime(
      ruleId,
      (_runtime[ruleId] ?? const WatchRuleRuntimeState()).copyWith(
        checking: true,
      ),
    );
    _emitRuntime();

    try {
      final conn = connectionFor(rule.connection);
      if (conn == null) {
        await _safeUpdateStatus(ruleId, '连接不存在');
        return;
      }

      final backend = backendFor(rule.connection);
      final rootDir = normalizeDir(rule.path);
      final files = await _listRecursive(backend, rootDir);
      if (_disposed) return;

      final candidatePaths = [
        for (final f in files)
          if (!f.isDir && !isPartialDownload(f.name)) f.path,
      ];

      final alreadyHandled = await _collectAlreadyHandled(
        rule.connection,
        candidatePaths,
      );
      if (_disposed) return;

      final result = stability.evaluate(
        ruleId: ruleId,
        files: files,
        alreadyHandledPaths: alreadyHandled,
        now: now(),
      );

      _setRuntime(
        ruleId,
        (_runtime[ruleId] ?? const WatchRuleRuntimeState()).copyWith(
          checking: false,
          pendingUnstableCount: result.pendingPaths.length,
        ),
      );
      _emitRuntime();

      if (result.readyPaths.isNotEmpty) {
        final taskId = await taskManager.submit(
          rule.connection,
          result.readyPaths,
          rule.mode,
          scrape: rule.scrape,
        );
        stability.markSubmitted(ruleId, result.readyPaths);
        await _safeUpdateStatus(ruleId, '已提交 ${result.readyVideoCount} 个新文件识别');
        if (rule.autoRunHighConfidence) {
          _watchForAutoRun(taskId, ruleId);
        }
      } else if (result.pendingPaths.isNotEmpty) {
        await _safeUpdateStatus(
          ruleId,
          '等待 ${result.pendingPaths.length} 个文件下载稳定',
        );
        _scheduleVerifyFollowUp(ruleId, conn.type);
      } else {
        await _safeUpdateStatus(ruleId, '无新文件');
      }
    } on StorageException catch (e) {
      if (!_disposed) {
        await _safeUpdateStatus(ruleId, '连接离线：${e.message}');
      }
    } on Object catch (e) {
      if (!_disposed) {
        await _safeUpdateStatus(ruleId, '检查失败：$e');
      }
    } finally {
      _inFlight.remove(ruleId);
      if (!_disposed) {
        _setRuntime(
          ruleId,
          (_runtime[ruleId] ?? const WatchRuleRuntimeState()).copyWith(
            checking: false,
          ),
        );
        _emitRuntime();
      }
    }
  }

  void _scheduleVerifyFollowUp(String ruleId, ConnectionType type) {
    if (_disposed || !autoStartTimers) return;
    final binding = _bindings[ruleId];
    if (binding == null) return;
    binding.verifyTimer?.cancel();
    final delay = type == ConnectionType.local
        ? localDebounce
        : remoteVerifyDelay;
    binding.verifyTimer = Timer(delay, () {
      if (_disposed || !(_rules[ruleId]?.enabled ?? false)) return;
      unawaited(scanRuleNow(ruleId));
    });
  }

  Future<List<RemoteEntry>> _listRecursive(
    StorageBackend backend,
    String rootDir,
  ) async {
    final files = <RemoteEntry>[];
    await walkDirs(
      [rootDir],
      (dir) async {
        final children = await backend.list(dir, refresh: true);
        final hasDisc = children.any(
          (e) =>
              e.isDir &&
              (e.name.toUpperCase() == 'BDMV' ||
                  e.name.toUpperCase() == 'VIDEO_TS'),
        );
        if (hasDisc && dir != '/') {
          return const <String>[];
        }
        final subs = <String>[];
        for (final e in children) {
          if (e.isDir) {
            final upper = e.name.toUpperCase();
            if (upper == 'BDMV' || upper == 'VIDEO_TS') continue;
            subs.add(normalizeDir(e.path));
          } else {
            files.add(e);
          }
        }
        return subs;
      },
      parallel: 3,
      stop: () => _disposed,
    );
    return files;
  }

  Future<Set<String>> _collectAlreadyHandled(
    ConnectionId connection,
    List<String> candidatePaths,
  ) async {
    final handled = <String>{};
    if (candidatePaths.isEmpty) return handled;

    // 1. Paths already organized in history.
    try {
      handled.addAll(await history.areOrganized(connection, candidatePaths));
    } on Object {
      // Ignore history read failure during shutdown.
    }

    // 2. Paths already covered by an active task in TaskManager.
    try {
      final tasks = await taskManager.watchAll().first;
      for (final t in tasks) {
        if (t.connection != connection || !t.stage.isActive) continue;
        for (final tp in t.paths) {
          final normTp = normalizeDir(tp);
          for (final cand in candidatePaths) {
            if (cand == normTp || isWithinDir(cand, normTp)) {
              handled.add(cand);
            }
          }
        }
      }
    } on Object {
      // Ignore task stream error.
    }

    return handled;
  }

  void _watchForAutoRun(TaskId taskId, String ruleId) {
    if (_disposed) return;
    _autoRunSubs.remove(taskId)?.cancel();

    late final StreamSubscription<List<TaskSummary>> sub;
    sub = taskManager.watchAll().listen(
      (tasks) {
        if (_disposed) {
          unawaited(sub.cancel());
          _autoRunSubs.remove(taskId);
          return;
        }
        final task = tasks.where((t) => t.id == taskId).firstOrNull;
        if (task == null) return;
        if (task.stage == TaskStage.awaitingReview) {
          if (!_autoRunHandled.add(taskId)) return;
          unawaited(sub.cancel());
          _autoRunSubs.remove(taskId);
          unawaited(_executeHighConfidence(taskId, ruleId));
        } else if (!task.stage.isActive) {
          unawaited(sub.cancel());
          _autoRunSubs.remove(taskId);
        }
      },
      onError: (_) {
        unawaited(sub.cancel());
        _autoRunSubs.remove(taskId);
      },
    );
    _autoRunSubs[taskId] = sub;
  }

  Future<void> _executeHighConfidence(TaskId taskId, String ruleId) async {
    if (_disposed) return;
    try {
      var rev = await taskManager.review(taskId);
      if (_disposed) return;
      if (rev.preview.conflicts.isNotEmpty) {
        await _safeUpdateStatus(ruleId, '发现命名冲突，已停留在待确认');
        return;
      }

      // Safety invariant: watch mode NEVER auto-deletes any file.
      final selectedDeletes = [
        for (final op in rev.preview.ops)
          if (op.selected && op.kind == OpKind.delete) op,
      ];
      if (selectedDeletes.isNotEmpty) {
        final unassignedPaths = {for (final f in rev.scan.unassigned) f.path};
        for (final op in selectedDeletes) {
          if (unassignedPaths.contains(op.src)) {
            rev = await taskManager.setUnassignedDelete(taskId, op.src, false);
          }
        }
        if (rev.preview.ops.any((o) => o.selected && o.kind == OpKind.delete)) {
          await _safeUpdateStatus(ruleId, '含删除操作，已停留在待确认');
          return;
        }
      }

      if (rev.preview.conflicts.isNotEmpty) {
        await _safeUpdateStatus(ruleId, '发现命名冲突，已停留在待确认');
        return;
      }

      await taskManager.run(taskId, onlyConfident: true);
      await _safeUpdateStatus(ruleId, '高置信新文件已自动执行整理');
    } on StateError {
      // E.g. no confident ops available -> safely stay in awaitingReview.
      if (!_disposed) {
        await _safeUpdateStatus(ruleId, '无高置信可执行项，已停留在待确认');
      }
    } on Object {
      // Leave task in awaitingReview for manual inspection.
    } finally {
      _autoRunHandled.remove(taskId);
    }
  }

  Future<void> _safeUpdateStatus(String ruleId, String status) async {
    if (_disposed) return;
    try {
      await rulesStore.updateRunStatus(ruleId, now(), status);
    } on Object {
      // Ignore DB updates racing with shutdown.
    }
  }

  void _setRuntime(String ruleId, WatchRuleRuntimeState next) {
    _runtime[ruleId] = next;
  }

  void _emitRuntime() {
    if (!_disposed && !_runtimeController.isClosed) {
      _runtimeController.add(runtimeSnapshot);
    }
  }

  static String? _resolveLocalDir(String endpoint, String virtualPath) {
    final root = endpoint.trim();
    if (root.isEmpty) return null;
    final norm = normalizeDir(virtualPath);
    final segs = norm.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.contains('..')) return null;
    return segs.isEmpty ? root : p.joinAll([root, ...segs]);
  }

  void dispose() {
    _disposed = true;
    for (final binding in _bindings.values) {
      binding.cancelAll();
    }
    _bindings.clear();
    for (final sub in _autoRunSubs.values) {
      unawaited(sub.cancel());
    }
    _autoRunSubs.clear();
    unawaited(_runtimeController.close());
  }
}

final watchServiceProvider = Provider<WatchService>((ref) {
  final demo = ref.watch(bootstrapProvider).demo;
  final svc = WatchService(
    backendFor: (id) => ref.read(connectionBackendProvider(id)),
    connectionFor: (id) =>
        ref.read(connectionsProvider).where((c) => c.id == id).firstOrNull,
    taskManager: ref.read(taskManagerProvider),
    history: ref.read(historyProvider),
    rulesStore: ref.read(watchRulesStoreProvider),
    autoStartTimers: !demo,
  );
  ref.onDispose(svc.dispose);
  return svc;
});

final watchRuntimeProvider = StreamProvider<Map<String, WatchRuleRuntimeState>>(
  (ref) => ref.watch(watchServiceProvider).watchRuntime(),
);
