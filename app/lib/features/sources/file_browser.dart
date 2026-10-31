import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'connection_dialog.dart' show connectionTypeLabel;
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

  Future<void> _submit() async {
    final paths = ref.read(browserSelectionProvider).toList()..sort();
    final id = await ref
        .read(taskManagerProvider)
        .submit(widget.connection.id, paths, ref.read(browserModeProvider));
    if (!mounted) return;
    ref.read(browserSelectionProvider.notifier).clear();
    ref.read(selectModeProvider.notifier).set(false);
    final router = GoRouter.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已提交任务 ${id.value}'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () => router.go('/tasks'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.connection;
    final p = Palette.of(context);
    final dir = ref.watch(browserDirProvider);
    final selectMode = ref.watch(selectModeProvider);
    final selection = ref.watch(browserSelectionProvider);
    final entries = ref.watch(browserEntriesProvider);
    // Re-read favorites from the editor so the star reflects edits.
    final fav = ref
        .watch(connectionsEditorProvider)
        .firstWhere((e) => e.id == c.id, orElse: () => c)
        .favorites
        .contains(dir);

    void toggleSelectMode(bool v) {
      ref.read(selectModeProvider.notifier).set(v);
      if (!v) ref.read(browserSelectionProvider.notifier).clear();
    }

    void selectAll() {
      final all = entries.asData?.value ?? const [];
      final sel = ref.read(browserSelectionProvider.notifier);
      final paths = all.map((e) => e.path);
      selection.containsAll(paths)
          ? sel.setAll(selection.difference(paths.toSet()))
          : sel.setAll({...selection, ...paths});
    }

    return PageScaffold(
      title: c.name,
      subtitle: '${connectionTypeLabel(c.type)}  ·  ${c.endpoint}',
      leading: IconButton(
        tooltip: '返回连接列表',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => ref.read(openConnectionProvider.notifier).set(null),
      ),
      actions: [
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref
              .read(browserRefreshProvider.notifier)
              .set(ref.read(browserRefreshProvider) + 1),
        ),
        IconButton(
          tooltip: fav ? '取消收藏此文件夹' : '收藏此文件夹',
          icon: Icon(
            fav ? Icons.star_rounded : Icons.star_outline_rounded,
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
            padding: const EdgeInsets.fromLTRB(24, 0, 32, 0),
            child: _Breadcrumbs(dir: dir, onTap: _goto),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 12),
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
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: '在当前文件夹内搜索',
                    ),
                    onChanged: ref.read(browserSearchProvider.notifier).set,
                  ),
                ),
                _SortMenu(
                  value: ref.watch(browserSortProvider),
                  onChanged: ref.read(browserSortProvider.notifier).set,
                ),
                // Hook: browserEntriesProvider applies isOrganizedProvider.
                FilterChip(
                  label: const Text('只看未整理的'),
                  selected: ref.watch(onlyUnorganizedProvider),
                  onSelected: ref.read(onlyUnorganizedProvider.notifier).set,
                ),
                FilterChip(
                  avatar: selectMode
                      ? null
                      : const Icon(Icons.checklist, size: 16),
                  label: const Text('多选'),
                  selected: selectMode,
                  onSelected: toggleSelectMode,
                ),
                if (selectMode)
                  TextButton(onPressed: selectAll, child: const Text('全选')),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
                    child: Panel(
                      child: entries.when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => EmptyState(
                          icon: Icons.error_outline,
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
                                icon: Icons.folder_off_outlined,
                                title: '这个文件夹是空的',
                              )
                            : ListView.separated(
                                padding: EdgeInsets.fromLTRB(
                                  6,
                                  6,
                                  6,
                                  selectMode ? 96 : 6,
                                ),
                                itemCount: list.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(indent: 16, endIndent: 16),
                                itemBuilder: (_, i) {
                                  final e = list[i];
                                  return _EntryTile(
                                    entry: e,
                                    selectMode: selectMode,
                                    selected: selection.contains(e.path),
                                    onToggle: () => ref
                                        .read(browserSelectionProvider.notifier)
                                        .toggle(e.path),
                                    onOpen: () => _goto(e.path),
                                  );
                                },
                              ),
                      ),
                    ),
                  ),
                ),
                if (selectMode)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 40,
                    child: Center(
                      child: _SelectionBar(
                        count: selection.length,
                        mode: ref.watch(browserModeProvider),
                        onMode: ref.read(browserModeProvider.notifier).set,
                        onCancel: () => toggleSelectMode(false),
                        onSubmit: selection.isEmpty ? null : _submit,
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
  final VoidCallback? onSubmit;

  const _SelectionBar({
    required this.count,
    required this.mode,
    required this.onMode,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 680),
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: p.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已选 $count 项',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          SegmentedButton<OrganizeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OrganizeMode.inPlace, label: Text('原地整理')),
              ButtonSegment(
                value: OrganizeMode.moveToLibrary,
                label: Text('移动到媒体库'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (v) => onMode(v.first),
          ),
          const SizedBox(width: 16),
          TextButton(onPressed: onCancel, child: const Text('取消')),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(Icons.arrow_upward, size: 18),
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
        PopupMenuItem(value: e.key, child: Text(e.value)),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: Palette.of(context).line),
        borderRadius: BorderRadius.circular(Radii.md),
        color: Palette.of(context).panel,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.swap_vert, size: 16),
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
          Icon(Icons.chevron_right, size: 16, color: p.textFaint),
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

const _videoExt = {
  'mkv',
  'mp4',
  'avi',
  'mov',
  'ts',
  'm2ts',
  'wmv',
  'flv',
  'rmvb',
  'webm',
  'iso',
};
const _subExt = {'ass', 'ssa', 'srt', 'sub', 'idx', 'vtt', 'sup'};

IconData _entryIcon(RemoteEntry e) {
  if (e.isDir) return Icons.folder_rounded;
  final ext = e.name.contains('.') ? e.name.split('.').last.toLowerCase() : '';
  if (_videoExt.contains(ext)) return Icons.movie_outlined;
  if (_subExt.contains(ext)) return Icons.subtitles_outlined;
  return Icons.insert_drive_file_outlined;
}

class _EntryTile extends StatelessWidget {
  final RemoteEntry entry;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  const _EntryTile({
    required this.entry,
    required this.selectMode,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final p = Palette.of(context);
    final meta = [
      fmtSize(e.size),
      fmtDate(e.modified),
    ].where((s) => s.isNotEmpty).join('  ·  ');
    return HoverRow(
      selected: selected,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      borderRadius: BorderRadius.circular(Radii.md),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectMode) ...[
            SizedBox(
              width: 24,
              child: Checkbox(value: selected, onChanged: (_) => onToggle()),
            ),
            const SizedBox(width: 8),
          ],
          Icon(
            _entryIcon(e),
            size: 20,
            color: e.isDir ? p.accent.withValues(alpha: 0.85) : p.textMuted,
          ),
        ],
      ),
      title: Text(e.name),
      subtitle: meta.isEmpty ? null : Text(meta),
      hoverTrailing: e.isDir
          ? IconButton(
              tooltip: '进入文件夹',
              iconSize: 18,
              icon: const Icon(Icons.chevron_right),
              onPressed: onOpen,
            )
          : null,
      onTap: selectMode ? onToggle : (e.isDir ? onOpen : null),
    );
  }
}
