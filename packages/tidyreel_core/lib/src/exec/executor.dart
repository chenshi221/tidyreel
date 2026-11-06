import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:path/path.dart' as p;

import '../model/history.dart';
import '../model/ids.dart';
import '../model/plan.dart';
import '../storage/storage_backend.dart';
import 'throttled_backend.dart';

export 'throttled_backend.dart';

/// Owner: Agent E. Persistence of executed ops; the app implements it with drift.
abstract interface class HistoryStore {
  /// Records all selected ops as [OpStatus.pending] before anything runs.
  Future<BatchId> beginBatch(
    TaskId task,
    ConnectionId connection,
    List<RenameOp> ops,
  );
  Future<void> mark(BatchId batch, OpId op, OpStatus status, {String? error});
  Future<List<HistoryRecord>> records(BatchId batch);
  Future<List<BatchSummary>> batches();

  /// For the 只看未整理的 filter: was [path] produced by a done op on [connection]?
  Future<bool> isOrganized(ConnectionId connection, String path);

  /// Batch check for 只看未整理的: returns all paths from [paths] that are organized.
  Future<Set<String>> areOrganized(
    ConnectionId connection,
    Iterable<String> paths,
  );

  /// Drops every batch (and its records) of [task]; it can't be undone after.
  Future<void> deleteTask(TaskId task);
}

/// Owner: Agent E. PLAN §4.3 (write-ahead log, ordering, throttling, undo).
abstract interface class Executor {
  Stream<ExecProgress> execute(
    TaskId task,
    ConnectionId connection,
    RenamePlan plan,
    StorageBackend backend,
  );

  /// Continue a batch that has pending ops (after a crash).
  Stream<ExecProgress> resume(BatchId batch, StorageBackend backend);

  /// Reverse done ops in reverse order; [only] limits to some ops. Never overwrites.
  Stream<ExecProgress> undo(
    BatchId batch,
    StorageBackend backend, {
    Set<OpId>? only,
  });
}

class DefaultExecutor implements Executor {
  final HistoryStore history;

  /// Max ops in flight (PLAN §4.3 rule 5).
  final int concurrency;

  /// Spacing between request starts; 200 ms = 5 req/s. Tests pass [Duration.zero].
  final Duration minInterval;
  final List<Duration> backoff;

  /// Injectable so retry/backoff tests run instantly.
  final Delay delay;

  /// Downloads a [OpKind.write] source URL (TMDB artwork). Tests inject one.
  final Future<List<int>> Function(Uri url) fetch;

  DefaultExecutor(
    this.history, {
    this.concurrency = 4,
    this.minInterval = const Duration(milliseconds: 200),
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.delay = _defaultDelay,
    this.fetch = _download,
  });

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.bytes,
    ),
  );

  static Future<List<int>> _download(Uri url) async {
    try {
      final r = await _dio.getUri<List<int>>(url);
      return r.data ?? const [];
    } on DioException catch (e) {
      throw StorageException(StorageErrorCode.network, '下载 $url：${e.message}');
    }
  }

  static Future<void> _defaultDelay(Duration d) => Future<void>.delayed(d);

  StorageBackend _wrap(StorageBackend be) => ThrottledBackend(
    be,
    minInterval: minInterval,
    backoff: backoff,
    delay: delay,
  );

  @override
  Stream<ExecProgress> execute(
    TaskId task,
    ConnectionId connection,
    RenamePlan plan,
    StorageBackend backend,
  ) {
    if (!plan.canExecute) {
      return Stream.error(
        StateError('plan has conflicts, refusing to execute'),
      );
    }
    final ops = _ordered(plan.ops.where((o) => o.selected));
    return _stream((emit, cancelled) async {
      // Write-ahead: every op is pending in history before storage is touched.
      final batch = await history.beginBatch(task, connection, ops);
      await _forward(
        ops,
        batch,
        _wrap(backend),
        emit,
        cancelled,
        resuming: false,
        failed: [],
      );
    });
  }

  static String _mapPath(String path, Iterable<RenameOp> doneFolders) {
    if (path.isEmpty) return path;
    var cur = path;
    for (final f in doneFolders) {
      if (cur == f.src) {
        cur = f.dst;
      } else if (cur.startsWith('${f.src}/')) {
        cur = '${f.dst}${cur.substring(f.src.length)}';
      }
    }
    return cur;
  }

  static RenameOp _mapOp(RenameOp op, Iterable<RenameOp> doneFolders) =>
      doneFolders.isEmpty
      ? op
      : RenameOp(
          id: op.id,
          kind: op.kind,
          phase: op.phase,
          group: op.group,
          src: _mapPath(op.src, doneFolders),
          dst: _mapPath(op.dst, doneFolders),
          selected: op.selected,
          warning: op.warning,
        );

  @override
  Stream<ExecProgress> resume(BatchId batch, StorageBackend backend) => _stream(
    (emit, cancelled) async {
      final records = await history.records(batch);
      final doneFolders = [
        for (final r in records)
          if (r.status == OpStatus.done &&
              r.op.phase == ExecPhase.folders &&
              r.op.kind == OpKind.relocate)
            r.op,
      ];
      await _forward(
        [
          for (final r in records)
            if (r.status == OpStatus.pending)
              r.op.phase == ExecPhase.files ? _mapOp(r.op, doneFolders) : r.op,
        ],
        batch,
        _wrap(backend),
        emit,
        cancelled,
        resuming: true,
        failed: [
          for (final r in records)
            if (r.status == OpStatus.failed) r.op,
        ],
        landed: {
          for (final r in records)
            if (r.status == OpStatus.done &&
                r.op.phase == ExecPhase.files &&
                r.op.kind == OpKind.relocate)
              _mapPath(r.op.dst, doneFolders),
        },
      );
    },
  );

  @override
  Stream<ExecProgress> undo(
    BatchId batch,
    StorageBackend backend, {
    Set<OpId>? only,
  }) => _stream((emit, cancelled) async {
    final be = _wrap(backend);
    final todo = [
      for (final r in (await history.records(batch)).reversed)
        if (r.status == OpStatus.done &&
            (only == null || only.contains(r.op.id)))
          r.op,
    ];
    final counts = <ExecPhase, int>{};
    for (final op in todo) {
      counts[op.phase] = (counts[op.phase] ?? 0) + 1;
    }
    final seen = <ExecPhase, int>{};

    /// [note] set => skipped (never overwrite / cannot undo). On [failure]
    /// the op stays done so the undo can be retried.
    Future<void> finish(RenameOp op, String? note, String? failure) async {
      if (failure == null) {
        await history.mark(
          batch,
          op.id,
          note == null ? OpStatus.undone : OpStatus.skipped,
          error: note,
        );
      }
      emit(
        ExecProgress(
          phase: op.phase,
          done: seen[op.phase] = (seen[op.phase] ?? 0) + 1,
          total: counts[op.phase]!,
          current: op.id,
          error: failure ?? note,
        ),
      );
    }

    Future<void> undoOne(RenameOp op) async {
      String? note, failure;
      try {
        note = await _undoOp(be, op);
      } on Object catch (e) {
        failure = e.toString();
      }
      await finish(op, note, failure);
    }

    // Folder renames first and one by one (they nest, and the file ops'
    // paths are from before them); then files, batched per folder and in
    // parallel; created folders last, once they are empty again.
    final folders = [
      for (final o in todo)
        if (o.phase != ExecPhase.files) o,
    ];
    final files = [
      for (final o in todo)
        if (o.phase == ExecPhase.files && o.kind != OpKind.mkdir) o,
    ];
    final mkdirs = [
      for (final o in todo)
        if (o.phase == ExecPhase.files && o.kind == OpKind.mkdir) o,
    ];
    for (final op in folders) {
      if (cancelled()) return;
      await undoOne(op);
    }
    final activeFolders = [
      for (final r in await history.records(batch))
        if (r.status == OpStatus.done &&
            r.op.phase == ExecPhase.folders &&
            r.op.kind == OpKind.relocate)
          r.op,
    ];
    final mappedFiles = [for (final o in files) _mapOp(o, activeFolders)];
    final mappedMkdirs = [for (final o in mkdirs) _mapOp(o, activeFolders)];

    // One fresh listing per folder stands in for two exists() per file.
    final dirs = {
      for (final o in mappedFiles)
        if (o.kind == OpKind.relocate) ...[
          p.posix.dirname(o.src),
          p.posix.dirname(o.dst),
        ],
    };
    final present = <String>{};
    for (final d in dirs) {
      if (cancelled()) return;
      try {
        present.addAll((await be.list(d, refresh: true)).map((e) => e.path));
      } on StorageException catch (e) {
        if (e.code != StorageErrorCode.notFound) rethrow;
      }
    }
    // An original location that is occupied only by a file this undo moves
    // away (a chain a->b, b->c) is not a reason to skip; drop candidates
    // until every remaining occupant is one of them.
    var cand = [
      for (final o in mappedFiles)
        if (o.kind == OpKind.relocate &&
            o.src != o.dst &&
            present.contains(o.dst))
          o,
    ];
    while (true) {
      final vacating = {for (final o in cand) o.dst};
      final keep = [
        for (final o in cand)
          if (!present.contains(o.src) || vacating.contains(o.src)) o,
      ];
      if (keep.length == cand.length) break;
      cand = keep;
    }
    final undoing = {for (final o in cand) o.id};
    final inverse = <RenameOp>[];
    final byId = <OpId, RenameOp>{};
    final rest = <RenameOp>[];
    for (final o in mappedFiles) {
      if (o.kind != OpKind.relocate || o.src == o.dst) {
        rest.add(o);
      } else if (!present.contains(o.dst)) {
        await finish(o, '目标已不存在：${o.dst}', null);
      } else if (!undoing.contains(o.id)) {
        await finish(o, '原位置已被占用：${o.src}', null);
      } else {
        final inv = RenameOp(
          id: o.id,
          kind: o.kind,
          phase: o.phase,
          group: o.group,
          src: o.dst,
          dst: o.src,
        );
        inverse.add(inv);
        byId[o.id] = o;
      }
    }

    // Inverses run like forward ops: a failed batch step is retried in resume
    // mode (picking up a half-done rename instead of reporting it missing),
    // and swaps / chains go through tmp names. Backends never overwrite.
    final taken = <String>{};
    Future<void> landed(RenameOp inv) {
      taken.add(inv.dst);
      return finish(byId[inv.id]!, null, null);
    }

    Future<void> invOne(RenameOp inv, {bool retry = false}) async {
      try {
        await _apply(
          be,
          inv,
          resuming: retry,
          srcTaken: taken.contains(inv.src),
        );
      } on Object catch (e) {
        return finish(byId[inv.id]!, null, e.toString());
      }
      await landed(inv);
    }

    final left = await _batched(
      inverse,
      be,
      (_) => null,
      (inv, status, error) => landed(inv),
      invOne,
      cancelled,
    );
    if (cancelled()) return;
    await _runStaged(
      left,
      be,
      width: concurrency,
      stage: true,
      resuming: false,
      taken: taken,
      blocked: (_) => false,
      one: invOne,
      parkFailed: (inv, e) => finish(byId[inv.id]!, null, e.toString()),
      cancelled: cancelled,
    );
    var next = 0;
    Future<void> worker() async {
      while (!cancelled() && next < rest.length) {
        await undoOne(rest[next++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < rest.length; i++) worker(),
    ]);
    for (final op in mappedMkdirs) {
      if (cancelled()) return;
      await undoOne(op);
    }
  });

  /// Returns a skip reason, or null when the op was undone.
  Future<String?> _undoOp(StorageBackend be, RenameOp op) async {
    switch (op.kind) {
      case OpKind.delete:
        return '删除无法撤销';
      case OpKind.mkdir:
        if (!await be.exists(op.dst)) return null;
        // Fresh listing: deleting a folder on stale data could lose files.
        if ((await be.list(op.dst, refresh: true)).isNotEmpty) {
          return '文件夹非空，已保留';
        }
        await be.remove(p.posix.dirname(op.dst), [p.posix.basename(op.dst)]);
        return null;
      case OpKind.write:
        // Only ever a file this op created (write never overwrites).
        if (!await be.exists(op.dst)) return null;
        await be.remove(p.posix.dirname(op.dst), [p.posix.basename(op.dst)]);
        return null;
      case OpKind.relocate:
        if (op.src == op.dst) return null;
        if (await be.exists(op.src)) return '原位置已被占用：${op.src}';
        if (!await be.exists(op.dst)) return '目标已不存在：${op.dst}';
        await _relocate(be, op.dst, op.src, op.id, resuming: false);
        return null;
    }
  }

  /// Files -> folders -> cleanup; mkdir first inside a phase; otherwise stable.
  List<RenameOp> _ordered(Iterable<RenameOp> ops) {
    int rank(RenameOp o) =>
        o.phase.index * 2 + (o.kind == OpKind.mkdir ? 0 : 1);
    final list = ops.toList();
    final idx = {for (var i = 0; i < list.length; i++) list[i]: i};
    list.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
    });
    return list;
  }

  Future<void> _forward(
    List<RenameOp> ops,
    BatchId batch,
    StorageBackend be,
    void Function(ExecProgress) emit,
    bool Function() cancelled, {
    required bool resuming,
    required List<RenameOp> failed,
    Set<String> landed = const {},
  }) async {
    final ordered = _ordered(ops);
    // Paths a done relocate put its file at. A pending op whose src is one of
    // them no longer finds its own file there (that one already left: the done
    // op could not have landed otherwise), so its src counts as gone.
    final taken = {...landed};
    for (final phase in ExecPhase.values) {
      final inPhase = ordered.where((o) => o.phase == phase).toList();
      var done = 0;
      Future<void> record(RenameOp op, OpStatus status, String? error) async {
        await history.mark(batch, op.id, status, error: error);
        if (status == OpStatus.done && op.kind == OpKind.relocate) {
          taken.add(op.dst);
        }
        emit(
          ExecProgress(
            phase: phase,
            done: ++done,
            total: inPhase.length,
            current: op.id,
            error: error,
          ),
        );
      }

      RenameOp? blockerOf(RenameOp op) =>
          failed.where((f) => _blocks(f, op)).firstOrNull;

      Future<void> one(RenameOp op, {bool retry = false}) async {
        String? error;
        var status = OpStatus.done;
        final blocker = blockerOf(op);
        if (blocker != null) {
          status = OpStatus.skipped;
          error =
              '依赖的操作失败：${blocker.kind == OpKind.mkdir ? blocker.dst : blocker.src}';
        } else {
          try {
            await _apply(
              be,
              op,
              resuming: resuming || retry,
              srcTaken: taken.contains(op.src),
            );
          } on Object catch (e) {
            status = OpStatus.failed;
            error = e.toString();
            failed.add(op);
          }
        }
        await record(op, status, error);
      }

      // mkdirs finish before anything that may move into them.
      for (var group in [
        inPhase.where((o) => o.kind == OpKind.mkdir).toList(),
        inPhase.where((o) => o.kind != OpKind.mkdir).toList(),
      ]) {
        if (phase == ExecPhase.files && !resuming) {
          group = await _batched(group, be, blockerOf, record, one, cancelled);
        }
        await _runStaged(
          group,
          be,
          // Folder renames can be nested (parent + child): one by one.
          width: phase == ExecPhase.files ? concurrency : 1,
          // Resume mode never runs _batched, so this is what keeps a retried
          // EP01 <-> EP02 from colliding.
          stage: phase == ExecPhase.files,
          resuming: resuming,
          taken: taken,
          blocked: (o) => blockerOf(o) != null,
          one: one,
          parkFailed: (o, e) async {
            failed.add(o);
            await record(o, OpStatus.failed, e.toString());
          },
          cancelled: cancelled,
        );
      }
      if (cancelled()) return;
    }
  }

  static String _tmpName(OpId id) => '.tidyreel-tmp-${id.value}';

  /// Runs [group] [width] at a time. With [stage], relocates whose target
  /// another op of [group] still has to vacate (swaps, chains) are parked
  /// under their tmp name first and landed after the rest via
  /// `one(op, retry: true)`, which resumes from the tmp name.
  Future<void> _runStaged(
    List<RenameOp> group,
    StorageBackend be, {
    required int width,
    required bool stage,
    required bool resuming,
    required Set<String> taken,
    required bool Function(RenameOp) blocked,
    required Future<void> Function(RenameOp, {bool retry}) one,
    required Future<void> Function(RenameOp, Object error) parkFailed,
    required bool Function() cancelled,
  }) async {
    final staged = stage ? _occupiedByPeer(group) : const <RenameOp>[];
    final parked = <RenameOp>[];
    if (staged.isNotEmpty) {
      final ids = {for (final o in staged) o.id};
      group = [
        for (final o in group)
          if (!ids.contains(o.id)) o,
      ];
      for (final o in staged) {
        if (cancelled()) return;
        if (blocked(o)) {
          parked.add(o); // one() records the skip
          continue;
        }
        try {
          // When resuming, the file may already be parked, or have landed
          // (src then holds the file of the op that moved in).
          final tmp = p.posix.join(p.posix.dirname(o.src), _tmpName(o.id));
          if (!resuming ||
              (!taken.contains(o.src) &&
                  !await be.exists(tmp) &&
                  await be.exists(o.src))) {
            await be.rename(o.src, _tmpName(o.id));
          }
          parked.add(o);
        } on Object catch (e) {
          await parkFailed(o, e);
        }
      }
    }
    var next = 0;
    Future<void> worker() async {
      while (!cancelled() && next < group.length) {
        await one(group[next++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < width && i < group.length; i++) worker(),
    ]);
    // Their targets are free now.
    for (final o in parked) {
      if (cancelled()) return;
      await one(o, retry: true);
    }
  }

  /// Relocates whose target is the source of another op in [ops].
  static List<RenameOp> _occupiedByPeer(List<RenameOp> ops) {
    final sources = {
      for (final o in ops)
        if (o.kind == OpKind.relocate) o.src,
    };
    return [
      for (final o in ops)
        if (o.kind == OpKind.relocate &&
            o.src != o.dst &&
            sources.contains(o.dst))
          o,
    ];
  }

  /// Is [op]'s file parked under its tmp name (by a swap or a crash)?
  Future<bool> _parked(StorageBackend be, RenameOp op) async {
    final srcDir = p.posix.dirname(op.src);
    final dstDir = p.posix.dirname(op.dst);
    final tmp = _tmpName(op.id);
    if (await be.exists(p.posix.join(srcDir, tmp))) return true;
    return srcDir != dstDir && await be.exists(p.posix.join(dstDir, tmp));
  }

  /// Runs the file relocates of each source folder as one batch rename plus one
  /// move per target folder (a few requests instead of ~4 per file). Returns
  /// the ops left for one-by-one execution; when a batch step fails its ops are
  /// retried one by one in resume mode, which picks up wherever each file got to.
  Future<List<RenameOp>> _batched(
    List<RenameOp> group,
    StorageBackend be,
    RenameOp? Function(RenameOp) blockerOf,
    Future<void> Function(RenameOp, OpStatus, String?) record,
    Future<void> Function(RenameOp, {bool retry}) one,
    bool Function() cancelled,
  ) async {
    final rest = <RenameOp>[];
    final bySrcDir = <String, List<RenameOp>>{};
    for (final op in group) {
      if (op.kind == OpKind.relocate &&
          op.src != op.dst &&
          blockerOf(op) == null) {
        (bySrcDir[p.posix.dirname(op.src)] ??= []).add(op);
      } else {
        rest.add(op);
      }
    }
    for (final MapEntry(key: dir, value: ops) in bySrcDir.entries) {
      if (cancelled()) return const [];
      if (ops.length < 2) {
        rest.addAll(ops);
        continue;
      }
      final taken = {for (final e in await be.list(dir, refresh: true)) e.name};
      final targets = <String, int>{};
      for (final o in ops) {
        final n = p.posix.basename(o.dst);
        targets[n] = (targets[n] ?? 0) + 1;
      }
      final freeing = {
        for (final o in ops)
          if (p.posix.basename(o.src) != p.posix.basename(o.dst) ||
              p.posix.dirname(o.dst) != dir)
            p.posix.basename(o.src),
      };
      // A name already there (or wanted twice) needs the tmp-name dance.
      final batch = <RenameOp>[];
      final viaTmp = <RenameOp>[];
      for (final o in ops) {
        final n = p.posix.basename(o.dst);
        final renames = p.posix.basename(o.src) != n;
        if (!renames) {
          batch.add(o);
        } else if (targets[n]! == 1 && !taken.contains(n)) {
          batch.add(o);
        } else if (targets[n]! == 1 &&
            p.posix.dirname(o.dst) == dir &&
            freeing.contains(n)) {
          viaTmp.add(o);
        } else {
          rest.add(o);
        }
      }
      final retry = <RenameOp>[], fresh = <RenameOp>[];
      final renames = {
        for (final o in batch)
          if (p.posix.basename(o.src) != p.posix.basename(o.dst))
            p.posix.basename(o.src): p.posix.basename(o.dst),
        for (final o in viaTmp) p.posix.basename(o.src): _tmpName(o.id),
      };
      try {
        if (renames.isNotEmpty) await be.renameMany(dir, renames);
      } on Object {
        retry.addAll([...batch, ...viaTmp]);
        batch.clear();
        viaTmp.clear();
      }
      final byDstDir = <String, List<RenameOp>>{};
      for (final o in batch) {
        final d = p.posix.dirname(o.dst);
        if (d != dir) (byDstDir[d] ??= []).add(o);
      }
      for (final MapEntry(key: dst, value: moving) in byDstDir.entries) {
        try {
          await be.mkdirs(dst);
          await be.move(dir, dst, [
            for (final o in moving) p.posix.basename(o.dst),
          ]);
        } on Object {
          batch.removeWhere(moving.contains);
          // Put the names back so each file can fail (or work) on its own.
          try {
            final nowInDir = {
              for (final e in await be.list(dir, refresh: true)) e.name,
            };
            final back = {
              for (final o in moving)
                if (renames.containsKey(p.posix.basename(o.src)) &&
                    nowInDir.contains(p.posix.basename(o.dst)))
                  p.posix.basename(o.dst): p.posix.basename(o.src),
            };
            if (back.isNotEmpty) await be.renameMany(dir, back);
            if (moving.every(
              (o) => nowInDir.contains(p.posix.basename(o.dst)),
            )) {
              fresh.addAll(moving);
            } else {
              retry.addAll(moving);
            }
          } on Object {
            retry.addAll(moving);
          }
        }
      }
      if (viaTmp.isNotEmpty) {
        try {
          await be.renameMany(dir, {
            for (final o in viaTmp) _tmpName(o.id): p.posix.basename(o.dst),
          });
          batch.addAll(viaTmp);
        } on Object {
          retry.addAll(viaTmp);
        }
      }
      for (final o in batch) {
        await record(o, OpStatus.done, null);
      }
      for (final o in [...fresh, ...retry]) {
        if (cancelled()) return const [];
        await one(o, retry: retry.contains(o));
      }
    }
    return rest;
  }

  /// Does a failed [f] make [op] impossible?
  bool _blocks(RenameOp f, RenameOp op) {
    if (f.kind == OpKind.mkdir) {
      return op.kind != OpKind.delete &&
          (op.dst == f.dst || op.dst.startsWith('${f.dst}/'));
    }
    if (f.kind != OpKind.relocate || op.src.isEmpty) return false;
    if (op.src.startsWith('${f.src}/')) return true;
    return f.phase == ExecPhase.folders &&
        f.dst.isNotEmpty &&
        op.src.startsWith('${f.dst}/');
  }

  Future<void> _apply(
    StorageBackend be,
    RenameOp op, {
    required bool resuming,
    bool srcTaken = false,
  }) async {
    switch (op.kind) {
      case OpKind.mkdir:
        await be.mkdirs(op.dst);
      case OpKind.delete:
        if (resuming && !await be.exists(op.src)) return;
        await be.remove(p.posix.dirname(op.src), [p.posix.basename(op.src)]);
      case OpKind.write:
        // After a crash the file may already be written.
        if (resuming && await be.exists(op.dst)) return;
        final bytes = op.src.startsWith(writeTextPrefix)
            ? utf8.encode(op.src.substring(writeTextPrefix.length))
            : await fetch(Uri.parse(op.src));
        await be.write(op.dst, bytes);
      case OpKind.relocate:
        // The tmp name carries this op's id, so a file there is ours whatever
        // sits at src or dst (another op's file may have landed on either).
        final parked = resuming && await _parked(be, op);
        final srcGone =
            parked || (resuming && (srcTaken || !await be.exists(op.src)));
        // After a crash the op may have finished without being marked.
        if (srcGone && !parked && await be.exists(op.dst)) return;
        await _relocate(
          be,
          op.src,
          op.dst,
          op.id,
          resuming: resuming,
          srcGone: srcGone,
        );
    }
  }

  /// PLAN §4.3 rule 3. Same dir: rename. Otherwise rename to the final name in the
  /// source dir (via a tmp name if taken), then move. When [resuming],
  /// [srcGone] says the file is no longer at [src] (checked by the caller).
  Future<void> _relocate(
    StorageBackend be,
    String src,
    String dst,
    OpId id, {
    required bool resuming,
    bool srcGone = false,
  }) async {
    final srcDir = p.posix.dirname(src);
    final dstDir = p.posix.dirname(dst);
    final name = p.posix.basename(dst);
    if (src == dst) return;
    final tmp = _tmpName(id);
    if (srcDir == dstDir) {
      if (resuming && srcGone) {
        final tmpPath = p.posix.join(srcDir, tmp);
        if (await be.exists(tmpPath)) {
          return be.rename(tmpPath, name);
        }
        throw StorageException(StorageErrorCode.notFound, src);
      }
      return be.rename(src, name);
    }

    if (resuming && srcGone) {
      // Crashed between steps: continue from wherever the file got to.
      final dstTmp = p.posix.join(dstDir, tmp);
      final srcTmp = p.posix.join(srcDir, tmp);
      final srcNamed = p.posix.join(srcDir, name);
      if (await be.exists(dstTmp)) {
        return be.rename(dstTmp, name);
      }
      if (await be.exists(srcTmp)) {
        await be.move(srcDir, dstDir, [tmp]);
        return be.rename(dstTmp, name);
      }
      if (await be.exists(srcNamed)) {
        await be.mkdirs(dstDir);
        return be.move(srcDir, dstDir, [name]);
      }
      throw StorageException(StorageErrorCode.notFound, src);
    }

    final srcName = p.posix.basename(src);
    var cur = srcName;
    if (srcName != name) {
      cur = await be.exists(p.posix.join(srcDir, name)) ? tmp : name;
      await be.rename(src, cur);
    }
    try {
      await be.mkdirs(dstDir);
      await be.move(srcDir, dstDir, [cur]);
    } on Object {
      if (cur != srcName) {
        try {
          await be.rename(p.posix.join(srcDir, cur), srcName);
        } on Object {
          // best effort; the original error is what matters
        }
      }
      rethrow;
    }
    if (cur != name) await be.rename(p.posix.join(dstDir, cur), name);
  }

  /// Runs [body] lazily on listen; cancelling the subscription stops it between
  /// ops and waits for in-flight ops to be recorded.
  Stream<ExecProgress> _stream(
    Future<void> Function(
      void Function(ExecProgress) emit,
      bool Function() cancelled,
    )
    body,
  ) {
    late final StreamController<ExecProgress> c;
    late final Future<void> job;
    var cancelled = false;
    c = StreamController<ExecProgress>(
      onListen: () {
        job = body(c.add, () => cancelled);
        job.then(
          (_) => c.close(),
          onError: (Object e, StackTrace st) {
            c.addError(e, st);
            c.close();
          },
        );
      },
      onCancel: () {
        cancelled = true;
        return job.then((_) {}, onError: (_) {});
      },
    );
    return c.stream;
  }
}
