import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'review_logic.dart';

/// Picker dialog to merge [source] into another group in [candidates].
/// Returns the selected `keep` [GroupId], or null when cancelled.
Future<GroupId?> showMergeGroupPicker(
  BuildContext context, {
  required MediaGroup source,
  required List<MediaGroup> candidates,
  required Map<GroupId, GroupDecision> decisions,
}) {
  GroupId? picked;
  final sourceTitle =
      effectiveMatch(source, decisions[source.id])?.title ?? source.anchorTitle;
  return showDialog<GroupId>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final p = Palette.of(ctx);
        final theme = Theme.of(ctx);
        return MacSheet(
          child: SizedBox(
            width: 480,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('合并到其他作品', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '将「$sourceTitle」中的 ${source.files.length} 个文件合并到选中的作品，原分组将被移除。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: Panel(
                      framed: true,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final g in candidates)
                            Builder(
                              builder: (context) {
                                final m = effectiveMatch(g, decisions[g.id]);
                                final title = m?.title ?? g.anchorTitle;
                                final isSelected = picked == g.id;
                                final isTv =
                                    effectiveGroup(g, decisions[g.id]).kind ==
                                    MediaKind.episode;
                                return Hoverable(
                                  key: ValueKey('merge-target-${g.id.value}'),
                                  onTap: () => setState(() => picked = g.id),
                                  builder: (context, hover) => Container(
                                    color: isSelected
                                        ? p.selected
                                        : (hover
                                              ? p.hover
                                              : Colors.transparent),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected
                                              ? CupertinoIcons
                                                    .largecircle_fill_circle
                                              : CupertinoIcons.circle,
                                          size: 15,
                                          color: isSelected
                                              ? p.text
                                              : p.lineStrong,
                                        ),
                                        const SizedBox(width: 10),
                                        Poster(
                                          posterPath: m?.posterPath,
                                          icon: isTv
                                              ? CupertinoIcons.tv
                                              : CupertinoIcons.film,
                                          width: 30,
                                          height: 45,
                                          radius: 4,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                m?.year == null
                                                    ? title
                                                    : '$title (${m!.year})',
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                '${g.files.length} 个文件 · ${g.rootDir}',
                                                style: TextStyle(
                                                  fontSize: TypeScale.small,
                                                  color: p.textMuted,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('merge-group-confirm'),
                        onPressed: picked == null
                            ? null
                            : () => Navigator.pop(ctx, picked),
                        child: const Text('确认合并'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Checklist dialog to split selected files out of [group] into a new group.
/// Returns the set of file paths to split out, or null when cancelled.
Future<Set<String>?> showSplitGroupDialog(
  BuildContext context, {
  required MediaGroup group,
}) {
  final picked = <String>{};
  final files = [...group.files]..sort((a, b) => a.path.compareTo(b.path));
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final p = Palette.of(ctx);
        final theme = Theme.of(ctx);
        final canConfirm = picked.isNotEmpty && picked.length < files.length;
        return MacSheet(
          child: SizedBox(
            width: 520,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('拆分分组', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '勾选要拆分到新作品的文件（需至少选择 1 个文件，且原分组至少保留 1 个文件）。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: Panel(
                      framed: true,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final f in files)
                            Builder(
                              builder: (context) {
                                final checked = picked.contains(f.path);
                                final roleLabel = switch (f.role) {
                                  FileRole.video => null,
                                  FileRole.subtitle => '字幕',
                                  FileRole.sidecar => '附属',
                                  FileRole.junk => '垃圾',
                                  FileRole.other => '其他',
                                };
                                void toggle() => setState(() {
                                  if (checked) {
                                    picked.remove(f.path);
                                  } else {
                                    picked.add(f.path);
                                  }
                                });
                                return Hoverable(
                                  onTap: toggle,
                                  builder: (context, hover) => Container(
                                    color: hover ? p.hover : Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 28,
                                          child: Checkbox(
                                            key: ValueKey(
                                              'split-file-${f.path}',
                                            ),
                                            value: checked,
                                            onChanged: (_) => toggle(),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            f.name,
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (roleLabel != null) ...[
                                          const SizedBox(width: 8),
                                          Tag(roleLabel),
                                        ],
                                        if (f.size > 0) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                            fmtSize(f.size),
                                            style: TextStyle(
                                              fontSize: TypeScale.small,
                                              color: p.textFaint,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Text(
                        '已选 ${picked.length} / ${files.length} 个文件',
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          color: p.textMuted,
                        ),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('split-group-confirm'),
                        onPressed: canConfirm
                            ? () => Navigator.pop(ctx, Set<String>.of(picked))
                            : null,
                        child: Text('拆分为新作品 (${picked.length})'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
