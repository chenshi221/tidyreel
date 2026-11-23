import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
    final conns = ref.watch(connectionsProvider);
    final state = ref.watch(healthControllerProvider);
    final ctrl = ref.read(healthControllerProvider.notifier);
    final selectedConn = conns
        .where((c) => c.id == state.selectedConnection)
        .firstOrNull;

    if (conns.isEmpty) {
      return PageScaffold(
        title: l10n.tr('体检', 'Health'),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_shield,
          title: l10n.tr('还没有连接', 'No Connections Yet'),
          message: l10n.tr(
            '先在「来源」添加你的 Alist、WebDAV、SMB 或本地媒体库，再开始体检',
            'Add an Alist, WebDAV, SMB, or local library in Sources before running a health check',
          ),
          action: OutlinedButton(
            onPressed: () => context.go('/sources'),
            child: Text(l10n.tr('去「来源」添加连接', 'Add Connection in Sources')),
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
        title: context.tr('选择体检目录', 'Choose Folder to Audit'),
        initial: initial,
        list: (dir) => backend.list(dir),
      );
      if (picked != null) ctrl.setTargetPath(picked);
    }

    return PageScaffold(
      title: l10n.tr('体检', 'Health'),
      subtitle: selectedConn == null
          ? null
          : l10n.tr(
              '只读扫描 ${selectedConn.name} · ${state.targetPath}',
              'Read-only scan of ${selectedConn.name} · ${state.targetPath}',
            ),
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
            tooltip: l10n.tr('忽略缓存重新扫描', 'Rescan ignoring cache'),
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 15),
            onPressed: () => ctrl.startScan(fresh: true),
          ),
        if (state.scanning)
          OutlinedButton.icon(
            key: const ValueKey('health-stop-scan'),
            onPressed: ctrl.cancelScan,
            icon: const Icon(CupertinoIcons.stop_fill, size: 12),
            label: Text(l10n.tr('停止', 'Stop')),
          )
        else
          FilledButton.icon(
            key: const ValueKey('health-start-scan'),
            onPressed: selectedConn == null ? null : () => ctrl.startScan(),
            icon: const Icon(CupertinoIcons.checkmark_shield, size: 14),
            label: Text(
              state.report == null
                  ? l10n.tr('开始体检', 'Start Audit')
                  : l10n.tr('重新体检', 'Scan Again'),
            ),
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
    final l10n = context.l10n;
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
        title: l10n.tr('体检未能完成', 'Audit Failed'),
        message: l10n.coreMessage(state.error!),
        action: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: pickFolder,
              child: Text(l10n.tr('更换目录', 'Change Folder')),
            ),
            FilledButton(
              onPressed: () => ctrl.startScan(fresh: true),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }

    final report = state.report;
    if (report == null) {
      return EmptyState(
        icon: CupertinoIcons.checkmark_shield,
        title: l10n.tr('媒体库体检', 'Library Health Check'),
        message: l10n.tr(
          '本地只读扫描重复片源、缺失 NFO/海报以及垃圾文件与空目录，绝不擅自改动文件',
          'Read-only scan for duplicate copies, missing NFO/posters, junk files, and empty folders — never modifies files without your confirmation',
        ),
        action: OutlinedButton.icon(
          onPressed: () => ctrl.startScan(),
          icon: const Icon(CupertinoIcons.play_fill, size: 12),
          label: Text(l10n.tr('开始体检', 'Start Audit')),
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
    final l10n = context.l10n;
    return PopupMenuButton<ConnectionId>(
      key: const ValueKey('health-conn-picker'),
      enabled: enabled,
      tooltip: l10n.tr('选择连接', 'Select Connection'),
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
              selected?.name ?? l10n.tr('选择连接', 'Select Connection'),
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
    final l10n = context.l10n;
    final quickDirs = <String>{
      if (libraryRoot != null && libraryRoot!.trim().isNotEmpty)
        normalizeDir(libraryRoot!),
      normalizeDir(startDir),
      for (final f in favorites) normalizeDir(f),
    }.toList();

    return PopupMenuButton<String>(
      key: const ValueKey('health-path-chip'),
      enabled: enabled,
      tooltip: l10n.tr('切换体检目录', 'Change Audit Folder'),
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
        PopupMenuItem<String>(
          value: '__browse__',
          height: 32,
          child: Row(
            children: [
              const Icon(CupertinoIcons.folder_open, size: 13),
              const SizedBox(width: 8),
              Text(l10n.tr('浏览选择其他目录…', 'Browse Another Folder…')),
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
    final l10n = context.l10n;
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
                      prog?.phase.localizedLabel(l10n) ??
                          l10n.tr('正在扫描媒体库', 'Scanning media library'),
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
                prog != null
                    ? l10n.coreMessage(prog.message)
                    : l10n.tr('正在扫描 $targetPath…', 'Scanning $targetPath…'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: Text(l10n.tr('停止', 'Stop')),
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
    final l10n = context.l10n;
    final reclaimable = report.totalReclaimableBytes;

    if (report.totalIssues == 0) {
      return EmptyState(
        icon: CupertinoIcons.checkmark_seal,
        title: l10n.tr('媒体库很整洁', 'Library Looks Clean'),
        message: l10n.tr(
          '已扫描 ${report.totalWorks} 部作品 · ${report.scannedFiles} 个文件，未发现重复片源、缺失元数据或垃圾文件',
          'Scanned ${l10n.plural(report.totalWorks, 'title')} · '
              '${l10n.plural(report.scannedFiles, 'file')}. '
              'No duplicates, missing metadata, or junk files found.',
        ),
      );
    }

    final summary = [
      l10n.tr(
        '${report.totalWorks} 部作品',
        l10n.plural(report.totalWorks, 'title'),
      ),
      l10n.tr(
        '${report.scannedFiles} 个文件',
        l10n.plural(report.scannedFiles, 'file'),
      ),
      if (reclaimable > 0)
        l10n.tr(
          '可释放 ${fmtSize(reclaimable)}',
          '${fmtSize(reclaimable)} reclaimable',
        ),
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
                HealthCategory.duplicates:
                    '${HealthCategory.duplicates.localizedLabel(l10n)} ${report.duplicates.length}',
                HealthCategory.missingAssets:
                    '${HealthCategory.missingAssets.localizedLabel(l10n)} ${report.missingAssets.length}',
                HealthCategory.cleanup:
                    '${HealthCategory.cleanup.localizedLabel(l10n)} ${report.cleanupItems.length}',
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
    final l10n = context.l10n;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: l10n.tr('没有发现重复片源', 'No Duplicates Found'),
          message: l10n.tr(
            '每部电影与每集剧集都只保存了一份副本',
            'Every movie and episode has only a single copy',
          ),
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
          final t = context.l10n;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.tr(
                    '已删除 $removed 个冗余副本',
                    'Deleted ${t.plural(removed, 'redundant copy', 'redundant copies')}',
                  ),
                ),
              ),
            );
        }
      } on Object catch (e) {
        if (context.mounted) {
          final t = context.l10n;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.tr('删除失败：$e', 'Delete failed: ${t.coreMessage('$e')}'),
                ),
              ),
            );
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
                              l10n.tr(
                                '共 ${items[i].copies.length} 份副本'
                                    '${items[i].reclaimableBytes > 0 ? ' · 删除冗余可释放 ${fmtSize(items[i].reclaimableBytes)}' : ''}',
                                '${items[i].copies.length} copies'
                                    '${items[i].reclaimableBytes > 0 ? ' · ${fmtSize(items[i].reclaimableBytes)} reclaimable' : ''}',
                              ),
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
                        label: Text(l10n.tr('删除冗余副本', 'Delete Redundant')),
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
    final l10n = context.l10n;
    final badges = copy.localizedQualityBadges(l10n);
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
                    if (recommended)
                      Tag(l10n.tr('推荐保留', 'Recommended'), color: p.success),
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
            tooltip: l10n.tr('删除此副本', 'Delete This Copy'),
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
    final l10n = context.l10n;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: l10n.tr('NFO 与海报齐全', 'All Metadata Present'),
          message: l10n.tr(
            '所有扫描到的作品都已有 NFO 与海报文件',
            'All scanned titles already have NFO files and posters',
          ),
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
          final t = context.l10n;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.tr(
                    '提交刮削任务失败：$e',
                    'Failed to submit scrape task: ${t.coreMessage('$e')}',
                  ),
                ),
              ),
            );
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.tr(
                '已选 ${selectedFolders.length} 项（仅生成缺失的 NFO 与海报，不改动视频文件）',
                '${selectedFolders.length} selected (writes missing NFO & artwork only; video files stay untouched)',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton(
              onPressed: ctrl.selectAllMissingFolders,
              child: Text(l10n.tr('全选', 'Select All')),
            ),
            TextButton(
              onPressed: selectedFolders.isEmpty
                  ? null
                  : ctrl.clearMissingFolders,
              child: Text(l10n.tr('取消全选', 'Deselect All')),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('health-scrape-missing'),
              onPressed: busy || selectedFolders.isEmpty
                  ? null
                  : triggerScrapeOnly,
              icon: const Icon(CupertinoIcons.sparkles, size: 14),
              label: Text(l10n.tr('一键仅刮削补全', 'Scrape Missing')),
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
                      if (item.missingNfo)
                        Tag(l10n.tr('缺 NFO', 'No NFO'), color: p.danger),
                      if (item.missingPoster)
                        Tag(l10n.tr('缺海报', 'No Poster'), color: p.warning),
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
    final l10n = context.l10n;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: CupertinoIcons.checkmark_circle,
          title: l10n.tr('没有待清理项目', 'Nothing to Clean Up'),
          message: l10n.tr(
            '未发现广告垃圾文件或空目录',
            'No ad/junk files or empty folders found',
          ),
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
          title: l10n.tr(
            '删除 $dirCount 个空目录？',
            'Delete ${l10n.plural(dirCount, 'empty folder')}?',
          ),
          content: Text(
            l10n.tr(
              '仅会删除确认为空（或仅含系统隐藏文件）的目录，删除前会再次实时校验。',
              'Only folders verified to be empty (or containing only OS hidden files) will be removed after a live re-check.',
            ),
          ),
          confirmLabel: l10n.tr('删除空目录', 'Delete Empty Folders'),
          destructive: true,
        );
      }
      if (!ok || !context.mounted) return;
      try {
        final res = await ctrl.cleanupSelected();
        if (context.mounted) {
          final t = context.l10n;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.tr(
                    '已清理 ${res.filesRemoved} 个垃圾文件、${res.dirsRemoved} 个空目录',
                    'Cleaned ${t.plural(res.filesRemoved, 'junk file')} and ${t.plural(res.dirsRemoved, 'empty folder')}',
                  ),
                ),
              ),
            );
        }
      } on Object catch (e) {
        if (context.mounted) {
          final t = context.l10n;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.tr('清理失败：$e', 'Cleanup failed: ${t.coreMessage('$e')}'),
                ),
              ),
            );
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.tr(
                '已选 ${selectedPaths.length} 项',
                '${selectedPaths.length} selected',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton(
              onPressed: ctrl.selectAllCleanup,
              child: Text(l10n.tr('全选', 'Select All')),
            ),
            TextButton(
              onPressed: selectedPaths.isEmpty
                  ? null
                  : ctrl.clearCleanupSelection,
              child: Text(l10n.tr('取消全选', 'Deselect All')),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('health-cleanup-selected'),
              style: OutlinedButton.styleFrom(foregroundColor: p.danger),
              onPressed: busy || selectedPaths.isEmpty
                  ? null
                  : confirmAndCleanup,
              icon: const Icon(CupertinoIcons.trash, size: 13),
              label: Text(l10n.tr('清理所选', 'Clean Selected')),
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
                        l10n.coreMessage(item.reason),
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
