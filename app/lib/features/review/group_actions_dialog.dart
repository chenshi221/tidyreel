import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../l10n/l10n.dart';
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
        final l10n = ctx.l10n;
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
                  Text(
                    l10n.tr('合并到其他作品', 'Merge into Another Title'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.tr(
                      '将「$sourceTitle」中的 ${source.files.length} 个文件合并到选中的作品，原分组将被移除。',
                      'Move ${l10n.plural(source.files.length, 'file')} from "$sourceTitle" into the selected title. The original group will be removed.',
                    ),
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
                                                '${l10n.tr('${g.files.length} 个文件', l10n.plural(g.files.length, 'file'))} · ${g.rootDir}',
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
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('merge-group-confirm'),
                        onPressed: picked == null
                            ? null
                            : () => Navigator.pop(ctx, picked),
                        child: Text(l10n.tr('确认合并', 'Merge')),
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
        final l10n = ctx.l10n;
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
                  Text(
                    l10n.tr('拆分分组', 'Split Group'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.tr(
                      '勾选要拆分到新作品的文件（需至少选择 1 个文件，且原分组至少保留 1 个文件）。',
                      'Select files to move into a new title (pick at least 1 file and leave at least 1 file in the original group).',
                    ),
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
                                  FileRole.subtitle => l10n.tr('字幕', 'Sub'),
                                  FileRole.sidecar => l10n.tr('附属', 'Sidecar'),
                                  FileRole.junk => l10n.tr('垃圾', 'Junk'),
                                  FileRole.other => l10n.tr('其他', 'Other'),
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
                        l10n.tr(
                          '已选 ${picked.length} / ${files.length} 个文件',
                          'Selected ${picked.length} / ${files.length} files',
                        ),
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          color: p.textMuted,
                        ),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('split-group-confirm'),
                        onPressed: canConfirm
                            ? () => Navigator.pop(ctx, Set<String>.of(picked))
                            : null,
                        child: Text(
                          l10n.tr(
                            '拆分为新作品 (${picked.length})',
                            'Split into New Title (${picked.length})',
                          ),
                        ),
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
