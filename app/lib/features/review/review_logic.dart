import 'package:tidyreel_core/tidyreel_core.dart';

/// Pure helpers for the review page (no Flutter), so they stay easy to test.

Candidate? effectiveMatch(MediaGroup g, GroupDecision? d) =>
    d?.match ?? g.match;

bool isMatched(MediaGroup g, GroupDecision? d) => effectiveMatch(g, d) != null;

/// Season bucket used for the tabs: -1 for movies / unknown groups.
const noSeason = -1;

int seasonOf(MediaGroup g, ScanFile f, FileOverride? o) =>
    g.kind == MediaKind.episode
    ? (o?.season ?? f.parsed?.season ?? 1)
    : noSeason;

int? episodeOf(ScanFile f, FileOverride? o) =>
    o?.episode ?? f.parsed?.episodes.firstOrNull;

class Completeness {
  final int localSeasons;
  final int localEpisodes;
  final int? tmdbSeasons;
  final int? tmdbEpisodes;

  const Completeness(
    this.localSeasons,
    this.localEpisodes,
    this.tmdbSeasons,
    this.tmdbEpisodes,
  );

  bool get incomplete => tmdbEpisodes != null && localEpisodes < tmdbEpisodes!;

  String get label {
    final local = '本地 $localSeasons 季 $localEpisodes 集';
    return tmdbEpisodes == null
        ? local
        : '$local / TMDB $tmdbSeasons 季 $tmdbEpisodes 集';
  }
}

Completeness completeness(MediaGroup g, GroupDecision? d) {
  final eps = <EpisodeRef>{};
  for (final f in g.files) {
    if (f.role != FileRole.video) continue;
    final o = d?.overrides[f.path];
    if (o?.ignore ?? false) continue;
    final e = episodeOf(f, o);
    if (e != null) eps.add(EpisodeRef(seasonOf(g, f, o), e));
  }
  final real = g.show?.seasons.where((s) => s.number > 0).toList();
  return Completeness(
    eps.map((e) => e.season).toSet().length,
    eps.length,
    real?.length,
    real?.fold<int>(0, (a, s) => a + s.episodeCount),
  );
}

/// One file in the middle pane with its planned op (matched by `op.src == file.path`).
class ReviewRow {
  final ScanFile file;
  final RenameOp? op;
  final FileOverride? override;
  final int season;
  final bool conflict;

  const ReviewRow(
    this.file,
    this.op,
    this.override,
    this.season,
    this.conflict,
  );

  bool get ignored => override?.ignore ?? false;

  String? get newName =>
      op == null || op!.dst.isEmpty ? null : op!.dst.split('/').last;
}

List<ReviewRow> rowsOf(MediaGroup g, GroupDecision? d, TaskReview r) {
  final bySrc = {for (final o in r.preview.ops) o.src: o};
  final conflictOps = {for (final c in r.preview.conflicts) ...c.ops};
  return [
    for (final f in g.files)
      ReviewRow(
        f,
        bySrc[f.path],
        d?.overrides[f.path],
        seasonOf(g, f, d?.overrides[f.path]),
        bySrc[f.path] != null && conflictOps.contains(bySrc[f.path]!.id),
      ),
  ];
}

/// Ops of [g] that are not tied to a single scanned file (mkdir / folder moves).
List<RenameOp> folderOps(MediaGroup g, TaskReview r) {
  final paths = {for (final f in g.files) f.path};
  return [
    for (final o in r.preview.ops)
      if (o.group == g.id && !paths.contains(o.src)) o,
  ];
}

/// Episodes present locally in [season] over the TMDB count, e.g. "12/12".
String seasonCountLabel(MediaGroup g, List<ReviewRow> rows, int season) {
  final local = {
    for (final r in rows)
      if (r.season == season &&
          r.file.role == FileRole.video &&
          !r.ignored &&
          episodeOf(r.file, r.override) != null)
        episodeOf(r.file, r.override),
  }.length;
  final tmdb = g.show?.seasons.where((s) => s.number == season).firstOrNull;
  return tmdb == null ? '$local' : '$local/${tmdb.episodeCount}';
}

const _parser = RuleBasedParser();

/// Season/episode the file ends up as: parsed back from the planned new name
/// (so strategies and offsets are reflected), falling back to the source.
EpisodeRef? targetRef(ReviewRow r) {
  final name = r.newName;
  if (name != null) {
    final p = _parser.parse(name);
    final e = p.episodes.firstOrNull;
    if (p.season != null && e != null) return EpisodeRef(p.season!, e);
  }
  final e = episodeOf(r.file, r.override);
  if (r.season == noSeason || e == null) return null;
  return EpisodeRef(r.season, e);
}

/// TMDB episode numbers of [season] with no local video, when local numbering
/// maps 1:1 onto TMDB (default strategy, no offset); empty otherwise.
List<int> missingEpisodes(
  MediaGroup g,
  GroupDecision? d,
  List<ReviewRow> rows,
  int season,
) {
  if (d != null &&
      (d.strategy != SeasonStrategy.asParsed ||
          d.episodeOffset != 0 ||
          d.episodeGroupId != null)) {
    return const [];
  }
  final total = g.show?.seasons
      .where((s) => s.number == season)
      .firstOrNull
      ?.episodeCount;
  if (total == null || season == noSeason) return const [];
  final have = {
    for (final r in rows)
      if (r.season == season && r.file.role == FileRole.video && !r.ignored)
        ?episodeOf(r.file, r.override),
  };
  return [
    for (var e = 1; e <= total; e++)
      if (!have.contains(e)) e,
  ];
}
