/// Naming options as shown in the 命名规则 page (PLAN §3.2).
/// The planner compiles these into a template string (PLAN §3.1).
library;

enum TargetPlayer { vidhub, infuse, plex, jellyfin }

enum TitleLanguage { chineseFirst, englishFirst }

enum ShowYearSource { firstSeason, seasonAir }

/// S01E02 / s01e02 / s1e2 / 1x02 / s01.e02
enum EpisodeStyle { upperPadded, lowerPadded, lowerShort, cross, lowerDotted }

enum NameField { title, year, episode, episodeTitle, extraInfo }

class NamingOptions {
  final TitleLanguage titleLanguage;

  /// Write both languages, e.g. "老友记.Friends".
  final bool bilingual;
  final bool includeYear;
  final bool yearInParens;

  /// TV only.
  final ShowYearSource showYear;

  /// TV only.
  final EpisodeStyle episodeStyle;

  /// TV only.
  final bool episodeTitle;
  final bool extraInfo;

  /// One of ".", "_", " ", "-".
  final String separator;
  final bool releaseGroup;
  final bool tmdbIdTag;
  final List<NameField> order;

  /// Media folder, e.g. "{title} ({year})".
  final String folderTemplate;

  /// TV only, e.g. "Season {season:02}".
  final String seasonFolderTemplate;

  /// Advanced: when set, used verbatim for the file name and the options above are ignored.
  final String? customTemplate;

  const NamingOptions({
    this.titleLanguage = TitleLanguage.chineseFirst,
    this.bilingual = true,
    this.includeYear = true,
    this.yearInParens = false,
    this.showYear = ShowYearSource.firstSeason,
    this.episodeStyle = EpisodeStyle.upperPadded,
    this.episodeTitle = false,
    this.extraInfo = false,
    this.separator = '.',
    this.releaseGroup = false,
    this.tmdbIdTag = false,
    this.order = const [
      NameField.title,
      NameField.year,
      NameField.episode,
      NameField.episodeTitle,
      NameField.extraInfo,
    ],
    this.folderTemplate = '{title} ({year})',
    this.seasonFolderTemplate = 'Season {season:02}',
    this.customTemplate,
  });

  NamingOptions copyWith({
    TitleLanguage? titleLanguage,
    bool? bilingual,
    bool? includeYear,
    bool? yearInParens,
    ShowYearSource? showYear,
    EpisodeStyle? episodeStyle,
    bool? episodeTitle,
    bool? extraInfo,
    String? separator,
    bool? releaseGroup,
    bool? tmdbIdTag,
    List<NameField>? order,
    String? folderTemplate,
    String? seasonFolderTemplate,
    String? Function()? customTemplate,
  }) => NamingOptions(
    titleLanguage: titleLanguage ?? this.titleLanguage,
    bilingual: bilingual ?? this.bilingual,
    includeYear: includeYear ?? this.includeYear,
    yearInParens: yearInParens ?? this.yearInParens,
    showYear: showYear ?? this.showYear,
    episodeStyle: episodeStyle ?? this.episodeStyle,
    episodeTitle: episodeTitle ?? this.episodeTitle,
    extraInfo: extraInfo ?? this.extraInfo,
    separator: separator ?? this.separator,
    releaseGroup: releaseGroup ?? this.releaseGroup,
    tmdbIdTag: tmdbIdTag ?? this.tmdbIdTag,
    order: order ?? this.order,
    folderTemplate: folderTemplate ?? this.folderTemplate,
    seasonFolderTemplate: seasonFolderTemplate ?? this.seasonFolderTemplate,
    customTemplate: customTemplate != null
        ? customTemplate()
        : this.customTemplate,
  );
}

/// Full naming setup: player preset + separate movie / TV options + library folder names.
class NamingProfile {
  final TargetPlayer player;
  final NamingOptions movie;
  final NamingOptions tv;

  /// First path segment in move-to-library mode.
  final String movieDir;
  final String tvDir;

  const NamingProfile({
    this.player = TargetPlayer.vidhub,
    this.movie = const NamingOptions(),
    this.tv = const NamingOptions(),
    this.movieDir = '电影',
    this.tvDir = '剧集',
  });

  /// VidHub defaults (PLAN §3.2): "老友记.Friends.1994.S02E03.mkv".
  static const vidhub = NamingProfile();

  NamingProfile copyWith({
    TargetPlayer? player,
    NamingOptions? movie,
    NamingOptions? tv,
    String? movieDir,
    String? tvDir,
  }) => NamingProfile(
    player: player ?? this.player,
    movie: movie ?? this.movie,
    tv: tv ?? this.tv,
    movieDir: movieDir ?? this.movieDir,
    tvDir: tvDir ?? this.tvDir,
  );
}
