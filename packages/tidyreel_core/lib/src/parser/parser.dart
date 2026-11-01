import '../model/media.dart';
import 'rules.dart';

/// Owner: Agent A. PLAN §4.5.
abstract interface class FilenameParser {
  /// [parentDirs] are folder names from nearest to farthest, e.g. ["Season 6", "权力的游戏"].
  ParsedName parse(String fileName, {List<String> parentDirs = const []});

  /// By extension and name only (video / subtitle / sidecar / junk / other).
  FileRole classify(String fileName);
}

/// Rule-based (regex) parser; no network, no state.
///
/// Design notes:
/// * Bilingual titles ("老友记 Friends"): when a CJK block and a Latin block with a
///   word of 3+ letters sit side by side, the title is the CJK part only (TMDB
///   zh-CN search works best on it). Short Latin suffixes ("龙珠 Z") are kept.
/// * Bare numbers ("海贼王 - 1080", "龙珠Z/291.mp4") become `absolute` unless a season
///   is known (file name or folder), in which case they are episodes. A season is
///   never invented.
/// * `extraInfo` = resolution + HDR/DV + premium audio (Atmos/TrueHD/DTS-HD), e.g.
///   `2160p.DV.Atmos`. Source and codec are left out.
/// * A date ("向往的生活.20240503") with no episode number is a variety-show
///   episode identified by [ParsedName.airDate]; the planner looks it up on TMDB.
/// * Season-0 content (OVA/SP/特别篇, `Specials/`) is kind `special` with season 0;
///   NCOP/NCED/花絮/Making/PV/特典 are kind `extra`.
class RuleBasedParser implements FilenameParser {
  const RuleBasedParser();

  @override
  FileRole classify(String fileName) => classifyFile(fileName);

  @override
  ParsedName parse(String fileName, {List<String> parentDirs = const []}) {
    final a = analyze(fileName.split('/').last, file: true);

    // Folder info: nearest folder with a title wins; season/special/extra folders
    // contribute flags.
    String? dTitle;
    int? dYear;
    int? dSeason;
    var dSpecial = false, dExtra = false, dirsSeen = false;
    for (final raw in parentDirs) {
      if (raw.trim().isEmpty) continue;
      final d = analyze(raw, file: false);
      if (d.title.isEmpty) {
        if (d.extraKw) dExtra = true;
        if (d.specialKw) dSpecial = true;
        if (d.season != null) {
          dSeason ??= d.season;
          dirsSeen = true;
        }
        continue;
      }
      if (genericDir.hasMatch(d.title.trim())) continue;
      dirsSeen = true;
      dTitle ??= d.title;
      dYear ??= d.year;
      dSeason ??= d.season;
    }

    // Leading "01 Pilot.mkv" only counts as an episode when folders give context.
    var episodes = a.episodes;
    int? bare = a.bare;
    var bareFrom = a.bareFrom;
    var fileTitle = a.title;
    if (bare == null && episodes.isEmpty && a.leadNum != null && dirsSeen) {
      bare = a.leadNum;
      bareFrom = 'lead';
      fileTitle = '';
    }
    final title = fileTitle.isNotEmpty ? fileTitle : (dTitle ?? '');
    final titleFromDir = fileTitle.isEmpty && title.isNotEmpty;

    var season = a.season ?? dSeason;
    if (season == null && dSpecial) season = 0;
    final year = a.year ?? dYear;

    int? absolute;
    if (episodes.isEmpty && bare != null) {
      if (season != null) {
        episodes = [bare];
      } else {
        absolute = bare;
      }
    }

    final isSpecial = a.specialKw || dSpecial || season == 0;
    final isExtra = a.extraKw || dExtra;
    MediaKind kind;
    if (isExtra) {
      kind = MediaKind.extra;
    } else if (isSpecial) {
      kind = MediaKind.special;
      season = 0;
    } else if (a.movieKw) {
      kind = MediaKind.movie;
      episodes = const [];
      absolute = null;
    } else if (episodes.isNotEmpty ||
        absolute != null ||
        season != null ||
        a.batch ||
        (a.airDate != null && title.isNotEmpty)) {
      kind = MediaKind.episode; // season-only = season pack, low confidence
    } else if (year != null || a.hasTech) {
      kind = MediaKind.movie;
    } else {
      kind = MediaKind.unknown;
    }
    if (kind == MediaKind.extra) {
      episodes = const [];
      absolute = null;
    }

    final hasTitle = title.isNotEmpty;
    var conf = switch (kind) {
      MediaKind.extra => hasTitle ? 0.8 : 0.55,
      MediaKind.special => hasTitle ? 0.8 : 0.5,
      MediaKind.movie =>
        a.movieKw
            ? (hasTitle ? 0.75 : 0.4)
            : year != null && hasTitle
            ? 0.92
            : hasTitle
            ? 0.55
            : 0.3,
      MediaKind.episode
          when episodes.isEmpty && absolute == null && a.airDate != null =>
        0.85,
      MediaKind.episode => _episodeConfidence(
        a,
        bareFrom,
        hasTitle: hasTitle,
        titleFromDir: titleFromDir,
        seasonKnown: season != null,
      ),
      MediaKind.unknown => hasTitle ? 0.25 : 0.1,
    };
    if (hasTitle && title.length == 1) conf -= 0.2;
    conf = conf.clamp(0.0, 1.0);

    return ParsedName(
      title: hasTitle ? title : null,
      year: year,
      season: season,
      episodes: episodes,
      absolute: absolute,
      kind: kind,
      resolution: a.res,
      group: a.group,
      lang: a.lang,
      extraInfo: a.extra,
      confidence: double.parse(conf.toStringAsFixed(2)),
      airDate: kind == MediaKind.episode ? a.airDate : null,
    );
  }

  double _episodeConfidence(
    Info a,
    String bareFrom, {
    required bool hasTitle,
    required bool titleFromDir,
    required bool seasonKnown,
  }) {
    if (a.explicitEp) {
      final base = a.season != null || a.episodes.isNotEmpty && a.sxe
          ? 0.95
          : 0.92;
      if (!hasTitle) return 0.55;
      return titleFromDir ? base - 0.1 : base;
    }
    switch (bareFrom) {
      case 'dash':
        if (!hasTitle) return 0.4;
        return titleFromDir ? 0.7 : (seasonKnown ? 0.85 : 0.8);
      case 'lead':
      case 'lone':
        if (!hasTitle) return 0.3;
        return seasonKnown ? 0.8 : 0.65;
      case 'trail':
        return 0.45;
    }
    return 0.3;
  }
}
