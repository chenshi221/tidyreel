import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/database.dart';
import 'package:tidyreel/data/drift_history_store.dart';
import 'package:tidyreel/data/drift_task_store.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

const task = TaskId('T1-aaaaaa');
const conn = ConnectionId('c1');

RenameOp op(
  String id,
  String src,
  String dst, {
  OpKind kind = OpKind.relocate,
  ExecPhase phase = ExecPhase.files,
}) => RenameOp(
  id: OpId(id),
  kind: kind,
  phase: phase,
  src: src,
  dst: dst,
  group: const GroupId('g1'),
  warning: id == 'o1' ? '超出 TMDB 总集数' : null,
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('DriftHistoryStore', () {
    late DriftHistoryStore history;
    setUp(() => history = DriftHistoryStore(db));

    final ops = [
      op('o0', '', '/d/New', kind: OpKind.mkdir),
      op('o1', '/d/a.mkv', '/d/New/a.mkv'),
      op('o2', '/d/Old', '/d/Newer', phase: ExecPhase.folders),
    ];

    test(
      'beginBatch writes pending records in order; mark updates them',
      () async {
        final b = await history.beginBatch(task, conn, ops);
        var recs = await history.records(b);
        expect(recs.map((r) => r.op.id.value), ['o0', 'o1', 'o2']);
        expect(recs.every((r) => r.status == OpStatus.pending), isTrue);
        expect(recs[1].op.warning, '超出 TMDB 总集数');
        expect(recs[1].op.group, const GroupId('g1'));
        expect(recs[2].op.phase, ExecPhase.folders);

        await history.mark(b, const OpId('o1'), OpStatus.done);
        await history.mark(b, const OpId('o2'), OpStatus.failed, error: 'boom');
        recs = await history.records(b);
        expect(recs.map((r) => r.status), [
          OpStatus.pending,
          OpStatus.done,
          OpStatus.failed,
        ]);
        expect(recs[2].error, 'boom');

        final s = (await history.batches()).single;
        expect((s.id, s.task, s.connection), (b, task, conn));
        expect((s.total, s.done, s.failed, s.undone), (3, 1, 1, false));
      },
    );

    test('batches are newest first and undone is derived', () async {
      final a = await history.beginBatch(task, conn, ops);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final b = await history.beginBatch(const TaskId('T2-bbbbbb'), conn, ops);
      expect((await history.batches()).map((x) => x.id), [b, a]);
      await history.mark(a, const OpId('o1'), OpStatus.undone);
      expect((await history.batches()).last.undone, isTrue);
    });

    test('isOrganized: only done ops on that connection', () async {
      final b = await history.beginBatch(task, conn, ops);
      expect(await history.isOrganized(conn, '/d/New/a.mkv'), isFalse);
      await history.mark(b, const OpId('o1'), OpStatus.done);
      expect(await history.isOrganized(conn, '/d/New/a.mkv'), isTrue);
      expect(
        await history.isOrganized(const ConnectionId('other'), '/d/New/a.mkv'),
        isFalse,
      );
      expect(await history.isOrganized(conn, '/d/nope'), isFalse);
    });

    test('executor round trip: crash, resume, undo through drift', () async {
      final fs = MemoryStorageBackend({
        '/d/Show/a.mkv': 1,
        '/d/Show/b.mkv': 2,
        '/d/Movie.mkv': 3,
      });
      final before = fs.files;
      final plan = RenamePlan(
        ops: [
          op('p1', '/d/Show/a.mkv', '/d/Show/S01/E01.mkv'),
          op('p2', '/d/Show/b.mkv', '/d/Show/S01/E02.mkv'),
          op('p3', '/d/Movie.mkv', '/d/M (2010)/M.mkv'),
          op('p4', '/d/Show', '/d/Show (2020)', phase: ExecPhase.folders),
        ],
      );
      final ex = DefaultExecutor(history, minInterval: Duration.zero);

      final sub = ex.execute(task, conn, plan, fs).listen(null);
      sub.onData((_) => sub.cancel());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final batch = (await history.batches()).single.id;
      expect(
        (await history.records(batch))
            .where((r) => r.status == OpStatus.pending),
        isNotEmpty,
      );

      await ex.resume(batch, fs).drain<void>();
      expect(fs.files, [
        '/d/M (2010)/M.mkv',
        '/d/Show (2020)/S01/E01.mkv',
        '/d/Show (2020)/S01/E02.mkv',
      ]);
      expect((await history.batches()).single.done, 4);

      await ex.undo(batch, fs).drain<void>();
      expect(fs.files, before);
      expect((await history.batches()).single.undone, isTrue);
    });
  });

  group('DriftTaskStore', () {
    late DriftTaskStore store;
    setUp(() => store = DriftTaskStore(db));

    final summary = TaskSummary(
      id: const TaskId('T3-abc123'),
      connection: conn,
      paths: const ['/下载/完成', '/x'],
      mode: OrganizeMode.moveToLibrary,
      stage: TaskStage.awaitingReview,
      message: '识别完成，请确认结果后继续执行',
      importedCount: 7,
      videoCount: 4,
      folderCount: 2,
      subtitleCount: 1,
      progress: 0.5,
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    test('summary round-trips and upserts', () async {
      await store.saveSummary(summary);
      var got = (await store.loadAll()).single;
      expect(got.summary.paths, ['/下载/完成', '/x']);
      expect(got.summary.mode, OrganizeMode.moveToLibrary);
      expect(got.summary.stage, TaskStage.awaitingReview);
      expect(got.summary.progress, 0.5);
      expect(got.summary.createdAt.toUtc(), summary.createdAt);
      expect(got.scan, isNull);
      expect(got.decisions, isEmpty);

      await store.saveSummary(
        TaskSummary(
          id: summary.id,
          connection: conn,
          paths: summary.paths,
          mode: summary.mode,
          stage: TaskStage.done,
          batch: const BatchId('B1'),
          createdAt: summary.createdAt,
        ),
      );
      got = (await store.loadAll()).single;
      expect(got.summary.stage, TaskStage.done);
      expect(got.summary.batch, const BatchId('B1'));
      expect(got.summary.progress, isNull);
    });

    test('scan and decisions round-trip and survive summary updates', () async {
      final review = Demo.review(summary.id, conn, '/下载/完成');
      final decisions = {
        for (final g in review.scan.groups)
          g.id: GroupDecision(
            match: g.match,
            strategy: SeasonStrategy.splitSequential,
            episodeOffset: -1,
            episodeGroupId: 'eg1',
            selected: false,
            overrides: {
              g.files.first.path: const FileOverride(
                season: 2,
                episode: 5,
                kind: MediaKind.special,
                ignore: true,
              ),
            },
          ),
      };
      await store.saveSummary(summary);
      await store.saveReview(summary.id, review.scan, decisions);
      await store.saveSummary(summary); // must not wipe the review

      final got = (await store.loadAll()).single;
      final scan = got.scan!;
      expect(scan.roots, review.scan.roots);
      expect(scan.groups, hasLength(review.scan.groups.length));
      for (var i = 0; i < scan.groups.length; i++) {
        final a = scan.groups[i], b = review.scan.groups[i];
        expect(
          (a.id, a.kind, a.rootDir, a.anchorTitle, a.matchScore),
          (b.id, b.kind, b.rootDir, b.anchorTitle, b.matchScore),
        );
        expect(a.match?.tmdbId, b.match?.tmdbId);
        expect(a.match?.englishTitle, b.match?.englishTitle);
        expect(
          a.show?.seasons.map((s) => s.episodeCount),
          b.show?.seasons.map((s) => s.episodeCount),
        );
        expect(
          a.files.map(
            (f) => (
              f.path,
              f.role,
              f.parsed?.season,
              f.parsed?.episodes.join(","),
              f.parsed?.confidence,
            ),
          ),
          b.files.map(
            (f) => (
              f.path,
              f.role,
              f.parsed?.season,
              f.parsed?.episodes.join(","),
              f.parsed?.confidence,
            ),
          ),
        );
      }
      expect(
        scan.unassigned.map((f) => f.path),
        review.scan.unassigned.map((f) => f.path),
      );

      expect(got.decisions.keys, decisions.keys);
      final d = got.decisions.values.first;
      expect(d.strategy, SeasonStrategy.splitSequential);
      expect(d.episodeOffset, -1);
      expect(d.episodeGroupId, 'eg1');
      expect(d.selected, isFalse);
      final o = d.overrides.values.single;
      expect(
        (o.season, o.episode, o.kind, o.ignore),
        (2, 5, MediaKind.special, true),
      );
    });
  });
}
