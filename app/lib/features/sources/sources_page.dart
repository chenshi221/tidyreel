import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
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
    final favorites = [
      for (final c in conns)
        for (final f in c.favorites) (conn: c, path: f),
    ];
    final add = FilledButton.icon(
      onPressed: () => _edit(context, ref),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('添加连接'),
    );
    return PageScaffold(
      title: '来源',
      subtitle: '连接 Alist、WebDAV 或本地文件夹，选择要整理的影视文件',
      maxWidth: 1000,
      actions: [if (conns.isNotEmpty) add],
      child: conns.isEmpty
          ? EmptyState(
              icon: Icons.cloud_outlined,
              title: '还没有连接',
              message: '添加一个 Alist、WebDAV 或本地文件夹，就可以开始整理了',
              action: add,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              children: [
                const SectionLabel('连接'),
                Panel(
                  child: Rows(
                    children: [
                      for (final c in conns) _ConnectionRow(connection: c),
                    ],
                  ),
                ),
                const SectionLabel('收藏文件夹'),
                if (favorites.isEmpty)
                  Panel(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text(
                      '打开一个连接，在文件夹右上角点 ☆ 收藏，常用的下载目录就会出现在这里',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  Panel(
                    child: Rows(
                      children: [
                        for (final f in favorites)
                          HoverRow(
                            key: ValueKey('fav ${f.conn.id.value} ${f.path}'),
                            leading: Icon(
                              Icons.star_rounded,
                              size: 20,
                              color: Palette.of(context).accent,
                            ),
                            title: Text(f.path),
                            subtitle: Text(f.conn.name),
                            hoverTrailing: const Icon(
                              Icons.chevron_right,
                              size: 18,
                            ),
                            onTap: () => openBrowser(ref, f.conn, f.path),
                          ),
                      ],
                    ),
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
  final passwords = ref.read(connectionPasswordsProvider);
  final draft = await showConnectionDialog(
    context,
    existing: existing,
    initialPassword: existing == null ? null : passwords[existing.id],
    tester: ref.read(connectionTesterProvider),
  );
  if (draft == null) return;
  ref.read(connectionsEditorProvider.notifier).upsert(draft.config);
  ref.read(connectionPasswordsProvider.notifier).set({
    ...ref.read(connectionPasswordsProvider),
    draft.config.id: draft.password,
  });
  ref.invalidate(connectionStatusProvider(draft.config.id));
}

Future<void> _delete(
  BuildContext context,
  WidgetRef ref,
  ConnectionConfig c,
) async {
  final ok = await confirmDialog(
    context,
    title: '删除连接',
    content: Text('确定删除「${c.name}」吗？只会删除这条连接配置和保存的密码，不会动网盘或磁盘上的任何文件。'),
    confirmLabel: '删除',
    destructive: true,
  );
  if (ok) ref.read(connectionsEditorProvider.notifier).remove(c.id);
}

class _ConnectionRow extends ConsumerWidget {
  final ConnectionConfig connection;

  const _ConnectionRow({required this.connection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = connection;
    final p = Palette.of(context);
    final status = ref.watch(connectionStatusProvider(c.id));
    final value = status.asData?.value;
    final (label, color) = switch (value?.status) {
      ConnStatus.connected => ('已连接', p.success),
      ConnStatus.authFailed => ('认证失败', p.danger),
      ConnStatus.offline => ('离线', p.warning),
      null => ('检测中', p.textFaint),
    };
    final failed = value != null && value.status != ConnStatus.connected;
    final meta = [
      connectionTypeLabel(c.type),
      c.endpoint,
      if (c.libraryRoot != null) '媒体库 ${c.libraryRoot}',
    ].join('  ·  ');

    return HoverRow(
      key: ValueKey('conn ${c.id.value}'),
      padding: const EdgeInsets.fromLTRB(Space.lg, 14, Space.sm, 14),
      leading: IconTile(connectionTypeIcon(c.type), size: 36),
      title: Text(c.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (failed && value.detail != null) ...[
            const SizedBox(height: 4),
            Text(
              value.detail!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ],
        ],
      ),
      onTap: () => openBrowser(ref, c),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusPill(label: label, color: color, busy: value == null),
          const SizedBox(width: 4),
          if (failed)
            IconButton(
              tooltip: '重新检测',
              iconSize: 18,
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(connectionStatusProvider(c.id)),
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (v) {
              if (v == 'edit') _edit(context, ref, c);
              if (v == 'delete') _delete(context, ref, c);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除', style: TextStyle(color: p.danger)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
