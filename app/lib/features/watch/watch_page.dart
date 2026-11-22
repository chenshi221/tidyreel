import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/watch_rules_store.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../sources/connection_dialog.dart' show connectionTypeIcon;
import 'watch_rule_dialog.dart';
import 'watch_service.dart';

/// 轻量化追更监控页：本地目录实时监听 / 远程网盘定时轮询（无 Webhook）。
class WatchPage extends ConsumerWidget {
  const WatchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conns = ref.watch(connectionsProvider);
    final rulesAsync = ref.watch(watchRulesProvider);
    final runtimeMap =
        ref.watch(watchRuntimeProvider).value ??
        const <String, WatchRuleRuntimeState>{};
    final isDemo = ref.watch(bootstrapProvider).demo;

    Future<void> openEditor([WatchRule? existing]) async {
      if (conns.isEmpty) {
        context.go('/sources');
        return;
      }
      final saved = await showWatchRuleDialog(
        context,
        connections: conns,
        existing: existing,
        isDemo: isDemo,
        remoteLister: (connId, dir) =>
            ref.read(connectionBackendProvider(connId)).list(dir),
      );
      if (saved == null || !context.mounted) return;
      await ref.read(watchRulesStoreProvider).upsert(saved);
    }

    final addBtn = OutlinedButton.icon(
      key: const ValueKey('add-watch-rule'),
      onPressed: conns.isEmpty ? null : () => openEditor(),
      icon: const Icon(CupertinoIcons.plus, size: 13),
      label: const Text('添加监控目录'),
    );

    final rules = rulesAsync.value ?? const <WatchRule>[];
    final activeCount = rules.where((r) => r.enabled).length;

    return PageScaffold(
      title: '追更',
      subtitle: rules.isEmpty
          ? null
          : '已启用 $activeCount / ${rules.length} 个监控目录 · 自动跳过未完成下载并等待大小稳定',
      actions: [addBtn],
      child: rulesAsync.when(
        loading: () => const Center(child: Spinner(size: 20)),
        error: (e, _) => EmptyState(
          icon: CupertinoIcons.exclamationmark_triangle,
          title: '无法加载追更规则',
          message: '$e',
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: CupertinoIcons.dot_radiowaves_left_right,
              title: '轻量化追更监控',
              message: '本地目录实时监听 / 远程网盘定时轮询，自动跳过 .aria2 / .!qB / .part 等未完成下载并等待文件大小稳定后再识别，无需配置 Webhook',
              action: conns.isEmpty
                  ? OutlinedButton(
                      onPressed: () => context.go('/sources'),
                      child: const Text('先去「来源」添加连接'),
                    )
                  : FilledButton.icon(
                      onPressed: () => openEditor(),
                      icon: const Icon(CupertinoIcons.plus, size: 13),
                      label: const Text('添加监控目录'),
                    ),
            );
          }

          final connById = {for (final c in conns) c.id: c};
          return ListView(
            padding: const EdgeInsets.fromLTRB(48, 0, 40, 32),
            children: [
              const SectionLabel('监控目录'),
              Panel(
                framed: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                child: Rows(
                  indent: 54,
                  children: [
                    for (var i = 0; i < list.length; i++)
                      FadeIn(
                        index: i,
                        child: _WatchRuleRow(
                          rule: list[i],
                          connection: connById[list[i].connection],
                          runtime:
                              runtimeMap[list[i].id] ??
                              const WatchRuleRuntimeState(),
                          onEdit: () => openEditor(list[i]),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WatchRuleRow extends ConsumerWidget {
  final WatchRule rule;
  final ConnectionConfig? connection;
  final WatchRuleRuntimeState runtime;
  final VoidCallback onEdit;

  const _WatchRuleRow({
    required this.rule,
    required this.connection,
    required this.runtime,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final isLocal = connection?.type == ConnectionType.local;
    final store = ref.read(watchRulesStoreProvider);
    final service = ref.read(watchServiceProvider);

    Future<void> toggle(bool enabled) async {
      await store.upsert(rule.copyWith(enabled: enabled));
    }

    Future<void> triggerNow() async {
      await service.triggerNow(rule.id);
    }

    Future<void> deleteRule() async {
      final ok = await confirmDialog(
        context,
        title: '删除监控规则？',
        content: Text('将停止监控「${rule.path}」，不会删除任何本地或远程文件。'),
        confirmLabel: '删除',
        destructive: true,
      );
      if (!ok) return;
      await store.delete(rule.id);
    }

    List<MenuAction?> menu() => [
      MenuAction('立即检查', triggerNow, icon: CupertinoIcons.arrow_clockwise),
      MenuAction('编辑', onEdit, icon: CupertinoIcons.pencil),
      MenuAction(
        rule.enabled ? '暂停监控' : '启用监控',
        () => toggle(!rule.enabled),
        icon: rule.enabled ? CupertinoIcons.pause : CupertinoIcons.play,
      ),
      null,
      MenuAction(
        '删除',
        deleteRule,
        icon: CupertinoIcons.trash,
        destructive: true,
      ),
    ];

    final statusLabel = runtime.checking
        ? '检查中'
        : (rule.enabled ? (isLocal ? '实时监听' : '轮询中') : '已暂停');
    final statusColor = runtime.checking
        ? p.accent
        : (rule.enabled ? p.success : p.textFaint);

    return ContextMenuArea(
      items: menu,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconTile(
              connection == null
                  ? CupertinoIcons.folder
                  : connectionTypeIcon(connection!.type),
              size: 40,
              outlined: true,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          pathBasename(rule.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TypeScale.headline,
                            fontWeight: FontWeight.w500,
                            color: rule.enabled ? p.text : p.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusPill(
                        label: statusLabel,
                        color: statusColor,
                        busy: runtime.checking,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _FramedTag(connection?.name ?? rule.connection.value),
                      Tag(isLocal ? '实时监听' : '每 ${rule.intervalMinutes} 分钟轮询'),
                      Tag(
                        rule.mode == OrganizeMode.inPlace ? '原地整理' : '移动到媒体库',
                      ),
                      if (rule.scrape) const Tag('刮削'),
                      Tag(
                        rule.autoRunHighConfidence ? '高置信自动执行' : '仅自动识别待确认',
                        color: rule.autoRunHighConfidence
                            ? p.warning
                            : p.textMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    rule.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: p.textMuted,
                      fontFamily: monoFamily,
                      fontFamilyFallback: [...monoFallback, ...sansFallback],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _formatLastRun(rule.lastScanAt, rule.lastStatus),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: p.textFaint,
                          ),
                        ),
                      ),
                      if (runtime.pendingUnstableCount > 0) ...[
                        const SizedBox(width: 8),
                        Tag(
                          '等待 ${runtime.pendingUnstableCount} 个文件稳定',
                          color: p.warning,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              key: ValueKey('watch-trigger-${rule.id}'),
              tooltip: '立即检查',
              onPressed: runtime.checking ? null : triggerNow,
              icon: runtime.checking
                  ? const Spinner(size: 14)
                  : const Icon(CupertinoIcons.arrow_clockwise, size: 15),
            ),
            IconButton(
              key: ValueKey('watch-edit-${rule.id}'),
              tooltip: '编辑',
              onPressed: onEdit,
              icon: const Icon(CupertinoIcons.pencil, size: 15),
            ),
            IconButton(
              key: ValueKey('watch-delete-${rule.id}'),
              tooltip: '删除',
              onPressed: deleteRule,
              icon: Icon(CupertinoIcons.trash, size: 15, color: p.danger),
            ),
            const SizedBox(width: 4),
            MacSwitch(
              key: ValueKey('watch-toggle-${rule.id}'),
              value: rule.enabled,
              onChanged: toggle,
            ),
          ],
        ),
      ),
    );
  }

  static String _formatLastRun(DateTime? lastScanAt, String lastStatus) {
    if (lastScanAt == null && lastStatus.isEmpty) return '尚未检查';
    final parts = <String>[];
    if (lastScanAt != null) {
      final local = lastScanAt.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      parts.add('上次检查 ${fmtDate(local)} $hh:$mm');
    }
    if (lastStatus.isNotEmpty) parts.add(lastStatus);
    return parts.join(' · ');
  }
}

class _FramedTag extends StatelessWidget {
  final String text;

  const _FramedTag(this.text);

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
