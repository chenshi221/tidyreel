import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../widgets/common.dart';
import 'connection_dialog.dart';
import 'file_browser.dart';
import 'sources_providers.dart';

/// 来源页：连接列表 + 收藏；点进连接后切换成文件浏览器（PLAN §5）.
class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openConnectionProvider);
    if (open != null) return FileBrowser(connection: open);
    final conns = ref.watch(connectionsEditorProvider);
    return PageScaffold(
      title: '来源',
      actions: [
        FilledButton.icon(
          onPressed: () => _edit(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('添加连接'),
        ),
      ],
      child: conns.isEmpty
          ? const Center(child: Text('还没有连接，点右上角「添加连接」'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final c in conns) _ConnectionCard(connection: c),
                  ],
                ),
                const SizedBox(height: 24),
                Text('收藏文件夹', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in conns)
                      for (final f in c.favorites)
                        ActionChip(
                          avatar: const Icon(Icons.star, size: 18),
                          label: Text('${c.name} · $f'),
                          onPressed: () => openBrowser(ref, c, f),
                        ),
                  ],
                ),
              ],
            ),
    );
  }
}

void openBrowser(WidgetRef ref, ConnectionConfig c, [String path = '/']) {
  ref.read(openConnectionProvider.notifier).set(c);
  ref.read(browserDirProvider.notifier).set(path);
  ref.read(browserSearchProvider.notifier).set('');
  ref.read(browserSelectionProvider.notifier).clear();
  ref.read(selectModeProvider.notifier).set(false);
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref, [
  ConnectionConfig? existing,
]) async {
  final draft = await showConnectionDialog(context, existing: existing);
  if (draft == null) return;
  ref.read(connectionsEditorProvider.notifier).upsert(draft.config);
  ref.read(connectionPasswordsProvider.notifier).set({
    ...ref.read(connectionPasswordsProvider),
    draft.config.id: draft.password,
  });
}

class _ConnectionCard extends ConsumerWidget {
  final ConnectionConfig connection;

  const _ConnectionCard({required this.connection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = connection;
    final status = ref.watch(connectionStatusProvider(c.id));
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status.asData?.value) {
      ConnStatus.connected => ('已连接', Colors.green),
      ConnStatus.authFailed => ('认证失败', scheme.error),
      ConnStatus.offline => ('离线', scheme.outline),
      null => ('检测中…', scheme.outline),
    };
    return SizedBox(
      width: 320,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openBrowser(ref, c),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(connectionTypeIcon(c.type)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      onSelected: (v) {
                        if (v == 'edit') _edit(context, ref, c);
                        if (v == 'delete') {
                          ref
                              .read(connectionsEditorProvider.notifier)
                              .remove(c.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
                Text(
                  '${connectionTypeLabel(c.type)} · ${c.endpoint}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
                if (c.libraryRoot != null)
                  Text(
                    '媒体库：${c.libraryRoot}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: color),
                    const SizedBox(width: 6),
                    Text(label, style: TextStyle(color: color)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
