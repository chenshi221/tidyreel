import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/settings.dart';
import 'shell/sidebar.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

import 'features/naming/naming_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';
import 'features/sources/sources_page.dart';
import 'features/tasks/tasks_page.dart';

final _router = GoRouter(
  initialLocation: '/sources',
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(path: '/sources', builder: (_, _) => const SourcesPage()),
        GoRoute(
          path: '/tasks',
          builder: (_, _) => const TasksPage(),
          routes: [
            GoRoute(
              path: ':id/review',
              builder: (_, s) => ReviewPage(taskId: s.pathParameters['id']!),
            ),
          ],
        ),
        GoRoute(path: '/naming', builder: (_, _) => const NamingPage()),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
      ],
    ),
  ],
);

class TidyreelApp extends ConsumerWidget {
  const TidyreelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: '理片 Tidyreel',
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ref.watch(themeModeProvider),
    routerConfig: _router,
    debugShowCheckedModeBanner: false,
  );
}

/// Sidebar + content. Destinations map 1:1 to top-level routes.
class AppShell extends StatelessWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.canvas,
      body: Row(
        children: [
          const Sidebar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}
