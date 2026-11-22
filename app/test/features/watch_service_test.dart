import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/database.dart';
import 'package:tidyreel/data/watch_rules_store.dart';
import 'package:tidyreel/features/watch/watch_service.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _SpyTaskManager extends FakeTaskManager {
  final List<
    ({ConnectionId conn, List<String> paths, OrganizeMode mode, bool scrape})
  >
  submitted = [];
  final List<({TaskId id, bool onlyConfident})> runCalls = [];
  final bool injectConflict;

  _SpyTaskManager({this.injectConflict = false}) : super(step: Duration.zero);

  @override
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode, {
    bool scrape = false,
    bool scrapeOnly = false,
  }) {
    submitted.add((conn: connection, paths: paths, mode: mode, scrape: scrape));
    return super.submit(
      connection,
      paths,
      mode,
      scrape: scrape,
      scrapeOnly: scrapeOnly,
    );
  }

  @override
  Future<TaskReview> review(TaskId id) async {
    final base = await super.review(id);
    if (!injectConflict) return base;
    return TaskReview(
      id: base.id,
      scan: base.scan,
      decisions: base.decisions,
      preview: RenamePlan(
        ops: base.preview.ops,
        conflicts: const [
          PlanConflict(
            ops: [OpId('op1')],
            path: '/conflict.mkv',
            reason: '目标文件名冲突',
          ),
        ],
      ),
    );
  }

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) {
    runCalls.add((id: id, onlyConfident: onlyConfident));
    return super.run(id, onlyConfident: onlyConfident);
  }
}

void main() {
  const connId = ConnectionId('nas-1');
  const conn = ConnectionConfig(
    id: connId,
    name: 'NAS',
    type: ConnectionType.alist,
    endpoint: 'http://nas.local:5244',
    libraryRoot: '/影视库',
  );

  group('isPartialDownload', () {
    test('ignores all partial-download extensions case-insensitively and hidden files', () {
      const partials = [
        'movie.mkv.aria2',
        'MOVIE.MKV.ARIA2',
        'ep01.mp4.!qB',
        'ep01.mp4.!qb',
        'ep01.mkv.part',
        'ep01.mkv.PART',
        'video.crdownload',
        'video.downloading',
        'video.tmp',
        'video.bc!',
        'video.utpart',
        'video.td',
        'video.td.cfg',
        '.syncthing.ep01.mkv.tmp',
        '.hidden.mkv',
        '.DS_Store',
      ];
      for (final name in partials) {
        expect(
          isPartialDownload(name),
          isTrue,
          reason: 'expected partial: $name',
        );
      }
    });

    test('allows completed media and subtitle filenames', () {
      const valid = [
        'Dorohedoro.S01E01.1080p.mkv',
        'Inception.2010.2160p.mp4',
        'Dorohedoro.S01E01.zh-Hans.ass',
        'movie.part1.mkv',
        'episode.srt',
      ];
      for (final name in valid) {
        expect(
          isPartialDownload(name),
          isFalse,
          reason: 'expected valid: $name',
        );
      }
    });
  });

  group('WatchService stability & submission', () {
    late AppDatabase db;
    late WatchRulesStore rulesStore;
    late MemoryHistoryStore history;
    late MemoryStorageBackend backend;
    late _SpyTaskManager tm;
    late WatchService service;
    late DateTime clock;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      rulesStore = WatchRulesStore(db);
      history = MemoryHistoryStore();
      backend = MemoryStorageBackend();
      tm = _SpyTaskManager();
      clock = DateTime.utc(2026, 5, 1, 12, 0);
      service = WatchService(
        backendFor: (_) => backend,
        connectionFor: (id) => id == connId ? conn : null,
        taskManager: tm,
        history: history,
        rulesStore: rulesStore,
        autoStartTimers: false,
        now: () => clock,
      );
    });

    tearDown(() async {
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tm.dispose();
      rulesStore.dispose();
      await db.close();
    });

    test('two-check size stability: growing file and sibling .aria2 are blocked; stable file submits once', () async {
      const rule = WatchRule(
        id: 'w1',
        connection: connId,
        path: '/下载/追番',
        mode: OrganizeMode.inPlace,
        scrape: true,
        autoRunHighConfidence: false,
      );
      await rulesStore.upsert(rule);
      service.syncRules([rule]);

      // Check 1: growing file at 100 MB + file with sibling .aria2
      backend.addFile('/下载/追番/Dorohedoro.S01E01.mkv', 100 << 20);
      backend.addFile('/下载/追番/Dorohedoro.S01E02.mkv', 500 << 20);
      backend.addFile('/下载/追番/Dorohedoro.S01E02.mkv.aria2', 4096);

      await service.scanRuleNow('w1');
      expect(tm.submitted, isEmpty);
      var saved = (await rulesStore.loadAll()).single;
      expect(saved.lastStatus, '等待 2 个文件下载稳定');

      // Check 2: E01 grew to 200 MB (still growing -> NOT ready); E02 still has .aria2 (blocked!)
      clock = clock.add(const Duration(seconds: 30));
      backend.addFile('/下载/追番/Dorohedoro.S01E01.mkv', 200 << 20);
      await service.scanRuleNow('w1');
      expect(tm.submitted, isEmpty);

      // Check 3: E01 stays 200 MB (now stable across 2 checks!); E02 still has .aria2
      clock = clock.add(const Duration(seconds: 30));
      await service.scanRuleNow('w1');
      expect(tm.submitted, hasLength(1));
      expect(tm.submitted.single.paths, ['/下载/追番/Dorohedoro.S01E01.mkv']);
      expect(tm.submitted.single.scrape, isTrue);

      // Check 4: E01 must NOT be re-submitted! E02's .aria2 is gone now (1st clean check -> waits)
      clock = clock.add(const Duration(seconds: 30));
      await backend.remove('/下载/追番', ['Dorohedoro.S01E02.mkv.aria2']);
      await service.scanRuleNow('w1');
      expect(tm.submitted, hasLength(1));

      // Check 5: E02 stable across 2 clean checks -> submits E02 ONCE
      clock = clock.add(const Duration(seconds: 30));
      await service.scanRuleNow('w1');
      expect(tm.submitted, hasLength(2));
      expect(tm.submitted.last.paths, ['/下载/追番/Dorohedoro.S01E02.mkv']);

      // Check 6: Nothing new -> no duplicate submissions, status becomes 无新文件
      clock = clock.add(const Duration(seconds: 30));
      await service.scanRuleNow('w1');
      expect(tm.submitted, hasLength(2));
      saved = (await rulesStore.loadAll()).single;
      expect(saved.lastStatus, '无新文件');
    });

    test('autoRunHighConfidence=false stops at awaitingReview without calling run()', () async {
      const rule = WatchRule(
        id: 'w-review',
        connection: connId,
        path: '/下载/追番',
        autoRunHighConfidence: false,
      );
      await rulesStore.upsert(rule);
      service.syncRules([rule]);

      backend.addFile('/下载/追番/Dorohedoro.S01E01.mkv', 1 << 30);
      await service.scanRuleNow('w-review');
      await service.scanRuleNow('w-review');
      // Let FakeTaskManager reach awaitingReview
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(tm.submitted, hasLength(1));
      expect(tm.runCalls, isEmpty);
      final tasks = await tm.watchAll().first;
      expect(tasks.single.stage, TaskStage.awaitingReview);
    });

    test('autoRunHighConfidence=true runs onlyConfident once awaitingReview when conflict-free', () async {
      const rule = WatchRule(
        id: 'w-auto',
        connection: connId,
        path: '/下载/追番',
        autoRunHighConfidence: true,
      );
      await rulesStore.upsert(rule);
      service.syncRules([rule]);

      backend.addFile('/下载/追番/Dorohedoro.S01E01.mkv', 1 << 30);
      await service.scanRuleNow('w-auto');
      await service.scanRuleNow('w-auto');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(tm.submitted, hasLength(1));
      expect(tm.runCalls, hasLength(1));
      expect(tm.runCalls.single.onlyConfident, isTrue);
      final tasks = await tm.watchAll().first;
      expect(tasks.single.stage, TaskStage.done);
    });

    test('autoRunHighConfidence=true pauses in awaitingReview when plan has conflicts', () async {
      final conflictTm = _SpyTaskManager(injectConflict: true);
      addTearDown(conflictTm.dispose);
      final conflictSvc = WatchService(
        backendFor: (_) => backend,
        connectionFor: (id) => id == connId ? conn : null,
        taskManager: conflictTm,
        history: history,
        rulesStore: rulesStore,
        autoStartTimers: false,
        now: () => clock,
      );
      addTearDown(conflictSvc.dispose);

      const rule = WatchRule(
        id: 'w-conflict',
        connection: connId,
        path: '/下载/追番',
        autoRunHighConfidence: true,
      );
      await rulesStore.upsert(rule);
      conflictSvc.syncRules([rule]);

      backend.addFile('/下载/追番/Dorohedoro.S01E01.mkv', 1 << 30);
      await conflictSvc.scanRuleNow('w-conflict');
      await conflictSvc.scanRuleNow('w-conflict');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(conflictTm.submitted, hasLength(1));
      expect(conflictTm.runCalls, isEmpty);
      final saved = (await rulesStore.loadAll()).single;
      expect(saved.lastStatus, contains('冲突'));
    });

    test('skips files already marked organized in HistoryStore', () async {
      const rule = WatchRule(id: 'w-hist', connection: connId, path: '/下载/追番');
      await rulesStore.upsert(rule);
      service.syncRules([rule]);

      const alreadyPath = '/下载/追番/Dorohedoro.S01E01.mkv';
      backend.addFile(alreadyPath, 1 << 30);
      final batch = await history.beginBatch(
        const TaskId('T-old'),
        connId,
        const [
          RenameOp(
            id: OpId('o1'),
            kind: OpKind.relocate,
            phase: ExecPhase.files,
            src: '/raw/ep01.mkv',
            dst: alreadyPath,
          ),
        ],
      );
      await history.mark(batch, const OpId('o1'), OpStatus.done);

      await service.scanRuleNow('w-hist');
      await service.scanRuleNow('w-hist');
      expect(tm.submitted, isEmpty);
      final saved = (await rulesStore.loadAll()).single;
      expect(saved.lastStatus, '无新文件');
    });
  });
}
