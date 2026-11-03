import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../map/map_providers.dart';
import '../map/repo_map_view.dart';
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
    final add = OutlinedButton.icon(
      onPressed: () => _edit(context, ref),
      icon: const Icon(CupertinoIcons.plus, size: 13),
      label: const Text('添加连接'),
    );
    final p = Palette.of(context);
    final theme = Theme.of(context);
    if (conns.isEmpty) {
      return PageScaffold(
        title: '来源',
        child: EmptyState(
          icon: CupertinoIcons.cloud,
          title: '还没有连接',
          message: '添加一个 Alist、WebDAV 或本地文件夹，就可以开始整理了',
          action: add,
        ),
      );
    }
    final focusId = ref.watch(sourcesMapConnectionProvider);
    final focus = conns.firstWhere(
      (c) => c.id == focusId,
      orElse: () => conns.first,
    );
    final mapDir = focus.libraryRoot ?? normalizeDir(focus.startDir);
    final scanner = ref.watch(sizeScannerProvider(focus.id));

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 36, bottom: 10),
      child: Text(text, style: theme.textTheme.labelSmall),
    );

    final left = ListView(
      padding: const EdgeInsets.fromLTRB(48, 30, 32, 32),
      children: [
        Text(
          '来源',
          key: const ValueKey('page-title'),
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 28),
        ListenableBuilder(
          listenable: scanner,
          builder: (_, _) => RepoMapSummary(
            scanner: scanner,
            dir: mapDir,
            title: '${focus.name} · $mapDir',
          ),
        ),
        label('连接'),
        for (var i = 0; i < conns.length; i++)
          FadeIn(
            index: i,
            child: _ConnectionRow(
              connection: conns[i],
              focused: conns[i].id == focus.id,
              onFocus: () => ref
                  .read(sourcesMapConnectionProvider.notifier)
                  .set(conns[i].id),
            ),
          ),
        label('收藏'),
        if (favorites.isEmpty)
          Text(
            '打开一个连接，在文件夹右上角点 ☆ 收藏，常用的下载目录就会出现在这里',
            style: theme.textTheme.bodySmall,
          )
        else
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
              child: Hoverable(
                key: ValueKey('fav ${f.conn.id.value} ${f.path}'),
                onTap: () => openBrowser(ref, f.conn, f.path),
                builder: (_, hover) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: f.path,
                          style: TextStyle(
                            color: p.text,
                            decoration: hover
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: p.textFaint,
                          ),
                        ),
                        TextSpan(
                          text: '  ${f.conn.name}',
                          style: TextStyle(color: p.textFaint, fontSize: 12),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        if (done.isNotEmpty) ...[
          label('最近整理'),
          SizedBox(
            height: 128,
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
        const SizedBox(height: 36),
        Align(alignment: Alignment.centerLeft, child: add),
      ],
    );

    void openAt(String path, {required bool map}) {
      openBrowser(ref, focus, path);
      ref.read(browserMapModeProvider.notifier).set(map);
    }

    return LayoutBuilder(
      builder: (context, box) {
        // Narrow windows: the list alone; the map lives in the browser.
        if (box.maxWidth < 860) return left;
        final leftWidth = (box.maxWidth * 0.36).clamp(360.0, 460.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: leftWidth, child: left),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 24, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: RepoMapView(
                        key: ValueKey('sources-map ${focus.id.value}'),
                        connection: focus.id,
                        dir: mapDir,
                        showHeader: false,
                        onOpen: (path) => openAt(path, map: true),
                        onShowList: () => openAt(mapDir, map: false),
                        menuFor: (e) => [
                          if (e.isDir)
                            MenuAction(
                              '在地图中打开',
                              () => openAt(e.path, map: true),
                              icon: CupertinoIcons.circle_grid_hex,
                            ),
                          MenuAction(
                            '在列表中显示',
                            () => openAt(
                              e.isDir
                                  ? e.path
                                  : e.path.substring(
                                      0,
                                      e.path.lastIndexOf('/'),
                                    ),
                              map: false,
                            ),
                            icon: CupertinoIcons.list_bullet,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerRight,
                      child: MapLegend(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
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
  if (draft == null || !context.mounted) return;
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
  if (ok && context.mounted) {
    ref.read(connectionsEditorProvider.notifier).remove(c.id);
  }
}

/// One connection as two lines of text: name, then type · address · status.
/// The ring on the left picks which connection the map shows.
class _ConnectionRow extends ConsumerWidget {
  final ConnectionConfig connection;
  final bool focused;
  final VoidCallback onFocus;

  const _ConnectionRow({
    required this.connection,
    required this.focused,
    required this.onFocus,
  });

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
      child: Hoverable(
        key: ValueKey('conn ${c.id.value}'),
        onTap: () => openBrowser(ref, c),
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(0, 9, 0, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: focused ? '右侧地图正在显示' : '在右侧地图中查看',
                child: GestureDetector(
                  onTap: onFocus,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 6, 14, 6),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: focused ? p.text : Colors.transparent,
                        border: Border.all(
                          color: focused ? p.text : p.textFaint,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        color: focused || hover ? p.text : p.textMuted,
                        decoration: hover
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: p.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.textFaint),
                    ),
                    const SizedBox(height: 2),
                    StatusPill(label: label, color: color, busy: value == null),
                    if (failed && value.detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        value.detail!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: color, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              if (failed)
                IconButton(
                  tooltip: '重新检测',
                  icon: const Icon(CupertinoIcons.arrow_clockwise),
                  onPressed: () =>
                      ref.invalidate(connectionStatusProvider(c.id)),
                ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: hover || failed ? 1 : 0.35,
                child: PopupMenuButton<String>(
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
              ),
            ],
          ),
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
            padding: const EdgeInsets.only(right: 12),
            child: Hoverable(
              key: ValueKey('recent ${task.id.value} ${w.tmdbId}'),
              onTap: () => context.go('/tasks/${task.id.value}'),
              builder: (context, hover) => AnimatedSlide(
                duration: const Duration(milliseconds: 160),
                offset: Offset(0, hover ? -0.02 : 0),
                child: SizedBox(
                  width: 64,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Poster(posterPath: w.posterPath, width: 64, height: 96),
                      const SizedBox(height: 6),
                      Text(
                        w.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: hover ? p.text : p.textMuted,
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
