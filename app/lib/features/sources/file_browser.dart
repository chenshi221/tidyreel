import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
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

    return PageScaffold(
      title: c.name,
      leading: IconButton(
        tooltip: '返回连接列表',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => ref.read(openConnectionProvider.notifier).set(null),
      ),
      actions: [
        IconButton(
          tooltip: fav ? '取消收藏此文件夹' : '收藏此文件夹',
          icon: Icon(fav ? Icons.star : Icons.star_border),
          onPressed: () => ref
              .read(connectionsEditorProvider.notifier)
              .toggleFavorite(c.id, dir),
        ),
      ],
      child: Column(
        children: [
          _Breadcrumbs(dir: dir, onTap: _goto),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '在当前文件夹内搜索',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: ref.read(browserSearchProvider.notifier).set,
                  ),
                ),
                DropdownButton<BrowserSort>(
                  value: ref.watch(browserSortProvider),
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(
                      value: BrowserSort.name,
                      child: Text('按名称'),
                    ),
                    DropdownMenuItem(
                      value: BrowserSort.time,
                      child: Text('按时间'),
                    ),
                    DropdownMenuItem(
                      value: BrowserSort.size,
                      child: Text('按大小'),
                    ),
                  ],
                  onChanged: (v) =>
                      ref.read(browserSortProvider.notifier).set(v!),
                ),
                // Hook: browserEntriesProvider applies isOrganizedProvider.
                FilterChip(
                  label: const Text('只看未整理的'),
                  selected: ref.watch(onlyUnorganizedProvider),
                  onSelected: ref.read(onlyUnorganizedProvider.notifier).set,
                ),
                FilterChip(
                  avatar: const Icon(Icons.checklist, size: 18),
                  label: const Text('多选'),
                  selected: selectMode,
                  onSelected: (v) {
                    ref.read(selectModeProvider.notifier).set(v);
                    if (!v) ref.read(browserSelectionProvider.notifier).clear();
                  },
                ),
                if (selectMode)
                  TextButton(
                    onPressed: () {
                      final all = entries.asData?.value ?? const [];
                      final sel = ref.read(browserSelectionProvider.notifier);
                      final paths = all.map((e) => e.path);
                      selection.containsAll(paths)
                          ? sel.setAll(selection.difference(paths.toSet()))
                          : sel.setAll({...selection, ...paths});
                    },
                    child: const Text('全选'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('无法读取文件夹：$e')),
              data: (list) => list.isEmpty
                  ? const Center(child: Text('这个文件夹是空的'))
                  : ListView.builder(
                      itemCount: list.length,
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
          if (selectMode)
            Material(
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text('已选 ${selection.length} 项'),
                    const SizedBox(width: 24),
                    SegmentedButton<OrganizeMode>(
                      segments: const [
                        ButtonSegment(
                          value: OrganizeMode.inPlace,
                          label: Text('原地整理'),
                        ),
                        ButtonSegment(
                          value: OrganizeMode.moveToLibrary,
                          label: Text('移动到媒体库'),
                        ),
                      ],
                      selected: {ref.watch(browserModeProvider)},
                      onSelectionChanged: (v) =>
                          ref.read(browserModeProvider.notifier).set(v.first),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: selection.isEmpty ? null : _submit,
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('提交为任务'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  final String dir;
  final void Function(String) onTap;

  const _Breadcrumbs({required this.dir, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final parts = dir.split('/').where((s) => s.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(onPressed: () => onTap('/'), child: const Text('根目录')),
          for (var i = 0; i < parts.length; i++) ...[
            const Icon(Icons.chevron_right, size: 18),
            TextButton(
              onPressed: () => onTap('/${parts.take(i + 1).join('/')}'),
              child: Text(parts[i]),
            ),
          ],
        ],
      ),
    );
  }
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
    return ListTile(
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectMode)
            Checkbox(value: selected, onChanged: (_) => onToggle()),
          Icon(e.isDir ? Icons.folder : Icons.movie_outlined),
        ],
      ),
      title: Text(e.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          fmtSize(e.size),
          fmtDate(e.modified),
        ].where((s) => s.isNotEmpty).join(' · '),
      ),
      trailing: selectMode && e.isDir
          ? IconButton(
              tooltip: '进入文件夹',
              icon: const Icon(Icons.chevron_right),
              onPressed: onOpen,
            )
          : null,
      onTap: selectMode ? onToggle : (e.isDir ? onOpen : null),
    );
  }
}
