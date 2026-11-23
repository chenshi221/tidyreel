import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import 'data/providers.dart';
import 'data/settings.dart';
import 'l10n/l10n.dart';
import 'shell/command_palette.dart';
import 'shell/sidebar.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

import 'features/health/health_page.dart';
import 'features/naming/naming_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';
import 'features/sources/sources_page.dart';
import 'features/tasks/task_detail_page.dart';
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
            GoRoute(
              path: ':id',
              builder: (_, s) =>
                  TaskDetailPage(taskId: s.pathParameters['id']!),
            ),
          ],
        ),
        GoRoute(path: '/health', builder: (_, _) => const HealthPage()),
        GoRoute(path: '/naming', builder: (_, _) => const NamingPage()),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
      ],
    ),
  ],
);

class TidyreelApp extends ConsumerWidget {
  const TidyreelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    final still = ref.watch(settingsProvider.select((s) => s.reduceMotion));
    final locale = ref.watch(resolvedLocaleProvider);
    final isDemo = ref.watch(bootstrapProvider.select((b) => b.demo));
    ref.listen(resolvedLocaleProvider, (prev, next) {
      if (!isDemo && prev != next) {
        unawaited(windowManager.setTitle(AppL10n.forLocale(next).appTitle));
      }
    });
    return MaterialApp.router(
      locale: locale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      onGenerateTitle: (ctx) => ctx.l10n.appTitle,
      theme: buildTheme(Brightness.light, accent: accent.light),
      darkTheme: buildTheme(Brightness.dark, accent: accent.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => still
          ? MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : child!,
    );
  }
}

/// Sidebar + content. Destinations map 1:1 to top-level routes.
class AppShell extends ConsumerWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showCommandPalette(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showCommandPalette(context, ref),
      },
      child: Scaffold(
        backgroundColor: p.canvas,
        body: Row(
          children: [
            const Sidebar(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
