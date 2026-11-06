import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../data/providers.dart';
import '../data/settings.dart';
import '../features/sources/sources_page.dart' show openBrowser;
import '../features/sources/sources_providers.dart';
import '../features/tasks/tasks_page.dart' show stageLabel;
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/common.dart';

final sidebarCollapsedProvider = NotifierProvider<_Collapsed, bool>(
  _Collapsed.new,
);

/// Starts from the 启动时收起侧栏 setting; toggling doesn't change the setting.
class _Collapsed extends Val<bool> {
  _Collapsed() : super(false);

  @override
  bool build() => ref.read(settingsProvider).sidebarCollapsed;
}

/// Left sidebar: brand, the four destinations, and live background tasks so
/// import / recognition progress is visible from every page.
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  static const expandedWidth = 224.0;

  /// Wide enough for the macOS traffic lights.
  static const collapsedWidth = 78.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final tasks = ref.watch(tasksProvider).value ?? const <TaskSummary>[];
    final pending = tasks
        .where((t) => t.stage == TaskStage.awaitingReview)
        .length;
    final active = tasks.where((t) => t.stage.isActive).toList();
    final location = GoRouterState.of(context).uri.path;
    final favorites = [
      for (final c in ref.watch(connectionsEditorProvider))
        for (final f in c.favorites) (conn: c, path: f),
    ];
    // macOS: the traffic lights float over the sidebar's top-left corner.
    final mac = Theme.of(context).platform == TargetPlatform.macOS;

    // Toast when a background task finishes recognizing or executing, unless
    // that task's page is already open.
    ref.listen(tasksProvider, (prev, next) {
      final before = {for (final t in prev?.value ?? const []) t.id: t.stage};
      for (final t in next.value ?? const <TaskSummary>[]) {
        final was = before[t.id];
        final onTaskPage =
            location == '/tasks/${t.id.value}' ||
            location == '/tasks/${t.id.value}/review';
        if (was == null || was == t.stage || onTaskPage) {
          continue;
        }
        final (msg, path) = switch (t.stage) {
          TaskStage.awaitingReview => (
            '识别完成，等你确认',
            '/tasks/${t.id.value}/review',
          ),
          TaskStage.done => ('整理完成', '/tasks/${t.id.value}'),
          TaskStage.partiallyFailed => ('整理完成，但有失败项', '/tasks/${t.id.value}'),
          _ => (null, null),
        };
        if (msg == null) continue;
        final s = ref.read(settingsProvider);
        if (t.stage == TaskStage.awaitingReview
            ? !s.notifyRecognized
            : !s.notifyFinished) {
          continue;
        }
        final name =
            t.paths.firstOrNull
                ?.split('/')
                .where((s) => s.isNotEmpty)
                .lastOrNull ??
            t.id.value;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('$name · $msg'),
              action: SnackBarAction(
                label: '查看',
                onPressed: () => context.go(path!),
              ),
            ),
          );
      }
    });

    void go(String path) {
      // Re-selecting 来源 leaves the file browser and shows the list again.
      if (path == '/sources' && location.startsWith('/sources')) {
        ref.read(openConnectionProvider.notifier).set(null);
      }
      context.go(path);
    }

    Widget item(
      String path,
      IconData icon,
      IconData selectedIcon,
      String label, {
      int badge = 0,
    }) => _NavItem(
      key: ValueKey('nav-$label'),
      icon: location.startsWith(path) ? selectedIcon : icon,
      label: label,
      selected: location.startsWith(path),
      badge: badge,
      collapsed: collapsed,
      onTap: () => go(path),
    );

    final toggle = IconButton(
      tooltip: collapsed ? '展开侧栏' : '收起侧栏',
      iconSize: 16,
      icon: const Icon(CupertinoIcons.sidebar_left),
      onPressed: () => ref
          .read(sidebarCollapsedProvider.notifier)
          .set(!ref.read(sidebarCollapsedProvider)),
    );

    Widget sectionTitle(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 22, 10, 6),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? collapsedWidth : expandedWidth,
      // A shade off the content, with a rule: the page's first division.
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(
          right: BorderSide(color: p.line, width: hairline),
        ),
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: collapsed ? collapsedWidth : expandedWidth,
          child: Padding(
            padding: EdgeInsets.fromLTRB(8, mac ? 8 : 12, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (mac)
                  SizedBox(
                    // Collapsed, the traffic lights take the whole first row.
                    height: collapsed ? 58 : 30,
                    child: Align(
                      alignment: collapsed
                          ? Alignment.bottomCenter
                          : Alignment.centerRight,
                      child: toggle,
                    ),
                  ),
                if (collapsed && !mac) Center(child: toggle),
                if (!collapsed) _Brand(trailing: mac ? null : toggle),
                SizedBox(height: collapsed ? 12 : 26),
                item(
                  '/sources',
                  CupertinoIcons.folder,
                  CupertinoIcons.folder_fill,
                  '来源',
                ),
                item(
                  '/tasks',
                  CupertinoIcons.square_list,
                  CupertinoIcons.square_list_fill,
                  '任务',
                  badge: pending,
                ),
                item(
                  '/naming',
                  CupertinoIcons.textformat,
                  CupertinoIcons.textformat,
                  '命名规则',
                ),
                if (collapsed)
                  const Spacer()
                else
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        if (favorites.isNotEmpty) ...[
                          sectionTitle('收藏'),
                          for (final f in favorites.take(6))
                            _FavItem(
                              key: ValueKey(
                                'side-fav ${f.conn.id.value} ${f.path}',
                              ),
                              path: f.path,
                              connection: f.conn.name,
                              onTap: () {
                                openBrowser(ref, f.conn, f.path);
                                context.go('/sources');
                              },
                            ),
                        ],
                        if (active.isNotEmpty) ...[
                          sectionTitle('后台任务'),
                          for (final t in active)
                            _TaskItem(
                              task: t,
                              onTap: () => go(
                                t.stage == TaskStage.awaitingReview
                                    ? '/tasks/${t.id.value}/review'
                                    : '/tasks',
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                if (!collapsed)
                  _Summary(
                    waiting: pending,
                    done: tasks
                        .where(
                          (t) =>
                              t.stage == TaskStage.done ||
                              t.stage == TaskStage.partiallyFailed,
                        )
                        .length,
                    onTap: () => go('/tasks'),
                  ),
                item(
                  '/settings',
                  CupertinoIcons.gear,
                  CupertinoIcons.gear_solid,
                  '设置',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  final Widget? trailing;

  const _Brand({this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 0, 2),
      child: Row(
        children: [
          const AppLogo(size: 22),
          const SizedBox(width: 9),
          Text(
            '理片',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: p.text,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Tidyreel',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(fontSize: 12, color: p.textFaint),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final bool collapsed;
  final VoidCallback onTap;

  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final iconW = Icon(icon, size: 15, color: selected ? p.text : p.textFaint);
    final body = Hoverable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 32,
        margin: const EdgeInsets.only(bottom: 2),
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 9 : 12),
        decoration: BoxDecoration(
          // Selection is the ink itself; only the collapsed rail gets a fill.
          color: selected && collapsed
              ? p.selected
              : (hover ? p.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: collapsed
            ? Center(
                child: badge == 0
                    ? iconW
                    : Badge(label: Text('$badge'), child: iconW),
              )
            : Row(
                children: [
                  iconW,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        color: selected ? p.text : p.textMuted,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  // A quiet count in the accent: the one thing asking for you.
                  if (badge > 0)
                    Text(
                      '$badge',
                      style: TextStyle(
                        color: p.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
      ),
    );
    return collapsed ? Tooltip(message: label, child: body) : body;
  }
}

/// One running task in the sidebar: name, stage, thin progress bar.
class _TaskItem extends StatelessWidget {
  final TaskSummary task;
  final VoidCallback onTap;

  const _TaskItem({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = task;
    final review = t.stage == TaskStage.awaitingReview;
    final first = t.paths.isEmpty
        ? t.id.value
        : t.paths.first.split('/').where((s) => s.isNotEmpty).lastOrNull ??
              '根目录';
    final name = t.paths.length > 1 ? '$first 等 ${t.paths.length} 项' : first;
    final status = switch (t.stage) {
      TaskStage.importing => '导入中 · ${t.importedCount} 个文件',
      TaskStage.recognizing => '识别中…',
      TaskStage.awaitingReview => '识别完成，待确认',
      _ => '执行中 · ${stageLabel(t.stage)}',
    };
    return Hoverable(
      onTap: onTap,
      builder: (context, hover) => Container(
        margin: const EdgeInsets.only(bottom: 1),
        padding: const EdgeInsets.fromLTRB(9, 6, 9, 7),
        decoration: BoxDecoration(
          color: hover ? p.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: review
                  ? Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      size: 14,
                      color: p.accent,
                    )
                  : t.progress == null
                  ? const Spinner(size: 14)
                  : SizedBox(
                      width: 14,
                      height: 14,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: CircularProgressIndicator(
                          value: t.progress,
                          strokeWidth: 1.4,
                          color: p.text,
                          backgroundColor: p.selected,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: p.text),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: review ? p.accent : p.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A favorite folder: a quick way back to the download dirs you tidy most.
class _FavItem extends StatelessWidget {
  final String path;
  final String connection;
  final VoidCallback onTap;

  const _FavItem({
    super.key,
    required this.path,
    required this.connection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '根目录';
    return Tooltip(
      message: '$connection · $path',
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        onTap: onTap,
        builder: (context, hover) => Container(
          height: 30,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hover ? p.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Row(
            children: [
              Icon(CupertinoIcons.star, size: 13, color: p.textFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two counts at the foot of the sidebar: what waits for you, what's done.
class _Summary extends StatelessWidget {
  final int waiting;
  final int done;
  final VoidCallback onTap;

  const _Summary({
    required this.waiting,
    required this.done,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget stat(String value, String label, {bool hot = false}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: hot ? p.accent : p.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(label, style: TextStyle(fontSize: 11, color: p.textFaint)),
        ],
      ),
    );
    return Hoverable(
      key: const ValueKey('side-summary'),
      onTap: onTap,
      builder: (context, hover) => Container(
        margin: const EdgeInsets.fromLTRB(0, 8, 0, 6),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: hover ? p.hover : p.panel,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: p.line, width: hairline),
        ),
        child: Row(
          children: [
            stat('$waiting', '待确认', hot: waiting > 0),
            stat('$done', '已整理'),
          ],
        ),
      ),
    );
  }
}
