import 'probe.dart';

/// What a file or group is, in media terms.
enum MediaKind { movie, episode, special, extra, unknown }

/// What a scanned file is, in file terms.
enum FileRole { video, subtitle, sidecar, junk, other }

/// External catalog ID found directly in a folder or file name,
/// e.g. `{tmdb-27205}`, `[tmdbid=1668]`, `{imdb-tt1375666}`, `{tvdb-81189}`.
class ExternalId {
  /// One of `'tmdb'`, `'imdb'`, `'tvdb'`.
  final String source;
  final String id;

  const ExternalId(this.source, this.id);

  @override
  bool operator ==(Object other) =>
      other is ExternalId && other.source == source && other.id == id;

  @override
  int get hashCode => Object.hash(source, id);

  @override
  String toString() => '$source:$id';
}

/// A season/episode pair. Season 0 means specials.
class EpisodeRef {
  final int season;
  final int episode;

  const EpisodeRef(this.season, this.episode);

  @override
  bool operator ==(Object other) =>
      other is EpisodeRef && other.season == season && other.episode == episode;

  @override
  int get hashCode => Object.hash(season, episode);

  @override
  String toString() => 'S${season}E$episode';
}

/// Result of parsing one file name (plus its parent folders).
class ParsedName {
  final String? title;
  final int? year;
  final int? season;

  /// Episode numbers; more than one for multi-episode files (S01E01-E02).
  final List<int> episodes;

  /// Absolute episode number when the name has no season (anime "海贼王 1080").
  final int? absolute;
  final MediaKind kind;
  final String? resolution;

  /// Release / fansub group, e.g. "Nekomoe".
  final String? group;

  /// Subtitle language tag as found in the name, e.g. "chs", "zh-CN".
  final String? lang;

  /// Extra info kept when "附加信息" is on, e.g. "2160p.DV.Atmos".
  final String? extraInfo;

  /// 0..1. Below the planner's threshold the UI asks the user.
  final double confidence;

  /// Air date in the name ("向往的生活.20240503"): variety shows are matched to
  /// a TMDB episode by date.
  final DateTime? airDate;

  /// Release edition/version tag (e.g. "Director's Cut", "Extended", "IMAX",
  /// "3D", "Remux", "国语"). Used to keep multi-version movies/episodes distinct.
  final String? edition;

  /// Multi-part movie index (CD1/Part 1/上 → 1).
  final int? part;

  /// Normalized multi-part suffix (e.g. "cd1", "pt1").
  final String? partLabel;

  /// Subtitle trait flags parsed from filename (e.g. "forced", "default",
  /// "sdh", "bilingual").
  final List<String> subFlags;

  /// Explicit catalog ID found in folder or file name ({tmdb-xxx}, {imdb-ttxxx}).
  final ExternalId? externalId;

  /// True when representing a whole Blu-ray (BDMV) or DVD (VIDEO_TS) disc unit.
  final bool isDisc;

  /// Container header probe result, when media probing ran on this file.
  final MediaProbeInfo? probe;

  const ParsedName({
    this.title,
    this.year,
    this.season,
    this.episodes = const [],
    this.absolute,
    this.kind = MediaKind.unknown,
    this.resolution,
    this.group,
    this.lang,
    this.extraInfo,
    this.confidence = 0,
    this.airDate,
    this.edition,
    this.part,
    this.partLabel,
    this.subFlags = const [],
    this.externalId,
    this.isDisc = false,
    this.probe,
  });

  ParsedName copyWith({
    String? Function()? title,
    int? Function()? year,
    int? Function()? season,
    List<int>? episodes,
    int? Function()? absolute,
    MediaKind? kind,
    String? Function()? resolution,
    String? Function()? group,
    String? Function()? lang,
    String? Function()? extraInfo,
    double? confidence,
    DateTime? Function()? airDate,
    String? Function()? edition,
    int? Function()? part,
    String? Function()? partLabel,
    List<String>? subFlags,
    ExternalId? Function()? externalId,
    bool? isDisc,
    MediaProbeInfo? Function()? probe,
  }) => ParsedName(
    title: title != null ? title() : this.title,
    year: year != null ? year() : this.year,
    season: season != null ? season() : this.season,
    episodes: episodes ?? this.episodes,
    absolute: absolute != null ? absolute() : this.absolute,
    kind: kind ?? this.kind,
    resolution: resolution != null ? resolution() : this.resolution,
    group: group != null ? group() : this.group,
    lang: lang != null ? lang() : this.lang,
    extraInfo: extraInfo != null ? extraInfo() : this.extraInfo,
    confidence: confidence ?? this.confidence,
    airDate: airDate != null ? airDate() : this.airDate,
    edition: edition != null ? edition() : this.edition,
    part: part != null ? part() : this.part,
    partLabel: partLabel != null ? partLabel() : this.partLabel,
    subFlags: subFlags ?? this.subFlags,
    externalId: externalId != null ? externalId() : this.externalId,
    isDisc: isDisc ?? this.isDisc,
    probe: probe != null ? probe() : this.probe,
  );
}
