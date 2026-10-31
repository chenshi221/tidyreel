import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../data/providers.dart';
import '../features/sources/sources_providers.dart';
import '../features/tasks/tasks_page.dart' show stageLabel;
import '../ui/tokens.dart';
import '../widgets/common.dart';

final sidebarCollapsedProvider = NotifierProvider<Val<bool>, bool>(
  () => Val(false),
);

/// Left sidebar: brand, the four destinations, and live background tasks so
/// import / recognition progress is visible from every page.
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  static const expandedWidth = 236.0;
  static const collapsedWidth = 64.0;

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
    }) {
      final selected = location.startsWith(path);
      return _NavItem(
        key: ValueKey('nav-$label'),
        icon: selected ? selectedIcon : icon,
        label: label,
        selected: selected,
        badge: badge,
        collapsed: collapsed,
        onTap: () => go(path),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      width: collapsed ? collapsedWidth : expandedWidth,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.line)),
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: collapsed ? collapsedWidth : expandedWidth,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Brand(collapsed: collapsed),
                const SizedBox(height: 18),
                item(
                  '/sources',
                  Icons.folder_open_outlined,
                  Icons.folder_open,
                  '来源',
                ),
                item(
                  '/tasks',
                  Icons.checklist_rtl_outlined,
                  Icons.checklist_rtl,
                  '任务',
                  badge: pending,
                ),
                item(
                  '/naming',
                  Icons.text_fields_outlined,
                  Icons.text_fields,
                  '命名规则',
                ),
                if (!collapsed && active.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.only(left: 10, bottom: 6),
                    child: Text(
                      '后台任务',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
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
                const SizedBox(height: 8),
                item(
                  '/settings',
                  Icons.settings_outlined,
                  Icons.settings,
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

class _Brand extends ConsumerWidget {
  final bool collapsed;

  const _Brand({required this.collapsed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final toggle = IconButton(
      tooltip: collapsed ? '展开侧栏' : '收起侧栏',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.view_sidebar_outlined),
      onPressed: () => ref
          .read(sidebarCollapsedProvider.notifier)
          .set(!ref.read(sidebarCollapsedProvider)),
    );
    if (collapsed) return Center(child: toggle);
    return Row(
      children: [
        const SizedBox(width: 6),
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: p.accent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(Icons.movie_filter, size: 16, color: p.onAccent),
        ),
        const SizedBox(width: 10),
        Text(
          '理片',
          style: TextStyle(
            fontFamily: serifFamily,
            fontFamilyFallback: serifFallback,
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Tidyreel',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: serifFamily,
              fontFamilyFallback: serifFallback,
              fontSize: 13,
              color: p.textFaint,
            ),
          ),
        ),
        toggle,
      ],
    );
  }
}

class _NavItem extends StatefulWidget {
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
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = widget;
    final bg = w.selected
        ? p.selected
        : (_hover ? p.hover : Colors.transparent);
    final icon = Icon(
      w.icon,
      size: 19,
      color: w.selected ? p.text : p.textMuted,
    );
    final badge = w.badge > 0
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: p.accent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${w.badge}',
              style: TextStyle(
                color: p.onAccent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        : null;
    final body = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: w.onTap,
        child: Container(
          height: 38,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: w.collapsed
              ? Center(
                  child: badge == null
                      ? icon
                      : Badge(label: Text('${w.badge}'), child: icon),
                )
              : Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        w.label,
                        style: TextStyle(
                          fontSize: 14,
                          color: p.text,
                          fontWeight: w.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    ?badge,
                  ],
                ),
        ),
      ),
    );
    return w.collapsed ? Tooltip(message: w.label, child: body) : body;
  }
}

/// One running task in the sidebar: name, stage, thin progress bar.
class _TaskItem extends ConsumerStatefulWidget {
  final TaskSummary task;
  final VoidCallback onTap;

  const _TaskItem({required this.task, required this.onTap});

  @override
  ConsumerState<_TaskItem> createState() => _TaskItemState();
}

class _TaskItemState extends ConsumerState<_TaskItem> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = widget.task;
    final review = t.stage == TaskStage.awaitingReview;
    final first = t.paths.isEmpty
        ? t.id.value
        : t.paths.first.split('/').where((s) => s.isNotEmpty).lastOrNull ??
              '根目录';
    final name = t.paths.length > 1 ? '$first 等 ${t.paths.length} 项' : first;
    final status = switch (t.stage) {
      TaskStage.importing => '导入中 · ${t.importedCount} 个文件',
      TaskStage.recognizing => '识别中',
      TaskStage.awaitingReview => '待确认',
      _ => '执行中 · ${stageLabel(t.stage)}',
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: _hover ? p.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: review
                    ? Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: p.accent,
                          shape: BoxShape.circle,
                        ),
                      )
                    : SizedBox(
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: p.textMuted,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.text),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: review ? p.accent : p.textFaint,
                      ),
                    ),
                    if (!review && t.progress != null) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: t.progress, minHeight: 3),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
