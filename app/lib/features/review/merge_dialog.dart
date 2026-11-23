import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';

final _sxxeyy = RegExp(r'S(\d{1,2})E(\d{1,3})', caseSensitive: false);

final _seasonDir = RegExp(
  r'^(?:Season\s*(\d{1,2})|Specials)$',
  caseSensitive: false,
);

String _parentDir(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

/// Season → episodes found in show folder [dir] and its season folders.
Future<Map<int, Set<int>>> episodesIn(StorageBackend be, String dir) async {
  final out = <int, Set<int>>{};
  Future<void> scan(String d, {required bool deeper}) async {
    for (final e in await be.list(d)) {
      if (e.isDir) {
        if (!deeper) continue;
        if (_seasonDir.firstMatch(e.name) case final m?) {
          out.putIfAbsent(m[1] == null ? 0 : int.parse(m[1]!), () => {});
        }
        await scan(e.path, deeper: false);
        continue;
      }
      for (final x in _sxxeyy.allMatches(e.name)) {
        (out[int.parse(x[1]!)] ??= {}).add(int.parse(x[2]!));
      }
    }
  }

  await scan(dir, deeper: true);
  return out;
}

/// 「Season 01 E01–E05、E07；Season 02」.
String describeEpisodes(
  Map<int, Set<int>> bySeason, {
  AppL10n l10n = AppL10n.zh,
}) {
  if (bySeason.isEmpty) {
    return l10n.tr('（没有识别到剧集）', '(no episodes detected)');
  }
  String two(int n) => n.toString().padLeft(2, '0');
  final parts = <String>[];
  for (final s in bySeason.keys.toList()..sort()) {
    final eps = bySeason[s]!.toList()..sort();
    final runs = <String>[];
    for (var i = 0; i < eps.length; i++) {
      var j = i;
      while (j + 1 < eps.length && eps[j + 1] == eps[j] + 1) {
        j++;
      }
      runs.add(j == i ? 'E${two(eps[i])}' : 'E${two(eps[i])}–E${two(eps[j])}');
      i = j;
    }
    final name = s == 0 ? 'Specials' : 'Season ${two(s)}';
    parts.add(
      runs.isEmpty ? name : '$name ${runs.join(l10n.isEn ? ', ' : '、')}',
    );
  }
  return parts.join(l10n.isEn ? '; ' : '；');
}

/// Asks about each [PlanMerge] before running: where the show goes, what is
/// there already, what this task adds. Returns the groups to keep separate
/// (分开保留), or null when cancelled.
Future<Set<GroupId>?> showMergeDialog(
  BuildContext context, {
  required TaskReview review,
  required List<PlanMerge> merges,
  required StorageBackend backend,
  OrganizeMode? mode,
}) {
  final separate = <GroupId>{};
  final byId = {for (final g in review.scan.groups) g.id: g};
  // Pre-create & cache existing-folder listing futures ONCE so toggling
  // 合并 / 分开保留 never re-fires storage requests.
  final existingFutures = <String, Future<Map<int, Set<int>>>>{
    for (final m in merges)
      if (m.exists) m.into: episodesIn(backend, m.into),
  };

  // Episodes this task puts into the merged folder, read off the plan.
  Map<int, Set<int>> adding(PlanMerge m) {
    final out = <int, Set<int>>{};
    for (final o in review.preview.ops) {
      if (o.group != m.group ||
          o.kind != OpKind.relocate ||
          o.phase != ExecPhase.files) {
        continue;
      }
      for (final x in _sxxeyy.allMatches(o.dst.split('/').last)) {
        (out[int.parse(x[1]!)] ??= {}).add(int.parse(x[2]!));
      }
    }
    if (out.isEmpty) {
      for (final s in m.seasons) {
        out[s] = {};
      }
    }
    return out;
  }

  String separatedPreview(PlanMerge m, MediaGroup? g, AppL10n l10n) {
    final effectiveMode =
        mode ??
        (g != null && _parentDir(m.into) == _parentDir(g.rootDir)
            ? OrganizeMode.inPlace
            : OrganizeMode.moveToLibrary);
    if (effectiveMode == OrganizeMode.inPlace && g != null) {
      return l10n.tr(
        '保留原目录：${g.rootDir}',
        'Keep original folder: ${g.rootDir}',
      );
    }
    var n = 2;
    for (final prev in merges) {
      if (prev.group == m.group) break;
      if (prev.into == m.into && separate.contains(prev.group)) n++;
    }
    return l10n.tr('独立目录：${m.into} ($n)', 'Separate folder: ${m.into} ($n)');
  }

  return showDialog<Set<GroupId>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final p = Palette.of(ctx);
        final l10n = ctx.l10n;
        final small = TextStyle(fontSize: 12, color: p.textMuted);
        return MacSheet(
          child: SizedBox(
            width: 560,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr('合并到已有剧集文件夹？', 'Merge into Existing Show Folder?'),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.tr(
                      '下面的作品会和已有的（或本次另一个文件夹里的）同一部作品放进同一个文件夹。',
                      'The titles below will be combined with an existing folder (or another folder in this batch) for the same show.',
                    ),
                    style: small,
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final m in merges)
                            Builder(
                              builder: (context) {
                                final g = byId[m.group];
                                final match = g == null
                                    ? null
                                    : review.decisions[g.id]?.match ?? g.match;
                                final other = m.withGroup == null
                                    ? null
                                    : byId[m.withGroup];
                                final keep = separate.contains(m.group);
                                final name =
                                    match?.title ?? g?.anchorTitle ?? '';
                                return Container(
                                  key: ValueKey('merge-${m.group.value}'),
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: p.panel,
                                    borderRadius: BorderRadius.circular(
                                      Radii.lg,
                                    ),
                                    border: Border.all(
                                      color: p.line,
                                      width: hairline,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Poster(
                                        posterPath: match?.posterPath,
                                        width: 40,
                                        height: 60,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l10n.isEn
                                                  ? '$name${match?.year == null ? '' : ' (${match!.year})'}'
                                                  : '《$name》${match?.year == null ? '' : ' (${match!.year})'}',
                                              style: const TextStyle(
                                                fontSize: TypeScale.body,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            SelectableText(
                                              keep
                                                  ? separatedPreview(m, g, l10n)
                                                  : l10n.tr(
                                                      '合并到 ${m.into}',
                                                      'Merge into ${m.into}',
                                                    ),
                                              style: TextStyle(
                                                fontSize: TypeScale.small,
                                                color: p.text,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            if (m.exists)
                                              FutureBuilder<Map<int, Set<int>>>(
                                                future: existingFutures[m.into],
                                                builder: (context, snap) => Text(
                                                  snap.hasError
                                                      ? l10n.tr(
                                                          '已有文件夹（读取内容失败）',
                                                          'Existing folder (failed to read contents)',
                                                        )
                                                      : !snap.hasData
                                                      ? l10n.tr(
                                                          '已有：读取中…',
                                                          'Existing: loading…',
                                                        )
                                                      : l10n.tr(
                                                          '已有：${describeEpisodes(snap.data!, l10n: l10n)}',
                                                          'Existing: ${describeEpisodes(snap.data!, l10n: l10n)}',
                                                        ),
                                                  style: small,
                                                ),
                                              )
                                            else if (other != null)
                                              Text(
                                                l10n.tr(
                                                  '和本次的 ${other.rootDir} 放在一起',
                                                  'Combined with ${other.rootDir} from this batch',
                                                ),
                                                style: small,
                                              ),
                                            Text(
                                              l10n.tr(
                                                '本次加入：${describeEpisodes(adding(m), l10n: l10n)}',
                                                'Adding: ${describeEpisodes(adding(m), l10n: l10n)}',
                                              ),
                                              style: small,
                                            ),
                                            if (g != null)
                                              Text(
                                                l10n.tr(
                                                  '本次来源：${g.rootDir}',
                                                  'Source: ${g.rootDir}',
                                                ),
                                                style: small,
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Segmented<bool>(
                                        key: ValueKey(
                                          'merge-choice-${m.group.value}',
                                        ),
                                        options: {
                                          false: l10n.tr('合并', 'Merge'),
                                          true: l10n.tr(
                                            '分开保留',
                                            'Keep Separate',
                                          ),
                                        },
                                        value: keep,
                                        onChanged: (v) => setState(
                                          () => v
                                              ? separate.add(m.group)
                                              : separate.remove(m.group),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    l10n.tr(
                      '已有的集不会被覆盖：两边有相同的集时会标为冲突，由你决定保留哪个。',
                      'Existing episodes are never overwritten; duplicate episodes are flagged as conflicts for you to resolve.',
                    ),
                    style: small,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('merge-continue'),
                        onPressed: () => Navigator.pop(ctx, separate),
                        child: Text(l10n.tr('继续', 'Continue')),
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
