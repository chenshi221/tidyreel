/// What a file or group is, in media terms.
enum MediaKind { movie, episode, special, extra, unknown }

/// What a scanned file is, in file terms.
enum FileRole { video, subtitle, sidecar, junk, other }

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
  });
}
