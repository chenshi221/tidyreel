/// Naming options as shown in the 命名规则 page (PLAN §3.2).
/// The planner compiles these into a template string (PLAN §3.1).
library;

enum TargetPlayer { vidhub, infuse, plex, jellyfin }

enum TitleLanguage { chineseFirst, englishFirst }

enum ShowYearSource { firstSeason, seasonAir }

/// S01E02 / s01e02 / s1e2 / 1x02 / s01.e02
enum EpisodeStyle { upperPadded, lowerPadded, lowerShort, cross, lowerDotted }

enum NameField { title, year, episode, episodeTitle, extraInfo }

/// One find/replace applied to every generated name, after the template.
class NameRewrite {
  /// Regular expression.
  final String pattern;

  /// Replacement; `$1` is the first capture group.
  final String replacement;

  const NameRewrite(this.pattern, this.replacement);

  @override
  bool operator ==(Object other) =>
      other is NameRewrite &&
      other.pattern == pattern &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(pattern, replacement);
}

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

  /// TV only: single-season shows also get a Season folder (multi-season
  /// shows always do).
  final bool singleSeasonFolder;

  /// Advanced: when set, used verbatim for the file name and the options above are ignored.
  final String? customTemplate;

  /// Applied in order to file, media-folder and season-folder names.
  final List<NameRewrite> rewrites;

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
    this.singleSeasonFolder = true,
    this.customTemplate,
    this.rewrites = const [],
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
    bool? singleSeasonFolder,
    String? Function()? customTemplate,
    List<NameRewrite>? rewrites,
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
    singleSeasonFolder: singleSeasonFolder ?? this.singleSeasonFolder,
    customTemplate: customTemplate != null
        ? customTemplate()
        : this.customTemplate,
    rewrites: rewrites ?? this.rewrites,
  );

  @override
  bool operator ==(Object other) =>
      other is NamingOptions &&
      other.titleLanguage == titleLanguage &&
      other.bilingual == bilingual &&
      other.includeYear == includeYear &&
      other.yearInParens == yearInParens &&
      other.showYear == showYear &&
      other.episodeStyle == episodeStyle &&
      other.episodeTitle == episodeTitle &&
      other.extraInfo == extraInfo &&
      other.separator == separator &&
      other.releaseGroup == releaseGroup &&
      other.tmdbIdTag == tmdbIdTag &&
      _listEq(other.order, order) &&
      other.folderTemplate == folderTemplate &&
      other.seasonFolderTemplate == seasonFolderTemplate &&
      other.singleSeasonFolder == singleSeasonFolder &&
      other.customTemplate == customTemplate &&
      _listEq(other.rewrites, rewrites);

  @override
  int get hashCode => Object.hashAll([
    titleLanguage,
    bilingual,
    includeYear,
    yearInParens,
    showYear,
    episodeStyle,
    episodeTitle,
    extraInfo,
    separator,
    releaseGroup,
    tmdbIdTag,
    ...order,
    folderTemplate,
    seasonFolderTemplate,
    singleSeasonFolder,
    customTemplate,
    ...rewrites,
  ]);
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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

  /// Recommended defaults for each target media player.
  static NamingProfile forPlayer(TargetPlayer player) => switch (player) {
    TargetPlayer.vidhub => vidhub,
    TargetPlayer.infuse => const NamingProfile(
      player: TargetPlayer.infuse,
      movie: NamingOptions(
        bilingual: false,
        separator: '.',
        yearInParens: false,
      ),
      tv: NamingOptions(bilingual: false, separator: '.', yearInParens: false),
      movieDir: '电影',
      tvDir: '剧集',
    ),
    TargetPlayer.plex => const NamingProfile(
      player: TargetPlayer.plex,
      movie: NamingOptions(
        bilingual: false,
        separator: ' ',
        yearInParens: true,
        tmdbIdTag: true,
        folderTemplate: '{title} ({year})',
      ),
      tv: NamingOptions(
        bilingual: false,
        separator: ' ',
        yearInParens: true,
        episodeTitle: true,
        tmdbIdTag: true,
        folderTemplate: '{title} ({year})',
        seasonFolderTemplate: 'Season {season:02}',
      ),
      movieDir: 'Movies',
      tvDir: 'TV Shows',
    ),
    TargetPlayer.jellyfin => const NamingProfile(
      player: TargetPlayer.jellyfin,
      movie: NamingOptions(
        bilingual: false,
        separator: ' ',
        yearInParens: true,
        tmdbIdTag: true,
        folderTemplate: '{title} ({year})',
      ),
      tv: NamingOptions(
        bilingual: false,
        separator: ' ',
        yearInParens: true,
        tmdbIdTag: true,
        folderTemplate: '{title} ({year})',
        seasonFolderTemplate: 'Season {season:02}',
      ),
      movieDir: 'Movies',
      tvDir: 'Shows',
    ),
  };

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

  @override
  bool operator ==(Object other) =>
      other is NamingProfile &&
      other.player == player &&
      other.movie == movie &&
      other.tv == tv &&
      other.movieDir == movieDir &&
      other.tvDir == tvDir;

  @override
  int get hashCode => Object.hash(player, movie, tv, movieDir, tvDir);
}
