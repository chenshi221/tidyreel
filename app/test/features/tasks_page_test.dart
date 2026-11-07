import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/tasks/tasks_page.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('awaiting-review task offers 去确认 and 立即执行', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);

    // Waiting for review: the track stands at 待确认.
    expect(find.byType(TaskStepper), findsOneWidget);
    // The id lives in the menu now, not on the card.
    expect(find.text(id.value), findsNothing);
    expect(find.text('去确认'), findsOneWidget);
    expect(find.text('立即执行'), findsOneWidget);
    expect(find.text('个待确认'), findsOneWidget);

    await tester.tap(find.text('去确认'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE review ${id.value}'), findsOneWidget);
  });

  testWidgets('clicking a finished task opens its details', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);
    await tester.tap(find.text('立即执行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行'));
    await waitForStage(tester, tm, id, TaskStage.done);
    await tester.tap(find.text('已完成 (1)'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getTopLeft(find.byKey(ValueKey('task ${id.value}'))) +
          const Offset(40, 30), // the path line
    );
    await tester.pumpAndSettle();
    expect(find.text('ROUTE detail ${id.value}'), findsOneWidget);
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

    // 重新识别 runs it again from the start.
    await tester.tap(find.byKey(ValueKey('retry ${id.value}')));
    await waitForStage(tester, tm, id, TaskStage.awaitingReview);
  });

  testWidgets('right-click 删除记录 and 清空 remove finished tasks', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final a = await submitAndWait(tester, tm);
    await tester.tap(find.text('立即执行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行'));
    await waitForStage(tester, tm, a, TaskStage.done);
    await tester.tap(find.text('已完成 (1)'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('task ${a.value}')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不能再撤销'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(await tm.watchAll().first, isEmpty);
    expect(find.byKey(const ValueKey('clear-finished')), findsNothing);
  });

  testWidgets('a running task shows the five-step track', (tester) async {
    await pumpPage(
      tester,
      TaskCard(
        task: TaskSummary(
          id: const TaskId('T1'),
          connection: const ConnectionId('c'),
          paths: const ['/剧/三体'],
          mode: OrganizeMode.inPlace,
          stage: TaskStage.renamingFiles,
          message: '正在重命名文件',
          progress: 0.4,
          createdAt: DateTime(2026),
        ),
      ),
    );
    expect(find.byType(TaskStepper), findsOneWidget);
    for (final s in ['导入', '识别', '待确认', '文件', '文件夹']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('正在改名文件 40%'), findsOneWidget);
    // Progress messages stay off the card.
    expect(find.text('正在重命名文件'), findsNothing);
  });
}
