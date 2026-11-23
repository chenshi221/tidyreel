import 'package:tidyreel_core/tidyreel_core.dart';

/// Pure helpers for the review page (no Flutter), so they stay easy to test.

Candidate? effectiveMatch(MediaGroup g, GroupDecision? d) =>
    d?.match ?? g.match;

bool isMatched(MediaGroup g, GroupDecision? d) => effectiveMatch(g, d) != null;

/// [g] as the match in [d] makes it: picking a show for a folder recognized
/// as a movie makes it a show (the planner goes by the match too).
MediaGroup effectiveGroup(MediaGroup g, GroupDecision? d) {
  final m = effectiveMatch(g, d);
  if (m == null || m.kind == g.kind) return g;
  final sameMatch = d?.match == null || d?.match?.tmdbId == g.match?.tmdbId;
  return MediaGroup(
    id: g.id,
    kind: m.kind,
    anchorTitle: g.anchorTitle,
    anchorYear: g.anchorYear,
    rootDir: g.rootDir,
    files: g.files,
    match: g.match,
    matchScore: g.matchScore,
    show: sameMatch ? g.show : null,
    suggestedStrategy: sameMatch ? g.suggestedStrategy : null,
    suggestedStrategyReason: sameMatch ? g.suggestedStrategyReason : null,
  );
}

/// Season bucket used for the tabs: -1 for movies / unknown groups.
const noSeason = -1;

int seasonOf(MediaGroup g, ScanFile f, FileOverride? o) =>
    g.kind == MediaKind.episode
    ? (o?.season ?? f.parsed?.season ?? 1)
    : noSeason;

/// Like the planner: a bare number ("01.mkv") counts as the episode.
int? episodeOf(ScanFile f, FileOverride? o) =>
    o?.episode ?? f.parsed?.episodes.firstOrNull ?? f.parsed?.absolute;

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

  String get label => localizedLabel();

  String localizedLabel({bool isEn = false}) {
    if (isEn) {
      final local = 'Local ${localSeasons}S ${localEpisodes}E';
      return tmdbEpisodes == null
          ? local
          : '$local / TMDB ${tmdbSeasons}S ${tmdbEpisodes}E';
    }
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
  final String? conflictReason;

  const ReviewRow(
    this.file,
    this.op,
    this.override,
    this.season,
    this.conflict, [
    this.conflictReason,
  ]);

  bool get ignored => override?.ignore ?? false;

  bool get selected => !ignored && (op?.selected ?? false);

  String? get newName =>
      op == null || op!.dst.isEmpty ? null : op!.dst.split('/').last;

  /// What the row shows after the arrow.
  String get newLabel => localizedNewLabel();

  String localizedNewLabel({bool isEn = false}) => ignored
      ? (isEn ? 'Ignored' : '已忽略')
      : op != null && op!.src == op!.dst
      ? (isEn ? '(Unchanged)' : '（名称不变）')
      : newName ?? (isEn ? '(No change)' : '（无改动）');
}

List<ReviewRow> rowsOf(MediaGroup g, GroupDecision? d, TaskReview r) {
  final bySrc = {for (final o in r.preview.ops) o.src: o};
  final conflictByOp = <OpId, PlanConflict>{
    for (final c in r.preview.conflicts)
      for (final id in c.ops) id: c,
  };
  return [
    for (final f in g.files)
      ReviewRow(
        f,
        bySrc[f.path],
        d?.overrides[f.path],
        seasonOf(g, f, d?.overrides[f.path]),
        bySrc[f.path] != null && conflictByOp.containsKey(bySrc[f.path]!.id),
        bySrc[f.path] == null ? null : conflictByOp[bySrc[f.path]!.id]?.reason,
      ),
  ];
}

/// Group IDs that have at least one op involved in [r.preview.conflicts].
Set<GroupId> conflictGroups(TaskReview r) {
  if (r.preview.conflicts.isEmpty) return const {};
  final conflictOps = {for (final c in r.preview.conflicts) ...c.ops};
  final byPath = <String, GroupId>{
    for (final g in r.scan.groups)
      for (final f in g.files) f.path: g.id,
  };
  final out = <GroupId>{};
  for (final o in r.preview.ops) {
    if (!conflictOps.contains(o.id)) continue;
    final gid = o.group ?? byPath[o.src];
    if (gid != null) out.add(gid);
  }
  return out;
}

/// First group (and its conflicting season, or null if it's a folder conflict)
/// involved in [r.preview.conflicts].
({GroupId group, int? season})? firstConflictLocation(TaskReview r) {
  final groups = conflictGroups(r);
  if (groups.isEmpty) return null;
  for (final g in r.scan.groups) {
    if (!groups.contains(g.id)) continue;
    final d = r.decisions[g.id];
    final eg = effectiveGroup(g, d);
    final bad = rowsOf(eg, d, r).where((row) => row.conflict).firstOrNull;
    return (group: g.id, season: bad?.season);
  }
  return null;
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

/// Episodes per regular season from TMDB, when [g.show] is the show the group
/// is matched to and no episode group reshapes the seasons; empty otherwise.
Map<int, int> seasonSizes(MediaGroup g, GroupDecision? d) {
  final show = g.show;
  if (show == null ||
      d?.episodeGroupId != null ||
      show.info.tmdbId != effectiveMatch(g, d)?.tmdbId) {
    return const {};
  }
  return {
    for (final s in show.seasons)
      if (s.number > 0) s.number: s.episodeCount,
  };
}

/// The file's own number ("12.mkv" -> 12), ignoring any correction.
int? _localEpisode(ScanFile f) =>
    f.parsed?.episodes.firstOrNull ?? f.parsed?.absolute;

bool _isMainVideo(ReviewRow r) {
  if (r.file.role != FileRole.video || r.ignored) return false;
  final kind = r.override?.kind ?? r.file.parsed?.kind;
  if (kind == MediaKind.special || kind == MediaKind.extra) return false;
  if ((r.override?.season ?? r.file.parsed?.season) == 0) return false;
  return true;
}

/// Number of later main-video files in the same local season that [shiftFrom]
/// would renumber alongside [from].
int shiftFollowingCount(List<ReviewRow> rows, ReviewRow from) {
  final start = _localEpisode(from.file);
  if (start == null) return 0;
  final localSeason = from.file.parsed?.season ?? 1;
  var count = 0;
  for (final r in rows) {
    if (_isMainVideo(r) &&
        r.file.path != from.file.path &&
        (r.file.parsed?.season ?? 1) == localSeason &&
        (_localEpisode(r.file) ?? 0) > start) {
      count++;
    }
  }
  return count;
}

/// Puts [from] at [to] and shifts every later file of the same local season
/// after it by its local-episode delta (preserving missing-episode gaps and
/// keeping duplicate representations of the same episode together), moving into
/// the next season when TMDB says one is full. Returns the overrides to set,
/// [from]'s included.
Map<String, FileOverride> shiftFrom(
  MediaGroup g,
  GroupDecision? d,
  List<ReviewRow> rows,
  ReviewRow from,
  EpisodeRef to, {
  MediaKind? kind,
}) {
  final out = {
    from.file.path: FileOverride(
      season: to.season,
      episode: to.episode,
      kind: kind,
    ),
  };
  final start = _localEpisode(from.file);
  if (start == null || to.season < 1) return out;
  final localSeason = from.file.parsed?.season ?? 1;
  final later = [
    for (final r in rows)
      if (_isMainVideo(r) &&
          r.file.path != from.file.path &&
          (r.file.parsed?.season ?? 1) == localSeason &&
          (_localEpisode(r.file) ?? 0) > start)
        r,
  ]..sort((a, b) => _localEpisode(a.file)!.compareTo(_localEpisode(b.file)!));
  final sizes = seasonSizes(g, d);
  var prevLocal = start;
  var s = to.season, e = to.episode;
  for (final r in later) {
    final curLocal = _localEpisode(r.file)!;
    final delta = curLocal - prevLocal;
    for (var step = 0; step < delta; step++) {
      e++;
      final size = sizes[s];
      if (size != null && e > size && sizes.containsKey(s + 1)) {
        s++;
        e = 1;
      }
    }
    prevLocal = curLocal;
    out[r.file.path] = FileOverride(
      season: s,
      episode: e,
      kind: r.override?.kind,
    );
  }
  return out;
}

/// The first file planned past the end of its TMDB season while a next
/// season exists, e.g. "12.mkv" -> S01E12 when season 1 has 11 episodes.
({ReviewRow row, EpisodeRef target, int size})? seasonOverflow(
  MediaGroup g,
  GroupDecision? d,
  List<ReviewRow> rows,
) {
  final sizes = seasonSizes(g, d);
  ({ReviewRow row, EpisodeRef target, int size})? best;
  for (final r in rows) {
    if (!_isMainVideo(r) || r.op == null) continue;
    final t = targetRef(r);
    final size = t == null ? null : sizes[t.season];
    if (t == null || size == null || t.episode <= size) continue;
    if (!sizes.containsKey(t.season + 1)) continue;
    if (best == null ||
        t.season < best.target.season ||
        (t.season == best.target.season && t.episode < best.target.episode)) {
      best = (row: r, target: t, size: size);
    }
  }
  return best;
}

// ---------------------------------------------------------------- filters

/// Left-pane quick filter chips on the matched ("可整理") tab.
enum ReviewFilter { all, conflict, incomplete, lowConfidence }

/// Whether [g] is a TV show missing episodes compared to TMDB.
bool isGroupIncomplete(MediaGroup g, GroupDecision? d) {
  final eg = effectiveGroup(g, d);
  return eg.kind == MediaKind.episode && completeness(eg, d).incomplete;
}

/// Whether [g] has a low match score or any non-ignored low-confidence file.
bool isGroupLowConfidence(
  MediaGroup g,
  GroupDecision? d,
  TaskReview r, {
  double threshold = 0.7,
}) {
  final lowMatch =
      d?.match == null && g.match != null && g.matchScore < threshold;
  if (lowMatch) return true;
  final bySrc = {for (final o in r.preview.ops) o.src: o};
  for (final f in g.files) {
    final ov = d?.overrides[f.path];
    if (ov?.ignore ?? false) continue;
    final op = bySrc[f.path];
    if (op?.warning != null && op!.warning!.contains('置信度')) {
      return true;
    }
    if (d?.match == null &&
        f.role == FileRole.video &&
        ov == null &&
        f.parsed != null &&
        f.parsed!.confidence < threshold) {
      return true;
    }
  }
  return false;
}

/// Whether [g] passes [filter] on the review list.
bool matchesReviewFilter(
  MediaGroup g,
  GroupDecision? d,
  TaskReview r,
  ReviewFilter filter, {
  Set<GroupId>? conflicts,
  double threshold = 0.7,
}) {
  return switch (filter) {
    ReviewFilter.all => true,
    ReviewFilter.conflict => (conflicts ?? conflictGroups(r)).contains(g.id),
    ReviewFilter.incomplete => isGroupIncomplete(g, d),
    ReviewFilter.lowConfidence => isGroupLowConfidence(
      g,
      d,
      r,
      threshold: threshold,
    ),
  };
}

// ---------------------------------------------------------------- tech badges & diff

/// Compact technical badges derived from [file] and its [ParsedName] / [MediaProbeInfo].
List<String> fileTechBadges(ScanFile file, {bool isEn = false}) {
  final p = file.parsed;
  final badges = <String>[];
  if (file.isDiscDir || (p?.isDisc ?? false)) {
    badges.add(isEn ? 'Disc' : '原盘');
  }
  if (p != null) {
    final tech = <String>[];
    final seenTech = <String>{};
    void addTech(String? raw) {
      final t = raw?.trim();
      if (t == null || t.isEmpty) return;
      if (seenTech.add(t.toLowerCase())) tech.add(t);
    }

    addTech(p.resolution ?? p.probe?.resolution);
    if (p.extraInfo != null && p.extraInfo!.trim().isNotEmpty) {
      for (final part in p.extraInfo!.trim().split(RegExp(r'[._\s]+'))) {
        addTech(part);
      }
    }
    if (p.probe != null) {
      addTech(p.probe!.hdr);
      addTech(p.probe!.audioCodec);
      if (tech.length <= 1) {
        addTech(p.probe!.videoCodec);
      }
    }
    if (tech.isNotEmpty) {
      badges.add(tech.join(' · '));
    }

    final edition = p.edition?.trim();
    if (edition != null && edition.isNotEmpty) {
      badges.add(edition);
    }

    final part = p.partLabel?.trim();
    if (part != null && part.isNotEmpty) {
      badges.add(part);
    }

    final seenFlags = <String>{};
    for (final raw in p.subFlags) {
      final norm = raw.trim().toLowerCase();
      if (norm.isEmpty) continue;
      final label = norm == 'bilingual' ? (isEn ? 'Bilingual' : '双语') : norm;
      if (seenFlags.add(label)) badges.add(label);
    }
  }
  return badges;
}

enum DiffTokenKind { unchanged, changed, episodeTag, extension, subFlag }

class DiffToken {
  final String text;
  final DiffTokenKind kind;

  const DiffToken(this.text, this.kind);
}

const _subExtensions = {'.srt', '.ass', '.ssa', '.vtt', '.sub', '.idx', '.sup'};

const _subSuffixTags = {
  'forced',
  'sdh',
  'default',
  'bilingual',
  'hi',
  'cc',
  'zh',
  'zh-cn',
  'zh-tw',
  'zh-hk',
  'chs',
  'cht',
  'sc',
  'tc',
  'en',
  'eng',
  'ja',
  'jpn',
  'ko',
  'kor',
  'chi',
  'zho',
  'chs-eng',
  'cht-eng',
  'zh-en',
};

final _extRe = RegExp(r'^\.[A-Za-z0-9]{1,5}$');
final _sepSplitRe = RegExp(r'[\s._\-\[\]()（）【】{}]+');
final _diffChunkRe = RegExp(
  r'S\d{1,2}E\d{1,3}(?:-E?\d{1,3})?|[\s._\-\[\]()（）【】{}]+|[^\s._\-\[\]()（）【】{}]+',
  caseSensitive: false,
);
final _epTagRe = RegExp(
  r'^S\d{1,2}E\d{1,3}(?:-E?\d{1,3})?$',
  caseSensitive: false,
);

/// Tokenizes [newName] relative to [oldName] for structured diff highlighting.
/// Concatenating all returned tokens always reproduces [newName] verbatim.
List<DiffToken> diffFilenameTokens(String oldName, String newName) {
  if (newName.isEmpty ||
      newName == oldName ||
      newName == '已忽略' ||
      newName == '（名称不变）' ||
      newName == '（无改动）' ||
      newName == 'Ignored' ||
      newName == '(Unchanged)' ||
      newName == '(No change)') {
    return [DiffToken(newName, DiffTokenKind.unchanged)];
  }

  var body = newName;
  var ext = '';
  final lastDot = newName.lastIndexOf('.');
  if (lastDot > 0) {
    final maybeExt = newName.substring(lastDot);
    if (_extRe.hasMatch(maybeExt)) {
      body = newName.substring(0, lastDot);
      ext = maybeExt;
    }
  }

  final isSub = _subExtensions.contains(ext.toLowerCase());
  final subTokens = <String>[];
  if (isSub) {
    while (true) {
      final dot = body.lastIndexOf('.');
      if (dot <= 0) break;
      final seg = body.substring(dot + 1);
      if (!_subSuffixTags.contains(seg.toLowerCase())) break;
      subTokens.insert(0, body.substring(dot));
      body = body.substring(0, dot);
    }
  }

  final oldLastDot = oldName.lastIndexOf('.');
  final oldStem =
      oldLastDot > 0 && _extRe.hasMatch(oldName.substring(oldLastDot))
      ? oldName.substring(0, oldLastDot)
      : oldName;
  final oldWords = {
    for (final w in oldStem.split(_sepSplitRe))
      if (w.isNotEmpty) w.toLowerCase(),
  };

  final raw = <DiffToken>[];
  for (final m in _diffChunkRe.allMatches(body)) {
    final chunk = m.group(0)!;
    final DiffTokenKind kind;
    if (_epTagRe.hasMatch(chunk)) {
      kind = DiffTokenKind.episodeTag;
    } else if (_sepSplitRe.hasMatch(chunk) &&
        chunk.replaceAll(_sepSplitRe, '').isEmpty) {
      kind = DiffTokenKind.unchanged;
    } else if (oldWords.contains(chunk.toLowerCase())) {
      kind = DiffTokenKind.unchanged;
    } else {
      kind = DiffTokenKind.changed;
    }
    raw.add(DiffToken(chunk, kind));
  }
  for (final st in subTokens) {
    raw.add(DiffToken(st, DiffTokenKind.subFlag));
  }
  if (ext.isNotEmpty) {
    raw.add(DiffToken(ext, DiffTokenKind.extension));
  }

  // Merge adjacent tokens of the same kind for cleaner spans.
  final merged = <DiffToken>[];
  for (final t in raw) {
    if (merged.isNotEmpty && merged.last.kind == t.kind) {
      merged[merged.length - 1] = DiffToken(merged.last.text + t.text, t.kind);
    } else {
      merged.add(t);
    }
  }
  return merged;
}

// ---------------------------------------------------------------- conflict quick-resolve

/// Same-group duplicate collision: 2+ files in one group planned to the same path.
class GroupDuplicateConflict {
  final String targetPath;
  final String reason;

  /// Colliding rows sorted by file size descending (largest first).
  final List<ReviewRow> rows;

  const GroupDuplicateConflict({
    required this.targetPath,
    required this.reason,
    required this.rows,
  });

  ReviewRow get largest => rows.first;
  List<ReviewRow> get smaller => rows.sublist(1);
}

/// Finds same-group duplicate conflicts where 2+ non-ignored files in [g]
/// target the same destination path.
List<GroupDuplicateConflict> groupDuplicateConflicts(
  MediaGroup g,
  GroupDecision? d,
  TaskReview r,
) {
  if (r.preview.conflicts.isEmpty) return const [];
  final rows = rowsOf(g, d, r);
  final byOpId = <OpId, ReviewRow>{
    for (final row in rows)
      if (row.op != null && !row.ignored) row.op!.id: row,
  };
  final out = <GroupDuplicateConflict>[];
  for (final c in r.preview.conflicts) {
    final matched = <ReviewRow>[for (final id in c.ops) ?byOpId[id]];
    if (matched.length < 2) continue;
    matched.sort((a, b) {
      final sz = b.file.size.compareTo(a.file.size);
      return sz != 0 ? sz : a.file.path.compareTo(b.file.path);
    });
    out.add(
      GroupDuplicateConflict(
        targetPath: c.path,
        reason: c.reason,
        rows: matched,
      ),
    );
  }
  return out;
}

/// Returns updated overrides ignoring the smaller duplicate(s) in each conflict.
Map<String, FileOverride> resolveKeepLargestOverrides(
  GroupDecision current,
  List<GroupDuplicateConflict> conflicts,
) {
  final next = {...current.overrides};
  for (final c in conflicts) {
    for (final row in c.smaller) {
      final old = next[row.file.path] ?? row.override;
      next[row.file.path] = FileOverride(
        season: old?.season,
        episode: old?.episode,
        kind: old?.kind,
        ignore: true,
      );
    }
  }
  return next;
}
