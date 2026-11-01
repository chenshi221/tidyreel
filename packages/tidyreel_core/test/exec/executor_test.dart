import 'dart:async';

import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Delegates to [inner]; [before] runs ahead of each call and may throw.
class HookBackend implements StorageBackend {
  final MemoryStorageBackend inner;
  final FutureOr<void> Function(String method, List<Object?> args)? before;
  final calls = <String>[];

  HookBackend(this.inner, [this.before]);

  Future<T> _c<T>(String m, List<Object?> a, Future<T> Function() f) async {
    calls.add('$m ${a.join(' ')}');
    await before?.call(m, a);
    return f();
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) =>
      _c('list', [dir], () => inner.list(dir, refresh: refresh));
  @override
  Future<void> mkdirs(String dir) =>
      _c('mkdirs', [dir], () => inner.mkdirs(dir));
  @override
  Future<void> rename(String path, String newName) =>
      _c('rename', [path, newName], () => inner.rename(path, newName));
  @override
  Future<void> renameMany(String dir, Map<String, String> names) => _c(
    'renameMany',
    [dir, for (final e in names.entries) '${e.key}>${e.value}'],
    () => inner.renameMany(dir, names),
  );
  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) => _c(
    'move',
    [srcDir, dstDir, ...names],
    () => inner.move(srcDir, dstDir, names),
  );
  @override
  Future<void> remove(String dir, List<String> names) =>
      _c('remove', [dir, ...names], () => inner.remove(dir, names));
  @override
  Future<bool> exists(String path) =>
      _c('exists', [path], () => inner.exists(path));
  @override
  Future<void> ping() async {}
}

var _n = 0;
RenameOp reloc(
  String src,
  String dst, {
  ExecPhase phase = ExecPhase.files,
  bool selected = true,
}) => RenameOp(
  id: OpId('op${++_n}'),
  kind: OpKind.relocate,
  phase: phase,
  src: src,
  dst: dst,
  selected: selected,
);

RenameOp mkdir(String dir) => RenameOp(
  id: OpId('op${++_n}'),
  kind: OpKind.mkdir,
  phase: ExecPhase.files,
  src: '',
  dst: dir,
);

RenameOp del(String path) => RenameOp(
  id: OpId('op${++_n}'),
  kind: OpKind.delete,
  phase: ExecPhase.cleanup,
  src: path,
  dst: '',
);

const task = TaskId('T1-aaaaaa');
const conn = ConnectionId('c1');

DefaultExecutor executor(HistoryStore h, {List<Duration>? delays}) =>
    DefaultExecutor(
      h,
      minInterval: Duration.zero,
      delay: (d) async => delays?.add(d),
    );

Map<String, int> tree() => {
  '/d/Show.S01/a.mkv': 1,
  '/d/Show.S01/b.mkv': 2,
  '/d/Show.S01/a.srt': 3,
  '/d/Movie.mkv': 4,
  '/d/junk.txt': 5,
};

List<RenameOp> plan() => [
  // listed out of order on purpose: executor must sort by phase
  reloc('/d/Show.S01', '/d/Show (2020)', phase: ExecPhase.folders),
  mkdir('/d/Movie (2010)'),
  reloc('/d/Show.S01/a.mkv', '/d/Show.S01/Season 01/Show.S01E01.mkv'),
  reloc('/d/Show.S01/b.mkv', '/d/Show.S01/Season 01/Show.S01E02.mkv'),
  reloc('/d/Show.S01/a.srt', '/d/Show.S01/Season 01/Show.S01E01.zh-Hans.srt'),
  reloc('/d/Movie.mkv', '/d/Movie (2010)/Movie.2010.mkv'),
  del('/d/junk.txt'),
];

const finalFiles = [
  '/d/Movie (2010)/Movie.2010.mkv',
  '/d/Show (2020)/Season 01/Show.S01E01.mkv',
  '/d/Show (2020)/Season 01/Show.S01E01.zh-Hans.srt',
  '/d/Show (2020)/Season 01/Show.S01E02.mkv',
];

Future<List<ExecProgress>> run(Stream<ExecProgress> s) => s.toList();

Future<BatchId> theBatch(HistoryStore h) async => (await h.batches()).first.id;

Map<OpStatus, int> statusCounts(List<HistoryRecord> rs) {
  final m = <OpStatus, int>{};
  for (final r in rs) {
    m[r.status] = (m[r.status] ?? 0) + 1;
  }
  return m;
}

void main() {
  late MemoryHistoryStore history;
  late MemoryStorageBackend fs;

  setUp(() {
    history = MemoryHistoryStore();
    fs = MemoryStorageBackend(tree());
  });

  test('happy path runs files, then folders, then cleanup', () async {
    final events = await run(
      executor(history).execute(task, conn, RenamePlan(ops: plan()), fs),
    );
    expect(fs.files, finalFiles);
    final b = await theBatch(history);
    expect(statusCounts(await history.records(b)), {OpStatus.done: 7});
    expect(events.map((e) => e.phase).toSet(), ExecPhase.values.toSet());
    final phases = events.map((e) => e.phase.index).toList();
    expect(phases, [...phases]..sort());
    expect(events.where((e) => e.phase == ExecPhase.files).last.done, 5);
    expect(events.where((e) => e.phase == ExecPhase.files).last.total, 5);
    expect(
      await history.isOrganized(conn, '/d/Movie (2010)/Movie.2010.mkv'),
      isTrue,
    );
  });

  test('refuses plans with conflicts and unselected ops are not run', () async {
    final bad = RenamePlan(
      ops: plan(),
      conflicts: const [PlanConflict(ops: [], path: '/x', reason: 'dup')],
    );
    await expectLater(
      executor(history).execute(task, conn, bad, fs),
      emitsError(isA<StateError>()),
    );
    expect(await history.batches(), isEmpty);
    expect(fs.files, tree().keys.toList()..sort());

    await run(
      executor(history).execute(
        task,
        conn,
        RenamePlan(ops: [reloc('/d/Movie.mkv', '/d/M.mkv', selected: false)]),
        fs,
      ),
    );
    expect(fs.files, tree().keys.toList()..sort());
    expect((await history.records(await theBatch(history))), isEmpty);
  });

  test('history is written before storage is touched', () async {
    final seen = <int>[];
    final be = HookBackend(fs, (m, a) async {
      if (m != 'exists') seen.add((await history.batches()).length);
    });
    await run(
      executor(history).execute(task, conn, RenamePlan(ops: plan()), be),
    );
    expect(seen, everyElement(1));
  });

  test(
    'a failed op does not stop independent ops; dependants are skipped',
    () async {
      final ops = [
        reloc('/d/Show.S01/a.mkv', '/d/Show.S01/Season 01/Show.S01E01.mkv'),
        reloc('/d/Show.S01/b.mkv', '/d/Show.S01/Season 01/Show.S01E02.mkv'),
        reloc('/d/Movie.mkv', '/d/Movie (2010)/Movie.2010.mkv'),
        reloc('/d/Show.S01', '/d/Show (2020)', phase: ExecPhase.folders),
        reloc(
          '/d/Show.S01/Season 01',
          '/d/Show.S01/S1',
          phase: ExecPhase.folders,
        ),
      ];
      final be = HookBackend(fs, (m, a) {
        // fail b's move (batched with a's, then on its own), and the folder rename
        if (m == 'move' && a.contains('Show.S01E02.mkv')) {
          throw const StorageException(StorageErrorCode.other, 'boom');
        }
        if (m == 'rename' && a.first == '/d/Show.S01') {
          throw const StorageException(StorageErrorCode.other, 'folder boom');
        }
      });
      final events = await run(
        executor(history).execute(task, conn, RenamePlan(ops: ops), be),
      );
      final recs = await history.records(await theBatch(history));
      final c = statusCounts(recs);
      expect(c[OpStatus.done], 2);
      expect(c[OpStatus.failed], 2);
      expect(c[OpStatus.skipped], 1);
      expect(events.where((e) => e.error != null), hasLength(3));
      // the failed file rename was rolled back to its original name
      expect(fs.files, contains('/d/Show.S01/b.mkv'));
    },
  );

  test('crash after N ops then resume ends in the same tree', () async {
    for (final n in [1, 3, 5]) {
      final h = MemoryHistoryStore();
      final f = MemoryStorageBackend(tree());
      final p = RenamePlan(ops: plan());
      final sub = executor(h).execute(task, conn, p, f).listen(null);
      var seen = 0;
      final stopped = Completer<void>();
      sub.onData((_) {
        if (++seen == n && !stopped.isCompleted) {
          stopped.complete();
        }
      });
      await stopped.future;
      await sub.cancel(); // "crash": nothing after this point runs
      final b = await theBatch(h);
      final left = (await h.records(b))
          .where((r) => r.status == OpStatus.pending);
      expect(left, isNotEmpty, reason: 'n=$n');

      // a crash can also hit between the storage call and the history mark
      final pendingOp = left.first.op;
      if (pendingOp.kind == OpKind.relocate &&
          pendingOp.phase == ExecPhase.files) {
        await f.rename(pendingOp.src, pendingOp.dst.split('/').last);
        await f.mkdirs(
          pendingOp.dst.substring(0, pendingOp.dst.lastIndexOf('/')),
        );
        await f.move(
          pendingOp.src.substring(0, pendingOp.src.lastIndexOf('/')),
          pendingOp.dst.substring(0, pendingOp.dst.lastIndexOf('/')),
          [pendingOp.dst.split('/').last],
        );
      }

      await run(executor(h).resume(b, f));
      expect(f.files, finalFiles, reason: 'n=$n');
      expect(statusCounts(await h.records(b)), {
        OpStatus.done: 7,
      }, reason: 'n=$n');
    }
  });

  test(
    'resume continues from a half-finished cross-directory relocate',
    () async {
      final op = reloc('/d/x/a.mkv', '/d/y/b.mkv');
      final f = MemoryStorageBackend({'/d/x/a.mkv': 1, '/d/x/b.mkv': 2});
      final b = await history.beginBatch(task, conn, [op]);
      await f.rename('/d/x/a.mkv', '.tidyreel-tmp-${op.id.value}');
      await f.mkdirs('/d/y');
      await f.move('/d/x', '/d/y', ['.tidyreel-tmp-${op.id.value}']);
      await run(executor(history).resume(b, f));
      expect(f.files, ['/d/x/b.mkv', '/d/y/b.mkv']);
      expect(statusCounts(await history.records(b)), {OpStatus.done: 1});
    },
  );

  test('undo restores the exact original tree', () async {
    final ex = executor(history);
    await run(
      ex.execute(task, conn, RenamePlan(ops: plan().sublist(0, 6)), fs),
    );
    expect(fs.files, isNot(tree().keys.toList()..sort()));
    final b = await theBatch(history);
    final events = await run(ex.undo(b, fs));
    expect(fs.files, tree().keys.toList()..sort());
    final recs = await history.records(b);
    expect(statusCounts(recs), {OpStatus.undone: 6});
    expect(events, hasLength(6));
    expect(events.every((e) => e.error == null), isTrue);
    expect((await history.batches()).first.undone, isTrue);
  });

  test('undo skips deletes and leaves non-empty mkdir folders', () async {
    final ex = executor(history);
    await run(ex.execute(task, conn, RenamePlan(ops: plan()), fs));
    final b = await theBatch(history);
    // somebody dropped a file into the folder we created
    fs.addFile('/d/Movie (2010)/extra.txt');
    final events = await run(ex.undo(b, fs));
    final byId = {for (final r in await history.records(b)) r.op.kind: r};
    expect(byId[OpKind.delete]!.status, OpStatus.skipped);
    expect(byId[OpKind.mkdir]!.status, OpStatus.skipped);
    expect(events.where((e) => e.error != null), hasLength(2));
    expect(fs.files, contains('/d/Movie (2010)/extra.txt'));
    expect(fs.files, contains('/d/Movie.mkv'));
  });

  test('undo never overwrites an occupied original path', () async {
    final ex = executor(history);
    await run(
      ex.execute(task, conn, RenamePlan(ops: plan().sublist(0, 6)), fs),
    );
    final b = await theBatch(history);
    fs.addFile('/d/Movie.mkv', 99); // new file at the original location
    final events = await run(ex.undo(b, fs));
    // the movie itself, and the then non-empty folder we created
    expect(events.where((e) => e.error != null), hasLength(2));
    final skipped = (await history.records(b))
        .where((r) => r.status == OpStatus.skipped);
    expect(skipped.map((r) => r.op.kind).toSet(), {
      OpKind.relocate,
      OpKind.mkdir,
    });
    expect(fs.files, contains('/d/Movie (2010)/Movie.2010.mkv'));
    expect(fs.files, contains('/d/Movie.mkv'));
  });

  test('undo with only restores just those ops', () async {
    final ex = executor(history);
    final ops = [
      reloc('/d/Movie.mkv', '/d/M2.mkv'),
      reloc('/d/junk.txt', '/d/J2.txt'),
    ];
    await run(ex.execute(task, conn, RenamePlan(ops: ops), fs));
    final b = await theBatch(history);
    await run(ex.undo(b, fs, only: {ops.first.id}));
    expect(fs.files, containsAll(['/d/Movie.mkv', '/d/J2.txt']));
    expect(fs.files, isNot(contains('/d/junk.txt')));
  });

  test('name collision in the source dir goes through a tmp name', () async {
    final f = MemoryStorageBackend({'/d/x/a.mkv': 1, '/d/x/b.mkv': 2});
    final be = HookBackend(f);
    final op = reloc('/d/x/a.mkv', '/d/y/b.mkv');
    await run(executor(history).execute(task, conn, RenamePlan(ops: [op]), be));
    final tmp = '.tidyreel-tmp-${op.id.value}';
    expect(be.calls, contains('rename /d/x/a.mkv $tmp'));
    expect(be.calls, contains('move /d/x /d/y $tmp'));
    expect(f.files, ['/d/x/b.mkv', '/d/y/b.mkv']);
    // and it undoes cleanly (original x/b.mkv untouched)
    await run(executor(history).undo(await theBatch(history), f));
    expect(f.files, ['/d/x/a.mkv', '/d/x/b.mkv']);
  });

  group('retry', () {
    test(
      'rateLimited and network errors retry with 1s/2s/4s backoff',
      () async {
        final delays = <Duration>[];
        var fails = 0;
        final be = HookBackend(fs, (m, a) {
          if (m == 'rename' && fails < 3) {
            throw StorageException(
              fails++ == 1
                  ? StorageErrorCode.network
                  : StorageErrorCode.rateLimited,
              'slow down',
            );
          }
        });
        await run(
          executor(history, delays: delays).execute(
            task,
            conn,
            RenamePlan(ops: [reloc('/d/Movie.mkv', '/d/M2.mkv')]),
            be,
          ),
        );
        expect(delays, const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
        ]);
        expect(fs.files, contains('/d/M2.mkv'));
      },
    );

    test('gives up after 3 retries; other errors are not retried', () async {
      final delays = <Duration>[];
      var renames = 0;
      final be = HookBackend(fs, (m, a) {
        if (m == 'rename') {
          renames++;
          throw StorageException(
            a.first == '/d/Movie.mkv'
                ? StorageErrorCode.rateLimited
                : StorageErrorCode.notFound,
            'x',
          );
        }
      });
      await run(
        executor(history, delays: delays).execute(
          task,
          conn,
          RenamePlan(ops: [reloc('/d/Movie.mkv', '/d/M2.mkv')]),
          be,
        ),
      );
      expect(renames, 4);
      expect(delays, hasLength(3));
      var r = await history.records(await theBatch(history));
      expect(r.single.status, OpStatus.failed);

      renames = 0;
      delays.clear();
      await run(
        executor(history, delays: delays).execute(
          task,
          conn,
          RenamePlan(ops: [reloc('/d/junk.txt', '/d/J2.txt')]),
          be,
        ),
      );
      expect(renames, 1);
      expect(delays, isEmpty);
    });

    test('at most 4 ops in flight', () async {
      var inFlight = 0, peak = 0;
      // One file per folder, so nothing is batched.
      final be = HookBackend(
        MemoryStorageBackend({for (var i = 0; i < 6; i++) '/d$i/f': 1}),
        (m, a) async {
          if (m != 'rename') return;
          peak = peak < ++inFlight ? inFlight : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
        },
      );
      final ops = [for (var i = 0; i < 6; i++) reloc('/d$i/f', '/d$i/g')];
      await run(
        executor(history).execute(task, conn, RenamePlan(ops: ops), be),
      );
      expect(peak, 4);
    });
  });

  test('files of one folder go in one batch rename and one move', () async {
    final f = MemoryStorageBackend({
      for (var i = 1; i <= 3; i++) '/s/4K/0$i.mkv': 1,
    });
    final be = HookBackend(f);
    final ops = [
      for (var i = 1; i <= 3; i++)
        reloc('/s/4K/0$i.mkv', '/s/Season 01/S.S01E0$i.mkv'),
    ];
    await run(executor(history).execute(task, conn, RenamePlan(ops: ops), be));
    // Paced per file on non-Alist backends; Alist gets one batch_rename.
    expect(be.calls.where((c) => c.startsWith('rename ')), hasLength(3));
    expect(be.calls.where((c) => c.startsWith('move')), hasLength(1));
    expect(be.calls.where((c) => c.startsWith('exists')), isEmpty);
    expect(f.files, [
      for (var i = 1; i <= 3; i++) '/s/Season 01/S.S01E0$i.mkv',
    ]);
    final recs = await history.records(await theBatch(history));
    expect(statusCounts(recs)[OpStatus.done], 3);
  });

  test(
    'cancelling the stream stops before the next op but records in-flight ones',
    () async {
      final f = MemoryStorageBackend({
        for (var i = 0; i < 10; i++) '/d$i/f': 1,
      });
      final ops = [for (var i = 0; i < 10; i++) reloc('/d$i/f', '/d$i/g')];
      final sub = executor(history)
          .execute(task, conn, RenamePlan(ops: ops), f)
          .listen(null);
      final first = Completer<void>();
      sub.onData((_) => first.isCompleted ? null : first.complete());
      await first.future;
      await sub.cancel();
      final recs = await history.records(await theBatch(history));
      final done = recs.where((r) => r.status == OpStatus.done).length;
      expect(done, inInclusiveRange(1, 9));
      expect(f.files.where((p) => p.endsWith('/g')), hasLength(done));
    },
  );
}
