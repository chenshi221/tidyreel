import 'dart:async';

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
  });

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

  @override
  Stream<ExecProgress> resume(BatchId batch, StorageBackend backend) =>
      _stream((emit, cancelled) async {
        final records = await history.records(batch);
        await _forward(
          [
            for (final r in records)
              if (r.status == OpStatus.pending) r.op,
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
        );
      });

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

    // One fresh listing per folder stands in for two exists() per file.
    final dirs = {
      for (final o in files)
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
    final inverse = <RenameOp>[];
    final byId = <OpId, RenameOp>{};
    final rest = <RenameOp>[];
    for (final o in files) {
      if (o.kind != OpKind.relocate || o.src == o.dst) {
        rest.add(o);
      } else if (present.contains(o.src)) {
        await finish(o, '原位置已被占用：${o.src}', null);
      } else if (!present.contains(o.dst)) {
        await finish(o, '目标已不存在：${o.dst}', null);
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
    final left = await _batched(
      inverse,
      be,
      (_) => null,
      (inv, status, error) => finish(byId[inv.id]!, null, null),
      (inv, {retry = false}) => undoOne(byId[inv.id]!),
      cancelled,
    );
    final queue = [for (final inv in left) byId[inv.id]!, ...rest];
    var next = 0;
    Future<void> worker() async {
      while (!cancelled() && next < queue.length) {
        await undoOne(queue[next++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < queue.length; i++) worker(),
    ]);
    for (final op in mkdirs) {
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
  }) async {
    final ordered = _ordered(ops);
    for (final phase in ExecPhase.values) {
      final inPhase = ordered.where((o) => o.phase == phase).toList();
      var done = 0;
      Future<void> record(RenameOp op, OpStatus status, String? error) async {
        await history.mark(batch, op.id, status, error: error);
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
            await _apply(be, op, resuming: resuming || retry);
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
        var next = 0;
        Future<void> worker() async {
          while (!cancelled() && next < group.length) {
            await one(group[next++]);
          }
        }

        // Folder renames can be nested (parent + child), so they run one by one.
        final width = phase == ExecPhase.files ? concurrency : 1;
        await Future.wait([
          for (var i = 0; i < width && i < group.length; i++) worker(),
        ]);
      }
      if (cancelled()) return;
    }
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
      // A name already there (or wanted twice) needs the tmp-name dance.
      final batch = <RenameOp>[];
      for (final o in ops) {
        final n = p.posix.basename(o.dst);
        final renames = p.posix.basename(o.src) != n;
        if (renames && (taken.contains(n) || targets[n]! > 1)) {
          rest.add(o);
        } else {
          batch.add(o);
        }
      }
      final retry = <RenameOp>[], fresh = <RenameOp>[];
      final renames = {
        for (final o in batch)
          if (p.posix.basename(o.src) != p.posix.basename(o.dst))
            p.posix.basename(o.src): p.posix.basename(o.dst),
      };
      try {
        if (renames.isNotEmpty) await be.renameMany(dir, renames);
      } on Object {
        retry.addAll(batch);
        batch.clear();
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
            final back = {
              for (final o in moving)
                if (renames.containsKey(p.posix.basename(o.src)))
                  p.posix.basename(o.dst): p.posix.basename(o.src),
            };
            if (back.isNotEmpty) await be.renameMany(dir, back);
            fresh.addAll(moving);
          } on Object {
            retry.addAll(moving);
          }
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
    return f.kind == OpKind.relocate &&
        op.src.isNotEmpty &&
        op.src.startsWith('${f.src}/');
  }

  Future<void> _apply(
    StorageBackend be,
    RenameOp op, {
    required bool resuming,
  }) async {
    switch (op.kind) {
      case OpKind.mkdir:
        await be.mkdirs(op.dst);
      case OpKind.delete:
        if (resuming && !await be.exists(op.src)) return;
        await be.remove(p.posix.dirname(op.src), [p.posix.basename(op.src)]);
      case OpKind.relocate:
        // After a crash the op may have finished without being marked.
        if (resuming && !await be.exists(op.src) && await be.exists(op.dst)) {
          return;
        }
        await _relocate(be, op.src, op.dst, op.id, resuming: resuming);
    }
  }

  /// PLAN §4.3 rule 3. Same dir: rename. Otherwise rename to the final name in the
  /// source dir (via a tmp name if taken), then move.
  Future<void> _relocate(
    StorageBackend be,
    String src,
    String dst,
    OpId id, {
    required bool resuming,
  }) async {
    final srcDir = p.posix.dirname(src);
    final dstDir = p.posix.dirname(dst);
    final name = p.posix.basename(dst);
    if (src == dst) return;
    if (srcDir == dstDir) return be.rename(src, name);

    final tmp = '.tidyreel-tmp-${id.value}';
    if (resuming && !await be.exists(src)) {
      // Crashed between steps: continue from wherever the file got to.
      if (await be.exists('$dstDir/$tmp')) {
        return be.rename('$dstDir/$tmp', name);
      }
      if (await be.exists('$srcDir/$tmp')) {
        await be.move(srcDir, dstDir, [tmp]);
        return be.rename('$dstDir/$tmp', name);
      }
      if (await be.exists('$srcDir/$name')) {
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
