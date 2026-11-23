import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/data/settings.dart';
import 'package:tidyreel/features/sources/sources_providers.dart';
import 'package:tidyreel/shell/command_palette.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

class _PaletteHost extends ConsumerWidget {
  final String routeLabel;
  final void Function(VoidCallback open)? onTriggerReady;

  const _PaletteHost(this.routeLabel, {this.onTriggerReady});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => showCommandPalette(context, ref);
    onTriggerReady?.call(open);
    return Scaffold(
      body: Column(
        children: [
          Text('ROUTE $routeLabel'),
          TextButton(
            key: const ValueKey('open-palette'),
            onPressed: open,
            child: const Text('打开命令面板'),
          ),
        ],
      ),
    );
  }
}

Future<(FakeTaskManager, ProviderContainer, VoidCallback)> _pumpPaletteApp(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final tm = FakeTaskManager(step: Duration.zero);
  addTearDown(tm.dispose);
  late VoidCallback trigger;
  final router = GoRouter(
    initialLocation: '/sources',
    routes: [
      for (final path in [
        '/sources',
        '/tasks',
        '/health',
        '/naming',
        '/settings',
      ])
        GoRoute(
          path: path,
          builder: (_, _) =>
              _PaletteHost(path, onTriggerReady: (f) => trigger = f),
        ),
      GoRoute(
        path: '/tasks/:id/review',
        builder: (_, s) => _PaletteHost(
          '/tasks/${s.pathParameters['id']}/review',
          onTriggerReady: (f) => trigger = f,
        ),
      ),
      GoRoute(
        path: '/tasks/:id',
        builder: (_, s) => _PaletteHost(
          '/tasks/${s.pathParameters['id']}',
          onTriggerReady: (f) => trigger = f,
        ),
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
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  );
  return (tm, container, () => trigger());
}

void main() {
  testWidgets(
    'fuzzy search and keyboard navigation jump to pages and close on Esc',
    (tester) async {
      await _pumpPaletteApp(tester);

      // Open palette.
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
      expect(find.byKey(const ValueKey('palette-search')), findsOneWidget);

      // Esc closes the palette.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-palette')), findsNothing);

      // Reopen, fuzzy search for 命名规则, press Enter to navigate.
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('palette-search')),
        'naming',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('palette-item-nav-naming')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('ROUTE /naming'), findsOneWidget);

      // Use arrowDown + arrowUp + Enter to jump from default list (index 0: 来源,
      // index 1: 任务, index 2: 体检).
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 任务
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 体检
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // 任务
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('ROUTE /tasks'), findsOneWidget);
    },
  );

  testWidgets(
    'jumps to saved connections, favorites, recent tasks and toggles theme',
    (tester) async {
      final (tm, c, _) = await _pumpPaletteApp(tester);
      final taskId = await submitAndWait(tester, tm);

      // Jump to saved connection -> sets openConnectionProvider and goes /sources.
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('palette-search')),
        '演示本地',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('palette-item-conn-demo-local')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ROUTE /sources'), findsOneWidget);
      expect(
        c.read(openConnectionProvider)?.id,
        const ConnectionId('demo-local'),
      );

      // Jump to favorite folder -> opens connection at favorite directory.
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('palette-search')),
        '/下载/完成',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('palette-item-fav-demo-alist-/下载/完成')),
      );
      await tester.pumpAndSettle();
      expect(
        c.read(openConnectionProvider)?.id,
        const ConnectionId('demo-alist'),
      );
      expect(c.read(browserDirProvider), '/下载/完成');

      // Jump to awaitingReview task -> /tasks/:id/review.
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('palette-search')),
        taskId.value,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('palette-item-task-${taskId.value}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ROUTE /tasks/${taskId.value}/review'), findsOneWidget);

      // Toggle light -> dark theme.
      expect(c.read(settingsProvider).themeMode, ThemeMode.light);
      await tester.tap(find.byKey(const ValueKey('open-palette')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('palette-search')),
        '主题',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('palette-item-action-toggle-theme')),
      );
      await tester.pumpAndSettle();
      expect(c.read(settingsProvider).themeMode, ThemeMode.dark);
    },
  );

  testWidgets('guards against opening duplicate command palettes', (
    tester,
  ) async {
    final (_, _, openPalette) = await _pumpPaletteApp(tester);
    openPalette();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);

    // Triggering again while open must be ignored (no stacked dialog).
    openPalette();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);

    // One Esc closes the single palette completely, and it can reopen cleanly.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);

    openPalette();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
  });
}
