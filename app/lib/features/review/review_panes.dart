import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'review_logic.dart';

/// TMDB episodes of one season, keyed by (tmdbId, season). Cached by the
/// provider for the life of the review page.
final seasonEpisodesProvider = FutureProvider.autoDispose
    .family<List<Episode>, (int, int)>(
      (ref, k) => ref.watch(metadataProvider).season(k.$1, k.$2),
    );

String _country(String? code) => switch (code) {
  null => '',
  'CN' => '中国大陆',
  'HK' => '中国香港',
  'TW' => '中国台湾',
  'JP' => '日本',
  'KR' => '韩国',
  'US' => '美国',
  'GB' => '英国',
  'FR' => '法国',
  'DE' => '德国',
  'TH' => '泰国',
  'IN' => '印度',
  _ => code,
};

String _date(DateTime? d) => d == null
    ? ''
    : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _pad(int n) => n.toString().padLeft(2, '0');

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
    final p = Palette.of(context);
    return HoverRow(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      borderRadius: BorderRadius.circular(Radii.md),
      leading: Poster(posterPath: c.posterPath, width: 34, height: 51),
      title: Text(c.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (c.originalTitle != null && c.originalTitle != c.title)
                c.originalTitle!,
              if (c.year != null) '${c.year}',
              c.kind == MediaKind.movie ? '电影' : '剧集',
              if (c.originCountry != null) _country(c.originCountry),
            ].join(' · '),
          ),
          if (c.overview != null)
            Text(
              c.overview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textFaint),
            ),
        ],
      ),
      trailing: c.voteAverage == null || c.voteAverage == 0
          ? null
          : _Rating(c.voteAverage!),
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
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _c,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: '搜索 TMDB',
            prefixIcon: const Icon(CupertinoIcons.search, size: 14),
            suffixIcon: _busy
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : IconButton(
                    tooltip: '搜索',
                    iconSize: 15,
                    icon: const Icon(CupertinoIcons.arrow_right_circle_fill),
                    onPressed: _search,
                  ),
          ),
          onSubmitted: (_) => _search(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(color: p.danger, fontSize: 12),
            ),
          ),
        if (_results != null && _results!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('没有找到结果', style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_results != null && _results!.isNotEmpty) const SizedBox(height: 4),
        for (final c in _results ?? const <Candidate>[])
          CandidateTile(candidate: c, onTap: () => widget.onPick(c)),
      ],
    );
  }
}

Future<Candidate?> showTmdbSearchDialog(
  BuildContext context, {
  required String initial,
  MediaKind? kind,
}) => showDialog<Candidate>(
  context: context,
  builder: (ctx) => MacSheet(
    child: SizedBox(
      width: 520,
      height: 480,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('重新搜索 TMDB', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: TmdbSearchBox(
                  initial: initial,
                  kind: kind,
                  autoSearch: true,
                  onPick: (c) => Navigator.pop(ctx, c),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _Rating extends StatelessWidget {
  final double value;
  final Color? color;

  const _Rating(this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFD9A21B);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.star_fill, size: 11, color: c),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color ?? Palette.of(context).text,
          ),
        ),
      ],
    );
  }
}

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
      ? const EmptyState(icon: CupertinoIcons.tray, title: '这里没有作品')
      : ListView.builder(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
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
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final m = effectiveMatch(g, decision);
    final comp = completeness(g, decision);
    final isTv = g.kind == MediaKind.episode;
    final title = m?.title ?? g.anchorTitle;
    final orig = m?.originalTitle ?? m?.englishTitle;
    final ratio = comp.tmdbEpisodes == null || comp.tmdbEpisodes == 0
        ? null
        : (comp.localEpisodes / comp.tmdbEpisodes!).clamp(0.0, 1.0);
    return Hoverable(
      onTap: onSelect,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(6, 8, 10, 8),
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.10)
              : (hover ? p.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Checkbox(
                    key: ValueKey('group-check-${g.id.value}'),
                    value: decision?.selected ?? true,
                    onChanged: (v) => onCheck(v ?? false),
                  ),
                ),
                Poster(
                  posterPath: m?.posterPath,
                  icon: isTv ? CupertinoIcons.tv : CupertinoIcons.film,
                  width: 44,
                  height: 66,
                  radius: 5,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (orig != null && orig != title)
                        Text(
                          orig,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 3),
                      if (m == null)
                        Tag('未能识别', color: p.danger)
                      else
                        Row(
                          children: [
                            Tag(isTv ? '剧集' : '电影'),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                [
                                  m.year?.toString() ?? '年份未知',
                                  if (m.originCountry != null)
                                    _country(m.originCountry),
                                ].join(' · '),
                                style: theme.textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (m != null && isTv) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ratio != null)
                      LinearProgressIndicator(
                        value: ratio,
                        minHeight: 3,
                        color: comp.incomplete ? p.warning : p.success,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      comp.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: comp.incomplete ? p.warning : p.textMuted,
                        fontWeight: comp.incomplete ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (m != null)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 6),
                child: Text(
                  '电影 · ${g.files.length} 个文件',
                  style: TextStyle(fontSize: 11, color: p.textMuted),
                ),
              ),
            if (m == null)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 28),
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
      builder: (ctx, setState) => MacSheet(
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('修正这个文件', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  row.file.name,
                  style: Theme.of(ctx).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 14),
                Center(
                  child: Segmented<_RowKind>(
                    options: const {
                      _RowKind.main: '正片',
                      _RowKind.special: '特别篇',
                      _RowKind.extra: '花絮',
                      _RowKind.ignore: '忽略',
                    },
                    value: kind,
                    onChanged: (v) => setState(() => kind = v),
                  ),
                ),
                if (isTv) ...[
                  const SizedBox(height: 12),
                  FormRow(
                    label: '季',
                    labelWidth: 56,
                    child: TextField(
                      key: const ValueKey('edit-season'),
                      controller: season,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  FormRow(
                    label: '集',
                    labelWidth: 56,
                    child: TextField(
                      key: const ValueKey('edit-episode'),
                      controller: ep,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
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
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Artwork header: blurred backdrop (or warm gradient), poster, titles,
/// metadata, synopsis and completeness.
class WorkHeader extends StatelessWidget {
  final MediaGroup group;
  final GroupDecision? decision;

  const WorkHeader({super.key, required this.group, required this.decision});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final g = group;
    final m = effectiveMatch(g, decision);
    final detail = g.show?.info.tmdbId == m?.tmdbId ? g.show?.info : null;
    final backdrop = m?.backdropPath ?? detail?.backdropPath;
    final overview = m?.overview ?? detail?.overview;
    final genres = (detail?.genres.isNotEmpty ?? false)
        ? detail!.genres
        : (m?.genres ?? const <String>[]);
    final isTv = g.kind == MediaKind.episode;
    final comp = completeness(g, decision);
    final onImage = backdrop != null;
    final fg = onImage ? Colors.white : p.text;
    final fgMuted = onImage
        ? Colors.white.withValues(alpha: 0.78)
        : p.textMuted;

    final meta = [
      if (m?.year != null) '${m!.year}',
      if (m?.originCountry != null) _country(m!.originCountry),
      if (genres.isNotEmpty) genres.take(3).join(' / '),
      isTv ? comp.label : '电影 · ${g.files.length} 个文件',
    ];

    return Container(
      key: const ValueKey('work-header'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: p.line, width: hairline),
        gradient: onImage
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [p.accentSoft, p.panel],
              ),
      ),
      child: Stack(
        children: [
          if (onImage) ...[
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                child: Image.network(
                  tmdbImage(backdrop, 'w780'),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, _, _) => ColoredBox(color: p.text),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.82),
                      Colors.black.withValues(alpha: 0.55),
                      Colors.black.withValues(alpha: 0.25),
                    ],
                  ),
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Poster(
                  posterPath: m?.posterPath,
                  icon: isTv ? CupertinoIcons.tv : CupertinoIcons.film,
                  width: 96,
                  height: 144,
                  radius: 8,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              m?.title ?? g.anchorTitle,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: fg,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (m?.voteAverage != null &&
                              m!.voteAverage! > 0) ...[
                            const SizedBox(width: 10),
                            _Rating(
                              m.voteAverage!,
                              color: onImage ? Colors.white : null,
                            ),
                          ],
                        ],
                      ),
                      if (m?.originalTitle != null &&
                          m!.originalTitle != m.title)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            [
                              m.originalTitle!,
                              if (m.englishTitle != null &&
                                  m.englishTitle != m.originalTitle)
                                m.englishTitle!,
                            ].join('  ·  '),
                            style: TextStyle(fontSize: 13, color: fgMuted),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final t in meta)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: onImage
                                    ? Colors.white.withValues(alpha: 0.16)
                                    : p.panel.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(5),
                                border: onImage
                                    ? null
                                    : Border.all(
                                        color: p.line,
                                        width: hairline,
                                      ),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: t == comp.label && comp.incomplete
                                      ? (onImage
                                            ? const Color(0xFFFFD27A)
                                            : p.warning)
                                      : fg,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (overview != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          overview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: fgMuted,
                          ),
                        ),
                      ],
                      if (m == null) ...[
                        const SizedBox(height: 10),
                        Text(
                          '还没有匹配到 TMDB 条目，在左侧搜索或点右侧「重新搜索」',
                          style: TextStyle(fontSize: 12.5, color: p.danger),
                        ),
                      ],
                    ],
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
    final missing = current == folderTab
        ? const <int>[]
        : missingEpisodes(group, decision, rows, current);
    final m = effectiveMatch(group, decision);

    // Videos ordered by episode, each followed by its sidecars (same stem).
    final entries = <_Entry>[];
    if (current != folderTab) {
      final videos = shown.where((r) => r.file.role == FileRole.video).toList()
        ..sort((a, b) {
          final ea = targetRef(a)?.episode ?? 1 << 20;
          final eb = targetRef(b)?.episode ?? 1 << 20;
          return ea != eb
              ? ea.compareTo(eb)
              : a.file.name.compareTo(b.file.name);
        });
      final others = shown.where((r) => r.file.role != FileRole.video).toList();
      final used = <ReviewRow>{};
      String stem(String n) {
        final i = n.indexOf('.');
        return i < 0 ? n : n.substring(0, i);
      }

      final slots = <(int, _Entry)>[];
      for (final v in videos) {
        slots.add((targetRef(v)?.episode ?? 1 << 20, _Entry.video(v)));
        final s = stem(v.file.name);
        for (final o in others) {
          if (!used.contains(o) && stem(o.file.name) == s) {
            used.add(o);
            slots.add((targetRef(v)?.episode ?? 1 << 20, _Entry.sidecar(o)));
          }
        }
      }
      for (final e in missing) {
        slots.add((e, _Entry.missing(e)));
      }
      // Stable: missing rows slot in before the first video of a later episode.
      slots.sort((a, b) => a.$1.compareTo(b.$1));
      entries.addAll(slots.map((s) => s.$2));
      for (final o in others) {
        if (!used.contains(o)) entries.add(_Entry.sidecar(o));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        WorkHeader(group: group, decision: decision),
        const SizedBox(height: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in seasons)
              _SeasonChip(
                key: ValueKey('season-tab-$s'),
                label: s == noSeason
                    ? '全部 (${rows.length})'
                    : '${seasonTabLabel(s)} (${seasonCountLabel(group, rows, s)})',
                posterPath: group.show?.seasons
                    .where((x) => x.number == s)
                    .firstOrNull
                    ?.posterPath,
                selected: current == s,
                onTap: () => onTab(s),
              ),
            _SeasonChip(
              key: const ValueKey('folder-tab'),
              label: '文件夹',
              icon: CupertinoIcons.folder,
              selected: current == folderTab,
              onTap: () => onTab(folderTab),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (current == folderTab)
          _FolderOps(ops: folderOps(group, review))
        else
          Panel(
            child: Rows(
              indent: 52,
              children: [
                for (final e in entries)
                  switch (e) {
                    _Entry(:final row?, sidecar: false) => _EpisodeRow(
                      row: row,
                      tmdbId: group.kind == MediaKind.episode
                          ? m?.tmdbId
                          : null,
                      onEdit: () => onEdit(row),
                      onCheck: (v) => onCheck(row, v),
                    ),
                    _Entry(:final row?, sidecar: true) => _SidecarRow(
                      row: row,
                      onEdit: () => onEdit(row),
                      onCheck: (v) => onCheck(row, v),
                    ),
                    _Entry(:final missingEpisode?) => _MissingRow(
                      season: current,
                      episode: missingEpisode,
                      tmdbId: m?.tmdbId,
                    ),
                    _ => const SizedBox.shrink(),
                  },
              ],
            ),
          ),
      ],
    );
  }
}

class _Entry {
  final ReviewRow? row;
  final bool sidecar;
  final int? missingEpisode;

  const _Entry.video(ReviewRow this.row)
    : sidecar = false,
      missingEpisode = null;
  const _Entry.sidecar(ReviewRow this.row)
    : sidecar = true,
      missingEpisode = null;
  const _Entry.missing(int this.missingEpisode) : row = null, sidecar = false;
}

class _SeasonChip extends StatelessWidget {
  final String label;
  final String? posterPath;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _SeasonChip({
    super.key,
    required this.label,
    this.posterPath,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.fromLTRB(posterPath != null ? 4 : 10, 4, 11, 4),
        decoration: BoxDecoration(
          color: selected ? p.text : (hover ? p.hover : p.panel),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? p.text : p.line,
            width: hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (posterPath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.network(
                  tmdbImage(posterPath!, 'w92'),
                  width: 16,
                  height: 24,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(width: 16),
                ),
              ),
              const SizedBox(width: 7),
            ] else if (icon != null) ...[
              Icon(icon, size: 13, color: selected ? p.canvas : p.textMuted),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? p.canvas : p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Episode number badge: "01" in a rounded square.
class _EpBadge extends StatelessWidget {
  final String text;
  final bool dim;

  const _EpBadge(this.text, {this.dim = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: 34,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dim ? Colors.transparent : p.sidebar,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: dim ? p.lineStrong : p.line,
          width: dim ? 1 : hairline,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: dim ? p.textFaint : p.text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  final ReviewRow row;
  final int? tmdbId;
  final VoidCallback onEdit;
  final ValueChanged<bool> onCheck;

  const _EpisodeRow({
    required this.row,
    required this.tmdbId,
    required this.onEdit,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final r = row;
    final target = targetRef(r);
    Episode? ep;
    if (tmdbId != null && target != null) {
      ep = ref
          .watch(seasonEpisodesProvider((tmdbId!, target.season)))
          .asData
          ?.value
          .where((e) => e.number == target.episode)
          .firstOrNull;
    }
    final badge = target == null ? '—' : _pad(target.episode);
    final newName = r.ignored ? '已忽略' : r.newName ?? '（无改动）';
    final lowConfidence =
        r.file.parsed != null && r.file.parsed!.confidence < 0.7;

    return Hoverable(
      onTap: onEdit,
      builder: (context, hover) => Container(
        color: hover ? p.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(6, 9, 12, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Checkbox(
                value: !r.ignored,
                onChanged: (v) => onCheck(v ?? false),
              ),
            ),
            const SizedBox(width: 2),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: tmdbId == null && target == null
                  ? IconTile(CupertinoIcons.film, size: 26)
                  : _EpBadge(badge),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tmdbId != null)
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            ep?.title ??
                                (target == null
                                    ? '未识别集号'
                                    : '第 ${target.episode} 集'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: r.ignored ? p.textFaint : p.text,
                            ),
                          ),
                        ),
                        if (ep?.airDate != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            _date(ep!.airDate),
                            style: TextStyle(fontSize: 11, color: p.textFaint),
                          ),
                        ],
                      ],
                    ),
                  Text(
                    newName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: tmdbId != null ? 12.5 : 13,
                      color: r.ignored
                          ? p.textFaint
                          : (tmdbId != null ? p.textMuted : p.text),
                      fontWeight: tmdbId != null ? null : FontWeight.w500,
                      decoration: r.ignored ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.arrow_turn_down_right,
                        size: 10,
                        color: p.textFaint,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          r.file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: p.textFaint),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (r.conflict)
              Tag('冲突', color: p.danger)
            else if (r.op?.warning != null)
              Tag(r.op!.warning!, color: p.warning),
            if (lowConfidence) ...[
              const SizedBox(width: 4),
              Tag('低置信', color: p.warning),
            ],
            const SizedBox(width: 4),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: hover ? 1 : 0,
              child: Icon(CupertinoIcons.pencil, size: 14, color: p.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subtitle / sidecar following a video: compact, indented.
class _SidecarRow extends StatelessWidget {
  final ReviewRow row;
  final VoidCallback onEdit;
  final ValueChanged<bool> onCheck;

  const _SidecarRow({
    required this.row,
    required this.onEdit,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = row;
    final icon = switch (r.file.role) {
      FileRole.subtitle => CupertinoIcons.captions_bubble,
      FileRole.junk => CupertinoIcons.trash,
      _ => CupertinoIcons.doc,
    };
    return Hoverable(
      onTap: onEdit,
      builder: (context, hover) => Container(
        color: hover ? p.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Checkbox(
                value: !r.ignored,
                onChanged: (v) => onCheck(v ?? false),
              ),
            ),
            const SizedBox(width: 14),
            Icon(icon, size: 14, color: p.textFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.ignored ? '已忽略' : r.newName ?? '（无改动）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: r.ignored ? p.textFaint : p.textMuted,
                      decoration: r.ignored ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    r.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.textFaint),
                  ),
                ],
              ),
            ),
            if (r.conflict) Tag('冲突', color: p.danger),
          ],
        ),
      ),
    );
  }
}

/// A TMDB episode with no local file.
class _MissingRow extends ConsumerWidget {
  final int season;
  final int episode;
  final int? tmdbId;

  const _MissingRow({
    required this.season,
    required this.episode,
    required this.tmdbId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final ep = tmdbId == null
        ? null
        : ref
              .watch(seasonEpisodesProvider((tmdbId!, season)))
              .asData
              ?.value
              .where((e) => e.number == episode)
              .firstOrNull;
    return Container(
      key: ValueKey('missing-$season-$episode'),
      color: p.warning.withValues(alpha: 0.04),
      padding: const EdgeInsets.fromLTRB(36, 9, 12, 9),
      child: Row(
        children: [
          _EpBadge(_pad(episode), dim: true),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              [
                ep?.title ?? '第 $episode 集',
                if (ep?.airDate != null) _date(ep!.airDate),
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: p.textFaint),
            ),
          ),
          Tag('本地缺失', color: p.warning),
        ],
      ),
    );
  }
}

class _FolderOps extends StatelessWidget {
  final List<RenameOp> ops;

  const _FolderOps({required this.ops});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (ops.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: EmptyState(icon: CupertinoIcons.folder, title: '没有文件夹操作'),
      );
    }
    return Panel(
      child: Rows(
        indent: 44,
        children: [
          for (final o in ops)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    switch (o.kind) {
                      OpKind.mkdir => CupertinoIcons.folder_badge_plus,
                      OpKind.delete => CupertinoIcons.trash,
                      OpKind.relocate => CupertinoIcons.arrow_right_square,
                    },
                    size: 16,
                    color: o.kind == OpKind.delete ? p.danger : p.accent,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          switch (o.kind) {
                            OpKind.mkdir => '新建 ${o.dst}',
                            OpKind.delete => '删除 ${o.src}',
                            OpKind.relocate => o.dst,
                          },
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (o.kind == OpKind.relocate)
                          Text(
                            o.src,
                            style: TextStyle(fontSize: 11, color: p.textFaint),
                          ),
                      ],
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

/// One selectable option row (radio look) inside a [Panel].
class _OptionRow extends StatelessWidget {
  final String title;
  final String? caption;
  final bool selected;
  final VoidCallback onTap;

  const _OptionRow({
    super.key,
    required this.title,
    this.caption,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hover) => Container(
        color: hover ? p.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? CupertinoIcons.largecircle_fill_circle
                    : CupertinoIcons.circle,
                size: 15,
                color: selected ? p.accent : p.lineStrong,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
                      style: TextStyle(fontSize: 11, color: p.textMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final m = effectiveMatch(group, decision);
    final isTv = group.kind == MediaKind.episode;
    Widget note(String t) => Padding(
      padding: const EdgeInsets.all(12),
      child: Text(t, style: theme.textTheme.bodySmall),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 18, 20),
      children: [
        const SectionLabel('匹配'),
        Panel(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Poster(
                    posterPath: m?.posterPath,
                    width: 30,
                    height: 45,
                    radius: 4,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m == null ? '尚未匹配' : m.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          m == null
                              ? '在 TMDB 里搜索并选择'
                              : 'TMDB ${m.tmdbId}${m.year != null ? ' · ${m.year}' : ''}',
                          style: TextStyle(fontSize: 11, color: p.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('correct-button'),
                onPressed: onCorrect,
                icon: const Icon(CupertinoIcons.search, size: 13),
                label: const Text('重新搜索 TMDB'),
              ),
            ],
          ),
        ),
        if (isTv) ...[
          const SectionLabel('季集策略'),
          Panel(
            child: Rows(
              children: [
                for (final e in strategyInfo.entries)
                  _OptionRow(
                    key: ValueKey('strategy-${e.key.name}'),
                    title: e.value.$1,
                    caption: e.value.$2,
                    selected: decision.strategy == e.key,
                    onTap: () => onChange(decision.copyWith(strategy: e.key)),
                  ),
              ],
            ),
          ),
          const SectionLabel('剧集组'),
          Panel(
            child: m == null
                ? note('匹配作品后可选')
                : ref
                      .watch(_episodeGroupsProvider(m.tmdbId))
                      .when(
                        loading: () => note('读取中…'),
                        error: (e, _) => note('读取失败：$e'),
                        data: (groups) => groups.isEmpty
                            ? note('TMDB 上没有剧集组')
                            : Rows(
                                children: [
                                  _OptionRow(
                                    title: '默认季划分',
                                    selected: decision.episodeGroupId == null,
                                    onTap: () => onChange(
                                      decision.copyWith(
                                        episodeGroupId: () => null,
                                      ),
                                    ),
                                  ),
                                  for (final g in groups)
                                    _OptionRow(
                                      title: g.name,
                                      caption: '${g.seasons.length} 季',
                                      selected: decision.episodeGroupId == g.id,
                                      onTap: () => onChange(
                                        decision.copyWith(
                                          episodeGroupId: () => g.id,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
          ),
          const SectionLabel('集数偏移'),
          Panel(
            child: SettingRow(
              title: '偏移',
              caption: '应用策略之前，给所有集号加上偏移',
              control: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: p.lineStrong, width: hairline),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('offset-minus'),
                      tooltip: '减 1',
                      iconSize: 12,
                      icon: const Icon(CupertinoIcons.minus),
                      onPressed: () => onChange(
                        decision.copyWith(
                          episodeOffset: decision.episodeOffset - 1,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 30,
                      child: Text(
                        '${decision.episodeOffset}',
                        key: const ValueKey('offset-value'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('offset-plus'),
                      tooltip: '加 1',
                      iconSize: 12,
                      icon: const Icon(CupertinoIcons.plus),
                      onPressed: () => onChange(
                        decision.copyWith(
                          episodeOffset: decision.episodeOffset + 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
