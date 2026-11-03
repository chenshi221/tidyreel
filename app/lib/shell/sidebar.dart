import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../data/providers.dart';
import '../data/settings.dart';
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
  static const collapsedWidth = 60.0;

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
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? collapsedWidth : expandedWidth,
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
                    height: 30,
                    child: Align(
                      alignment: collapsed
                          ? Alignment.bottomCenter
                          : Alignment.centerRight,
                      child: toggle,
                    ),
                  ),
                if (collapsed && !mac) Center(child: toggle),
                if (!collapsed) _Brand(trailing: mac ? null : toggle),
                if (!collapsed)
                  sectionTitle('资料库')
                else
                  const SizedBox(height: 12),
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
                if (!collapsed && active.isNotEmpty) ...[
                  sectionTitle('后台任务'),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
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
                    ),
                  ),
                ] else
                  const Spacer(),
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
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(p.accent, Colors.white, 0.18)!, p.accent],
              ),
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.35),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: const Icon(
              CupertinoIcons.film_fill,
              size: 12,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            '理片',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
              letterSpacing: 0.5,
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
    final iconW = Icon(
      icon,
      size: 16,
      color: selected ? p.accent : p.textMuted,
    );
    final body = Hoverable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 30,
        margin: const EdgeInsets.only(bottom: 1),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.13)
              : (hover ? p.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(Radii.md),
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
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected ? p.accent : p.text,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (badge > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '$badge',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                        ),
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
          borderRadius: BorderRadius.circular(Radii.md),
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
                  : SizedBox(
                      width: 14,
                      height: 14,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: CircularProgressIndicator(
                          value: t.progress,
                          strokeWidth: 1.8,
                          color: p.accent,
                          backgroundColor: p.accent.withValues(alpha: 0.15),
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
                  if (!review && t.progress != null) ...[
                    const SizedBox(height: 5),
                    GradientProgress(
                      value: t.progress!,
                      color: p.accent,
                      height: 3,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
