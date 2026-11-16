import 'dart:async';

import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// One group per parent dir. Dir name hints: "low" => score 0.3, "nomatch" => no match.
class FakeRecognizer implements Recognizer {
  var calls = 0;
  Completer<void>? gate;

  /// Thrown once by the next recognize call.
  Object? failOnce;

  @override
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files, {
    Future<List<int>> Function(String path)? read,
  }) async {
    calls++;
    await gate?.future;
    if (failOnce case final e?) {
      failOnce = null;
      throw e;
    }
    final byDir = <String, List<ScanFile>>{};
    final junk = <ScanFile>[];
    for (final f in files) {
      final role = f.name.endsWith('.mkv')
          ? FileRole.video
          : f.name.endsWith('.srt')
          ? FileRole.subtitle
          : FileRole.junk;
      final sf = ScanFile(path: f.path, name: f.name, size: f.size, role: role);
      if (role == FileRole.junk) {
        junk.add(sf);
      } else {
        byDir
            .putIfAbsent(f.path.substring(0, f.path.lastIndexOf('/')), () => [])
            .add(sf);
      }
    }
    return ScanResult(
      connection: connection,
      roots: roots,
      unassigned: junk,
      groups: [
        for (final MapEntry(key: dir, value: fs) in byDir.entries)
          MediaGroup(
            id: GroupId('g:$dir'),
            kind: MediaKind.movie,
            anchorTitle: dir.split('/').last,
            rootDir: dir,
            files: fs,
            match: dir.contains('nomatch')
                ? null
                : const Candidate(tmdbId: 1, kind: MediaKind.movie, title: 'x'),
            matchScore: dir.contains('low') ? 0.3 : 0.95,
          ),
      ],
    );
  }
}

/// Files: `dir/name` -> `dir/ok_name` (warning if name has "warn"). One folder op per group:
/// `dir` -> `dir_done` (folders phase).
class FakePlanner implements Planner {
  final seenExisting = <Set<String>>[];
  final seenScrape = <bool>[];

  @override
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  }) async {
    seenExisting.add(existing);
    seenScrape.add(options.scrape);
    final ops = <RenameOp>[];
    final conflicts = <PlanConflict>[];
    for (final g in scan.groups) {
      final sel = decisions[g.id]?.selected ?? true;
      for (final f in g.files) {
        final dst = '${g.rootDir}/ok_${f.name}';
        final op = RenameOp(
          id: OpId('f:${f.path}'),
          kind: OpKind.relocate,
          phase: ExecPhase.files,
          src: f.path,
          dst: dst,
          group: g.id,
          selected: sel,
          warning: f.name.contains('warn') ? '需要确认' : null,
        );
        ops.add(op);
        if (existing.contains(dst)) {
          conflicts.add(PlanConflict(ops: [op.id], path: dst, reason: '已存在'));
        }
      }
      ops.add(
        RenameOp(
          id: OpId('d:${g.rootDir}'),
          kind: OpKind.relocate,
          phase: ExecPhase.folders,
          src: g.rootDir,
          dst: '${g.rootDir}_done',
          group: g.id,
          selected: sel,
        ),
      );
    }
    return RenamePlan(ops: ops, conflicts: conflicts);
  }
}

/// list() can be held back to test cancellation during import.
class GatedBackend extends MemoryStorageBackend {
  Completer<void>? gate;
  GatedBackend(super.files);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    await gate?.future;
    return super.list(dir, refresh: refresh);
  }
}

const conn = ConnectionId('c1');

Map<String, int> library() => {
  '/in/Good/a.mkv': 1,
  '/in/Good/a.srt': 1,
  '/in/Good/readme.txt': 1,
  '/in/Mixed/b.mkv': 1,
  '/in/Mixed/warn.mkv': 1,
  '/in/low/c.mkv': 1,
};

class Rig {
  final MemoryStorageBackend fs;
  final recognizer = FakeRecognizer();
  final planner = FakePlanner();
  final history = MemoryHistoryStore();
  final store = MemoryTaskStore();
  final modes = <OrganizeMode>[];
  late DefaultTaskManager tm;

  Rig(this.fs) {
    tm = make();
  }

  DefaultTaskManager make() => DefaultTaskManager(
    backendFor: (_) => fs,
    recognizer: recognizer,
    planner: planner,
    executor: DefaultExecutor(history, minInterval: Duration.zero),
    history: history,
    store: store,
    options: (c, mode) {
      modes.add(mode);
      return PlanOptions(mode: mode);
    },
    importUpdateInterval: Duration.zero,
  );

  Future<TaskSummary> waitFor(
    TaskId id,
    bool Function(TaskSummary) test, [
    DefaultTaskManager? m,
  ]) => (m ?? tm)
      .watchAll()
      .map((l) => l.where((t) => t.id == id).firstOrNull)
      .where((t) => t != null && test(t))
      .map((t) => t!)
      .first
      .timeout(const Duration(seconds: 5));

  Future<TaskId> submitReady([List<String> paths = const ['/in']]) async {
    final id = await tm.submit(conn, paths, OrganizeMode.inPlace);
    await waitFor(id, (t) => t.stage == TaskStage.awaitingReview);
    return id;
  }
}

/// Refuses to rename [path] while [locked], like a folder held open on Windows.
class LockedFolder extends MemoryStorageBackend {
  final String path;
  bool locked = true;

  LockedFolder(super.files, this.path);

  @override
  Future<void> rename(String p, String newName) async {
    if (locked && p == path) {
      throw StorageException(StorageErrorCode.other, 'Access is denied: $p');
    }
    return super.rename(p, newName);
  }
}

void main() {
  test('a 刮削 task plans with scrape on and keeps the flag', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.tm.submit(
      conn,
      ['/in'],
      OrganizeMode.inPlace,
      scrape: true,
    );
    final ready = await rig.waitFor(
      id,
      (t) => t.stage == TaskStage.awaitingReview,
    );
    expect(ready.scrape, isTrue);
    await rig.tm.review(id);
    expect(rig.planner.seenScrape, everyElement(isTrue));
  });

  test('full lifecycle: import, recognize, review, run, undo', () async {
    final before = library();
    final rig = Rig(MemoryStorageBackend(before));
    final stages = <TaskStage>[];
    final sub = rig.tm.watchAll().listen((l) {
      if (l.isNotEmpty && (stages.isEmpty || stages.last != l.first.stage)) {
        stages.add(l.first.stage);
      }
    });

    final id = await rig.tm.submit(conn, ['/in'], OrganizeMode.inPlace);
    expect(id.value, matches(RegExp(r'^T\d+-[0-9a-f]{6}$')));
    final ready = await rig.waitFor(
      id,
      (t) => t.stage == TaskStage.awaitingReview,
    );
    expect(ready.message, '识别完成，请确认结果后继续执行');
    expect(ready.importedCount, 6);
    expect(ready.videoCount, 4);
    expect(ready.subtitleCount, 1);
    expect(ready.folderCount, 3);

    final review = await rig.tm.review(id);
    expect(review.scan.groups, hasLength(3));
    expect(review.preview.ops.where((o) => o.selected), hasLength(8));

    await rig.tm.run(id);
    final done = await rig.waitFor(id, (t) => t.stage == TaskStage.done);
    expect(done.batch, isNotNull);
    expect(rig.fs.files, contains('/in/Good_done/ok_a.mkv'));
    expect(rig.fs.files, contains('/in/Mixed_done/ok_warn.mkv'));

    await rig.tm.undo(id);
    final undone = await rig.waitFor(id, (t) => t.stage == TaskStage.undone);
    expect(undone.message, '已撤销');
    expect(rig.fs.files, before.keys.toList()..sort());

    await sub.cancel();
    expect(stages, [
      TaskStage.importing,
      TaskStage.recognizing,
      TaskStage.awaitingReview,
      TaskStage.renamingFiles,
      TaskStage.renamingFolders,
      TaskStage.done,
      TaskStage.undone,
    ]);
    // persisted along the way
    expect((await rig.store.loadAll()).single.summary.stage, TaskStage.undone);
  });

  test(
    'retryFailed runs the failed ops again once the folder is free',
    () async {
      final fs = LockedFolder(library(), '/in/Good');
      final rig = Rig(fs);
      final id = await rig.submitReady();
      await rig.tm.run(id);
      final partial = await rig.waitFor(
        id,
        (t) => t.stage == TaskStage.partiallyFailed,
      );
      expect(fs.files, isNot(contains('/in/Good_done/ok_a.mkv')));

      fs.locked = false;
      await rig.tm.retryFailed(id);
      final done = await rig.waitFor(id, (t) => t.stage == TaskStage.done);
      expect(done.batch, partial.batch);
      expect(fs.files, contains('/in/Good_done/ok_a.mkv'));
    },
  );

  test('delete forgets a finished task and its undo log, files stay', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.submitReady();
    await rig.tm.run(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.done);
    final files = Set.of(rig.fs.files);
    expect(await rig.history.batches(), hasLength(1));

    await rig.tm.delete(id);
    expect(await rig.tm.watchAll().first, isEmpty);
    expect(await rig.store.loadAll(), isEmpty);
    expect(await rig.history.batches(), isEmpty);
    expect(rig.fs.files, files);
  });

  test('retry recognizes a failed task again', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    rig.recognizer.failOnce = StateError('请先在「设置」里填写 TMDB API key');
    final id = await rig.tm.submit(conn, ['/in/Good'], OrganizeMode.inPlace);
    final failed = await rig.waitFor(id, (t) => t.stage == TaskStage.cancelled);
    expect(canRetry(failed), isTrue);
    await rig.tm.retry(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.awaitingReview);
    expect(rig.recognizer.calls, 2);
    expect((await rig.tm.review(id)).scan.groups, hasLength(1));
  });

  test('retry re-recognizes an undone task and refuses a done one', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.tm.submit(conn, ['/in/Good'], OrganizeMode.inPlace);
    await rig.waitFor(id, (t) => t.stage == TaskStage.awaitingReview);
    await rig.tm.run(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.done);
    await expectLater(rig.tm.retry(id), throwsStateError);
    await rig.tm.undo(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.undone);
    await rig.tm.retry(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.awaitingReview);
    await rig.tm.run(id);
    final again = await rig.waitFor(id, (t) => t.stage == TaskStage.done);
    expect(rig.fs.files, contains('/in/Good_done/ok_a.mkv'));
    expect(again.batch, isNotNull);
  });

  test('delete refuses a task that is still scanning', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    rig.recognizer.gate = Completer();
    final id = await rig.tm.submit(conn, ['/in/Good'], OrganizeMode.inPlace);
    await rig.waitFor(id, (t) => t.stage.isActive);
    await expectLater(rig.tm.delete(id), throwsStateError);
    rig.recognizer.gate!.complete();
  });

  test('two tasks run concurrently', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    rig.recognizer.gate = Completer();
    final a = await rig.tm.submit(conn, ['/in/Good'], OrganizeMode.inPlace);
    final b = await rig.tm.submit(conn, ['/in/Mixed'], OrganizeMode.inPlace);
    expect(a, isNot(b));
    await rig.waitFor(a, (t) => t.stage == TaskStage.recognizing);
    await rig.waitFor(b, (t) => t.stage == TaskStage.recognizing);
    rig.recognizer.gate!.complete();
    await rig.waitFor(a, (t) => t.stage == TaskStage.awaitingReview);
    await rig.waitFor(b, (t) => t.stage == TaskStage.awaitingReview);
    final list = await rig.tm.watchAll().first;
    expect(list.map((t) => t.id), [b, a]); // newest first
    expect((await rig.tm.review(a)).scan.groups.single.rootDir, '/in/Good');
    expect((await rig.tm.review(b)).scan.groups.single.rootDir, '/in/Mixed');
  });

  test('submitting a single file works', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.submitReady(['/in/Mixed/b.mkv']);
    expect((await rig.tm.review(id)).scan.groups.single.files, hasLength(1));
  });

  test('submitting a path with trailing slash normalizes it', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.submitReady(['/in/Good/']);
    expect((await rig.tm.review(id)).scan.groups.single.rootDir, '/in/Good');
  });

  test('cancel during import stops the pipeline', () async {
    final fs = GatedBackend(library())..gate = Completer();
    final rig = Rig(fs);
    final id = await rig.tm.submit(conn, ['/in'], OrganizeMode.inPlace);
    await rig.tm.cancel(id);
    fs.gate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final t = (await rig.tm.watchAll().first).single;
    expect(t.stage, TaskStage.cancelled);
    expect(t.message, '已取消');
    expect(rig.recognizer.calls, 0);
    await expectLater(rig.tm.review(id), throwsStateError);
  });

  test(
    'a run with nothing selected is refused, not reported as done',
    () async {
      final rig = Rig(MemoryStorageBackend(library()));
      final id = await rig.submitReady();
      for (final g in (await rig.tm.review(id)).scan.groups) {
        await rig.tm.updateDecision(
          id,
          g.id,
          const GroupDecision(selected: false),
        );
      }
      await expectLater(rig.tm.run(id), throwsStateError);
      expect(
        (await rig.tm.watchAll().first).single.stage,
        TaskStage.awaitingReview,
      );
    },
  );

  test('cancel while awaiting review', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.submitReady();
    await rig.tm.cancel(id);
    expect((await rig.tm.watchAll().first).single.stage, TaskStage.cancelled);
    await expectLater(rig.tm.run(id), throwsStateError);
  });

  test(
    'onlyConfident runs only warning-free ops of well-matched groups',
    () async {
      final rig = Rig(MemoryStorageBackend(library()));
      final id = await rig.submitReady();
      await rig.tm.run(id, onlyConfident: true);
      await rig.waitFor(id, (t) => t.stage == TaskStage.done);
      expect(rig.fs.files, [
        '/in/Good_done/ok_a.mkv',
        '/in/Good_done/ok_a.srt',
        '/in/Good_done/readme.txt',
        '/in/Mixed_done/ok_b.mkv',
        '/in/Mixed_done/warn.mkv',
        '/in/low/c.mkv',
      ]);
    },
  );

  test('updateDecision and setMode re-plan and persist', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    final id = await rig.submitReady();
    final good = const GroupId('g:/in/Good');
    final r = await rig.tm.updateDecision(
      id,
      good,
      const GroupDecision(selected: false),
    );
    expect(r.preview.ops.where((o) => o.group == good && o.selected), isEmpty);
    expect(r.decisions[good]!.selected, isFalse);
    expect(
      (await rig.store.loadAll()).single.decisions[good]!.selected,
      isFalse,
    );

    rig.modes.clear();
    await rig.tm.setMode(id, OrganizeMode.moveToLibrary);
    expect(rig.modes, contains(OrganizeMode.moveToLibrary));
    expect(
      (await rig.tm.watchAll().first).single.mode,
      OrganizeMode.moveToLibrary,
    );

    await rig.tm.run(id);
    await rig.waitFor(id, (t) => t.stage == TaskStage.done);
    expect(
      rig.fs.files,
      contains('/in/Good/a.mkv'),
    ); // deselected group untouched
    expect(rig.fs.files, contains('/in/Mixed_done/ok_b.mkv'));
  });

  test('existing targets become conflicts and block run', () async {
    final fs = MemoryStorageBackend({...library(), '/in/Good/ok_a.mkv': 1});
    final rig = Rig(fs);
    final id = await rig.submitReady(['/in/Good/a.mkv']);
    expect(rig.planner.seenExisting.last, contains('/in/Good/ok_a.mkv'));
    expect((await rig.tm.review(id)).preview.canExecute, isFalse);
    await expectLater(rig.tm.run(id), throwsStateError);
    expect(
      (await rig.tm.watchAll().first).single.stage,
      TaskStage.awaitingReview,
    );
    expect(await rig.history.batches(), isEmpty);
  });

  test('restart: mid-import tasks start over from importing', () async {
    final rig = Rig(MemoryStorageBackend(library()));
    rig.recognizer.gate =
        Completer(); // first manager never finishes recognizing
    final id = await rig.tm.submit(conn, ['/in'], OrganizeMode.inPlace);
    await rig.waitFor(id, (t) => t.stage == TaskStage.recognizing);

    final rig2 = Rig(rig.fs);
    final tm2 = DefaultTaskManager(
      backendFor: (_) => rig.fs,
      recognizer: rig2.recognizer,
      planner: rig2.planner,
      executor: DefaultExecutor(rig.history, minInterval: Duration.zero),
      history: rig.history,
      store: rig.store, // same persisted state
      options: (c, m) => PlanOptions(mode: m),
    );
    final t = await rig2.waitFor(
      id,
      (t) => t.stage == TaskStage.awaitingReview,
      tm2,
    );
    expect(t.importedCount, 6);
    expect(rig2.recognizer.calls, 1);
    // ids keep counting upward after a restart
    final next = await tm2.submit(conn, ['/in/Good'], OrganizeMode.inPlace);
    expect(next.value, startsWith('T2-'));
  });

  test(
    'restart: interrupted execution resumes to the same final tree',
    () async {
      // reference run
      final ref = Rig(MemoryStorageBackend(library()));
      final refId = await ref.submitReady();
      await ref.tm.run(refId);
      await ref.waitFor(refId, (t) => t.stage == TaskStage.done);

      final rig = Rig(MemoryStorageBackend(library()));
      final id = await rig.submitReady();
      final plan = (await rig.tm.review(id)).preview;
      // "crash" after the first progress event
      final sub = DefaultExecutor(
        rig.history,
        minInterval: Duration.zero,
      ).execute(id, conn, plan, rig.fs).listen(null);
      final first = Completer<void>();
      sub.onData((_) => first.isCompleted ? null : first.complete());
      await first.future;
      await sub.cancel();
      final stored = (await rig.store.loadAll()).single.summary;
      await rig.store.saveSummary(
        TaskSummary(
          id: id,
          connection: conn,
          paths: stored.paths,
          mode: stored.mode,
          stage: TaskStage.renamingFiles,
          createdAt: stored.createdAt,
        ),
      );
      expect(rig.fs.files, isNot(ref.fs.files));

      final tm2 = rig.make();
      await tm2.resumeInterrupted();
      final t = (await tm2.watchAll().first).single;
      expect(t.stage, TaskStage.done);
      expect(t.batch, isNotNull);
      expect(rig.fs.files, ref.fs.files);

      // and the resumed task can still be undone
      await tm2.undo(id);
      expect(rig.fs.files, library().keys.toList()..sort());
    },
  );

  test(
    'restart: execution that never logged anything goes back to review',
    () async {
      final rig = Rig(MemoryStorageBackend(library()));
      final id = await rig.submitReady();
      final s = (await rig.store.loadAll()).single.summary;
      await rig.store.saveSummary(
        TaskSummary(
          id: id,
          connection: conn,
          paths: s.paths,
          mode: s.mode,
          stage: TaskStage.renamingFolders,
          createdAt: s.createdAt,
        ),
      );
      final tm2 = rig.make();
      await tm2.resumeInterrupted();
      expect(
        (await tm2.watchAll().first).single.stage,
        TaskStage.awaitingReview,
      );
      await tm2.run(id); // scan + decisions were restored from the store
      expect((await tm2.watchAll().first).single.stage, TaskStage.done);
    },
  );

  group('lifecycle and plan regressions', () {
    test('issue 2: undo -> retry -> run binds TaskSummary to the new batch and second undo works', () async {
      final rig = Rig(MemoryStorageBackend({'/in/Good/a.mkv': 1}));
      final id = await rig.submitReady(['/in/Good']);
      await rig.tm.run(id);
      await rig.waitFor(id, (t) => t.stage == TaskStage.done);
      final first = (await rig.tm.watchAll().first).single.batch;

      await rig.tm.undo(id);
      await rig.tm.retry(id);
      await rig.waitFor(id, (t) => t.stage == TaskStage.awaitingReview);
      await rig.tm.run(id);
      await rig.waitFor(id, (t) => t.stage == TaskStage.done);
      final second = (await rig.tm.watchAll().first).single.batch;

      expect(second, isNotNull);
      expect(second, isNot(first));
      expect(rig.fs.files, ['/in/Good_done/ok_a.mkv']);

      await rig.tm.undo(id);
      expect((await rig.tm.watchAll().first).single.stage, TaskStage.undone);
      expect(rig.fs.files, ['/in/Good/a.mkv']);
    });

    test('issue 3: cancelled recognizer from old run cannot overwrite retried task review', () async {
      final rig = Rig(MemoryStorageBackend({'/in/Good/a.mkv': 1}));
      final gate = Completer<void>();
      rig.recognizer.gate = gate;
      final id = await rig.tm.submit(conn, ['/in'], OrganizeMode.inPlace);
      await rig.waitFor(id, (t) => t.stage == TaskStage.recognizing);
      while (rig.recognizer.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await rig.tm.cancel(id);
      rig.recognizer.gate = null;
      rig.fs.addFile('/in/Good/b.mkv');
      await rig.tm.retry(id);
      await rig.waitFor(id, (t) => t.stage == TaskStage.awaitingReview);

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final scan = (await rig.tm.review(id)).scan;
      expect(scan.groups.single.files.map((f) => f.path).toList(), [
        '/in/Good/a.mkv',
        '/in/Good/b.mkv',
      ]);
    });

    test('issue 4: blocked folder undo keeps task non-undone and retryable until unblocked', () async {
      final fs = MemoryStorageBackend({'/in/Good/a.mkv': 1});
      final rig = Rig(fs);
      final id = await rig.submitReady(['/in/Good']);
      await rig.tm.run(id);
      await rig.waitFor(id, (t) => t.stage == TaskStage.done);

      fs.addFile('/in/Good/unrelated.txt', 2);
      await rig.tm.undo(id);
      final t = (await rig.tm.watchAll().first).single;
      expect(t.stage, isNot(TaskStage.undone));
      expect(t.message, contains('已撤销部分操作'));
      expect(canUndo(t), isTrue);

      await fs.remove('/in', ['Good']);
      await rig.tm.undo(id);
      expect((await rig.tm.watchAll().first).single.stage, TaskStage.undone);
      expect(fs.files, ['/in/Good/a.mkv']);
    });

    test('issue 5: onlyConfident honors manually confirmed low-confidence video with its subtitle, and drops unconfirmed subtitles', () async {
      const root = '/d/异兽魔都 2020';
      const gidLow = GroupId('g-low');
      const gidConfirmed = GroupId('g-ok');
      final fs = MemoryStorageBackend({
        '/unconf/a.mkv': 1,
        '/unconf/a.srt': 1,
        '$root/b.mkv': 1,
        '$root/b.srt': 1,
      });
      final scan = ScanResult(
        connection: conn,
        roots: const ['/unconf', root],
        groups: [
          const MediaGroup(
            id: gidLow,
            kind: MediaKind.episode,
            anchorTitle: '异兽魔都',
            rootDir: '/unconf',
            match: Demo.dorohedoro,
            matchScore: 0.2,
            files: [
              ScanFile(
                path: '/unconf/a.mkv',
                name: 'a.mkv',
                size: 1,
                role: FileRole.video,
                parsed: ParsedName(season: 1, episodes: [1], confidence: 0.2),
              ),
              ScanFile(
                path: '/unconf/a.srt',
                name: 'a.srt',
                size: 1,
                role: FileRole.subtitle,
              ),
            ],
          ),
          const MediaGroup(
            id: gidConfirmed,
            kind: MediaKind.episode,
            anchorTitle: '异兽魔都',
            rootDir: root,
            match: Demo.dorohedoro,
            matchScore: 0.9,
            files: [
              ScanFile(
                path: '$root/b.mkv',
                name: 'b.mkv',
                size: 1,
                role: FileRole.video,
                parsed: ParsedName(season: 1, episodes: [2], confidence: 0.2),
              ),
              ScanFile(
                path: '$root/b.srt',
                name: 'b.srt',
                size: 1,
                role: FileRole.subtitle,
              ),
            ],
          ),
        ],
      );
      final store = MemoryTaskStore();
      const tid = TaskId('t5');
      await store.saveSummary(
        TaskSummary(
          id: tid,
          connection: conn,
          paths: const ['/unconf', root],
          mode: OrganizeMode.inPlace,
          stage: TaskStage.awaitingReview,
          createdAt: DateTime(2026),
        ),
      );
      await store.saveReview(tid, scan, {
        gidLow: const GroupDecision(),
        gidConfirmed: const GroupDecision(
          overrides: {'$root/b.mkv': FileOverride()},
        ),
      });
      final h = MemoryHistoryStore();
      final tm = DefaultTaskManager(
        backendFor: (_) => fs,
        recognizer: FakeRecognizer(),
        planner: DefaultPlanner(FakeMetadataProvider()),
        executor: DefaultExecutor(h, minInterval: Duration.zero),
        history: h,
        store: store,
        options: (_, mode) => PlanOptions(mode: mode),
      );

      await tm.run(tid, onlyConfident: true);
      expect((await tm.watchAll().first).single.stage, TaskStage.done);
      // Unconfirmed low-confidence video & its subtitle/folder stay untouched.
      expect(fs.files, containsAll(['/unconf/a.mkv', '/unconf/a.srt']));
      // Manually confirmed video moves together with its subtitle and folder.
      expect(fs.files.where((p) => p.contains('S01E02')).toList(), [
        '/d/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E02.mkv',
        '/d/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E02.srt',
      ]);
    });

    test('issue 6: concurrent updateDecision enforces last-update-wins and blocks run while pending', () async {
      const root = '/d/异兽魔都 2020';
      const gid = GroupId('g1');
      const tid = TaskId('t6');
      final fs = MemoryStorageBackend({'$root/a.mkv': 1});
      final scan = ScanResult(
        connection: conn,
        roots: const ['/d'],
        groups: const [
          MediaGroup(
            id: gid,
            kind: MediaKind.episode,
            anchorTitle: '异兽魔都',
            rootDir: root,
            match: Demo.dorohedoro,
            matchScore: 0.9,
            files: [
              ScanFile(
                path: '$root/a.mkv',
                name: 'a.mkv',
                size: 1,
                role: FileRole.video,
                parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9),
              ),
            ],
          ),
        ],
      );
      final store = MemoryTaskStore();
      await store.saveSummary(
        TaskSummary(
          id: tid,
          connection: conn,
          paths: const ['/d'],
          mode: OrganizeMode.inPlace,
          stage: TaskStage.awaitingReview,
          createdAt: DateTime(2026),
        ),
      );
      await store.saveReview(tid, scan, {gid: const GroupDecision()});
      final gated = _GatedPlanner(gid, offsetToGate: 1);
      final h = MemoryHistoryStore();
      final tm = DefaultTaskManager(
        backendFor: (_) => fs,
        recognizer: FakeRecognizer(),
        planner: gated,
        executor: DefaultExecutor(h, minInterval: Duration.zero),
        history: h,
        store: store,
        options: (_, mode) => PlanOptions(mode: mode),
      );

      await tm.review(tid);
      final first = tm.updateDecision(
        tid,
        gid,
        const GroupDecision(episodeOffset: 1),
      );
      await gated.entered.future;
      // Attempting run while edit is pending must fail rather than run stale plan.
      await expectLater(tm.run(tid), throwsStateError);
      await tm.updateDecision(tid, gid, const GroupDecision(episodeOffset: 2));
      gated.release.complete();
      await first;

      final review = await tm.review(tid);
      expect(review.decisions[gid]!.episodeOffset, 2);
      final dst = review.preview.ops
          .firstWhere(
            (o) => o.kind == OpKind.relocate && o.phase == ExecPhase.files,
          )
          .dst;
      expect(dst, contains('S01E03'));
    });

    test(
      'issue 12: failed setMode restores original mode and plan atomically',
      () async {
        const root = '/d/异兽魔都 2020';
        const gid = GroupId('g1');
        const tid = TaskId('t12');
        final fs = MemoryStorageBackend({'$root/a.mkv': 1});
        final scan = ScanResult(
          connection: conn,
          roots: const ['/d'],
          groups: const [
            MediaGroup(
              id: gid,
              kind: MediaKind.episode,
              anchorTitle: '异兽魔都',
              rootDir: root,
              match: Demo.dorohedoro,
              matchScore: 0.9,
              files: [
                ScanFile(
                  path: '$root/a.mkv',
                  name: 'a.mkv',
                  size: 1,
                  role: FileRole.video,
                  parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9),
                ),
              ],
            ),
          ],
        );
        final store = MemoryTaskStore();
        await store.saveSummary(
          TaskSummary(
            id: tid,
            connection: conn,
            paths: const ['/d'],
            mode: OrganizeMode.inPlace,
            stage: TaskStage.awaitingReview,
            createdAt: DateTime(2026),
          ),
        );
        await store.saveReview(tid, scan, {gid: const GroupDecision()});
        final h = MemoryHistoryStore();
        final tm = DefaultTaskManager(
          backendFor: (_) => fs,
          recognizer: FakeRecognizer(),
          planner: DefaultPlanner(FakeMetadataProvider()),
          executor: DefaultExecutor(h, minInterval: Duration.zero),
          history: h,
          store: store,
          options: (_, mode) => PlanOptions(mode: mode), // missing libraryRoot
        );

        await tm.review(tid);
        await expectLater(
          tm.setMode(tid, OrganizeMode.moveToLibrary),
          throwsArgumentError,
        );
        expect((await tm.watchAll().first).single.mode, OrganizeMode.inPlace);
        expect(
          (await store.loadAll()).single.summary.mode,
          OrganizeMode.inPlace,
        );
      },
    );

    test('issue 13: reopening awaiting-review task reflects updated naming profile without rescan, and finished tasks stay unchanged', () async {
      const root = '/d/异兽魔都 2020';
      const gid = GroupId('g1');
      var naming = NamingProfile.vidhub;
      final fs = MemoryStorageBackend({'$root/a.mkv': 1});
      final scan = ScanResult(
        connection: conn,
        roots: const ['/d'],
        groups: const [
          MediaGroup(
            id: gid,
            kind: MediaKind.episode,
            anchorTitle: '异兽魔都',
            rootDir: root,
            match: Demo.dorohedoro,
            matchScore: 0.9,
            files: [
              ScanFile(
                path: '$root/a.mkv',
                name: 'a.mkv',
                size: 1,
                role: FileRole.video,
                parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9),
              ),
            ],
          ),
        ],
      );
      final store = MemoryTaskStore();
      const tid = TaskId('t13');
      await store.saveSummary(
        TaskSummary(
          id: tid,
          connection: conn,
          paths: const ['/d'],
          mode: OrganizeMode.inPlace,
          stage: TaskStage.awaitingReview,
          createdAt: DateTime(2026),
        ),
      );
      await store.saveReview(tid, scan, {gid: const GroupDecision()});
      final rec = FakeRecognizer();
      final h = MemoryHistoryStore();
      final tm = DefaultTaskManager(
        backendFor: (_) => fs,
        recognizer: rec,
        planner: DefaultPlanner(FakeMetadataProvider()),
        executor: DefaultExecutor(h, minInterval: Duration.zero),
        history: h,
        store: store,
        options: (_, mode) => PlanOptions(mode: mode, naming: naming),
      );

      final before = await tm.review(tid);
      expect(
        before.preview.ops.firstWhere((o) => o.src == '$root/a.mkv').dst,
        contains('异兽魔都.Dorohedoro.2020.S01E01.mkv'),
      );

      naming = naming.copyWith(
        tv: naming.tv.copyWith(
          customTemplate: () => 'CHANGED.S{season:02}E{episode:02}',
        ),
      );
      final after = await tm.review(tid);
      expect(
        after.preview.ops.firstWhere((o) => o.src == '$root/a.mkv').dst,
        contains('CHANGED.S01E01'),
      );
      expect(rec.calls, 0);

      // Executing uses the fresh naming profile, and finished review does not replan.
      await tm.run(tid);
      expect(fs.files, ['/d/异兽魔都 (2020)/Season 01/CHANGED.S01E01.mkv']);
      naming = NamingProfile.vidhub;
      final finished = await tm.review(tid);
      expect(
        finished.preview.ops.firstWhere((o) => o.src == '$root/a.mkv').dst,
        contains('CHANGED.S01E01'),
      );
    });
  });
}

class _GatedPlanner implements Planner {
  final GroupId gid;
  final int offsetToGate;
  final entered = Completer<void>();
  final release = Completer<void>();

  _GatedPlanner(this.gid, {required this.offsetToGate});

  @override
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  }) async {
    final plan = await DefaultPlanner(FakeMetadataProvider())
        .build(scan, decisions, options, existing: existing);
    if (decisions[gid]?.episodeOffset == offsetToGate &&
        existing.isNotEmpty &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return plan;
  }
}
