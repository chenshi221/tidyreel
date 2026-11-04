import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/app.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  testWidgets('sidebar navigates between the four pages', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: TidyreelApp()));
    await tester.pumpAndSettle();
    expect(find.text('来源'), findsWidgets);

    for (final label in ['任务', '命名规则', '设置', '来源']) {
      await tester.tap(find.byKey(ValueKey('nav-$label')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        label,
      );
    }
  });

  testWidgets('sidebar collapses to icons and lists background tasks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: TidyreelApp()));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    await c.read(taskManagerProvider).submit(const ConnectionId('demo-alist'), [
      '/下载/完成',
    ], OrganizeMode.inPlace);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('后台任务'), findsOneWidget);
    expect(find.text('完成'), findsWidgets); // sidebar task + favorite row

    await tester.tap(find.byTooltip('收起侧栏'));
    await tester.pumpAndSettle();
    expect(find.text('后台任务'), findsNothing);
    expect(find.byTooltip('展开侧栏'), findsOneWidget);
    // Let the fake task finish so no timers are left pending.
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  test('providers wire the fake engine', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final tm = c.read(taskManagerProvider);
    await tm.submit(const ConnectionId('demo-alist'), [
      '/下载/完成',
    ], OrganizeMode.inPlace);
    final tasks = await tm.watchAll().first;
    expect(tasks.single.stage, TaskStage.importing);
    expect(c.read(namingProfileProvider).player, TargetPlayer.vidhub);
  });
}
