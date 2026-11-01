import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Pumps [page] at 1280x800 inside a tiny router so `context.go` works.
/// Routes other than '/' render their path as text.
Future<(FakeTaskManager, ProviderContainer)> pumpPage(
  WidgetTester tester,
  Widget page, {
  FakeTaskManager? tm,
  String initialLocation = '/',
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final manager = tm ?? FakeTaskManager(step: Duration.zero);
  addTearDown(manager.dispose);
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: page),
      ),
      GoRoute(
        path: '/tasks',
        builder: (_, _) => const Scaffold(body: Text('ROUTE /tasks')),
        routes: [
          GoRoute(
            path: ':id/review',
            builder: (_, s) =>
                Scaffold(body: Text('ROUTE review ${s.pathParameters['id']}')),
          ),
          GoRoute(
            path: ':id',
            builder: (_, s) =>
                Scaffold(body: Text('ROUTE detail ${s.pathParameters['id']}')),
          ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [taskManagerProvider.overrideWithValue(manager)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  );
  return (manager, container);
}

/// Pumps until task [id] reaches [stage].
Future<void> waitForStage(
  WidgetTester tester,
  FakeTaskManager tm,
  TaskId id,
  TaskStage stage,
) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    final all = await tm.watchAll().first;
    if (all.firstWhere((t) => t.id == id).stage == stage) break;
  }
  await tester.pumpAndSettle();
}

/// Submits a task and waits for it to reach [stage].
Future<TaskId> submitAndWait(
  WidgetTester tester,
  FakeTaskManager tm, {
  TaskStage stage = TaskStage.awaitingReview,
}) async {
  final id = await tm.submit(const ConnectionId('demo-alist'), [
    '/下载/完成',
  ], OrganizeMode.inPlace);
  await waitForStage(tester, tm, id, stage);
  return id;
}
