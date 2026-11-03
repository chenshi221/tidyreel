import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/settings.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'connection_dialog.dart' show connectionTypeLabel;
import 'scan_preview.dart';
import 'sources_providers.dart';

/// In-page file browser for one connection (PLAN §1 步骤 2–3).
class FileBrowser extends ConsumerStatefulWidget {
  final ConnectionConfig connection;

  const FileBrowser({super.key, required this.connection});

  @override
  ConsumerState<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends ConsumerState<FileBrowser> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _goto(String path) {
    _search.clear();
    ref.read(browserSearchProvider.notifier).set('');
    ref.read(browserDirProvider.notifier).set(path);
  }

  /// The selection, which may span folders: remove items or jump to one.
  Future<void> _showSelected() => showDialog<void>(
    context: context,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final sel = ref.watch(browserSelectionProvider).toList()..sort();
        if (sel.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted) Navigator.of(ctx).pop();
          });
        }
        return AlertDialog(
          title: Text('已选 ${sel.length} 项'),
          content: SizedBox(
            width: 520,
            height: 360,
            child: ListView(
              children: [
                for (final path in sel)
                  ListTile(
                    key: ValueKey('selected $path'),
                    dense: true,
                    title: Text(path.substring(path.lastIndexOf('/') + 1)),
                    subtitle: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      final i = path.lastIndexOf('/');
                      _goto(i <= 0 ? '/' : path.substring(0, i));
                    },
                    trailing: IconButton(
                      tooltip: '移出选择',
                      icon: const Icon(CupertinoIcons.xmark, size: 14),
                      onPressed: () => ref
                          .read(browserSelectionProvider.notifier)
                          .toggle(path),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成'),
            ),
          ],
        );
      },
    ),
  );

  /// Submits [only] (one row's 整理 button) or the current selection.
  Future<void> _submit([String? only, OrganizeMode? mode]) async {
    final paths = only != null
        ? [only]
        : (ref.read(browserSelectionProvider).toList()..sort());
    final history = ref.read(historyProvider);
    final ok =
        !ref.read(settingsProvider).scanPreview ||
        await showScanPreview(
          context,
          backend: ref.read(backendForProvider)(widget.connection.id),
          paths: paths,
          organizedCount: (dirs) async {
            final organized = await history.areOrganized(
              widget.connection.id,
              dirs,
            );
            return organized.length;
          },
        );
    if (!ok || !mounted) return;
    final id = await ref
        .read(taskManagerProvider)
        .submit(
          widget.connection.id,
          paths,
          mode ?? ref.read(browserModeProvider),
        );
    if (!mounted) return;
    if (only == null) ref.read(browserSelectionProvider.notifier).clear();
    // The detail page follows the task and opens the review once recognized.
    context.go('/tasks/${id.value}');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.connection;
    final p = Palette.of(context);
    final dir = ref.watch(browserDirProvider);
    final selection = ref.watch(browserSelectionProvider);
    final entries = ref.watch(browserEntriesProvider);
    // Re-read favorites from the editor so the star reflects edits.
    final fav = ref
        .watch(connectionsEditorProvider)
        .firstWhere((e) => e.id == c.id, orElse: () => c)
        .favorites
        .contains(dir);

    void selectAll() {
      final all = entries.asData?.value ?? const [];
      final sel = ref.read(browserSelectionProvider.notifier);
      final paths = all.map((e) => e.path);
      selection.containsAll(paths)
          ? sel.setAll(selection.difference(paths.toSet()))
          : sel.setAll({...selection, ...paths});
    }

    final favs = ref
        .watch(connectionsEditorProvider)
        .firstWhere((e) => e.id == c.id, orElse: () => c)
        .favorites;
    void toggleFav(String path) =>
        ref.read(connectionsEditorProvider.notifier).toggleFavorite(c.id, path);
    void copyPath(String path) {
      Clipboard.setData(ClipboardData(text: path));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制路径')));
    }

    List<MenuAction?> organizeItems(String path) => [
      MenuAction(
        '整理（原地）',
        () => _submit(path, OrganizeMode.inPlace),
        icon: CupertinoIcons.wand_stars,
      ),
      MenuAction(
        '整理（移动到媒体库）',
        () => _submit(path, OrganizeMode.moveToLibrary),
        icon: CupertinoIcons.tray_arrow_down,
      ),
    ];

    List<MenuAction?> entryMenu(RemoteEntry e) => [
      if (e.isDir)
        MenuAction('打开', () => _goto(e.path), icon: CupertinoIcons.folder),
      ...organizeItems(e.path),
      null,
      MenuAction(
        selection.contains(e.path) ? '取消选中' : '选中',
        () => ref.read(browserSelectionProvider.notifier).toggle(e.path),
        icon: CupertinoIcons.checkmark_square,
      ),
      if (e.isDir)
        MenuAction(
          favs.contains(e.path) ? '取消收藏' : '收藏',
          () => toggleFav(e.path),
          icon: favs.contains(e.path)
              ? CupertinoIcons.star_slash
              : CupertinoIcons.star,
        ),
      MenuAction(
        '复制路径',
        () => copyPath(e.path),
        icon: CupertinoIcons.doc_on_clipboard,
      ),
    ];

    List<MenuAction?> folderMenu() => [
      MenuAction('刷新', () {
        ref
            .read(browserRefreshProvider.notifier)
            .set(ref.read(browserRefreshProvider) + 1);
      }, icon: CupertinoIcons.arrow_clockwise),
      MenuAction('全选 / 取消全选', selectAll, icon: CupertinoIcons.checkmark_square),
      null,
      ...organizeItems(dir),
      MenuAction(
        fav ? '取消收藏当前文件夹' : '收藏当前文件夹',
        () => toggleFav(dir),
        icon: fav ? CupertinoIcons.star_slash : CupertinoIcons.star,
      ),
      MenuAction(
        '复制当前路径',
        () => copyPath(dir),
        icon: CupertinoIcons.doc_on_clipboard,
      ),
    ];

    return PageScaffold(
      title: c.name,
      subtitle: '${connectionTypeLabel(c.type)}  ·  ${c.endpoint}',
      leading: IconButton(
        tooltip: '返回连接列表',
        icon: const Icon(CupertinoIcons.chevron_left),
        onPressed: () => ref.read(openConnectionProvider.notifier).set(null),
      ),
      actions: [
        IconButton(
          tooltip: '刷新',
          icon: const Icon(CupertinoIcons.arrow_clockwise),
          onPressed: () => ref
              .read(browserRefreshProvider.notifier)
              .set(ref.read(browserRefreshProvider) + 1),
        ),
        IconButton(
          tooltip: fav ? '取消收藏此文件夹' : '收藏此文件夹',
          icon: Icon(
            fav ? CupertinoIcons.star_fill : CupertinoIcons.star,
            color: fav ? p.accent : null,
          ),
          onPressed: () => ref
              .read(connectionsEditorProvider.notifier)
              .toggleFavorite(c.id, dir),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 28, 0),
            child: _Breadcrumbs(dir: dir, onTap: _goto),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 6, 28, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(CupertinoIcons.search, size: 14),
                      hintText: '在当前文件夹内搜索',
                    ),
                    onChanged: ref.read(browserSearchProvider.notifier).set,
                  ),
                ),
                _SortMenu(
                  value: ref.watch(browserSortProvider),
                  onChanged: ref.read(browserSortProvider.notifier).set,
                ),
                // Hook: browserEntriesProvider filters via HistoryStore.areOrganized.
                FilterChip(
                  label: const Text('只看未整理的'),
                  selected: ref.watch(onlyUnorganizedProvider),
                  onSelected: ref.read(onlyUnorganizedProvider.notifier).set,
                ),
                TextButton(
                  onPressed: selectAll,
                  child: Text(
                    (entries.asData?.value ?? const []).isNotEmpty &&
                            selection.containsAll(
                              entries.asData!.value.map((e) => e.path),
                            )
                        ? '取消全选'
                        : '全选',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
                    child: ContextMenuArea(
                      items: folderMenu,
                      child: Panel(
                        child: entries.when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (e, _) => EmptyState(
                            icon: CupertinoIcons.exclamationmark_triangle,
                            title: '无法读取文件夹',
                            message: '$e',
                            action: OutlinedButton(
                              onPressed: () =>
                                  ref.invalidate(browserEntriesProvider),
                              child: const Text('重试'),
                            ),
                          ),
                          data: (list) => list.isEmpty
                              ? const EmptyState(
                                  icon: CupertinoIcons.folder,
                                  title: '这个文件夹是空的',
                                )
                              : ListView.separated(
                                  padding: EdgeInsets.fromLTRB(
                                    6,
                                    6,
                                    6,
                                    selection.isNotEmpty ? 96 : 6,
                                  ),
                                  itemCount: list.length,
                                  separatorBuilder: (_, _) =>
                                      const Divider(indent: 16, endIndent: 16),
                                  itemBuilder: (_, i) {
                                    final e = list[i];
                                    return ContextMenuArea(
                                      key: ValueKey('menu ${e.name}'),
                                      items: () => entryMenu(e),
                                      child: _EntryTile(
                                        entry: e,
                                        anySelected: selection.isNotEmpty,
                                        selected: selection.contains(e.path),
                                        onToggle: () => ref
                                            .read(
                                              browserSelectionProvider.notifier,
                                            )
                                            .toggle(e.path),
                                        onOpen: () => _goto(e.path),
                                        onOrganize: () => _submit(e.path),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (selection.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 40,
                    child: Center(
                      child: FadeIn(
                        child: _SelectionBar(
                          count: selection.length,
                          mode: ref.watch(browserModeProvider),
                          onMode: ref.read(browserModeProvider.notifier).set,
                          onCancel: ref
                              .read(browserSelectionProvider.notifier)
                              .clear,
                          onSubmit: _submit,
                          onShowSelected: _showSelected,
                          hint: ref.watch(
                            settingsProvider.select((s) => s.mediaHint),
                          ),
                          onHint: (h) => ref
                              .read(settingsProvider.notifier)
                              .update((o) => o.copyWith(mediaHint: h)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating bar for the 多选 → 提交为任务 step.
class _SelectionBar extends StatelessWidget {
  final int count;
  final OrganizeMode mode;
  final void Function(OrganizeMode) onMode;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;
  final VoidCallback onShowSelected;
  final MediaHint hint;
  final void Function(MediaHint) onHint;

  const _SelectionBar({
    required this.count,
    required this.mode,
    required this.onMode,
    required this.onCancel,
    required this.onSubmit,
    required this.onShowSelected,
    required this.hint,
    required this.onHint,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 860),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: floatShadow(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            key: const ValueKey('show-selected'),
            onPressed: onShowSelected,
            style: TextButton.styleFrom(foregroundColor: p.text),
            icon: Container(
              constraints: const BoxConstraints(minWidth: 22),
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: p.onAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '已选 $count 项',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(CupertinoIcons.chevron_up, size: 11),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<MediaHint>(
            key: const ValueKey('media-hint'),
            tooltip: '内容类型（也可在设置里改）',
            initialValue: hint,
            onSelected: onHint,
            itemBuilder: (_) => [
              for (final e in mediaHintLabels.entries)
                PopupMenuItem(value: e.key, child: Text(e.value)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '类型：${mediaHintLabels[hint]}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Icon(CupertinoIcons.chevron_down, size: 11),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Segmented<OrganizeMode>(
            options: const {
              OrganizeMode.inPlace: '原地整理',
              OrganizeMode.moveToLibrary: '移动到媒体库',
            },
            value: mode,
            onChanged: onMode,
          ),
          const SizedBox(width: 16),
          TextButton(onPressed: onCancel, child: const Text('取消')),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(CupertinoIcons.arrow_up_circle_fill, size: 15),
            label: const Text('提交为任务'),
          ),
        ],
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  final BrowserSort value;
  final void Function(BrowserSort) onChanged;

  const _SortMenu({required this.value, required this.onChanged});

  static const _labels = {
    BrowserSort.name: '按名称',
    BrowserSort.time: '按时间',
    BrowserSort.size: '按大小',
  };

  @override
  Widget build(BuildContext context) => PopupMenuButton<BrowserSort>(
    tooltip: '排序',
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final e in _labels.entries)
        PopupMenuItem(value: e.key, height: 30, child: Text(e.value)),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: Palette.of(context).lineStrong,
          width: hairline,
        ),
        borderRadius: BorderRadius.circular(Radii.md),
        color: Palette.of(context).panel,
        boxShadow: panelShadow(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.arrow_up_arrow_down, size: 12),
          const SizedBox(width: 6),
          Text(_labels[value]!, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}

class _Breadcrumbs extends StatelessWidget {
  final String dir;
  final void Function(String) onTap;

  const _Breadcrumbs({required this.dir, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final parts = dir.split('/').where((s) => s.isNotEmpty).toList();
    Widget crumb(String label, String path, bool last) => TextButton(
      style: TextButton.styleFrom(
        foregroundColor: p.textMuted,
        disabledForegroundColor: p.text,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        textStyle: TextStyle(
          fontFamilyFallback: sansFallback,
          fontSize: 13,
          fontWeight: last ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      onPressed: last ? null : () => onTap(path),
      child: Text(label),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        crumb('根目录', '/', parts.isEmpty),
        for (var i = 0; i < parts.length; i++) ...[
          Icon(CupertinoIcons.chevron_right, size: 11, color: p.textFaint),
          crumb(
            parts[i],
            '/${parts.take(i + 1).join('/')}',
            i == parts.length - 1,
          ),
        ],
      ],
    );
  }
}

Color _entryColor(RemoteEntry e, Palette p) => switch (_entryIcon(e)) {
  CupertinoIcons.folder_fill => p.textMuted,
  CupertinoIcons.film => p.text,
  _ => p.textFaint,
};

IconData _entryIcon(RemoteEntry e) {
  if (e.isDir) return CupertinoIcons.folder_fill;
  final ext = e.name.contains('.') ? e.name.split('.').last.toLowerCase() : '';
  if (videoExt.contains(ext)) return CupertinoIcons.film;
  if (subtitleExt.contains(ext)) return CupertinoIcons.captions_bubble;
  return CupertinoIcons.doc;
}

/// Finder-style row: click a folder to open it, click a file (or the
/// checkbox) to select; 整理 on hover submits just this item.
class _EntryTile extends StatelessWidget {
  final RemoteEntry entry;
  final bool anySelected;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onOrganize;

  const _EntryTile({
    required this.entry,
    required this.anySelected,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    required this.onOrganize,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final p = Palette.of(context);
    final meta = [
      fmtSize(e.size),
      fmtDate(e.modified),
    ].where((s) => s.isNotEmpty).join('  ·  ');
    return Hoverable(
      onTap: e.isDir ? onOpen : onToggle,
      builder: (context, hover) => AnimatedContainer(
        key: ValueKey('entry ${e.name}'),
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.fromLTRB(4, 7, 8, 7),
        decoration: BoxDecoration(
          color: selected ? p.selected : (hover ? p.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: selected || hover || anySelected ? 1 : 0,
                child: Checkbox(
                  key: ValueKey('check ${e.name}'),
                  value: selected,
                  onChanged: (_) => onToggle(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(_entryIcon(e), size: 20, color: _entryColor(e, p)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: TextStyle(fontSize: 11.5, color: p.textMuted),
                    ),
                ],
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 100),
              opacity: hover ? 1 : 0,
              child: IgnorePointer(
                ignoring: !hover,
                child: TextButton.icon(
                  key: ValueKey('organize ${e.name}'),
                  onPressed: onOrganize,
                  icon: const Icon(CupertinoIcons.wand_stars, size: 13),
                  label: const Text('整理'),
                ),
              ),
            ),
            SizedBox(
              width: 24,
              child: e.isDir
                  ? Icon(
                      CupertinoIcons.chevron_right,
                      size: 12,
                      color: p.textFaint,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
