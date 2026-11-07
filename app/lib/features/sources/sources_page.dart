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
    ].take(3).toList();
    final favorites = [
      for (final c in conns)
        for (final f in c.favorites) (conn: c, path: f),
    ];
    final add = OutlinedButton.icon(
      onPressed: () => _edit(context, ref),
      icon: const Icon(CupertinoIcons.plus, size: 13),
      label: const Text('添加连接'),
    );
    final theme = Theme.of(context);
    if (conns.isEmpty) {
      return PageScaffold(
        title: '来源',
        child: EmptyState(
          icon: CupertinoIcons.cloud,
          title: '还没有连接',
          message: '添加一个 Alist、WebDAV、SMB 共享或本地文件夹，就可以开始整理了',
          action: add,
        ),
      );
    }
    Widget label(String text, IconData icon) => Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 13, color: theme.textTheme.labelSmall?.color),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.labelSmall),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 30, 32, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '来源',
                key: const ValueKey('page-title'),
                style: theme.textTheme.displaySmall,
              ),
            ),
            add,
          ],
        ),
        const SizedBox(height: 8),
        label('连接', CupertinoIcons.link),
        Panel(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
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
        label('收藏', CupertinoIcons.star),
        if (favorites.isEmpty)
          Text('打开一个文件夹，点右上角的 ☆，常用目录就会出现在这里', style: theme.textTheme.bodySmall)
        else
          Panel(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Rows(
              children: [
                for (final f in favorites)
                  _FavoriteRow(connection: f.conn, path: f.path),
              ],
            ),
          ),
        if (done.isNotEmpty) ...[
          label('最近整理', CupertinoIcons.clock),
          Wrap(
            spacing: 20,
            runSpacing: 16,
            children: [
              for (var i = 0; i < done.length; i++)
                FadeIn(
                  index: i,
                  child: _RecentTask(task: done[i]),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Opens [c] at [path], or at its 连接路径 when none is given or [path] (an old
/// favorite, say) lies above it.
void openBrowser(WidgetRef ref, ConnectionConfig c, [String? path]) {
  ref.read(openConnectionProvider.notifier).set(c);
  final root = normalizeDir(c.startDir);
  ref
      .read(browserDirProvider.notifier)
      .set(path != null && isWithinDir(path, root) ? path : root);
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

/// Deletes at once and offers 撤销: only the config and saved password go,
/// never a file, so a confirmation dialog would be noise.
void _delete(BuildContext context, WidgetRef ref, ConnectionConfig c) {
  final password = ref.read(connectionPasswordsProvider)[c.id];
  ref.read(connectionsEditorProvider.notifier).remove(c.id);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('已删除「${c.name}」'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            ref.read(connectionsEditorProvider.notifier).upsert(c);
            if (password != null) {
              ref.read(connectionPasswordsProvider.notifier).set({
                ...ref.read(connectionPasswordsProvider),
                c.id: password,
              });
            }
          },
        ),
      ),
    );
}

/// One connection as two lines of text: name, then type, address and status.
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
    final start = normalizeDir(c.startDir);

    List<MenuAction?> menu() => [
      MenuAction('打开', () => openBrowser(ref, c), icon: CupertinoIcons.folder),
      MenuAction(
        '编辑',
        () => _edit(context, ref, c),
        icon: CupertinoIcons.pencil,
      ),
      MenuAction(
        '复制为新连接',
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
    ];
    return ContextMenuArea(
      items: menu,
      child: Hoverable(
        key: ValueKey('conn ${c.id.value}'),
        onTap: () => openBrowser(ref, c),
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(0, 9, 0, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconTile(connectionTypeIcon(c.type), size: 40, outlined: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TypeScale.headline,
                        fontWeight: FontWeight.w500,
                        color: p.text,
                        decoration: hover
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: p.textFaint,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        _TypeTag(connectionTypeLabel(c.type)),
                        const SizedBox(width: 10),
                        Flexible(child: _Meta(null, c.endpoint, mono: true)),
                        if (start != '/') ...[
                          const SizedBox(width: 14),
                          Flexible(child: _Meta(CupertinoIcons.folder, start)),
                        ],
                        if (c.libraryRoot != null) ...[
                          const SizedBox(width: 14),
                          Flexible(
                            child: _Meta(
                              CupertinoIcons.tray_arrow_down,
                              c.libraryRoot!,
                              tooltip: '媒体库',
                            ),
                          ),
                        ],
                      ],
                    ),
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
              ),
              const SizedBox(width: 12),
              StatusPill(label: label, color: color, busy: value == null),
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
                child: MoreButton(items: menu),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A favorite folder: same two lines and … menu as a connection.
class _FavoriteRow extends ConsumerWidget {
  final ConnectionConfig connection;
  final String path;

  const _FavoriteRow({required this.connection, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '根目录';
    List<MenuAction?> menu() => [
      MenuAction(
        '打开',
        () => openBrowser(ref, connection, path),
        icon: CupertinoIcons.folder,
      ),
      MenuAction(
        '取消收藏',
        () => ref
            .read(connectionsEditorProvider.notifier)
            .toggleFavorite(connection.id, path),
        icon: CupertinoIcons.star_slash,
        destructive: true,
      ),
    ];
    return ContextMenuArea(
      items: menu,
      child: Hoverable(
        key: ValueKey('fav ${connection.id.value} $path'),
        onTap: () => openBrowser(ref, connection, path),
        builder: (context, hover) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            children: [
              IconTile(CupertinoIcons.star, size: 40, outlined: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TypeScale.headline,
                        fontWeight: FontWeight.w500,
                        color: p.text,
                        decoration: hover
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: p.textFaint,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        _TypeTag(connection.name),
                        const SizedBox(width: 10),
                        Flexible(child: _Meta(null, path, mono: true)),
                      ],
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: hover ? 1 : 0.35,
                child: MoreButton(items: menu),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The latest finished task as one large poster (its first work).
class _RecentTask extends ConsumerWidget {
  final TaskSummary task;

  const _RecentTask({required this.task});

  static const _w = 148.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final works = ref.watch(taskWorksProvider(task.id)).value ?? const [];
    final w = works.firstOrNull;
    final title = w == null
        ? task.paths.first.split('/').where((s) => s.isNotEmpty).lastOrNull ??
              '根目录'
        : works.length > 1
        ? '${w.title} 等 ${works.length} 部'
        : w.title;
    return Hoverable(
      key: ValueKey('recent ${task.id.value}'),
      onTap: () => context.go('/tasks/${task.id.value}?from=sources'),
      builder: (context, hover) => AnimatedSlide(
        duration: const Duration(milliseconds: 160),
        offset: Offset(0, hover ? -0.015 : 0),
        child: SizedBox(
          width: _w,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Poster(
                posterPath: w?.posterPath,
                icon: CupertinoIcons.folder,
                width: _w,
                height: _w * 1.5,
                radius: Radii.lg,
              ),
              const SizedBox(height: 10),
              HoverMarquee(
                text: title,
                active: hover,
                style: TextStyle(
                  fontSize: TypeScale.body,
                  fontWeight: FontWeight.w500,
                  color: p.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (w?.year != null) '${w!.year}',
                  '${task.videoCount} 个视频',
                ].join('  '),
                style: TextStyle(fontSize: TypeScale.small, color: p.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Connection type (or owning connection) as a small framed tag.
class _TypeTag extends StatelessWidget {
  final String text;

  const _TypeTag(this.text);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: p.lineStrong, width: hairline),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: TypeScale.small, color: p.textMuted),
      ),
    );
  }
}

/// One fact on the second line: an optional glyph and the value. Addresses and
/// paths use the mono face so they read as data.
class _Meta extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool mono;
  final String? tooltip;

  const _Meta(this.icon, this.text, {this.mono = false, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: p.textFaint),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: TypeScale.small,
              color: p.textMuted,
              fontFamily: mono ? monoFamily : null,
              // Paths hold CJK names; the mono face has no such glyphs.
              fontFamilyFallback: mono
                  ? [...monoFallback, ...sansFallback]
                  : null,
            ),
          ),
        ),
      ],
    );
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }
}
