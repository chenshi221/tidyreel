import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Seasons of a show the user matched by hand; group.show only has the show
/// the recognizer found.
final showDetailProvider = FutureProvider.autoDispose.family<ShowDetail, int>(
  (ref, id) => ref.watch(metadataProvider).show(id),
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

/// Search box + type / year filters + result list; shared by the 纠错 dialog
/// and the inline box on unmatched groups.
class TmdbSearchBox extends ConsumerStatefulWidget {
  final String initial;
  final ValueChanged<Candidate> onPick;
  final bool autoSearch;

  const TmdbSearchBox({
    super.key,
    required this.initial,
    required this.onPick,
    this.autoSearch = false,
  });

  @override
  ConsumerState<TmdbSearchBox> createState() => _TmdbSearchBoxState();
}

class _TmdbSearchBoxState extends ConsumerState<TmdbSearchBox> {
  late final _c = TextEditingController(text: widget.initial);
  // Both filters start open: the guess being corrected may be what's wrong
  // (a year taken from a wrong match hides the right one). MediaKind.unknown = 全部.
  final _yearC = TextEditingController();
  var _kind = MediaKind.unknown;
  List<Candidate>? _results;
  var _busy = false;
  var _searchSeq = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoSearch) _search();
  }

  @override
  void didUpdateWidget(TmdbSearchBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) {
      _c.text = widget.initial;
      _yearC.text = '';
      _kind = MediaKind.unknown;
      _results = null;
      _error = null;
      if (widget.autoSearch) _search();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _yearC.dispose();
    super.dispose();
  }

  int? get _year {
    final y = int.tryParse(_yearC.text.trim());
    return y != null && y >= 1870 && y <= 2100 ? y : null;
  }

  void _setYear(int? y) {
    _yearC.text = y?.toString() ?? '';
    _search();
  }

  Future<void> _search() async {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    final seq = ++_searchSeq;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(metadataProvider)
          .search(
            q,
            kind: _kind == MediaKind.unknown ? null : _kind,
            year: _year,
          );
      if (mounted && seq == _searchSeq) setState(() => _results = r);
    } catch (e) {
      if (mounted && seq == _searchSeq) setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _busy = false);
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segmented<MediaKind>(
              key: const ValueKey('search-kind'),
              options: const {
                MediaKind.unknown: '全部',
                MediaKind.episode: '剧集',
                MediaKind.movie: '电影',
              },
              value: _kind,
              onChanged: (k) {
                setState(() => _kind = k);
                _search();
              },
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('search-year'),
                controller: _yearC,
                style: const TextStyle(fontSize: 13),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: InputDecoration(
                  hintText: '年份',
                  suffixIcon: PopupMenuButton<int>(
                    tooltip: '选择年份',
                    iconSize: 14,
                    icon: const Icon(CupertinoIcons.calendar),
                    onSelected: (y) => _setYear(y == 0 ? null : y),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 0,
                        height: 28,
                        child: Text('不限'),
                      ),
                      for (var y = DateTime.now().year + 1; y >= 1950; y--)
                        PopupMenuItem(value: y, height: 28, child: Text('$y')),
                    ],
                  ),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
          ],
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

  const _Rating(this.value);

  @override
  Widget build(BuildContext context) {
    const c = Color(0xFFD9A21B);
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
            color: Palette.of(context).text,
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
          color: selected ? p.selected : (hover ? p.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(
            color: selected
                ? p.text.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
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
                        maxLines: 2,
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
                      GradientProgress(
                        value: ratio,
                        height: 4,
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

/// Text cut to [maxLines] with 展开 / 收起 when it doesn't fit.
class ExpandableText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int maxLines;

  const ExpandableText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines = 3,
  });

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  var _open = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final overflows = (TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: widget.maxLines,
      )..layout(maxWidth: box.maxWidth)).didExceedMaxLines;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.text,
            maxLines: _open ? null : widget.maxLines,
            overflow: _open ? null : TextOverflow.ellipsis,
            style: widget.style,
          ),
          if (overflows)
            LinkText(
              _open ? '收起' : '展开',
              key: const ValueKey('expand-overview'),
              onTap: () => setState(() => _open = !_open),
            ),
        ],
      );
    },
  );
}

String seasonTabLabel(int season) => season == 0 ? '特别篇' : '第 $season 季';

enum _RowKind { main, special, extra, ignore }

/// Returns the override for [row], or null when cancelled. For episodes the
/// sheet lists the matched show's TMDB episodes to pick from; typing a season
/// and episode is the fallback (手动填写).
Future<FileOverride?> showEditRowDialog(
  BuildContext context,
  MediaGroup group,
  ReviewRow row, {
  GroupDecision? decision,
  List<ReviewRow> rows = const [],
}) => showDialog<FileOverride>(
  context: context,
  builder: (_) =>
      _EditRowSheet(group: group, row: row, decision: decision, rows: rows),
);

class _EditRowSheet extends ConsumerStatefulWidget {
  final MediaGroup group;
  final ReviewRow row;
  final GroupDecision? decision;
  final List<ReviewRow> rows;

  const _EditRowSheet({
    required this.group,
    required this.row,
    required this.decision,
    required this.rows,
  });

  @override
  ConsumerState<_EditRowSheet> createState() => _EditRowSheetState();
}

class _EditRowSheetState extends ConsumerState<_EditRowSheet> {
  late final row = widget.row;
  late final isTv = widget.group.kind == MediaKind.episode;
  late final current = targetRef(row);
  late final seasonC = TextEditingController(
    text: '${row.season == noSeason ? 1 : row.season}',
  );
  late final epC = TextEditingController(
    text: '${episodeOf(row.file, row.override) ?? ''}',
  );
  late var kind = row.override?.ignore ?? false
      ? _RowKind.ignore
      : switch (row.override?.kind) {
          MediaKind.special => _RowKind.special,
          MediaKind.extra => _RowKind.extra,
          _ => _RowKind.main,
        };
  late var season = current?.season ?? 1;
  EpisodeRef? picked;
  var manual = false;

  MediaKind? get _kind => switch (kind) {
    _RowKind.main =>
      widget.group.kind == MediaKind.movie
          ? MediaKind.movie
          : MediaKind.episode,
    _RowKind.special => MediaKind.special,
    _RowKind.extra => MediaKind.extra,
    _RowKind.ignore => row.override?.kind,
  };

  void _confirm(EpisodeRef e) => Navigator.pop(
    context,
    FileOverride(season: e.season, episode: e.episode, kind: _kind),
  );

  void _save() => Navigator.pop(
    context,
    FileOverride(
      season: isTv ? int.tryParse(seasonC.text) : null,
      episode: isTv ? int.tryParse(epC.text) : null,
      kind: _kind,
      ignore: kind == _RowKind.ignore,
    ),
  );

  @override
  void dispose() {
    seasonC.dispose();
    epC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = effectiveMatch(widget.group, widget.decision);
    final tmdbId = match?.tmdbId;
    final fetch =
        isTv &&
        tmdbId != null &&
        widget.group.show?.info.tmdbId != tmdbId &&
        widget.decision?.episodeGroupId == null;
    final fetched = fetch ? ref.watch(showDetailProvider(tmdbId)) : null;
    final show = fetch ? fetched!.value : widget.group.show;
    final sizes = fetch
        ? {
            for (final s in show?.seasons ?? const <SeasonInfo>[])
              if (s.number > 0) s.number: s.episodeCount,
          }
        : seasonSizes(widget.group, widget.decision);
    final hasSpecials = show?.seasons.any((s) => s.number == 0) ?? false;
    final seasons = switch (kind) {
      _RowKind.main => (sizes.keys.toList()..sort()),
      _RowKind.special when hasSpecials && sizes.isNotEmpty => [0],
      _ => const <int>[],
    };
    final picking = isTv && tmdbId != null && seasons.isNotEmpty && !manual;
    if (picking && !seasons.contains(season)) season = seasons.first;
    final waiting =
        !manual &&
        (fetched?.isLoading ?? false) &&
        (kind == _RowKind.main || kind == _RowKind.special);
    final fields =
        isTv &&
        !picking &&
        !waiting &&
        kind != _RowKind.ignore &&
        kind != _RowKind.extra;
    return MacSheet(
      child: SizedBox(
        width: picking ? 620 : 460,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('修正这个文件', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                row.file.name,
                style: theme.textTheme.bodySmall,
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
                  onChanged: (v) => setState(() {
                    kind = v;
                    picked = null;
                  }),
                ),
              ),
              if (waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (picking) ...[
                const SizedBox(height: 14),
                _showHeader(match!),
                const SizedBox(height: 12),
                Flexible(
                  child: SizedBox(
                    height: 300,
                    child: Panel(
                      framed: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 110, child: _seasonList(seasons)),
                          Container(
                            width: hairline,
                            color: Palette.of(context).line,
                          ),
                          Expanded(child: _episodeList(tmdbId, season)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (fields) ...[
                const SizedBox(height: 12),
                FormRow(
                  label: '季',
                  labelWidth: 56,
                  child: TextField(
                    key: const ValueKey('edit-season'),
                    controller: seasonC,
                    keyboardType: TextInputType.number,
                  ),
                ),
                FormRow(
                  label: '集',
                  labelWidth: 56,
                  child: TextField(
                    key: const ValueKey('edit-episode'),
                    controller: epC,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  if (isTv &&
                      tmdbId != null &&
                      seasons.isNotEmpty &&
                      kind != _RowKind.ignore)
                    TextButton(
                      key: const ValueKey('edit-manual'),
                      onPressed: () => setState(() => manual = !manual),
                      child: Text(manual ? '从 TMDB 剧集里选' : '手动填写季和集'),
                    ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  if (picking) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('pick-confirm'),
                      onPressed: picked == null
                          ? null
                          : () => _confirm(picked!),
                      child: const Text('确认'),
                    ),
                  ],
                  if (!picking && !waiting) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('edit-save'),
                      onPressed: _save,
                      child: const Text('保存'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _showHeader(Candidate m) {
    final p = Palette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Poster(posterPath: m.posterPath, width: 46, height: 69),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (m.year != null) '${m.year}',
                  if (m.overview != null) m.overview!,
                ].join(' | '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _seasonList(List<int> seasons) {
    final p = Palette.of(context);
    return ListView(
      children: [
        for (final s in seasons)
          Hoverable(
            key: ValueKey('pick-season-$s'),
            onTap: () => setState(() => season = s),
            builder: (context, hover) => Container(
              height: 38,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 11),
              decoration: BoxDecoration(
                color: hover ? p.hover : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    width: 3,
                    color: s == season ? p.text : Colors.transparent,
                  ),
                ),
              ),
              child: Text(
                seasonTabLabel(s),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: s == season ? FontWeight.w600 : FontWeight.w400,
                  color: s == season ? null : p.textMuted,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _episodeList(int tmdbId, int season) {
    final p = Palette.of(context);
    // Which file each episode already gets, so double-booking shows.
    final taken = <EpisodeRef, String>{
      for (final r in widget.rows)
        // Later files follow this one when it moves, so they never clash.
        if (r.file.path != row.file.path &&
            r.file.role == FileRole.video &&
            !r.ignored &&
            (episodeOf(r.file, null) ?? 0) < (episodeOf(row.file, null) ?? 0))
          ?targetRef(r): r.file.name,
    };
    return ref
        .watch(seasonEpisodesProvider((tmdbId, season)))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: CupertinoIcons.exclamationmark_triangle,
            title: '读不到这一季的剧集',
            message: '可以用「手动填写季和集」',
          ),
          data: (eps) => ListView(
            padding: const EdgeInsets.all(4),
            children: [
              for (final e in eps)
                Hoverable(
                  key: ValueKey('pick-ep-$season-${e.number}'),
                  onTap: () =>
                      setState(() => picked = EpisodeRef(season, e.number)),
                  builder: (context, hover) {
                    final ref = EpisodeRef(season, e.number);
                    final isCurrent = ref == current;
                    final other = taken[ref];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: ref == picked
                            ? p.selected
                            : hover
                            ? p.hover
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 34,
                            child: Text(
                              'E${_pad(e.number)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: p.textMuted,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  [
                                    e.title ?? '第 ${e.number} 集',
                                    if (e.airDate != null) fmtDate(e.airDate),
                                  ].join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                if (other != null)
                                  Text(
                                    '已对应：$other',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: p.warning,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Icon(
                              CupertinoIcons.checkmark,
                              size: 13,
                              color: p.text,
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        );
  }
}

/// Artwork header: blurred backdrop (or warm gradient), poster, titles,
/// metadata, synopsis and completeness.
class WorkHeader extends StatelessWidget {
  final MediaGroup group;
  final GroupDecision? decision;

  /// Season shown below: its poster replaces the show's when TMDB has one.
  final int? season;

  const WorkHeader({
    super.key,
    required this.group,
    required this.decision,
    this.season,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final g = group;
    final m = effectiveMatch(g, decision);
    final detailShow = g.show?.info.tmdbId == m?.tmdbId ? g.show : null;
    final detail = detailShow?.info;
    final backdrop = m?.backdropPath ?? detail?.backdropPath;
    final overview = m?.overview ?? detail?.overview;
    final genres = (detail?.genres.isNotEmpty ?? false)
        ? detail!.genres
        : (m?.genres ?? const <String>[]);
    final isTv = g.kind == MediaKind.episode;
    final comp = completeness(g, decision);
    final onImage = backdrop != null;
    // Artwork is only an ambient tint under a frosted panel; text stays dark.
    final fg = p.text;
    final fgMuted = p.textMuted;

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
              child: Image(
                image: CachedImage(tmdbImage(backdrop, 'w1280')),
                fit: BoxFit.cover,
                alignment: Alignment.topRight,
                errorBuilder: (_, _, _) => ColoredBox(color: p.accentSoft),
              ),
            ),
            // Opaque behind the text on the left, artwork showing on the right.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0, 0.5, 1],
                    colors: [
                      p.panel.withValues(alpha: 0.97),
                      p.panel.withValues(alpha: 0.86),
                      p.panel.withValues(alpha: 0.18),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.center,
                    colors: [
                      p.panel.withValues(alpha: 0.9),
                      p.panel.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Poster(
                  posterPath:
                      detailShow?.seasons
                          .where((x) => x.number == season)
                          .firstOrNull
                          ?.posterPath ??
                      m?.posterPath,
                  icon: isTv ? CupertinoIcons.tv : CupertinoIcons.film,
                  width: 112,
                  height: 168,
                  radius: 9,
                ),
                const SizedBox(width: 20),
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
                              detail?.title ?? m?.title ?? g.anchorTitle,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: fg,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (m?.voteAverage != null &&
                              m!.voteAverage! > 0) ...[
                            const SizedBox(width: 10),
                            _Rating(m.voteAverage!),
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
                                color: p.panel.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: p.line,
                                  width: hairline,
                                ),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: t == comp.label && comp.incomplete
                                      ? p.warning
                                      : fg,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (isTv &&
                          m != null &&
                          (comp.tmdbEpisodes ?? 0) > 0) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: 220,
                          child: GradientProgress(
                            value: comp.localEpisodes / comp.tmdbEpisodes!,
                            color: comp.incomplete ? p.warning : p.success,
                            height: 5,
                          ),
                        ),
                      ],
                      if (overview != null) ...[
                        const SizedBox(height: 10),
                        ExpandableText(
                          key: ValueKey(overview),
                          overview,
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

  /// Put the row at this episode and renumber the files after it.
  final void Function(ReviewRow, EpisodeRef) onShift;

  const DetailPane({
    super.key,
    required this.group,
    required this.decision,
    required this.review,
    required this.tab,
    required this.onTab,
    required this.onEdit,
    required this.onCheck,
    required this.onShift,
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

    // Videos ordered by episode, each carrying the subtitles / audio / other
    // files named after it ("Show.S01E01.mkv" → "Show.S01E01.zh.ass").
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
      String base(String n) {
        final i = n.lastIndexOf('.');
        return i <= 0 ? n : n.substring(0, i);
      }

      // Each companion goes to the video with the longest matching name.
      final owned = <ReviewRow, List<ReviewRow>>{for (final v in videos) v: []};
      final videoRef = {for (final v in videos) v: targetRef(v)};
      final loose = <ReviewRow>[];
      for (final o in others) {
        ReviewRow? best;
        for (final v in videos) {
          final b = base(v.file.name);
          if (o.file.name.startsWith('$b.') &&
              (best == null || b.length > base(best.file.name).length)) {
            best = v;
          }
        }
        // Names often differ ("… [1080p].mkv" vs "….chs.ass"): same episode.
        final ref = targetRef(o);
        best ??= ref == null
            ? null
            : videos.where((v) => videoRef[v] == ref).firstOrNull;
        best == null ? loose.add(o) : owned[best]!.add(o);
      }

      final slots = <(int, _Entry)>[];
      for (final v in videos) {
        slots.add((
          targetRef(v)?.episode ?? 1 << 20,
          _Entry.video(v, owned[v]!),
        ));
      }
      for (final e in missing) {
        slots.add((e, _Entry.missing(e)));
      }
      // Stable: missing rows slot in before the first video of a later episode.
      slots.sort((a, b) => a.$1.compareTo(b.$1));
      entries.addAll(slots.map((s) => s.$2));
      for (final o in loose) {
        entries.add(_Entry.sidecar(o));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        WorkHeader(group: group, decision: decision, season: current),
        if (!(decision?.selected ?? true)) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('unchecked-note'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Palette.of(context).warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Text(
              m == null
                  ? '还没有匹配作品，执行时会跳过。先在右侧「重新搜索 TMDB」选定作品。'
                  : '这个作品没有勾选，执行时会跳过，下面也不会生成新名字。在左侧列表勾选它即可。',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
        if (seasonOverflow(group, decision, rows) case final o?) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('overflow-note'),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: Palette.of(context).warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '「${o.row.file.name}」排到了 '
                    'S${_pad(o.target.season)}E${_pad(o.target.episode)}，'
                    '但 TMDB 第 ${o.target.season} 季只有 ${o.size} 集。'
                    '要改成 S${_pad(o.target.season + 1)}E01，后面的文件依次顺延吗？',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('overflow-apply'),
                  onPressed: () =>
                      onShift(o.row, EpisodeRef(o.target.season + 1, 1)),
                  child: const Text('改成并顺延'),
                ),
              ],
            ),
          ),
        ],
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
                color: s == noSeason ? null : seasonColor(s),
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
                  if (e.companions.isNotEmpty)
                    _VideoBlock(
                      key: ValueKey('block ${e.row!.file.path}'),
                      video: _withMenu(e, current),
                      companions: [
                        for (final c in e.companions)
                          _withMenu(_Entry.sidecar(c), current),
                      ],
                      summary: _companionSummary(e.companions),
                      startOpen: e.companions.any(
                        (c) => c.conflict || c.ignored,
                      ),
                    )
                  else
                    _withMenu(e, current),
              ],
            ),
          ),
      ],
    );
  }

  Widget _withMenu(_Entry e, int current) {
    final row = e.row;
    if (row == null) return _rowFor(e, current);
    return ContextMenuArea(
      items: () => [
        MenuAction('修改对应关系…', () => onEdit(row), icon: CupertinoIcons.pencil),
        MenuAction(
          row.ignored ? '恢复（参与整理）' : '忽略这个文件',
          () => onCheck(row, row.ignored),
          icon: row.ignored
              ? CupertinoIcons.arrow_uturn_left
              : CupertinoIcons.eye_slash,
        ),
      ],
      child: _rowFor(e, current),
    );
  }

  /// "2 个字幕 · 1 条音轨 · 1 个其他".
  static String _companionSummary(List<ReviewRow> rows) {
    var subs = 0, audio = 0, other = 0;
    for (final r in rows) {
      if (r.file.role == FileRole.subtitle) {
        subs++;
      } else if (_audioExt.contains(
        r.file.name.split('.').last.toLowerCase(),
      )) {
        audio++;
      } else {
        other++;
      }
    }
    return [
      if (subs > 0) '$subs 个字幕',
      if (audio > 0) '$audio 条音轨',
      if (other > 0) '$other 个其他文件',
    ].join(' · ');
  }

  Widget _rowFor(_Entry e, int current) {
    final m = effectiveMatch(group, decision);
    return switch (e) {
      _Entry(:final row?, sidecar: false) => _EpisodeRow(
        row: row,
        tmdbId: group.kind == MediaKind.episode ? m?.tmdbId : null,
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
    };
  }
}

const _audioExt = {'mka', 'ac3', 'eac3', 'dts', 'dtshd', 'truehd'};

class _Entry {
  final ReviewRow? row;
  final bool sidecar;
  final int? missingEpisode;

  /// Subtitles / audio / other files that follow this video.
  final List<ReviewRow> companions;

  const _Entry.video(ReviewRow this.row, [this.companions = const []])
    : sidecar = false,
      missingEpisode = null;
  const _Entry.sidecar(ReviewRow this.row)
    : sidecar = true,
      missingEpisode = null,
      companions = const [];
  const _Entry.missing(int this.missingEpisode)
    : row = null,
      sidecar = false,
      companions = const [];
}

/// A video row with its companions folded under a "▸ 2 个字幕" line. Opens
/// by itself when a companion needs attention.
class _VideoBlock extends StatefulWidget {
  final Widget video;
  final List<Widget> companions;
  final String summary;
  final bool startOpen;

  const _VideoBlock({
    super.key,
    required this.video,
    required this.companions,
    required this.summary,
    required this.startOpen,
  });

  @override
  State<_VideoBlock> createState() => _VideoBlockState();
}

class _VideoBlockState extends State<_VideoBlock> {
  late var _open = widget.startOpen;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.video,
        Hoverable(
          onTap: () => setState(() => _open = !_open),
          builder: (context, hover) => Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 12, 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    CupertinoIcons.chevron_right,
                    size: 10,
                    color: p.textFaint,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  widget.summary,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hover ? p.text : p.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.companions,
            ),
          ),
      ],
    );
  }
}

class _SeasonChip extends StatelessWidget {
  final String label;
  final String? posterPath;
  final IconData? icon;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _SeasonChip({
    super.key,
    required this.label,
    this.posterPath,
    this.icon,
    this.color,
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
        // Fixed: a chip with a poster and one with an icon line up.
        height: 34,
        padding: EdgeInsets.fromLTRB(posterPath != null ? 4 : 10, 0, 11, 0),
        decoration: BoxDecoration(
          color: selected
              ? (color ?? p.text)
              : (hover ? (color ?? p.text).withValues(alpha: 0.07) : p.panel),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? (color ?? p.text)
                : (color?.withValues(alpha: 0.35) ?? p.line),
            width: selected ? hairline : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: (color ?? p.text).withValues(alpha: 0.28),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (posterPath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image(
                  image: CachedImage(tmdbImage(posterPath!, 'w92')),
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
            ] else if (color != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? Colors.white : color,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? (color == null ? p.canvas : Colors.white)
                    : p.text,
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
  final Color? color;

  const _EpBadge(this.text, {this.dim = false, this.color});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color;
    return Container(
      width: 34,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dim
            ? Colors.transparent
            : (c?.withValues(alpha: 0.13) ?? p.sidebar),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: dim ? p.lineStrong : (c?.withValues(alpha: 0.3) ?? p.line),
          width: dim ? 1 : hairline,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: dim ? p.textFaint : (c ?? p.text),
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
    // The planner flags real guesses on the op ("识别置信度较低"); only a file
    // it skipped falls back to the parser's own confidence.
    final lowConfidence =
        r.op == null &&
        r.file.parsed != null &&
        r.file.parsed!.confidence < 0.7;

    final issue = r.conflict
        ? p.danger
        : (r.op?.warning != null || lowConfidence ? p.warning : null);
    return Hoverable(
      onTap: onEdit,
      builder: (context, hover) => Container(
        decoration: BoxDecoration(
          color: hover
              ? p.hover
              : (issue?.withValues(alpha: 0.05) ?? Colors.transparent),
          border: Border(
            left: BorderSide(color: issue ?? Colors.transparent, width: 3),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(3, 9, 12, 9),
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
                  : _EpBadge(
                      badge,
                      color: target == null || r.ignored
                          ? null
                          : seasonColor(target.season),
                    ),
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
                  Tooltip(
                    message: [
                      '原：${r.file.path}',
                      if (r.op != null && r.op!.dst.isNotEmpty)
                        '新：${r.op!.dst}',
                    ].join('\n'),
                    waitDuration: const Duration(milliseconds: 700),
                    // 原名 → 新名, reading order: what it is now, then what it becomes.
                    child: Text(
                      r.file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: p.textFaint),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(
                          CupertinoIcons.arrow_right,
                          size: 10,
                          color: p.textFaint,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          newName,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: tmdbId != null ? 12.5 : 13,
                            color: r.ignored
                                ? p.textFaint
                                : (tmdbId != null ? p.textMuted : p.text),
                            fontWeight: tmdbId != null ? null : FontWeight.w500,
                            decoration: r.ignored
                                ? TextDecoration.lineThrough
                                : null,
                          ),
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
      _ when _audioExt.contains(r.file.name.split('.').last.toLowerCase()) =>
        CupertinoIcons.music_note,
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
                    r.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.textFaint),
                  ),
                  Text(
                    '→ ${r.ignored ? '已忽略' : r.newName ?? '（无改动）'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: r.ignored ? p.textFaint : p.textMuted,
                      decoration: r.ignored ? TextDecoration.lineThrough : null,
                    ),
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
                    color: o.kind == OpKind.delete ? p.danger : p.textMuted,
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
                            OpKind.relocate => o.src,
                          },
                          style: o.kind == OpKind.relocate
                              ? TextStyle(fontSize: 11.5, color: p.textFaint)
                              : const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                        ),
                        if (o.kind == OpKind.relocate)
                          Text(
                            '→ ${o.dst}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
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
                color: selected ? p.text : p.lineStrong,
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

/// Why a file joined no work, in words.
String unassignedReason(ScanFile f) => switch (f.role) {
  FileRole.junk => '广告或垃圾文件',
  FileRole.video => '没识别出所属作品',
  FileRole.subtitle || FileRole.sidecar => '没找到对应的视频',
  FileRole.other => '不认识的文件类型',
};

/// Files no work claimed, by folder. Read-only: they are never touched.
class UnassignedPane extends StatelessWidget {
  final List<ScanFile> files;

  const UnassignedPane({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final byDir = <String, List<ScanFile>>{};
    for (final f in files) {
      final i = f.path.lastIndexOf('/');
      (byDir[i <= 0 ? '/' : f.path.substring(0, i)] ??= []).add(f);
    }
    final dirs = byDir.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        Text(
          '未归类 ${files.length} 个文件',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '这些文件没归进任何作品，执行时原样保留。',
          style: TextStyle(fontSize: 12.5, color: p.textMuted),
        ),
        for (final d in dirs) ...[
          const SizedBox(height: 14),
          Text(
            d,
            style: TextStyle(fontSize: 12, color: p.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Panel(
            child: Rows(
              children: [
                for (final f in byDir[d]!)
                  Padding(
                    key: ValueKey('unassigned ${f.path}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            f.name,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${fmtSize(f.size)} · ${unassignedReason(f)}',
                          style: TextStyle(fontSize: 12, color: p.textFaint),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
