import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../plan/helpers.dart';

const conn = ConnectionId('c');

/// One 异兽魔都 group per task root; the episode number comes from "E05".
/// Listing can be made to fail, like a share that went offline.
class FlakyBackend extends MemoryStorageBackend {
  var broken = false;
  FlakyBackend(super.files);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    if (broken) throw StorageException(StorageErrorCode.network, dir);
    return super.list(dir, refresh: refresh);
  }
}

class ShowRecognizer implements Recognizer {
  @override
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files, {
    Future<List<int>> Function(String path)? read,
  }) async => scanOf([
    tvGroup([
      for (final f in files)
        video(
          f.path,
          season: 1,
          episode: int.parse(RegExp(r'E(\d+)').firstMatch(f.name)![1]!),
        ),
    ], rootDir: roots.single),
  ], roots: roots);
}

void main() {
  late MemoryStorageBackend fs;
  late DefaultTaskManager tm;
  late DefaultTaskManager Function() make;

  setUp(() {
    final history = MemoryHistoryStore();
    final store = MemoryTaskStore();
    fs = FlakyBackend({
      for (var e = 1; e <= 5; e++) '/d/异兽魔都 第一部分/E0$e.mkv': 1,
    });
    make = () => DefaultTaskManager(
      backendFor: (_) => fs,
      recognizer: ShowRecognizer(),
      planner: DefaultPlanner(FakeMetadataProvider()),
      executor: DefaultExecutor(history, minInterval: Duration.zero),
      history: history,
      store: store,
      options: (c, mode) => PlanOptions(mode: mode),
      importUpdateInterval: Duration.zero,
    );
    tm = make();
  });
  tearDown(() => tm.dispose());

  Future<TaskId> submit(String root) async {
    final id = await tm.submit(conn, [root], OrganizeMode.inPlace);
    await tm.watchAll().firstWhere(
      (a) => a.any((t) => t.id == id && t.stage == TaskStage.awaitingReview),
    );
    return id;
  }

  Future<void> runAndWait(TaskId id) async {
    await tm.run(id);
    await tm.watchAll().firstWhere(
      (a) => a.any((t) => t.id == id && !t.stage.isActive),
    );
  }

  List<String> season1() => [
    for (final f in fs.files)
      if (f.startsWith('/d/异兽魔都 (2020)/Season 01/') && f.endsWith('.mkv')) f,
  ];

  test('the rest of a season joins the folder organized earlier', () async {
    await runAndWait(await submit('/d/异兽魔都 第一部分'));
    expect(season1(), hasLength(5));

    for (var e = 6; e <= 12; e++) {
      fs.addFile('/d/异兽魔都 06-12/E${e.toString().padLeft(2, '0')}.mkv', 1);
    }
    final id = await submit('/d/异兽魔都 06-12');
    final review = await tm.review(id);
    final m = review.preview.merges.single;
    expect(m.into, '/d/异兽魔都 (2020)');
    expect(m.exists, isTrue);
    expect(review.preview.canExecute, isTrue);

    await runAndWait(id);
    expect(season1(), hasLength(12));
  });

  test(
    'an episode that is already there is a conflict, never overwritten',
    () async {
      await runAndWait(await submit('/d/异兽魔都 第一部分'));
      fs
        ..addFile('/d/异兽魔都 05-12/E05.mkv')
        ..addFile('/d/异兽魔都 05-12/E06.mkv');
      final id = await submit('/d/异兽魔都 05-12');
      final review = await tm.review(id);
      expect(review.preview.canExecute, isFalse);
      expect(
        review.preview.conflicts.single.path,
        startsWith('/d/异兽魔都 (2020)/Season 01/'),
      );
    },
  );

  test(
    'a folder another tool named (with a TMDB tag) is merged into',
    () async {
      fs = MemoryStorageBackend({
        '/d/Dorohedoro (2020) {tmdb-94954}/Season 01/old S01E01.mkv': 1,
        '/d/异兽魔都 新下载/E02.mkv': 1,
      });
      final id = await submit('/d/异兽魔都 新下载');
      final m = (await tm.review(id)).preview.merges.single;
      expect(m.into, '/d/Dorohedoro (2020) {tmdb-94954}');
      expect(m.exists, isTrue);
    },
  );

  test(
    'a finished task still shows its works without reading the share',
    () async {
      final id = await submit('/d/异兽魔都 第一部分');
      await runAndWait(id);
      (fs as FlakyBackend).broken = true;
      // After a restart nothing is cached: the review comes from the store.
      final restarted = make();
      addTearDown(restarted.dispose);
      final review = await restarted.review(id);
      expect(review.scan.groups.single.match?.tmdbId, 94954);
    },
  );
}
