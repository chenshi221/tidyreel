import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import 'review_logic.dart';

// ---------------------------------------------------------------- TMDB search

class CandidateTile extends StatelessWidget {
  final Candidate candidate;
  final VoidCallback onTap;

  const CandidateTile({
    super.key,
    required this.candidate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    return ListTile(
      leading: Poster(posterPath: c.posterPath, width: 36, height: 54),
      title: Text(c.title),
      subtitle: Text(
        [
          if (c.originalTitle != null) c.originalTitle!,
          if (c.year != null) '${c.year}',
          c.kind == MediaKind.movie ? '电影' : '剧集',
          if (c.originCountry != null) c.originCountry!,
        ].join(' · '),
      ),
      onTap: onTap,
    );
  }
}

/// Search box + result list; shared by the 纠错 dialog and the inline box on
/// unmatched groups.
class TmdbSearchBox extends ConsumerStatefulWidget {
  final String initial;
  final MediaKind? kind;
  final ValueChanged<Candidate> onPick;
  final bool autoSearch;

  const TmdbSearchBox({
    super.key,
    required this.initial,
    this.kind,
    required this.onPick,
    this.autoSearch = false,
  });

  @override
  ConsumerState<TmdbSearchBox> createState() => _TmdbSearchBoxState();
}

class _TmdbSearchBoxState extends ConsumerState<TmdbSearchBox> {
  late final _c = TextEditingController(text: widget.initial);
  List<Candidate>? _results;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoSearch) _search();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(metadataProvider).search(q, kind: widget.kind);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _c,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索 TMDB',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _busy ? null : _search,
          ),
        ),
        onSubmitted: (_) => _search(),
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (_results != null && _results!.isEmpty) const Text('没有找到结果'),
      for (final c in _results ?? const <Candidate>[])
        CandidateTile(candidate: c, onTap: () => widget.onPick(c)),
    ],
  );
}

Future<Candidate?> showTmdbSearchDialog(
  BuildContext context, {
  required String initial,
  MediaKind? kind,
}) => showDialog<Candidate>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('纠错：重新搜索 TMDB'),
    content: SizedBox(
      width: 480,
      height: 420,
      child: SingleChildScrollView(
        child: TmdbSearchBox(
          initial: initial,
          kind: kind,
          autoSearch: true,
          onPick: (c) => Navigator.pop(ctx, c),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
    ],
  ),
);

// ---------------------------------------------------------------- left pane

class GroupList extends StatelessWidget {
  final List<MediaGroup> groups;
  final TaskReview review;
  final GroupId? selected;
  final ValueChanged<GroupId> onSelect;
  final void Function(GroupId, bool) onCheck;
  final void Function(MediaGroup, Candidate) onPick;

  const GroupList({
    super.key,
    required this.groups,
    required this.review,
    required this.selected,
    required this.onSelect,
    required this.onCheck,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) => groups.isEmpty
      ? const Center(child: Text('这里没有作品'))
      : ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: groups.length,
          itemBuilder: (_, i) {
            final g = groups[i];
            final d = review.decisions[g.id];
            return _GroupCard(
              group: g,
              decision: d,
              selected: g.id == selected,
              onSelect: () => onSelect(g.id),
              onCheck: (v) => onCheck(g.id, v),
              onPick: (c) => onPick(g, c),
            );
          },
        );
}

class _GroupCard extends StatelessWidget {
  final MediaGroup group;
  final GroupDecision? decision;
  final bool selected;
  final VoidCallback onSelect;
  final ValueChanged<bool> onCheck;
  final ValueChanged<Candidate> onPick;

  const _GroupCard({
    required this.group,
    required this.decision,
    required this.selected,
    required this.onSelect,
    required this.onCheck,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final g = group;
    final m = effectiveMatch(g, decision);
    final scheme = Theme.of(context).colorScheme;
    final comp = completeness(g, decision);
    final isTv = g.kind == MediaKind.episode;
    final title = m?.title ?? g.anchorTitle;
    final orig = m?.originalTitle ?? m?.englishTitle;
    return Card(
      color: selected ? scheme.secondaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    key: ValueKey('group-check-${g.id.value}'),
                    value: decision?.selected ?? true,
                    onChanged: (v) => onCheck(v ?? false),
                  ),
                  Poster(
                    posterPath: m?.posterPath,
                    icon: isTv ? Icons.tv : Icons.movie_outlined,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (orig != null && orig != title)
                          Text(
                            orig,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (m != null)
                          Text(
                            [
                              m.year?.toString() ?? '年份未知',
                              if (m.originCountry != null) m.originCountry!,
                            ].join(' · '),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        if (m == null)
                          Text('未能识别', style: TextStyle(color: scheme.error))
                        else if (isTv)
                          Text(
                            comp.label,
                            style: TextStyle(
                              color: comp.incomplete
                                  ? warningColor
                                  : scheme.onSurfaceVariant,
                              fontWeight: comp.incomplete
                                  ? FontWeight.w600
                                  : null,
                            ),
                          )
                        else
                          Text(
                            '电影 · ${g.files.length} 个文件',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (m == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TmdbSearchBox(
                    key: ValueKey('inline-search-${g.id.value}'),
                    initial: g.anchorTitle,
                    kind: g.kind == MediaKind.unknown ? null : g.kind,
                    onPick: onPick,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- middle pane

const folderTab = -2;

String seasonTabLabel(int season) => season == 0 ? '特别篇' : '第 $season 季';

enum _RowKind { main, special, extra, ignore }

/// Returns the override for [row], or null when cancelled.
Future<FileOverride?> showEditRowDialog(
  BuildContext context,
  MediaGroup group,
  ReviewRow row,
) {
  final season = TextEditingController(
    text: '${row.season == noSeason ? 1 : row.season}',
  );
  final ep = TextEditingController(
    text: '${episodeOf(row.file, row.override) ?? ''}',
  );
  var kind = row.override?.ignore ?? false
      ? _RowKind.ignore
      : switch (row.override?.kind) {
          MediaKind.special => _RowKind.special,
          MediaKind.extra => _RowKind.extra,
          _ => _RowKind.main,
        };
  final isTv = group.kind == MediaKind.episode;
  return showDialog<FileOverride>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('修正这个文件'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.file.name, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              if (isTv)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('edit-season'),
                        controller: season,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '季'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('edit-episode'),
                        controller: ep,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '集'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              SegmentedButton<_RowKind>(
                segments: const [
                  ButtonSegment(value: _RowKind.main, label: Text('正片')),
                  ButtonSegment(value: _RowKind.special, label: Text('特别篇')),
                  ButtonSegment(value: _RowKind.extra, label: Text('花絮')),
                  ButtonSegment(value: _RowKind.ignore, label: Text('忽略')),
                ],
                selected: {kind},
                onSelectionChanged: (v) => setState(() => kind = v.first),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('edit-save'),
            onPressed: () => Navigator.pop(
              ctx,
              FileOverride(
                season: isTv ? int.tryParse(season.text) : null,
                episode: isTv ? int.tryParse(ep.text) : null,
                kind: switch (kind) {
                  _RowKind.main =>
                    group.kind == MediaKind.movie
                        ? MediaKind.movie
                        : MediaKind.episode,
                  _RowKind.special => MediaKind.special,
                  _RowKind.extra => MediaKind.extra,
                  _RowKind.ignore => row.override?.kind,
                },
                ignore: kind == _RowKind.ignore,
              ),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

class DetailPane extends StatelessWidget {
  final MediaGroup group;
  final GroupDecision? decision;
  final TaskReview review;
  final int tab;
  final ValueChanged<int> onTab;
  final void Function(ReviewRow) onEdit;
  final void Function(ReviewRow, bool) onCheck;

  const DetailPane({
    super.key,
    required this.group,
    required this.decision,
    required this.review,
    required this.tab,
    required this.onTab,
    required this.onEdit,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final rows = rowsOf(group, decision, review);
    final seasons = ({for (final r in rows) r.season}.toList()..sort());
    final current = tab == folderTab || seasons.contains(tab)
        ? tab
        : (seasons.isEmpty ? folderTab : seasons.first);
    final shown = rows.where((r) => r.season == current).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final s in seasons)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('season-tab-$s'),
                    label: Text(
                      s == noSeason
                          ? '全部 (${rows.length})'
                          : '${seasonTabLabel(s)} (${seasonCountLabel(group, rows, s)})',
                    ),
                    selected: current == s,
                    onSelected: (_) => onTab(s),
                  ),
                ),
              ChoiceChip(
                key: const ValueKey('folder-tab'),
                label: const Text('文件夹'),
                selected: current == folderTab,
                onSelected: (_) => onTab(folderTab),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: current == folderTab
              ? _FolderOps(ops: folderOps(group, review))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _FileRow(
                    row: shown[i],
                    onEdit: () => onEdit(shown[i]),
                    onCheck: (v) => onCheck(shown[i], v),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  final ReviewRow row;
  final VoidCallback onEdit;
  final ValueChanged<bool> onCheck;

  const _FileRow({
    required this.row,
    required this.onEdit,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = row;
    final grey = scheme.onSurfaceVariant;
    final primary = r.ignored ? '已忽略' : r.newName ?? '（无改动）';
    return InkWell(
      onTap: onEdit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Checkbox(value: !r.ignored, onChanged: (v) => onCheck(v ?? false)),
            Icon(
              switch (r.file.role) {
                FileRole.subtitle => Icons.subtitles_outlined,
                FileRole.video => Icons.movie_outlined,
                FileRole.junk => Icons.delete_outline,
                _ => Icons.insert_drive_file_outlined,
              },
              size: 20,
              color: grey,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      primary,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: r.ignored ? grey : null,
                        decoration: r.ignored
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    Text(
                      r.file.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            if (r.conflict)
              _Chip('冲突', scheme.error)
            else if (r.op?.warning != null)
              _Chip(r.op!.warning!, warningColor),
            if (r.file.parsed != null && r.file.parsed!.confidence < 0.7)
              const _Chip('低置信', warningColor),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;

  const _Chip(this.text, this.color);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    ),
  );
}

class _FolderOps extends StatelessWidget {
  final List<RenameOp> ops;

  const _FolderOps({required this.ops});

  @override
  Widget build(BuildContext context) => ops.isEmpty
      ? const Center(child: Text('没有文件夹操作'))
      : ListView(
          children: [
            for (final o in ops)
              ListTile(
                leading: Icon(switch (o.kind) {
                  OpKind.mkdir => Icons.create_new_folder_outlined,
                  OpKind.delete => Icons.delete_outline,
                  OpKind.relocate => Icons.drive_file_move_outline,
                }),
                title: Text(switch (o.kind) {
                  OpKind.mkdir => '新建 ${o.dst}',
                  OpKind.delete => '删除 ${o.src}',
                  OpKind.relocate => o.dst,
                }),
                subtitle: o.kind == OpKind.relocate ? Text(o.src) : null,
              ),
          ],
        );
}

// ---------------------------------------------------------------- right pane

const strategyInfo = {
  SeasonStrategy.asParsed: ('识别到的季集', '直接使用文件名或文件夹里解析出的季号和集号'),
  SeasonStrategy.splitSequential: (
    '顺序拆多季',
    '一季到底的编号按 TMDB 每季集数拆开，每季从第 1 集开始（龙珠Z）',
  ),
  SeasonStrategy.splitKeepEpisode: ('跳序拆多季', '按 TMDB 每季集数找出季号，集号保持不变（海贼王）'),
  SeasonStrategy.mergeIntoOne: ('合并成一季', '多季合并为 S01，集号依次累加（名侦探柯南）'),
};

final _episodeGroupsProvider = FutureProvider.autoDispose
    .family<List<EpisodeGroup>, int>(
      (ref, tmdbId) => ref.watch(metadataProvider).episodeGroups(tmdbId),
    );

class ActionPane extends ConsumerWidget {
  final MediaGroup group;
  final GroupDecision decision;
  final ValueChanged<GroupDecision> onChange;
  final VoidCallback onCorrect;

  const ActionPane({
    super.key,
    required this.group,
    required this.decision,
    required this.onChange,
    required this.onCorrect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final m = effectiveMatch(group, decision);
    final isTv = group.kind == MediaKind.episode;
    Widget title(String t) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(t, style: theme.textTheme.titleSmall),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('作品操作', style: theme.textTheme.titleMedium),
        title('纠错'),
        Text(
          m == null
              ? '尚未匹配'
              : '当前：${m.title}${m.year != null ? ' (${m.year})' : ''}',
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('correct-button'),
          onPressed: onCorrect,
          icon: const Icon(Icons.manage_search),
          label: const Text('重新搜索 TMDB'),
        ),
        if (isTv) ...[
          title('季集策略'),
          RadioGroup<SeasonStrategy>(
            groupValue: decision.strategy,
            onChanged: (v) => onChange(decision.copyWith(strategy: v)),
            child: Column(
              children: [
                for (final e in strategyInfo.entries)
                  RadioListTile<SeasonStrategy>(
                    key: ValueKey('strategy-${e.key.name}'),
                    contentPadding: EdgeInsets.zero,
                    value: e.key,
                    title: Text(e.value.$1),
                    subtitle: Text(e.value.$2),
                  ),
              ],
            ),
          ),
          title('剧集组'),
          if (m == null)
            const Text('匹配作品后可选')
          else
            ref
                .watch(_episodeGroupsProvider(m.tmdbId))
                .when(
                  loading: () => const Text('读取中…'),
                  error: (e, _) => Text('读取失败：$e'),
                  data: (groups) => groups.isEmpty
                      ? const Text('TMDB 上没有剧集组')
                      : RadioGroup<String?>(
                          groupValue: decision.episodeGroupId,
                          onChanged: (v) => onChange(
                            decision.copyWith(episodeGroupId: () => v),
                          ),
                          child: Column(
                            children: [
                              const RadioListTile<String?>(
                                contentPadding: EdgeInsets.zero,
                                value: null,
                                title: Text('默认季划分'),
                              ),
                              for (final g in groups)
                                RadioListTile<String?>(
                                  contentPadding: EdgeInsets.zero,
                                  value: g.id,
                                  title: Text(g.name),
                                  subtitle: Text('${g.seasons.length} 季'),
                                ),
                            ],
                          ),
                        ),
                ),
          title('集数偏移'),
          Row(
            children: [
              IconButton.outlined(
                key: const ValueKey('offset-minus'),
                tooltip: '减 1',
                icon: const Icon(Icons.remove),
                onPressed: () => onChange(
                  decision.copyWith(episodeOffset: decision.episodeOffset - 1),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${decision.episodeOffset}',
                  key: const ValueKey('offset-value'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton.outlined(
                key: const ValueKey('offset-plus'),
                tooltip: '加 1',
                icon: const Icon(Icons.add),
                onPressed: () => onChange(
                  decision.copyWith(episodeOffset: decision.episodeOffset + 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '在应用策略之前给所有集号加上偏移',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
