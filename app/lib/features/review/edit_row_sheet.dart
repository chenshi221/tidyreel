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

/// Seasons of a show the user matched by hand; group.show only has the show
/// the recognizer found.
final showDetailProvider = FutureProvider.autoDispose.family<ShowDetail, int>(
  (ref, id) => ref.watch(metadataProvider).show(id),
);

String seasonTabLabel(int season) => season == 0 ? '特别篇' : '第 $season 季';

String _pad(int n) => n.toString().padLeft(2, '0');

enum _RowKind { main, special, extra, ignore }

/// Outcome of [showEditRowDialog]: the edited override plus whether later files
/// in the same local season should be shifted accordingly.
class EditRowResult {
  final FileOverride override;
  final bool shiftFollowing;

  const EditRowResult(this.override, {this.shiftFollowing = true});
}

/// Returns the override for [row], or null when cancelled. For episodes the
/// sheet lists the matched show's TMDB episodes to pick from; typing a season
/// and episode is the fallback (手动填写).
Future<EditRowResult?> showEditRowDialog(
  BuildContext context,
  MediaGroup group,
  ReviewRow row, {
  GroupDecision? decision,
  List<ReviewRow> rows = const [],
}) => showDialog<EditRowResult>(
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
  EpisodeRef? _lastTapRef;
  DateTime? _lastTapAt;
  var manual = false;
  var shiftFollowing = true;

  void _tapEpisode(EpisodeRef ref) {
    final now = DateTime.now();
    if (_lastTapRef == ref &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 350)) {
      _confirm(ref);
      return;
    }
    _lastTapRef = ref;
    _lastTapAt = now;
    setState(() => picked = ref);
  }

  MediaKind? get _kind => switch (kind) {
    _RowKind.main =>
      widget.group.kind == MediaKind.movie
          ? MediaKind.movie
          : MediaKind.episode,
    _RowKind.special => MediaKind.special,
    _RowKind.extra => MediaKind.extra,
    _RowKind.ignore => row.override?.kind,
  };

  String? _validationError(bool fields) {
    if (!fields) return null;
    final s = int.tryParse(seasonC.text.trim());
    if (s == null || s < 0) return '季号需为不小于 0 的整数';
    final e = int.tryParse(epC.text.trim());
    if (e == null || e < 1) return '集号需为大于 0 的整数';
    return null;
  }

  void _confirm(EpisodeRef e) => Navigator.pop(
    context,
    EditRowResult(
      FileOverride(season: e.season, episode: e.episode, kind: _kind),
      shiftFollowing: shiftFollowing,
    ),
  );

  void _save() => Navigator.pop(
    context,
    EditRowResult(
      FileOverride(
        season: isTv ? int.tryParse(seasonC.text.trim()) : null,
        episode: isTv ? int.tryParse(epC.text.trim()) : null,
        kind: _kind,
        ignore: kind == _RowKind.ignore,
      ),
      shiftFollowing: shiftFollowing,
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
    final groupWithShow = fetch && show != null
        ? MediaGroup(
            id: widget.group.id,
            kind: widget.group.kind,
            anchorTitle: widget.group.anchorTitle,
            anchorYear: widget.group.anchorYear,
            rootDir: widget.group.rootDir,
            files: widget.group.files,
            match: widget.group.match,
            matchScore: widget.group.matchScore,
            show: show,
          )
        : widget.group;
    final sizes = seasonSizes(groupWithShow, widget.decision);
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
    final error = _validationError(fields);
    final laterCount =
        isTv && row.file.role == FileRole.video && kind == _RowKind.main
        ? shiftFollowingCount(widget.rows, row)
        : 0;
    final showShiftOption = !waiting && laterCount > 0;

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
                  child: Center(child: Spinner(size: 18)),
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
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                FormRow(
                  label: '集',
                  labelWidth: 56,
                  child: TextField(
                    key: const ValueKey('edit-episode'),
                    controller: epC,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    error,
                    key: const ValueKey('edit-validation-error'),
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: Palette.of(context).danger,
                    ),
                  ),
                ],
              ],
              if (showShiftOption) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Checkbox(
                      key: const ValueKey('edit-shift-following'),
                      value: shiftFollowing,
                      onChanged: (v) =>
                          setState(() => shiftFollowing = v ?? true),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '同时顺延本季后续集号（影响后续 $laterCount 个文件）',
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          color: Palette.of(context).textMuted,
                        ),
                      ),
                    ),
                  ],
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
                      onPressed: error != null ? null : _save,
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
                  fontSize: TypeScale.body,
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
        // When shifting, later files follow this one so they never clash.
        if (r.file.path != row.file.path &&
            r.file.role == FileRole.video &&
            !r.ignored &&
            (!shiftFollowing ||
                (episodeOf(r.file, null) ?? 0) <
                    (episodeOf(row.file, null) ?? 0)))
          ?targetRef(r): r.file.name,
    };
    return ref
        .watch(seasonEpisodesProvider((tmdbId, season)))
        .when(
          loading: () => const Center(child: Spinner(size: 18)),
          error: (e, _) => const EmptyState(
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
                  onTap: () => _tapEpisode(EpisodeRef(season, e.number)),
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
                        borderRadius: BorderRadius.circular(Radii.sm),
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
                                      fontSize: TypeScale.small,
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
