import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../data/providers.dart';
import '../data/settings.dart';
import '../features/sources/connection_dialog.dart'
    show connectionTypeIcon, connectionTypeLabel;
import '../features/sources/sources_page.dart' show editConnection, openBrowser;
import '../features/sources/sources_providers.dart' show openConnectionProvider;
import '../features/tasks/tasks_page.dart' show stageLabel;
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/common.dart';

var _paletteOpen = false;

/// Global ⌘K / Ctrl+K Spotlight-style command palette.
Future<void> showCommandPalette(BuildContext context, WidgetRef ref) async {
  if (_paletteOpen) return;
  _paletteOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.25),
      builder: (_) => _CommandPaletteDialog(hostContext: context, hostRef: ref),
    );
  } finally {
    _paletteOpen = false;
  }
}

class _PaletteItem {
  final String id;
  final String group;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String searchText;
  final VoidCallback onActivate;

  const _PaletteItem({
    required this.id,
    required this.group,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.searchText,
    required this.onActivate,
  });
}

class _CommandPaletteDialog extends ConsumerStatefulWidget {
  final BuildContext hostContext;
  final WidgetRef hostRef;

  const _CommandPaletteDialog({
    required this.hostContext,
    required this.hostRef,
  });

  @override
  ConsumerState<_CommandPaletteDialog> createState() =>
      _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends ConsumerState<_CommandPaletteDialog> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late final _focusNode = FocusNode(onKeyEvent: _handleKey);
  var _selectedIndex = 0;
  List<_PaletteItem> _visible = const [];

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  void _activate(_PaletteItem item) {
    item.onActivate();
  }

  void _activateSelected() {
    if (_visible.isEmpty) return;
    final idx = _selectedIndex.clamp(0, _visible.length - 1);
    _activate(_visible[idx]);
  }

  void _moveSelection(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _selectedIndex =
          (_selectedIndex + delta + _visible.length) % _visible.length;
    });
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    const approxRowHeight = 46.0;
    final target = _selectedIndex * approxRowHeight;
    final min = _scroll.offset;
    final max = min + _scroll.position.viewportDimension - approxRowHeight;
    if (target < min) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    } else if (target > max) {
      _scroll.jumpTo(
        (target - _scroll.position.viewportDimension + approxRowHeight * 2)
            .clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activateSelected();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<_PaletteItem> _buildItems() {
    final hostContext = widget.hostContext;
    final hostRef = widget.hostRef;
    final conns = ref.watch(connectionsProvider);
    final tasks = ref.watch(tasksProvider).value ?? const <TaskSummary>[];
    final settings = ref.watch(settingsProvider);
    final isDark =
        settings.themeMode == ThemeMode.dark ||
        (settings.themeMode == ThemeMode.system &&
            Theme.of(context).brightness == Brightness.dark);

    void goRoute(String route, {bool resetBrowser = false}) {
      if (resetBrowser) {
        ref.read(openConnectionProvider.notifier).set(null);
      }
      _close();
      if (hostContext.mounted) hostContext.go(route);
    }

    final items = <_PaletteItem>[
      // 1. 页面导航
      _PaletteItem(
        id: 'nav-sources',
        group: '页面导航',
        icon: CupertinoIcons.folder,
        title: '来源',
        subtitle: '/sources',
        searchText: '来源 sources 连接 浏览 文件',
        onActivate: () => goRoute('/sources', resetBrowser: true),
      ),
      _PaletteItem(
        id: 'nav-tasks',
        group: '页面导航',
        icon: CupertinoIcons.square_list,
        title: '任务',
        subtitle: '/tasks',
        searchText: '任务 tasks 进度 历史 撤销',
        onActivate: () => goRoute('/tasks'),
      ),
      _PaletteItem(
        id: 'nav-health',
        group: '页面导航',
        icon: CupertinoIcons.checkmark_shield,
        title: '体检',
        subtitle: '/health',
        searchText: '体检 health 媒体库 缺失 诊断',
        onActivate: () => goRoute('/health'),
      ),
      _PaletteItem(
        id: 'nav-watch',
        group: '页面导航',
        icon: CupertinoIcons.dot_radiowaves_left_right,
        title: '追更',
        subtitle: '/watch',
        searchText: '追更 watch 自动监控 定时',
        onActivate: () => goRoute('/watch'),
      ),
      _PaletteItem(
        id: 'nav-naming',
        group: '页面导航',
        icon: CupertinoIcons.textformat,
        title: '命名规则',
        subtitle: '/naming',
        searchText: '命名规则 naming 模板 播放器 片名',
        onActivate: () => goRoute('/naming'),
      ),
      _PaletteItem(
        id: 'nav-settings',
        group: '页面导航',
        icon: CupertinoIcons.gear,
        title: '设置',
        subtitle: '/settings',
        searchText: '设置 settings tmdb 外观 并发 限流',
        onActivate: () => goRoute('/settings'),
      ),

      // 2. 快捷操作
      _PaletteItem(
        id: 'action-add-connection',
        group: '快捷操作',
        icon: CupertinoIcons.plus_circle,
        title: '添加连接',
        subtitle: '新建 Alist、WebDAV、SMB 或本地目录',
        searchText: '添加连接 新建 连接 alist webdav smb local add connection',
        onActivate: () {
          _close();
          if (hostContext.mounted) {
            unawaited(editConnection(hostContext, hostRef));
          }
        },
      ),
      _PaletteItem(
        id: 'action-toggle-theme',
        group: '快捷操作',
        icon: isDark ? CupertinoIcons.sun_max : CupertinoIcons.moon,
        title: isDark ? '切换到浅色主题' : '切换到深色主题',
        subtitle: '当前：${isDark ? '深色' : '浅色'}外观',
        searchText: '切换浅色深色主题 主题 外观 浅色 深色 暗黑 theme dark light',
        onActivate: () {
          ref
              .read(settingsProvider.notifier)
              .update(
                (s) => s.copyWith(
                  themeMode: isDark ? ThemeMode.light : ThemeMode.dark,
                ),
              );
          _close();
        },
      ),

      // 3. 所有已保存连接
      for (final c in conns)
        _PaletteItem(
          id: 'conn-${c.id.value}',
          group: '连接',
          icon: connectionTypeIcon(c.type),
          title: c.name,
          subtitle: '${connectionTypeLabel(c.type)} · ${c.endpoint}',
          searchText:
              '连接 ${c.name} ${connectionTypeLabel(c.type)} ${c.endpoint} ${c.startDir}',
          onActivate: () {
            openBrowser(ref, c);
            _close();
            if (hostContext.mounted) hostContext.go('/sources');
          },
        ),

      // 4. 所有收藏目录
      for (final c in conns)
        for (final fav in c.favorites)
          _PaletteItem(
            id: 'fav-${c.id.value}-$fav',
            group: '收藏目录',
            icon: CupertinoIcons.star,
            title: pathBasename(fav),
            subtitle: '${c.name} · $fav',
            searchText: '收藏 ${c.name} $fav ${pathBasename(fav)}',
            onActivate: () {
              openBrowser(ref, c, fav);
              _close();
              if (hostContext.mounted) hostContext.go('/sources');
            },
          ),

      // 5. 最近任务
      for (final t in tasks.take(10))
        _PaletteItem(
          id: 'task-${t.id.value}',
          group: '最近任务',
          icon: t.stage == TaskStage.awaitingReview
              ? CupertinoIcons.checkmark_circle
              : CupertinoIcons.clock,
          title: () {
            final first = t.paths.isEmpty
                ? t.id.value
                : pathBasename(t.paths.first);
            return t.paths.length > 1 ? '$first 等 ${t.paths.length} 项' : first;
          }(),
          subtitle:
              '${stageLabel(t.stage)} · ${t.videoCount} 个视频 · ${t.id.value}',
          searchText:
              '任务 ${t.id.value} ${t.paths.join(' ')} ${stageLabel(t.stage)}',
          onActivate: () {
            final route = t.stage == TaskStage.awaitingReview
                ? '/tasks/${t.id.value}/review'
                : '/tasks/${t.id.value}';
            goRoute(route);
          },
        ),
    ];

    final q = _query.text.trim();
    if (q.isEmpty) return items;
    return [
      for (final it in items)
        if (fuzzyMatch(q, it.title) ||
            (it.subtitle != null && fuzzyMatch(q, it.subtitle!)) ||
            fuzzyMatch(q, it.searchText))
          it,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final items = _buildItems();
    _visible = items;
    final activeIndex = items.isEmpty
        ? 0
        : _selectedIndex.clamp(0, items.length - 1);

    // Build rows with section headers interleaved.
    final rows = <Widget>[];
    String? lastGroup;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.group != lastGroup) {
        lastGroup = item.group;
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(14, i == 0 ? 10 : 14, 14, 4),
            child: Text(
              item.group,
              style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
            ),
          ),
        );
      }
      final selected = i == activeIndex;
      rows.add(
        _PaletteRow(
          key: ValueKey('palette-item-${item.id}'),
          item: item,
          selected: selected,
          onHover: () {
            if (_selectedIndex != i) {
              setState(() => _selectedIndex = i);
            }
          },
          onTap: () => _activate(item),
        ),
      );
    }

    return MacSheet(
      key: const ValueKey('command-palette'),
      child: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.search, size: 17, color: p.textMuted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('palette-search'),
                        controller: _query,
                        focusNode: _focusNode,
                        autofocus: true,
                        style: TextStyle(
                          fontSize: TypeScale.headline,
                          color: p.text,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索页面、连接、收藏目录或任务…',
                          hintStyle: TextStyle(
                            fontSize: TypeScale.headline,
                            color: p.textFaint,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 6,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                        ),
                        onChanged: (_) => setState(() => _selectedIndex = 0),
                        onSubmitted: (_) => _activateSelected(),
                      ),
                    ),
                    if (_query.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空',
                        iconSize: 14,
                        icon: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          color: p.textFaint,
                        ),
                        onPressed: () => setState(() {
                          _query.clear();
                          _selectedIndex = 0;
                        }),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: p.sidebar,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: p.line, width: hairline),
                        ),
                        child: Text(
                          'Esc',
                          style: TextStyle(
                            fontSize: 11,
                            color: p.textFaint,
                            fontFamily: monoFamily,
                            fontFamilyFallback: monoFallback,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Text(
                      '没有匹配的结果',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: p.textFaint,
                      ),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: rows,
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: p.sidebar,
                  border: Border(
                    top: BorderSide(color: p.line, width: hairline),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '↑↓ 选择  ·  ↵ 打开  ·  Esc 关闭',
                      style: TextStyle(
                        fontSize: TypeScale.small,
                        color: p.textFaint,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${items.length} 项',
                      style: TextStyle(
                        fontSize: TypeScale.small,
                        color: p.textFaint,
                      ),
                    ),
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

class _PaletteRow extends StatelessWidget {
  final _PaletteItem item;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _PaletteRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? p.selected : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            children: [
              Icon(item.icon, size: 16, color: selected ? p.text : p.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TypeScale.body,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: p.text,
                      ),
                    ),
                    if (item.subtitle != null)
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          color: p.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                Icon(CupertinoIcons.return_icon, size: 13, color: p.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
