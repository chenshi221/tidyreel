import '../model/metadata.dart';

// Kodi-style .nfo files (VidHub, Infuse, Jellyfin and Emby read them too).

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _doc(String root, List<(String, Object?)> fields) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<$root>\n',
  );
  for (final (tag, v) in fields) {
    if (v == null || '$v'.isEmpty) continue;
    if (tag == '#raw') {
      b.write('$v\n');
    } else {
      b.write('  <$tag>${_esc('$v')}</$tag>\n');
    }
  }
  b.write('</$root>\n');
  return b.toString();
}

String _date(DateTime? d) => d == null
    ? ''
    : '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

String _actor(PersonCredit a) {
  final b = StringBuffer('  <actor>\n');
  b.write('    <name>${_esc(a.name)}</name>\n');
  final role = a.role;
  if (role != null && role.isNotEmpty) {
    b.write('    <role>${_esc(role)}</role>\n');
  }
  final path = a.profilePath;
  if (path != null && path.isNotEmpty) {
    final thumb = path.startsWith('http://') || path.startsWith('https://')
        ? path
        : 'https://image.tmdb.org/t/p/w185${path.startsWith('/') ? path : '/$path'}';
    b.write('    <thumb>${_esc(thumb)}</thumb>\n');
  }
  b.write('  </actor>');
  return b.toString();
}

List<(String, Object?)> _common(Candidate c) => [
  ('title', c.title),
  ('originaltitle', c.originalTitle ?? c.englishTitle),
  ('year', c.year),
  ('mpaa', c.certification),
  ('plot', c.overview),
  for (final g in c.genres) ('genre', g),
  for (final t in c.tags) ('tag', t),
  for (final s in c.studios) ('studio', s),
  for (final d in c.directors) ('director', d),
  for (final w in c.writers) ('credits', w),
  if (c.voteAverage != null)
    (
      '#raw',
      '  <ratings><rating name="themoviedb" max="10" default="true">'
          '<value>${c.voteAverage!.toStringAsFixed(1)}</value>'
          '${c.voteCount != null ? '<votes>${c.voteCount}</votes>' : ''}'
          '</rating></ratings>',
    ),
  ('#raw', '  <uniqueid type="tmdb" default="true">${c.tmdbId}</uniqueid>'),
  if (c.imdbId != null && c.imdbId!.isNotEmpty)
    ('#raw', '  <uniqueid type="imdb">${_esc(c.imdbId!)}</uniqueid>'),
  if (c.tvdbId != null)
    ('#raw', '  <uniqueid type="tvdb">${c.tvdbId}</uniqueid>'),
  ('tmdbid', c.tmdbId),
  if (c.imdbId != null && c.imdbId!.isNotEmpty) ('imdbid', c.imdbId),
  for (final a in c.actors)
    if (a.name.isNotEmpty) ('#raw', _actor(a)),
];

/// `tvshow.nfo` for a show folder; its tmdb uniqueid lets the next scan (and
/// players) match the folder without searching.
String tvShowNfo(ShowDetail show) {
  final first = show.seasons
      .where((s) => s.number > 0 && s.airDate != null)
      .map((s) => s.airDate!)
      .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
  return _doc('tvshow', [..._common(show.info), ('premiered', _date(first))]);
}

/// `<video>.nfo` for a movie file.
String movieNfo(Candidate movie) => _doc('movie', [
  ..._common(movie),
  if (movie.collectionName != null && movie.collectionName!.isNotEmpty)
    ('#raw', '  <set><name>${_esc(movie.collectionName!)}</name></set>'),
]);

/// `<video>.nfo` for an episode file.
String episodeNfo({
  required Candidate show,
  required int season,
  required int episode,
  Episode? info,
  String? title,
}) => _doc('episodedetails', [
  ('title', info?.title ?? title ?? 'Episode $episode'),
  ('showtitle', show.title),
  ('season', season),
  ('episode', episode),
  ('plot', info?.overview),
  ('aired', _date(info?.airDate)),
  ('runtime', info?.runtimeMinutes),
]);
