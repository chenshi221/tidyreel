import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/app.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  testWidgets('rail navigates between the four pages', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: TidyreelApp()));
    await tester.pumpAndSettle();
    expect(find.text('来源'), findsWidgets);

    for (final label in ['任务', '命名规则', '设置', '来源']) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        label,
      );
    }
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
