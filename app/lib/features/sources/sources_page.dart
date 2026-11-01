import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../tasks/tasks_page.dart' show taskWorksProvider;

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
    final done = [
      for (final t in ref.watch(tasksProvider).value ?? const <TaskSummary>[])
        if (t.stage == TaskStage.done || t.stage == TaskStage.partiallyFailed)
          t,
    ].take(8).toList();
    final favorites = [
      for (final c in conns)
        for (final f in c.favorites) (conn: c, path: f),
    ];
    final add = FilledButton.icon(
      onPressed: () => _edit(context, ref),
      icon: const Icon(CupertinoIcons.plus, size: 14),
      label: const Text('添加连接'),
    );
    return PageScaffold(
      title: '来源',
      subtitle: '连接 Alist、WebDAV 或本地文件夹，选择要整理的影视文件',
      maxWidth: 1000,
      actions: [if (conns.isNotEmpty) add],
      child: conns.isEmpty
          ? EmptyState(
              icon: CupertinoIcons.cloud,
              title: '还没有连接',
              message: '添加一个 Alist、WebDAV 或本地文件夹，就可以开始整理了',
              action: add,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              children: [
                if (done.isNotEmpty) ...[
                  const SectionLabel('最近整理'),
                  SizedBox(
                    height: 186,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0; i < done.length; i++)
                          FadeIn(
                            index: i,
                            child: _RecentTask(task: done[i]),
                          ),
                      ],
                    ),
                  ),
                ],
                const SectionLabel('连接'),
                Panel(
                  child: Rows(
                    children: [
                      for (var i = 0; i < conns.length; i++)
                        FadeIn(
                          index: i,
                          child: _ConnectionRow(connection: conns[i]),
                        ),
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
                          ContextMenuArea(
                            items: () => [
                              MenuAction(
                                '打开',
                                () => openBrowser(ref, f.conn, f.path),
                                icon: CupertinoIcons.folder,
                              ),
                              MenuAction(
                                '取消收藏',
                                () => ref
                                    .read(connectionsEditorProvider.notifier)
                                    .toggleFavorite(f.conn.id, f.path),
                                icon: CupertinoIcons.star_slash,
                                destructive: true,
                              ),
                            ],
                            child: HoverRow(
                              key: ValueKey('fav ${f.conn.id.value} ${f.path}'),
                              leading: Icon(
                                CupertinoIcons.star_fill,
                                size: 20,
                                color: Palette.of(context).accent,
                              ),
                              title: Text(f.path),
                              subtitle: Text(f.conn.name),
                              hoverTrailing: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 13,
                              ),
                              onTap: () => openBrowser(ref, f.conn, f.path),
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

/// Opens [c] at [path], or at its 默认打开目录 when none is given.
void openBrowser(WidgetRef ref, ConnectionConfig c, [String? path]) {
  ref.read(openConnectionProvider.notifier).set(c);
  ref.read(browserDirProvider.notifier).set(path ?? normalizeDir(c.startDir));
  ref.read(browserSearchProvider.notifier).set('');
  ref.read(browserSelectionProvider.notifier).clear();
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref, [
  ConnectionConfig? existing,
  bool copy = false,
]) async {
  final passwords = ref.read(connectionPasswordsProvider);
  final draft = await showConnectionDialog(
    context,
    existing: existing,
    copy: copy,
    initialPassword: existing == null ? null : passwords[existing.id],
    tester: ref.read(connectionTesterProvider),
    lister: ref.read(connectionListerProvider),
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

    return ContextMenuArea(
      items: () => [
        MenuAction(
          '打开',
          () => openBrowser(ref, c),
          icon: CupertinoIcons.folder,
        ),
        MenuAction(
          '编辑',
          () => _edit(context, ref, c),
          icon: CupertinoIcons.pencil,
        ),
        MenuAction(
          '复制',
          () => _edit(context, ref, c, true),
          icon: CupertinoIcons.doc_on_doc,
        ),
        MenuAction(
          '重新检测',
          () => ref.invalidate(connectionStatusProvider(c.id)),
          icon: CupertinoIcons.arrow_clockwise,
        ),
        null,
        MenuAction(
          '删除',
          () => _delete(context, ref, c),
          icon: CupertinoIcons.trash,
          destructive: true,
        ),
      ],
      child: HoverRow(
        key: ValueKey('conn ${c.id.value}'),
        padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
        leading: IconTile(
          connectionTypeIcon(c.type),
          size: 34,
          color: connectionTypeColor(c.type),
          background: connectionTypeColor(c.type).withValues(alpha: 0.12),
        ),
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
                icon: const Icon(CupertinoIcons.arrow_clockwise),
                onPressed: () => ref.invalidate(connectionStatusProvider(c.id)),
              ),
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(CupertinoIcons.ellipsis, size: 16),
              onSelected: (v) {
                if (v == 'edit') _edit(context, ref, c);
                if (v == 'copy') _edit(context, ref, c, true);
                if (v == 'delete') _delete(context, ref, c);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'edit',
                  height: 30,
                  child: Text('编辑'),
                ),
                const PopupMenuItem(
                  value: 'copy',
                  height: 30,
                  child: Text('复制（同一服务器的另一个文件夹）'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  height: 30,
                  child: Text('删除', style: TextStyle(color: p.danger)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Posters of what one finished task organized; click opens its details.
class _RecentTask extends ConsumerWidget {
  final TaskSummary task;

  const _RecentTask({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final works = ref.watch(taskWorksProvider(task.id)).value ?? const [];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in works.take(4))
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Hoverable(
              key: ValueKey('recent ${task.id.value} ${w.tmdbId}'),
              onTap: () => context.go('/tasks/${task.id.value}'),
              builder: (context, hover) => AnimatedSlide(
                duration: const Duration(milliseconds: 160),
                offset: Offset(0, hover ? -0.02 : 0),
                child: SizedBox(
                  width: 92,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Poster(posterPath: w.posterPath, width: 92, height: 138),
                      const SizedBox(height: 6),
                      Text(
                        w.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: hover ? p.accent : p.text,
                        ),
                      ),
                      if (w.year != null)
                        Text(
                          '${w.year}',
                          style: TextStyle(fontSize: 11, color: p.textFaint),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
