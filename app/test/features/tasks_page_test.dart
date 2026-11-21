import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/tasks/task_detail_page.dart';
import 'package:tidyreel/features/tasks/tasks_page.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('awaiting-review task offers 去确认 and 只整理有把握的', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);

    // Waiting for review: the track stands at 待确认.
    expect(find.byType(TaskStepper), findsOneWidget);
    // The id lives in the menu now, not on the card.
    expect(find.text(id.value), findsNothing);
    expect(find.text('去确认'), findsOneWidget);
    expect(find.text('只整理有把握的'), findsOneWidget);
    expect(find.text('个待确认'), findsOneWidget);

    await tester.tap(find.text('去确认'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE review ${id.value}'), findsOneWidget);
  });

  testWidgets('clicking a finished task opens its details', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);
    await tester.tap(find.text('只整理有把握的'));
    await tester.pumpAndSettle();
    await waitForStage(tester, tm, id, TaskStage.done);
    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getTopLeft(find.byKey(ValueKey('task ${id.value}'))) +
          const Offset(40, 30), // the path line
    );
    await tester.pumpAndSettle();
    expect(find.text('ROUTE detail ${id.value}'), findsOneWidget);
  });

  testWidgets('只整理有把握的 runs without asking, finishes, then 撤销 undoes', (
    tester,
  ) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final id = await submitAndWait(tester, tm);

    await tester.tap(find.text('只整理有把握的'));
    await tester.pumpAndSettle();
    await waitForStage(tester, tm, id, TaskStage.done);

    // moved to the 已完成 tab
    expect(find.text('已完成 1'), findsOneWidget);
    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
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
    expect(find.text('进行中 0'), findsOneWidget);

    // 重新识别 runs it again from the start.
    await tester.tap(find.byKey(ValueKey('retry ${id.value}')));
    await waitForStage(tester, tm, id, TaskStage.awaitingReview);
  });

  testWidgets('right-click 删除记录 and 清空 remove finished tasks', (tester) async {
    final (tm, _) = await pumpPage(tester, const TasksPage());
    final a = await submitAndWait(tester, tm);
    await tester.tap(find.text('只整理有把握的'));
    await tester.pumpAndSettle();
    await waitForStage(tester, tm, a, TaskStage.done);
    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('task ${a.value}')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不能再撤销'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '删除'));
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
    for (final s in ['导入', '识别', '确认', '重命名', '整理文件夹']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('正在重命名文件 40%'), findsOneWidget);
    // Progress messages stay off the card.
    expect(find.text('正在重命名文件'), findsNothing);
  });

  testWidgets(
    'issue 14: cancelled task with executed batch exposes undo in card and detail',
    (tester) async {
      final withBatch = TaskSummary(
        id: const TaskId('cancelled-b'),
        connection: const ConnectionId('demo-alist'),
        paths: const ['/d'],
        mode: OrganizeMode.inPlace,
        stage: TaskStage.cancelled,
        batch: const BatchId('b1'),
        createdAt: DateTime(2026),
      );
      await pumpPage(tester, TaskCard(task: withBatch));
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('task cancelled-b')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('撤销'), findsWidgets);

      final withoutBatch = TaskSummary(
        id: const TaskId('cancelled-no-b'),
        connection: const ConnectionId('demo-alist'),
        paths: const ['/d'],
        mode: OrganizeMode.inPlace,
        stage: TaskStage.cancelled,
        createdAt: DateTime(2026),
      );
      await pumpPage(tester, TaskCard(task: withoutBatch));
      expect(find.text('撤销'), findsNothing);

      final (tm, _) = await pumpPage(tester, const SizedBox());
      final id = await submitAndWait(tester, tm);
      unawaited(tm.run(id));
      await waitForStage(tester, tm, id, TaskStage.done);
      // TaskDetailPage also respects canUndo() (header action only; summary
      // header is non-interactive with no duplicate buttons).
      await pumpPage(tester, TaskDetailPage(taskId: id.value), tm: tm);
      expect(
        find.descendant(
          of: find.byType(OutlinedButton),
          matching: find.text('撤销'),
        ),
        findsOneWidget,
      );
      expect(find.text('撤销'), findsOneWidget);
    },
  );

  testWidgets('TaskStage.failed shows 失败 badge, error, 重新识别 and 去设置', (
    tester,
  ) async {
    final failedTask = TaskSummary(
      id: const TaskId('failed-tmdb'),
      connection: const ConnectionId('demo-alist'),
      paths: const ['/下载/三体'],
      mode: OrganizeMode.inPlace,
      stage: TaskStage.failed,
      message: '请先在「设置」里填写 TMDB API key',
      createdAt: DateTime(2026),
    );
    await pumpPage(tester, TaskCard(task: failedTask));
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('请先在「设置」里填写 TMDB API key'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry failed-tmdb')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goto-settings failed-tmdb')),
      findsOneWidget,
    );
  });

  testWidgets('TaskDetailPage shows failure card with selectable error', (
    tester,
  ) async {
    final failedTask = TaskSummary(
      id: const TaskId('T-fail'),
      connection: const ConnectionId('demo-alist'),
      paths: const ['/下载/三体'],
      mode: OrganizeMode.inPlace,
      stage: TaskStage.failed,
      message: '请先在「设置」里填写 TMDB API key',
      createdAt: DateTime(2026),
    );
    final tm = _StaticTaskManager([failedTask]);
    await pumpPage(tester, const TaskDetailPage(taskId: 'T-fail'), tm: tm);
    expect(find.byKey(const ValueKey('task-stop-card')), findsOneWidget);
    expect(find.text('识别失败'), findsOneWidget);
    expect(find.text('请先在「设置」里填写 TMDB API key'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.text('重新识别'), findsWidgets);
  });
}

class _StaticTaskManager extends FakeTaskManager {
  final List<TaskSummary> _items;
  _StaticTaskManager(this._items) : super(step: Duration.zero);

  @override
  Stream<List<TaskSummary>> watchAll() => Stream.value(_items);
}
