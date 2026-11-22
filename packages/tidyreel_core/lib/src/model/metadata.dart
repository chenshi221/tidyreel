import 'media.dart';

/// Cast member credit for enriched NFO scraping.
class PersonCredit {
  final String name;
  final String? role;
  final String? profilePath;

  const PersonCredit({required this.name, this.role, this.profilePath});

  @override
  bool operator ==(Object other) =>
      other is PersonCredit &&
      other.name == name &&
      other.role == role &&
      other.profilePath == profilePath;

  @override
  int get hashCode => Object.hash(name, role, profilePath);
}

/// A TMDB search hit. [kind] is [MediaKind.movie] or [MediaKind.episode] (= TV show).
class Candidate {
  final int tmdbId;
  final MediaKind kind;

  /// zh-CN title.
  final String title;

  /// en-US title (used as the second language, e.g. "老友记.Friends").
  final String? englishTitle;

  /// Title in the original language, e.g. "ドロヘドロ".
  final String? originalTitle;
  final int? year;
  final String? posterPath;
  final String? originCountry;
  final double? voteAverage;

  /// Number of TMDB votes; helps break ties between obscure and popular homonyms.
  final int? voteCount;

  /// TMDB popularity score; secondary tie-breaker.
  final double? popularity;

  /// zh-CN synopsis.
  final String? overview;

  /// 16:9 artwork for the review header.
  final String? backdropPath;

  /// zh-CN genre names; only filled by detail calls (search returns ids).
  final List<String> genres;

  /// TMDB alternative titles, e.g. "流人" for Slow Horses. Only filled for
  /// search hits whose own titles don't explain the match.
  final List<String> aliases;

  /// External IDs populated by detail calls.
  final String? imdbId;
  final int? tvdbId;

  /// Movie collection (belongs_to_collection) info.
  final String? collectionName;
  final int? collectionId;

  /// Extra artwork paths from TMDB `/images`.
  final String? clearLogoPath;
  final String? landscapePath;

  /// Content rating / MPAA certification (e.g. PG-13, TV-14).
  final String? certification;

  /// Production studios / networks.
  final List<String> studios;

  /// Top billed cast members.
  final List<PersonCredit> actors;

  /// Directors and writers.
  final List<String> directors;
  final List<String> writers;

  /// TMDB keywords / tags.
  final List<String> tags;

  const Candidate({
    required this.tmdbId,
    required this.kind,
    required this.title,
    this.englishTitle,
    this.originalTitle,
    this.year,
    this.posterPath,
    this.originCountry,
    this.voteAverage,
    this.voteCount,
    this.popularity,
    this.overview,
    this.backdropPath,
    this.genres = const [],
    this.aliases = const [],
    this.imdbId,
    this.tvdbId,
    this.collectionName,
    this.collectionId,
    this.clearLogoPath,
    this.landscapePath,
    this.certification,
    this.studios = const [],
    this.actors = const [],
    this.directors = const [],
    this.writers = const [],
    this.tags = const [],
  });
}

class SeasonInfo {
  final int number;
  final int episodeCount;
  final String? name;
  final DateTime? airDate;
  final String? posterPath;

  const SeasonInfo({
    required this.number,
    required this.episodeCount,
    this.name,
    this.airDate,
    this.posterPath,
  });
}

class ShowDetail {
  final Candidate info;

  /// Includes season 0 (specials) when TMDB has it.
  final List<SeasonInfo> seasons;

  const ShowDetail({required this.info, required this.seasons});
}

class MovieDetail {
  final Candidate info;

  const MovieDetail({required this.info});
}

class Episode {
  final int season;
  final int number;
  final String? title;
  final DateTime? airDate;

  /// 16:9 frame from the episode.
  final String? stillPath;
  final String? overview;
  final int? runtimeMinutes;

  const Episode({
    required this.season,
    required this.number,
    this.title,
    this.airDate,
    this.stillPath,
    this.overview,
    this.runtimeMinutes,
  });
}

/// A TMDB "episode group": an alternative season layout (absolute, story arcs...).
class EpisodeGroup {
  final String id;
  final String name;

  /// TMDB group type (1 original air date ... 7 TV). Kept raw.
  final int type;

  /// Ordered seasons of this layout; each maps to original TMDB episodes.
  final List<EpisodeGroupSeason> seasons;

  const EpisodeGroup({
    required this.id,
    required this.name,
    required this.type,
    required this.seasons,
  });
}

class EpisodeGroupSeason {
  final int order;
  final String name;

  /// Original (TMDB-numbered) episodes in this group's season, in order.
  final List<EpisodeRef> episodes;

  const EpisodeGroupSeason({
    required this.order,
    required this.name,
    required this.episodes,
  });
}
