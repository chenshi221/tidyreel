import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/watch/watch_page.dart';
import 'package:tidyreel_core/testing.dart';

void main() {
  testWidgets(
    'WatchPage adds a watch rule, toggles enable switch, triggers manual check, and deletes rule with zero pending timers',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final tm = FakeTaskManager(step: Duration.zero);
      addTearDown(tm.dispose);

      final router = GoRouter(
        initialLocation: '/watch',
        routes: [
          GoRoute(
            path: '/watch',
            builder: (_, _) => const Scaffold(body: WatchPage()),
          ),
          GoRoute(
            path: '/sources',
            builder: (_, _) => const Scaffold(body: Text('SOURCES')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [taskManagerProvider.overrideWithValue(tm)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Empty state explains lightweight watch mode without Webhook
      expect(find.text('轻量化追更监控'), findsOneWidget);
      expect(find.textContaining('无需配置 Webhook'), findsOneWidget);

      // Open add rule dialog
      expect(find.byKey(const ValueKey('add-watch-rule')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-watch-rule')));
      await tester.pumpAndSettle();

      // Default path pre-fills connection's favorite `/下载/完成`; toggle scrape & save
      expect(find.byKey(const ValueKey('watch-field-path')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('watch-field-path')),
        '/下载/完成',
      );
      await tester.tap(find.byKey(const ValueKey('watch-switch-scrape')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('watch-rule-save')));
      await tester.pumpAndSettle();

      // Rule is now persisted & visible
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WatchPage)),
      );
      final rules = await container.read(watchRulesStoreProvider).loadAll();
      expect(rules, hasLength(1));
      final ruleId = rules.single.id;
      expect(rules.single.path, '/下载/完成');
      expect(rules.single.scrape, isTrue);
      expect(rules.single.enabled, isTrue);

      expect(find.text('/下载/完成'), findsOneWidget);
      expect(find.text('刮削'), findsOneWidget);
      expect(find.text('轮询中'), findsOneWidget);

      // Toggle enable switch off -> shows 已暂停
      await tester.tap(find.byKey(ValueKey('watch-toggle-$ruleId')));
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      expect(
        (await container.read(watchRulesStoreProvider).loadAll())
            .single
            .enabled,
        isFalse,
      );

      // Toggle back on
      await tester.tap(find.byKey(ValueKey('watch-toggle-$ruleId')));
      await tester.pumpAndSettle();
      expect(find.text('轮询中'), findsOneWidget);

      // Trigger manual check (1st check discovers demo backend files -> 等待稳定)
      await tester.tap(find.byKey(ValueKey('watch-trigger-$ruleId')));
      await tester.pumpAndSettle();
      final afterTrigger =
          (await container.read(watchRulesStoreProvider).loadAll()).single;
      expect(afterTrigger.lastScanAt, isNotNull);
      expect(afterTrigger.lastStatus, contains('等待'));

      // Delete rule via trash button + confirmation dialog
      await tester.tap(find.byKey(ValueKey('watch-delete-$ruleId')));
      await tester.pumpAndSettle();
      expect(find.text('删除监控规则？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(await container.read(watchRulesStoreProvider).loadAll(), isEmpty);
      expect(find.text('轻量化追更监控'), findsOneWidget);
    },
  );
}
