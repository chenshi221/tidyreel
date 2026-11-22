import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
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

  testWidgets('scrapeOnly task shows 仅刮削 badge distinct from 刮削', (
    tester,
  ) async {
    final scrapeBoth = TaskSummary(
      id: const TaskId('T-scrape'),
      connection: const ConnectionId('demo-alist'),
      paths: const ['/下载/三体'],
      mode: OrganizeMode.inPlace,
      scrape: true,
      scrapeOnly: false,
      stage: TaskStage.done,
      createdAt: DateTime(2026),
    );
    await pumpPage(tester, TaskCard(task: scrapeBoth));
    expect(find.textContaining('刮削'), findsOneWidget);
    expect(find.byKey(const ValueKey('scrape-only-T-scrape')), findsNothing);

    final scrapeOnly = TaskSummary(
      id: const TaskId('T-scrape-only'),
      connection: const ConnectionId('demo-alist'),
      paths: const ['/下载/三体'],
      mode: OrganizeMode.inPlace,
      scrape: true,
      scrapeOnly: true,
      stage: TaskStage.done,
      createdAt: DateTime(2026),
    );
    await pumpPage(tester, TaskCard(task: scrapeOnly));
    expect(
      find.byKey(const ValueKey('scrape-only-T-scrape-only')),
      findsOneWidget,
    );
    expect(find.text('仅刮削'), findsOneWidget);

    final tm = _StaticTaskManager([scrapeOnly]);
    await pumpPage(
      tester,
      const TaskDetailPage(taskId: 'T-scrape-only'),
      tm: tm,
    );
    expect(
      find.byKey(const ValueKey('scrape-only-T-scrape-only')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cleanup-empty-dirs')), findsNothing);
  });

  testWidgets(
    'TaskDetailPage single-op undo calls undo(id, only: {opId}) and hides undo on deletes',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const tid = TaskId('T-ops');
      final history = MemoryHistoryStore();
      final bid = await history.beginBatch(
        tid,
        const ConnectionId('demo-alist'),
        const [
          RenameOp(
            id: OpId('op-move'),
            kind: OpKind.relocate,
            phase: ExecPhase.files,
            src: '/下载/a.mkv',
            dst: '/媒体库/异兽魔都/Season 01/异兽魔都.S01E01.mkv',
          ),
          RenameOp(
            id: OpId('op-del'),
            kind: OpKind.delete,
            phase: ExecPhase.cleanup,
            src: '/下载/ad.txt',
            dst: '',
          ),
        ],
      );
      await history.mark(bid, const OpId('op-move'), OpStatus.done);
      await history.mark(bid, const OpId('op-del'), OpStatus.done);

      final task = TaskSummary(
        id: tid,
        connection: const ConnectionId('demo-alist'),
        paths: const ['/下载'],
        mode: OrganizeMode.moveToLibrary,
        stage: TaskStage.done,
        batch: bid,
        createdAt: DateTime(2026),
      );
      final tm = _DetailActionsTaskManager(task, history: history);
      addTearDown(tm.dispose);

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const Scaffold(body: TaskDetailPage(taskId: 'T-ops')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskManagerProvider.overrideWithValue(tm),
            historyProvider.overrideWithValue(history),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Relocate op exposes single-op undo; delete op does not.
      expect(find.byKey(const ValueKey('undo-op-op-move')), findsOneWidget);
      expect(find.byKey(const ValueKey('undo-op-op-del')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('undo-op-op-move')));
      await tester.pumpAndSettle();

      expect(tm.undoCalls, hasLength(1));
      expect(tm.undoCalls.single.$1, tid);
      expect(tm.undoCalls.single.$2, {const OpId('op-move')});
      expect(find.text('已撤销该操作'), findsOneWidget);
      expect(find.byKey(const ValueKey('undo-op-op-move')), findsNothing);
    },
  );

  testWidgets(
    'TaskDetailPage cleanup-empty-dirs shows empty snackbar or dialog with selection',
    (tester) async {
      const tid = TaskId('T-clean');
      final task = TaskSummary(
        id: tid,
        connection: const ConnectionId('demo-alist'),
        paths: const ['/下载'],
        mode: OrganizeMode.moveToLibrary,
        stage: TaskStage.done,
        batch: const BatchId('B-clean'),
        createdAt: DateTime(2026),
      );
      final tm = _DetailActionsTaskManager(task, emptyDirs: const []);
      await pumpPage(tester, const TaskDetailPage(taskId: 'T-clean'), tm: tm);

      expect(find.byKey(const ValueKey('cleanup-empty-dirs')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cleanup-empty-dirs')));
      await tester.pumpAndSettle();
      expect(find.text('没有可清理的空目录'), findsOneWidget);

      // Now return two empty dirs and uncheck one before confirming.
      tm.emptyDirs = ['/下载/old1', '/下载/old2'];
      await tester.tap(find.byKey(const ValueKey('cleanup-empty-dirs')));
      await tester.pumpAndSettle();
      expect(find.text('清理所选 (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-dir-/下载/old1')), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-dir-/下载/old2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('empty-dir-/下载/old2')));
      await tester.pumpAndSettle();
      expect(find.text('清理所选 (1)'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('confirm-cleanup-empty-dirs')),
      );
      await tester.pumpAndSettle();
      expect(tm.removedDirsCalls, [
        ['/下载/old1'],
      ]);
      expect(find.text('已清理 1 个空目录'), findsOneWidget);
    },
  );
}

class _StaticTaskManager extends FakeTaskManager {
  final List<TaskSummary> _items;
  _StaticTaskManager(this._items) : super(step: Duration.zero);

  @override
  Stream<List<TaskSummary>> watchAll() => Stream.value(_items);
}

class _DetailActionsTaskManager extends FakeTaskManager {
  final TaskSummary _task;
  final MemoryHistoryStore? history;
  List<String> emptyDirs;
  final undoCalls = <(TaskId, Set<OpId>?)>[];
  final removedDirsCalls = <List<String>>[];

  _DetailActionsTaskManager(
    this._task, {
    this.history,
    this.emptyDirs = const [],
  }) : super(step: Duration.zero);

  @override
  Stream<List<TaskSummary>> watchAll() => Stream.value([_task]);

  @override
  Future<TaskReview> review(TaskId id) async =>
      throw StateError('not recognized');

  @override
  Future<void> undo(TaskId id, {Set<OpId>? only}) async {
    undoCalls.add((id, only));
    if (history != null && _task.batch != null && only != null) {
      for (final opId in only) {
        await history!.mark(_task.batch!, opId, OpStatus.undone);
      }
    }
  }

  @override
  Future<List<String>> findEmptyDirs(TaskId id) async => emptyDirs;

  @override
  Future<int> removeEmptyDirs(TaskId id, List<String> dirs) async {
    removedDirsCalls.add(List.of(dirs));
    return dirs.length;
  }
}
