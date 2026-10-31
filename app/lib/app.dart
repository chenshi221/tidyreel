import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/naming/naming_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';
import 'features/sources/sources_page.dart';
import 'features/tasks/tasks_page.dart';

const _seed = Color(0xFF00796B);

ThemeData _theme(Brightness b) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: b),
  visualDensity: VisualDensity.compact,
);

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

class TidyreelApp extends StatelessWidget {
  const TidyreelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: '理片 Tidyreel',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    routerConfig: _router,
    debugShowCheckedModeBanner: false,
  );
}

/// Left NavigationRail + content. Destinations map 1:1 to top-level routes.
class AppShell extends StatelessWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  static const _paths = ['/sources', '/tasks', '/naming', '/settings'];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final index = _paths.indexWhere(location.startsWith);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index < 0 ? 0 : index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => context.go(_paths[i]),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: Text('来源'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.task_outlined),
                selectedIcon: Icon(Icons.task),
                label: Text('任务'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.text_fields_outlined),
                selectedIcon: Icon(Icons.text_fields),
                label: Text('命名规则'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
