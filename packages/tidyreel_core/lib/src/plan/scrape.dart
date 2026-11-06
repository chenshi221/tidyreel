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

List<(String, Object?)> _common(Candidate c) => [
  ('title', c.title),
  ('originaltitle', c.originalTitle ?? c.englishTitle),
  ('year', c.year),
  ('plot', c.overview),
  for (final g in c.genres) ('genre', g),
  if (c.voteAverage != null)
    (
      '#raw',
      '  <ratings><rating name="themoviedb" max="10" default="true">'
          '<value>${c.voteAverage!.toStringAsFixed(1)}</value></rating></ratings>',
    ),
  ('#raw', '  <uniqueid type="tmdb" default="true">${c.tmdbId}</uniqueid>'),
  ('tmdbid', c.tmdbId),
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
String movieNfo(Candidate movie) => _doc('movie', _common(movie));

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
