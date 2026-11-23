import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../sources/connection_dialog.dart' show connectionTypeIcon;
import '../sources/folder_picker.dart';
import 'health_models.dart';
import 'health_providers.dart';

/// 轻量媒体库体检：重复片源画质对比、缺 NFO/海报一键刮削补全、垃圾与空目录清理。
class HealthPage extends ConsumerWidget {
  const HealthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conns = ref.watch(connectionsProvider);
    final state = ref.watch(healthControllerProvider);
    final ctrl = ref.read(healthControllerProvider.notifier);
    final selectedConn = conns
        .where((c) => c.id == state.selectedConnection)
        .firstOrNull;

    if (conns.isEmpty) {
      return PageScaffold(
        title: '体检',
        child: EmptyState(
          icon: CupertinoIcons.checkmark_shield,
          title: '还没有连接',
          message: '先在「来源」添加你的 Alist、WebDAV、SMB 或本地媒体库，再开始体检',
          action: OutlinedButton(
            onPressed: () => context.go('/sources'),
            child: const Text('去「来源」添加连接'),
          ),
        ),
      );
    }

    Future<void> pickFolder() async {
      if (selectedConn == null || state.scanning) return;
      final backend = ref.read(connectionBackendProvider(selectedConn.id));
      var initial = state.targetPath;
      try {
        if (!await backend.exists(initial)) initial = '/';
      } on Object {
        initial = '/';
      }
      if (!context.mounted) return;
      final picked = await showRemoteFolderPicker(
        context,
        title: '选择体检目录',
        initial: initial,
        list: (dir) => backend.list(dir),
      );
      if (picked != null) ctrl.setTargetPath(picked);
    }

    return PageScaffold(
      title: '体检',
      subtitle: selectedConn == null
          ? null
          : '只读扫描 ${selectedConn.name} · ${state.targetPath}',
      actions: [
        _ConnectionPicker(
          connections: conns,
          selected: selectedConn,
          enabled: !state.scanning,
          onSelected: ctrl.selectConnection,
        ),
        _PathChip(
          path: state.targetPath,
          favorites: selectedConn?.favorites ?? const [],
          libraryRoot: selectedConn?.libraryRoot,
          startDir: selectedConn?.startDir ?? '/',
          enabled: !state.scanning,
          onBrowse: pickFolder,
          onQuickSelect: ctrl.setTargetPath,
        ),
        if (state.report != null && !state.scanning)
          IconButton(
            tooltip: '忽略缓存重新扫描',
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 15),
            onPressed: () => ctrl.startScan(fresh: true),
          ),
        if (state.scanning)
          OutlinedButton.icon(
            key: const ValueKey('health-stop-scan'),
            onPressed: ctrl.cancelScan,
            icon: const Icon(CupertinoIcons.stop_fill, size: 12),
            label: const Text('停止'),
          )
        else
          FilledButton.icon(
            key: const ValueKey('health-start-scan'),
            onPressed: selectedConn == null ? null : () => ctrl.startScan(),
            icon: const Icon(CupertinoIcons.checkmark_shield, size: 14),
            label: Text(state.report == null ? '开始体检' : '重新体检'),
          ),
      ],
      child: _buildBody(context, state, ctrl, pickFolder),
    );
  }

  Widget _buildBody(
    BuildContext context,
    HealthState state,
    HealthController ctrl,
    Future<void> Function() pickFolder,
  ) {
    if (state.scanning) {
      return _ScanningView(
        progress: state.progress,
        targetPath: state.targetPath,
        onCancel: ctrl.cancelScan,
      );
    }

    if (state.error != null) {
      return EmptyState(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: '体检未能完成',
        message: state.error,
        action: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(onPressed: pickFolder, child: const Text('更换目录')),
            FilledButton(
              onPressed: () => ctrl.startScan(fresh: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    final report = state.report;
    if (report == null) {
      return EmptyState(
        icon: CupertinoIcons.checkmark_shield,
        title: '媒体库体检',
        message: '本地只读扫描重复片源、缺失 NFO/海报以及垃圾文件与空目录，绝不擅自改动文件',
        action: OutlinedButton.icon(
          onPressed: () => ctrl.startScan(),
          icon: const Icon(CupertinoIcons.play_fill, size: 12),
          label: const Text('开始体检'),
        ),
      );
    }

    return _ReportView(state: state, report: report, ctrl: ctrl);
  }
}

// ---- Top bar controls -----------------------------------------------------

class _ConnectionPicker extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final ConnectionConfig? selected;
  final bool enabled;
  final ValueChanged<ConnectionId> onSelected;

  const _ConnectionPicker({
    required this.connections,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopupMenuButton<ConnectionId>(
      key: const ValueKey('health-conn-picker'),
      enabled: enabled,
      tooltip: '选择连接',
      initialValue: selected?.id,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final c in connections)
          PopupMenuItem<ConnectionId>(
            value: c.id,
            height: 32,
            child: Row(
              children: [
                Icon(connectionTypeIcon(c.type), size: 14, color: p.textMuted),
                const SizedBox(width: 8),
                Text(c.name),
              ],
            ),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 10, right: 7),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected != null) ...[
              Icon(
                connectionTypeIcon(selected!.type),
                size: 13,
                color: p.textMuted,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              selected?.name ?? '选择连接',
              style: TextStyle(fontSize: TypeScale.small, color: p.text),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 10,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _PathChip extends StatelessWidget {
  final String path;
  final List<String> favorites;
  final String? libraryRoot;
  final String startDir;
  final bool enabled;
  final VoidCallback onBrowse;
  final ValueChanged<String> onQuickSelect;

  const _PathChip({
    required this.path,
    required this.favorites,
    required this.libraryRoot,
    required this.startDir,
    required this.enabled,
    required this.onBrowse,
    required this.onQuickSelect,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final quickDirs = <String>{
      if (libraryRoot != null && libraryRoot!.trim().isNotEmpty)
        normalizeDir(libraryRoot!),
      normalizeDir(startDir),
      for (final f in favorites) normalizeDir(f),
    }.toList();

    return PopupMenuButton<String>(
      key: const ValueKey('health-path-chip'),
      enabled: enabled,
      tooltip: '切换体检目录',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == '__browse__') {
          onBrowse();
        } else {
          onQuickSelect(value);
        }
      },
      itemBuilder: (_) => [
        for (final dir in quickDirs)
          PopupMenuItem<String>(
            value: dir,
            height: 32,
            child: Row(
              children: [
                Icon(
                  dir == path
                      ? CupertinoIcons.checkmark
                      : CupertinoIcons.folder,
                  size: 13,
                  color: dir == path ? p.accent : p.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  dir,
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontFamilyFallback: [...monoFallback, ...sansFallback],
                    fontSize: TypeScale.small,
                  ),
                ),
              ],
            ),
          ),
        if (quickDirs.isNotEmpty) const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          value: '__browse__',
          height: 32,
          child: Row(
            children: [
              Icon(CupertinoIcons.folder_open, size: 13),
              SizedBox(width: 8),
              Text('浏览选择其他目录…'),
            ],
          ),
        ),
      ],
      child: Container(
        height: 30,
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.folder, size: 13, color: p.textFaint),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TypeScale.small,
                  color: p.textMuted,
                  fontFamily: monoFamily,
                  fontFamilyFallback: [...monoFallback, ...sansFallback],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Scanning view --------------------------------------------------------

class _ScanningView extends StatelessWidget {
  final HealthScanProgress? progress;
  final String targetPath;
  final VoidCallback onCancel;

  const _ScanningView({
    required this.progress,
    required this.targetPath,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final prog = progress;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Panel(
          framed: true,
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Spinner(size: 16, color: p.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      prog?.phase.label ?? '正在扫描媒体库',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GradientProgress(
                value: prog?.fraction ?? 0.1,
                color: p.accent,
                height: 4,
              ),
              const SizedBox(height: 10),
              Text(
                prog?.message ?? '正在扫描 $targetPath…',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('停止'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Report view ----------------------------------------------------------

class _ReportView extends StatelessWidget {
  final HealthState state;
  final HealthReport report;
  final HealthController ctrl;

  const _ReportView({
    required this.state,
    required this.report,
    required this.ctrl,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final reclaimable = report.totalReclaimableBytes;

    if (report.totalIssues == 0) {
      return EmptyState(
        icon: CupertinoIcons.checkmark_seal,
        title: '媒体库很整洁',
        message:
            '已扫描 ${report.totalWorks} 部作品 · ${report.scannedFiles} 个文件，未发现重复片源、缺失元数据或垃圾文件',
      );
    }

    final summary = [
      '${report.totalWorks} 部作品',
      '${report.scannedFiles} 个文件',
      if (reclaimable > 0) '可释放 ${fmtSize(reclaimable)}',
    ].join(' · ');

    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 4, 40, 32),
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 10,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segmented<HealthCategory>(
              key: const ValueKey('health-category-tabs'),
              options: {
                HealthCategory.duplicates: '重复 ${report.duplicates.length}',
                HealthCategory.missingAssets:
                    '缺元数据 ${report.missingAssets.length}',
                HealthCategory.cleanup: '待清理 ${report.cleanupItems.length}',
              },
              value: state.category,
              onChanged: ctrl.setCategory,
            ),
            Text(
              summary,
              style: TextStyle(fontSize: TypeScale.small, color: p.textFaint),
            ),
          ],
        ),
        const SizedBox(height: 16),
        switch (state.category) {
          HealthCategory.duplicates => _DuplicatesSection(
            items: report.duplicates,
            busy: state.busyAction,
            ctrl: ctrl,
          ),
          HealthCategory.missingAssets => _MissingAssetsSection(
            items: report.missingAssets,
            selectedFolders: state.selectedMissingFolders,
            busy: state.busyAction,
            ctrl: ctrl,
          ),
          HealthCategory.cleanup => _CleanupSection(
            items: report.cleanupItems,
            selectedPaths: state.selectedCleanupPaths,
            busy: state.busyAction,
            ctrl: ctrl,
          ),
        },
      ],
    );
  }
}

// ---- Audit 1: Duplicates section ------------------------------------------

class _DuplicatesSection extends StatelessWidget {
  final List<DuplicateMediaIssue> items;
  final bool busy;
  final HealthController ctrl;

  const _DuplicatesSection({
    required this.items,
    required this.busy,
    required this.ctrl,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: '没有发现重复片源',
          message: '每部电影与每集剧集都只保存了一份副本',
        ),
      );
    }

    final p = Palette.of(context);
    final theme = Theme.of(context);

    Future<void> confirmAndDelete(List<String> paths) async {
      if (paths.isEmpty || busy) return;
      final ok = await confirmPermanentDelete(
        context,
        paths.length,
        paths: paths,
      );
      if (!ok || !context.mounted) return;
      try {
        final removed = await ctrl.deleteDuplicatePaths(paths);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('已删除 $removed 个冗余副本')));
        }
      } on Object catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Panel(
            framed: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
                  child: Row(
                    children: [
                      IconTile(
                        items[i].kind == MediaKind.movie
                            ? CupertinoIcons.film
                            : CupertinoIcons.tv,
                        size: 32,
                        outlined: true,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              items[i].title,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '共 ${items[i].copies.length} 份副本'
                              '${items[i].reclaimableBytes > 0 ? ' · 删除冗余可释放 ${fmtSize(items[i].reclaimableBytes)}' : ''}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('health-delete-dup-${items[i].id}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.danger,
                        ),
                        onPressed: busy
                            ? null
                            : () => confirmAndDelete([
                                for (final c in items[i].redundantCopies)
                                  c.path,
                              ]),
                        icon: const Icon(CupertinoIcons.trash, size: 13),
                        label: const Text('删除冗余副本'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Rows(
                  children: [
                    for (final copy in items[i].copies)
                      _DuplicateCopyRow(
                        copy: copy,
                        recommended: copy.path == items[i].recommendedKeepPath,
                        busy: busy,
                        onDelete: () => confirmAndDelete([copy.path]),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DuplicateCopyRow extends StatelessWidget {
  final DuplicateMediaCopy copy;
  final bool recommended;
  final bool busy;
  final VoidCallback onDelete;

  const _DuplicateCopyRow({
    required this.copy,
    required this.recommended,
    required this.busy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final badges = copy.qualityBadges;
    return Container(
      color: recommended ? p.success.withValues(alpha: 0.05) : null,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (recommended) Tag('推荐保留', color: p.success),
                    for (final b in badges) Tag(b),
                    if (copy.fileSize > 0)
                      Text(
                        fmtSize(copy.fileSize),
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          fontWeight: FontWeight.w500,
                          color: p.text,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  copy.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TypeScale.small,
                    color: p.textMuted,
                    fontFamily: monoFamily,
                    fontFamilyFallback: [...monoFallback, ...sansFallback],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '删除此副本',
            onPressed: busy ? null : onDelete,
            icon: Icon(CupertinoIcons.trash, size: 15, color: p.danger),
          ),
        ],
      ),
    );
  }
}

// ---- Audit 2: Missing Assets section --------------------------------------

class _MissingAssetsSection extends StatelessWidget {
  final List<MissingAssetIssue> items;
  final Set<String> selectedFolders;
  final bool busy;
  final HealthController ctrl;

  const _MissingAssetsSection({
    required this.items,
    required this.selectedFolders,
    required this.busy,
    required this.ctrl,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: 'NFO 与海报齐全',
          message: '所有扫描到的作品都已有 NFO 与海报文件',
        ),
      );
    }

    final p = Palette.of(context);

    Future<void> triggerScrapeOnly() async {
      try {
        final id = await ctrl.scrapeSelectedMissing();
        if (id != null && context.mounted) {
          context.go('/tasks/${id.value}');
        }
      } on Object catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('提交刮削任务失败：$e')));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '已选 ${selectedFolders.length} 项（仅生成缺失的 NFO 与海报，不改动视频文件）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton(
              onPressed: ctrl.selectAllMissingFolders,
              child: const Text('全选'),
            ),
            TextButton(
              onPressed: selectedFolders.isEmpty
                  ? null
                  : ctrl.clearMissingFolders,
              child: const Text('取消全选'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('health-scrape-missing'),
              onPressed: busy || selectedFolders.isEmpty
                  ? null
                  : triggerScrapeOnly,
              icon: const Icon(CupertinoIcons.sparkles, size: 14),
              label: const Text('一键仅刮削补全'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Panel(
          framed: true,
          child: Rows(
            indent: 84,
            children: [
              for (final item in items)
                HoverRow(
                  onTap: () => ctrl.toggleMissingFolder(item.folderPath),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: selectedFolders.contains(item.folderPath),
                        onChanged: (_) =>
                            ctrl.toggleMissingFolder(item.folderPath),
                      ),
                      const SizedBox(width: 8),
                      IconTile(
                        item.kind == MediaKind.movie
                            ? CupertinoIcons.film
                            : CupertinoIcons.tv,
                        size: 30,
                        outlined: true,
                      ),
                    ],
                  ),
                  title: Text(item.workTitle),
                  subtitle: Text(
                    item.folderPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: p.textFaint,
                      fontFamily: monoFamily,
                      fontFamilyFallback: [...monoFallback, ...sansFallback],
                    ),
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (item.missingNfo) Tag('缺 NFO', color: p.danger),
                      if (item.missingPoster) Tag('缺海报', color: p.warning),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Audit 3: Cleanup section ---------------------------------------------

class _CleanupSection extends StatelessWidget {
  final List<CleanupIssue> items;
  final Set<String> selectedPaths;
  final bool busy;
  final HealthController ctrl;

  const _CleanupSection({
    required this.items,
    required this.selectedPaths,
    required this.busy,
    required this.ctrl,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: '没有待清理项目',
          message: '未发现广告垃圾文件或空目录',
        ),
      );
    }

    final p = Palette.of(context);

    Future<void> confirmAndCleanup() async {
      final selectedItems = [
        for (final c in items)
          if (selectedPaths.contains(c.path)) c,
      ];
      if (selectedItems.isEmpty || busy) return;
      final filePaths = [
        for (final c in selectedItems)
          if (c.kind == CleanupKind.junkFile) c.path,
      ];
      final dirCount = selectedItems
          .where((c) => c.kind == CleanupKind.emptyDir)
          .length;

      final bool ok;
      if (filePaths.isNotEmpty) {
        ok = await confirmPermanentDelete(
          context,
          selectedItems.length,
          paths: [for (final c in selectedItems) c.path],
        );
      } else {
        ok = await confirmDialog(
          context,
          title: '删除 $dirCount 个空目录？',
          content: const Text('仅会删除确认为空（或仅含系统隐藏文件）的目录，删除前会再次实时校验。'),
          confirmLabel: '删除空目录',
          destructive: true,
        );
      }
      if (!ok || !context.mounted) return;
      try {
        final res = await ctrl.cleanupSelected();
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  '已清理 ${res.filesRemoved} 个垃圾文件、${res.dirsRemoved} 个空目录',
                ),
              ),
            );
        }
      } on Object catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('清理失败：$e')));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '已选 ${selectedPaths.length} 项',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton(
              onPressed: ctrl.selectAllCleanup,
              child: const Text('全选'),
            ),
            TextButton(
              onPressed: selectedPaths.isEmpty
                  ? null
                  : ctrl.clearCleanupSelection,
              child: const Text('取消全选'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('health-cleanup-selected'),
              style: OutlinedButton.styleFrom(foregroundColor: p.danger),
              onPressed: busy || selectedPaths.isEmpty
                  ? null
                  : confirmAndCleanup,
              icon: const Icon(CupertinoIcons.trash, size: 13),
              label: const Text('清理所选'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Panel(
          framed: true,
          child: Rows(
            indent: 84,
            children: [
              for (final item in items)
                HoverRow(
                  onTap: () => ctrl.toggleCleanupPath(item.path),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: selectedPaths.contains(item.path),
                        onChanged: (_) => ctrl.toggleCleanupPath(item.path),
                      ),
                      const SizedBox(width: 8),
                      IconTile(
                        item.kind == CleanupKind.emptyDir
                            ? CupertinoIcons.folder
                            : CupertinoIcons.doc_text,
                        size: 30,
                        outlined: true,
                      ),
                    ],
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    item.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: p.textFaint,
                      fontFamily: monoFamily,
                      fontFamilyFallback: [...monoFallback, ...sansFallback],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tag(
                        item.reason,
                        color: item.kind == CleanupKind.junkFile
                            ? p.danger
                            : p.warning,
                      ),
                      if (item.size > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          fmtSize(item.size),
                          style: TextStyle(
                            fontSize: TypeScale.small,
                            color: p.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
