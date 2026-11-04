import 'package:tidyreel_core/tidyreel_core.dart';

// JSON for the persisted parts of core models (prefs.json). Unknown enum names
// fall back to defaults so an older prefs file never crashes the app.

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

Map<String, Object?> connectionToJson(ConnectionConfig c) => {
  'id': c.id.value,
  'name': c.name,
  'type': c.type.name,
  'endpoint': c.endpoint,
  'username': c.username,
  'libraryRoot': c.libraryRoot,
  'favorites': c.favorites,
  'startDir': c.startDir,
};

ConnectionConfig connectionFromJson(Map<String, Object?> j) => ConnectionConfig(
  id: ConnectionId(j['id'] as String),
  name: j['name'] as String,
  type: _enum(ConnectionType.values, j['type'], ConnectionType.webdav),
  endpoint: j['endpoint'] as String,
  username: j['username'] as String?,
  libraryRoot: j['libraryRoot'] as String?,
  favorites: [...?(j['favorites'] as List?)?.cast<String>()],
  startDir: j['startDir'] as String? ?? '/',
);

Map<String, Object?> namingOptionsToJson(NamingOptions o) => {
  'titleLanguage': o.titleLanguage.name,
  'bilingual': o.bilingual,
  'includeYear': o.includeYear,
  'yearInParens': o.yearInParens,
  'showYear': o.showYear.name,
  'episodeStyle': o.episodeStyle.name,
  'episodeTitle': o.episodeTitle,
  'extraInfo': o.extraInfo,
  'separator': o.separator,
  'releaseGroup': o.releaseGroup,
  'tmdbIdTag': o.tmdbIdTag,
  'order': [for (final f in o.order) f.name],
  'folderTemplate': o.folderTemplate,
  'seasonFolderTemplate': o.seasonFolderTemplate,
  'singleSeasonFolder': o.singleSeasonFolder,
  'customTemplate': o.customTemplate,
  'rewrites': [
    for (final r in o.rewrites) {'p': r.pattern, 'r': r.replacement},
  ],
};

NamingOptions namingOptionsFromJson(Map<String, Object?> j) {
  const d = NamingOptions();
  final order = [
    for (final n in (j['order'] as List?) ?? const [])
      ?NameField.values.where((f) => f.name == n).firstOrNull,
  ];
  return NamingOptions(
    titleLanguage: _enum(
      TitleLanguage.values,
      j['titleLanguage'],
      d.titleLanguage,
    ),
    bilingual: j['bilingual'] as bool? ?? d.bilingual,
    includeYear: j['includeYear'] as bool? ?? d.includeYear,
    yearInParens: j['yearInParens'] as bool? ?? d.yearInParens,
    showYear: _enum(ShowYearSource.values, j['showYear'], d.showYear),
    episodeStyle: _enum(EpisodeStyle.values, j['episodeStyle'], d.episodeStyle),
    episodeTitle: j['episodeTitle'] as bool? ?? d.episodeTitle,
    extraInfo: j['extraInfo'] as bool? ?? d.extraInfo,
    separator: j['separator'] as String? ?? d.separator,
    releaseGroup: j['releaseGroup'] as bool? ?? d.releaseGroup,
    tmdbIdTag: j['tmdbIdTag'] as bool? ?? d.tmdbIdTag,
    order: order.isEmpty ? d.order : order,
    folderTemplate: j['folderTemplate'] as String? ?? d.folderTemplate,
    seasonFolderTemplate:
        j['seasonFolderTemplate'] as String? ?? d.seasonFolderTemplate,
    singleSeasonFolder:
        j['singleSeasonFolder'] as bool? ?? d.singleSeasonFolder,
    customTemplate: j['customTemplate'] as String?,
    rewrites: [
      for (final r in (j['rewrites'] as List?) ?? const [])
        NameRewrite((r as Map)['p'] as String, r['r'] as String? ?? ''),
    ],
  );
}

Map<String, Object?> namingProfileToJson(NamingProfile p) => {
  'player': p.player.name,
  'movie': namingOptionsToJson(p.movie),
  'tv': namingOptionsToJson(p.tv),
  'movieDir': p.movieDir,
  'tvDir': p.tvDir,
};

NamingProfile namingProfileFromJson(Map<String, Object?> j) {
  const d = NamingProfile.vidhub;
  return NamingProfile(
    player: _enum(TargetPlayer.values, j['player'], d.player),
    movie: j['movie'] is Map
        ? namingOptionsFromJson((j['movie'] as Map).cast())
        : d.movie,
    tv: j['tv'] is Map ? namingOptionsFromJson((j['tv'] as Map).cast()) : d.tv,
    movieDir: j['movieDir'] as String? ?? d.movieDir,
    tvDir: j['tvDir'] as String? ?? d.tvDir,
  );
}
