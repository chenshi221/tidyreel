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
  Future<List<int>> read(String path) =>
      _c('read', [path], () => inner.read(path));
  @override
  Future<void> write(String path, List<int> bytes) =>
      _c('write', [path], () => inner.write(path, bytes));
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

  test('undo moves a folder of files back in a few batch requests', () async {
    final mem = MemoryStorageBackend({
      for (var i = 1; i <= 12; i++) '/s/raw/ep$i.mkv': i,
    });
    final before = mem.files;
    final ops = [
      mkdir('/s/raw/Season 01'),
      for (var i = 1; i <= 12; i++)
        reloc('/s/raw/ep$i.mkv', '/s/raw/Season 01/Show.S01E$i.mkv'),
      reloc('/s/raw', '/s/Show (2026)', phase: ExecPhase.folders),
    ];
    final ex = executor(history);
    await run(ex.execute(task, conn, RenamePlan(ops: ops), mem));
    final b = await theBatch(history);
    final hook = HookBackend(mem);
    await run(ex.undo(b, hook));
    expect(mem.files, before);
    expect(statusCounts(await history.records(b)), {OpStatus.undone: 14});
    // Not ~4 requests per file: one move for all twelve, no per-file
    // exists() (renames are one fs/batch_rename on Alist).
    expect(hook.calls.where((c) => c.startsWith('move')), hasLength(1));
    expect(hook.calls.where((c) => c.startsWith('exists')).length, lessThan(4));
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

  group('undo of swaps, chains and half-done batches', () {
    Future<Map<String, int>> sizes(MemoryStorageBackend f, String dir) async =>
        {for (final e in await f.list(dir)) e.name: e.size};

    test('a rename chain is undone, not skipped', () async {
      final f = MemoryStorageBackend({'/d/E01.mkv': 1, '/d/E02.mkv': 2});
      final ops = [
        reloc('/d/E01.mkv', '/d/E02.mkv'),
        reloc('/d/E02.mkv', '/d/E03.mkv'),
      ];
      final ex = executor(history);
      await run(ex.execute(task, conn, RenamePlan(ops: ops), f));
      final b = await theBatch(history);
      expect(await sizes(f, '/d'), {'E02.mkv': 1, 'E03.mkv': 2});
      await run(ex.undo(b, f));
      expect(await sizes(f, '/d'), {'E01.mkv': 1, 'E02.mkv': 2});
      expect(statusCounts(await history.records(b)), {OpStatus.undone: 2});
    });

    test('a swap and a 3-cycle are undone', () async {
      final f = MemoryStorageBackend({
        '/d/01.mkv': 1,
        '/d/02.mkv': 2,
        '/d/x/a.mkv': 3,
        '/d/x/b.mkv': 4,
        '/d/x/c.mkv': 5,
      });
      final before = {...await sizes(f, '/d'), ...await sizes(f, '/d/x')};
      final ops = [
        reloc('/d/01.mkv', '/d/02.mkv'),
        reloc('/d/02.mkv', '/d/01.mkv'),
        reloc('/d/x/a.mkv', '/d/x/b.mkv'),
        reloc('/d/x/b.mkv', '/d/x/c.mkv'),
        reloc('/d/x/c.mkv', '/d/x/a.mkv'),
      ];
      final ex = executor(history);
      await run(ex.execute(task, conn, RenamePlan(ops: ops), f));
      final b = await theBatch(history);
      await run(ex.undo(b, f));
      expect({...await sizes(f, '/d'), ...await sizes(f, '/d/x')}, before);
      expect(statusCounts(await history.records(b)), {OpStatus.undone: 5});
    });

    test('an occupant that is not part of the undo still blocks it', () async {
      final f = MemoryStorageBackend({'/d/E01.mkv': 1});
      final op = reloc('/d/E01.mkv', '/d/E02.mkv');
      final ex = executor(history);
      await run(ex.execute(task, conn, RenamePlan(ops: [op]), f));
      final b = await theBatch(history);
      f.addFile('/d/E01.mkv', 9); // a new file took the original name
      await run(ex.undo(b, f));
      expect(await sizes(f, '/d'), {'E01.mkv': 9, 'E02.mkv': 1});
      expect(statusCounts(await history.records(b)), {OpStatus.skipped: 1});
    });

    test('a half-applied batch rename is finished on retry', () async {
      final mem = MemoryStorageBackend({
        for (var i = 1; i <= 3; i++) '/s/raw/ep$i.mkv': i,
      });
      final before = mem.files;
      final ops = [
        mkdir('/s/raw/Season 01'),
        for (var i = 1; i <= 3; i++)
          reloc('/s/raw/ep$i.mkv', '/s/raw/Season 01/E$i.mkv'),
      ];
      final ex = executor(history);
      await run(ex.execute(task, conn, RenamePlan(ops: ops), mem));
      final b = await theBatch(history);
      // The undo's batch rename applies E1, then errors on E2 (the throttle
      // splits it into per-file renames on non-Alist backends).
      var hit = false;
      final hook = HookBackend(mem, (m, a) {
        if (m == 'rename' && a.first == '/s/raw/Season 01/E2.mkv' && !hit) {
          hit = true;
          throw const StorageException(StorageErrorCode.other, 'boom');
        }
      });
      await run(ex.undo(b, hook));
      expect(hit, isTrue);
      expect(mem.files, before);
      expect(statusCounts(await history.records(b)), {OpStatus.undone: 4});
    });
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

  test('single-file undo after in-place folder rename locates and restores the file', () async {
    final f = MemoryStorageBackend({'/d/raw/01.mkv': 1, '/d/raw/02.mkv': 2});
    final ops = [
      mkdir('/d/raw/Season 01'),
      reloc('/d/raw/01.mkv', '/d/raw/Season 01/Show.S01E01.mkv'),
      reloc('/d/raw/02.mkv', '/d/raw/Season 01/Show.S01E02.mkv'),
      reloc('/d/raw', '/d/Show (2020)', phase: ExecPhase.folders),
    ];
    final ex = executor(history);
    await run(ex.execute(task, conn, RenamePlan(ops: ops), f));
    final b = await theBatch(history);
    expect(
      await history.isOrganized(
        conn,
        '/d/Show (2020)/Season 01/Show.S01E01.mkv',
      ),
      isTrue,
    );
    expect(
      await history.areOrganized(conn, [
        '/d/Show (2020)/Season 01/Show.S01E01.mkv',
        '/d/Show (2020)/Season 01/Show.S01E02.mkv',
      ]),
      {
        '/d/Show (2020)/Season 01/Show.S01E01.mkv',
        '/d/Show (2020)/Season 01/Show.S01E02.mkv',
      },
    );

    // Undo only the first episode while the folder stays renamed.
    await run(ex.undo(b, f, only: {ops[1].id}));
    expect(f.files, [
      '/d/Show (2020)/01.mkv',
      '/d/Show (2020)/Season 01/Show.S01E02.mkv',
    ]);
    final recs = {for (final r in await history.records(b)) r.op.id: r.status};
    expect(recs[ops[1].id], OpStatus.undone);
    expect(recs[ops[2].id], OpStatus.done);
  });

  test('same-directory colliding renames succeed via tmp names', () async {
    final f = MemoryStorageBackend({'/d/01.mkv': 10, '/d/02.mkv': 20});
    final ops = [
      reloc('/d/01.mkv', '/d/02.mkv'),
      reloc('/d/02.mkv', '/d/03.mkv'),
    ];
    await run(executor(history).execute(task, conn, RenamePlan(ops: ops), f));
    expect(f.files, ['/d/02.mkv', '/d/03.mkv']);
    final b = await theBatch(history);
    expect(statusCounts(await history.records(b)), {OpStatus.done: 2});
  });

  group('swaps and chains on resume / retry', () {
    test('a same-dir swap and a 3-cycle land on resume', () async {
      final f = MemoryStorageBackend({
        '/d/01.mkv': 1,
        '/d/02.mkv': 2,
        '/d/a.mkv': 3,
        '/d/b.mkv': 4,
        '/d/c.mkv': 5,
      });
      final ops = [
        reloc('/d/01.mkv', '/d/02.mkv'),
        reloc('/d/02.mkv', '/d/01.mkv'),
        reloc('/d/a.mkv', '/d/b.mkv'),
        reloc('/d/b.mkv', '/d/c.mkv'),
        reloc('/d/c.mkv', '/d/a.mkv'),
      ];
      final b = await history.beginBatch(task, conn, ops);
      final be = HookBackend(f);
      await run(executor(history).resume(b, be));
      expect(statusCounts(await history.records(b)), {OpStatus.done: 5});
      // Sizes stand in for contents: each file ended up under its new name.
      final sizes = {for (final e in await f.list('/d')) e.name: e.size};
      expect(sizes, {
        '01.mkv': 2,
        '02.mkv': 1,
        'a.mkv': 5,
        'b.mkv': 3,
        'c.mkv': 4,
      });
    });

    test('retryFailed-style resume of a chain parks the blocked op', () async {
      final f = MemoryStorageBackend({'/d/E01.mkv': 1, '/d/E02.mkv': 2});
      final ops = [
        reloc('/d/E01.mkv', '/d/E02.mkv'),
        reloc('/d/E02.mkv', '/d/E03.mkv'),
      ];
      final b = await history.beginBatch(task, conn, ops);
      await run(executor(history).resume(b, f));
      expect(statusCounts(await history.records(b)), {OpStatus.done: 2});
      final sizes = {for (final e in await f.list('/d')) e.name: e.size};
      expect(sizes, {'E02.mkv': 1, 'E03.mkv': 2});
    });

    test('a parked file is not mistaken for done while its target is '
        'still occupied', () async {
      final a = reloc('/d/a.mkv', '/d/b.mkv');
      final f = MemoryStorageBackend({'/d/a.mkv': 1, '/d/b.mkv': 2});
      final b = await history.beginBatch(task, conn, [a]);
      // Crash after a was parked; b.mkv (another file) never moved out.
      await f.rename('/d/a.mkv', '.tidyreel-tmp-${a.id.value}');
      await run(executor(history).resume(b, f));
      final recs = await history.records(b);
      expect(recs.single.status, OpStatus.failed);
      expect(f.files, ['/d/.tidyreel-tmp-${a.id.value}', '/d/b.mkv']);
    });

    test('crash mid-cycle: a landed but unmarked op does not grab the next '
        "op's source", () async {
      final f = MemoryStorageBackend({
        '/d/a.mkv': 1,
        '/d/b.mkv': 2,
        '/d/c.mkv': 3,
      });
      final ab = reloc('/d/a.mkv', '/d/b.mkv');
      final bc = reloc('/d/b.mkv', '/d/c.mkv');
      final ca = reloc('/d/c.mkv', '/d/a.mkv');
      final b = await history.beginBatch(task, conn, [ab, bc, ca]);
      // State at the crash: all three were parked, a->b landed and was
      // marked, b->c landed but the mark was lost, c->a still parked.
      String tmp(RenameOp o) => '.tidyreel-tmp-${o.id.value}';
      await f.rename('/d/a.mkv', tmp(ab));
      await f.rename('/d/b.mkv', tmp(bc));
      await f.rename('/d/c.mkv', tmp(ca));
      await f.rename('/d/${tmp(ab)}', 'b.mkv');
      await history.mark(b, ab.id, OpStatus.done);
      await f.rename('/d/${tmp(bc)}', 'c.mkv');
      await run(executor(history).resume(b, f));
      expect(statusCounts(await history.records(b)), {OpStatus.done: 3});
      final sizes = {for (final e in await f.list('/d')) e.name: e.size};
      expect(sizes, {'a.mkv': 3, 'b.mkv': 1, 'c.mkv': 2});
    });
  });

  test(
    'failed folder rename blocks cleanup delete targeting post-rename path',
    () async {
      final f = MemoryStorageBackend({'/d/raw/a.mkv': 1, '/d/raw/ad.txt': 1});
      final ops = [
        reloc('/d/raw/a.mkv', '/d/raw/Show.S01E01.mkv'),
        reloc('/d/raw', '/d/Show (2020)', phase: ExecPhase.folders),
        RenameOp(
          id: const OpId('del-1'),
          kind: OpKind.delete,
          phase: ExecPhase.cleanup,
          src: '/d/Show (2020)/ad.txt',
          dst: '',
        ),
      ];
      final be = HookBackend(f, (m, a) {
        if (m == 'rename' && a.first == '/d/raw') {
          throw const StorageException(StorageErrorCode.busy, 'locked');
        }
      });
      await run(
        executor(history).execute(task, conn, RenamePlan(ops: ops), be),
      );
      final recs = {
        for (final r in await history.records(await theBatch(history)))
          r.op.id: r.status,
      };
      expect(recs[const OpId('del-1')], OpStatus.skipped);
    },
  );
}
