// End-to-end: real parser + recognizer + planner + executor + task manager on an
// in-memory drive with messy names; only TMDB is faked.
import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

const conn = ConnectionId('c1');

final messy = <String, int>{
  '/下载/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv': 10,
  '/下载/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].chs.ass': 1,
  '/下载/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E02 [1080p].mkv': 10,
  '/下载/异兽魔都 2020 1080p/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv': 10,
  '/下载/Inception.2010.2160p.BluRay.x265-GRP.mkv': 50,
  '/下载/更多资源请访问 www.example.com.txt': 1,
};

DefaultTaskManager manager(MemoryStorageBackend be, OrganizeMode mode) {
  final metadata = FakeMetadataProvider();
  final history = MemoryHistoryStore();
  return DefaultTaskManager(
    backendFor: (_) => be,
    recognizer: AnchorRecognizer(const RuleBasedParser(), metadata),
    planner: DefaultPlanner(metadata),
    executor: DefaultExecutor(history, minInterval: Duration.zero),
    history: history,
    store: MemoryTaskStore(),
    options: (_, m) => PlanOptions(mode: m, libraryRoot: '/影视库'),
    importUpdateInterval: Duration.zero,
  );
}

Future<TaskSummary> waitFor(TaskManager tm, bool Function(TaskSummary) ok) =>
    tm.watchAll().map((ts) => ts.single).firstWhere(ok);

void main() {
  for (final (mode, expected) in [
    (
      OrganizeMode.inPlace,
      [
        '/下载/更多资源请访问 www.example.com.txt',
        '/下载/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E01.mkv',
        '/下载/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E01.zh-Hans.ass',
        '/下载/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E02.mkv',
        '/下载/异兽魔都 (2020)/Season 02/异兽魔都.Dorohedoro.2020.S02E01.mkv',
        '/下载/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv',
      ],
    ),
    (
      OrganizeMode.moveToLibrary,
      [
        '/下载/更多资源请访问 www.example.com.txt',
        '/影视库/剧集/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E01.mkv',
        '/影视库/剧集/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E01.zh-Hans.ass',
        '/影视库/剧集/异兽魔都 (2020)/Season 01/异兽魔都.Dorohedoro.2020.S01E02.mkv',
        '/影视库/剧集/异兽魔都 (2020)/Season 02/异兽魔都.Dorohedoro.2020.S02E01.mkv',
        '/影视库/电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv',
      ],
    ),
  ]) {
    test(
      'organize ${mode.name}, then undo restores the original tree',
      () async {
        final be = MemoryStorageBackend(messy);
        final original = be.files;
        final tm = manager(be, mode);

        final id = await tm.submit(conn, ['/下载'], mode);
        await waitFor(tm, (t) => t.stage == TaskStage.awaitingReview);

        final review = await tm.review(id);
        expect(review.scan.groups.map((g) => g.match?.title).toSet(), {
          '异兽魔都',
          '盗梦空间',
        });
        expect(review.preview.conflicts, isEmpty);

        await tm.run(id);
        final done = await waitFor(tm, (t) => !t.stage.isActive);
        expect(done.stage, TaskStage.done, reason: done.message);
        // Junk delete is unselected by default, so the ad file stays.
        expect(be.files, unorderedEquals(expected));

        await tm.undo(id);
        await waitFor(tm, (t) => t.stage == TaskStage.undone);
        expect(be.files, original);
      },
    );
  }
}
