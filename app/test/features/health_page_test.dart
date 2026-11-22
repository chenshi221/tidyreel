import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/health/health_page.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _RecordingTaskManager extends FakeTaskManager {
  final List<
    ({
      ConnectionId connection,
      List<String> paths,
      OrganizeMode mode,
      bool scrape,
      bool scrapeOnly,
    })
  >
  submissions = [];

  _RecordingTaskManager() : super(step: Duration.zero);

  @override
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode, {
    bool scrape = false,
    bool scrapeOnly = false,
  }) {
    submissions.add((
      connection: connection,
      paths: paths,
      mode: mode,
      scrape: scrape,
      scrapeOnly: scrapeOnly,
    ));
    return super.submit(
      connection,
      paths,
      mode,
      scrape: scrape,
      scrapeOnly: scrapeOnly,
    );
  }
}

void main() {
  testWidgets(
    'runs scan, switches tabs, deletes duplicate with confirmation, and submits scrapeOnly task',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final backend = MemoryStorageBackend({
        // Show with missing episodes & missing NFO/poster
        '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.1080p.mkv': 1 << 30,
        '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E03.1080p.mkv': 1 << 30,
        // Duplicate movie (2160p DV vs 1080p)
        '/影视库/盗梦空间 (2010)/Inception.2010.2160p.DV.mkv': 20 << 30,
        '/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv': 4 << 30,
        // Junk file
        '/影视库/更多资源请访问 www.example.com.txt': 120,
      });
      await backend.mkdirs('/影视库/空目录');

      final tm = _RecordingTaskManager();
      addTearDown(tm.dispose);

      final router = GoRouter(
        initialLocation: '/health',
        routes: [
          GoRoute(
            path: '/health',
            builder: (_, _) => const Scaffold(body: HealthPage()),
          ),
          GoRoute(
            path: '/tasks/:id',
            builder: (_, s) =>
                Scaffold(body: Text('TASK DETAIL ${s.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/sources',
            builder: (_, _) => const Scaffold(body: Text('SOURCES')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoBackendProvider.overrideWithValue(backend),
            taskManagerProvider.overrideWithValue(tm),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Start scan
      expect(find.byKey(const ValueKey('health-start-scan')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('health-start-scan')));
      await tester.pumpAndSettle();

      // Summary hero & metric cards appear
      expect(
        find.byKey(const ValueKey('health-metric-missing')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('health-metric-duplicates')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('health-metric-assets')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('health-metric-cleanup')),
        findsOneWidget,
      );

      // Switch to 缺集 tab
      await tester.tap(find.byKey(const ValueKey('health-metric-missing')));
      await tester.pumpAndSettle();
      expect(find.text('S01E02'), findsOneWidget);

      // Switch to 重复 tab & delete redundant copy with explicit confirmation
      await tester.tap(find.byKey(const ValueKey('health-metric-duplicates')));
      await tester.pumpAndSettle();
      expect(find.text('推荐保留'), findsOneWidget);
      expect(find.text('删除冗余副本'), findsOneWidget);
      await tester.tap(find.text('删除冗余副本'));
      await tester.pumpAndSettle();
      // confirmPermanentDelete dialog is shown
      expect(find.text('删除并整理'), findsOneWidget);
      await tester.tap(find.text('删除并整理'));
      await tester.pumpAndSettle();
      expect(
        await backend.exists('/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv'),
        isFalse,
      );
      expect(
        await backend.exists('/影视库/盗梦空间 (2010)/Inception.2010.2160p.DV.mkv'),
        isTrue,
      );

      // Switch to 待清理 tab
      await tester.tap(find.byKey(const ValueKey('health-metric-cleanup')));
      await tester.pumpAndSettle();
      expect(find.text('空目录'), findsWidgets);

      // Switch to 缺元数据 tab & trigger 一键仅刮削补全
      await tester.tap(find.byKey(const ValueKey('health-metric-assets')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('health-scrape-missing')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('health-scrape-missing')));
      await tester.pumpAndSettle();

      expect(tm.submissions, hasLength(1));
      final sub = tm.submissions.single;
      expect(sub.scrape, isTrue);
      expect(sub.scrapeOnly, isTrue);
      expect(sub.mode, OrganizeMode.inPlace);
      expect(sub.paths, contains('/影视库/盗梦空间 (2010)'));
      expect(find.textContaining('TASK DETAIL'), findsOneWidget);
    },
  );
}
