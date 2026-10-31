import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/tasks/tasks_page.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('awaiting-review task offers 去确认 and 立即执行', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);

    expect(find.text(id.value), findsOneWidget);
    expect(find.text('去确认'), findsOneWidget);
    expect(find.text('立即执行'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('识别完成，请确认结果后继续执行'), findsOneWidget);

    await tester.tap(find.text('去确认'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE review ${id.value}'), findsOneWidget);
  });

  testWidgets('立即执行 confirms, finishes, then 撤销 undoes', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);

    await tester.tap(find.text('立即执行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行'));
    await waitForStage(tester, tm, id, TaskStage.done);

    // moved to the 已完成 tab
    expect(find.text('已完成 (1)'), findsOneWidget);
    await tester.tap(find.text('已完成 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await waitForStage(tester, tm, id, TaskStage.undone);
    expect((await tm.watchAll().first).single.stage, TaskStage.undone);
  });

  testWidgets('cancel moves an active task to 已完成', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await tm.submit(const ConnectionId('demo-alist'), [
      '/下载/完成',
    ], OrganizeMode.inPlace);
    await tester.pump();
    await tester.tap(find.text('取消'));
    await waitForStage(tester, tm, id, TaskStage.cancelled);
    expect(find.text('进行中 (0)'), findsOneWidget);
  });
}
