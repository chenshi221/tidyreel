import 'package:dio/dio.dart';

import '../model/media.dart';
import '../model/metadata.dart';
import 'scoring.dart';
import 'tmdb_client.dart';

export 'scoring.dart'
    show scoreCandidate, normalizeQuery, sameTitle, sharesToken;
export 'tmdb_client.dart' show TmdbException, TmdbResponseCache;

/// Owner: Agent B. PLAN §4.6.
abstract interface class MetadataProvider {
  /// [kind]: [MediaKind.movie], [MediaKind.episode] (TV) or null for both.
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year});
  Future<ShowDetail> show(int tmdbId);
  Future<List<Episode>> season(int tmdbId, int season);
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId);
  Future<MovieDetail> movie(int tmdbId);
}

class TmdbConfig {
  /// v3 api key or v4 read token (detected by length / "eyJ" prefix).
  final String apiKey;

  /// Override for users behind a proxy.
  final String baseUrl;
  final String language;
  final String fallbackLanguage;

  const TmdbConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.themoviedb.org/3',
    this.language = 'zh-CN',
    this.fallbackLanguage = 'en-US',
  });
}

class TmdbProvider implements MetadataProvider {
  final TmdbConfig config;
  final TmdbClient _http;

  /// [dio] is for tests / custom adapters; defaults to a fresh [Dio].
  TmdbProvider(this.config, {Dio? dio, TmdbResponseCache? cache})
    : _http = TmdbClient(
        apiKey: config.apiKey,
        baseUrl: config.baseUrl,
        dio: dio,
        store: cache,
      );

  static const _en = 'en-US';
  static final _han = RegExp(r'[\u4e00-\u9fff]');

  /// How deep to look when page 1 has no exact title.
  static const _maxPages = 3;
  static const _maxAliasLookups = 10;

  /// Candidates sorted best first by [scoreCandidate]. Normalizes [query]
  /// (a year inside it is used when [year] is null).
  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    final q = normalizeQuery(query);
    final y = year ?? q.year;
    if (q.text.isEmpty) return [];
    final kinds = kind == null
        ? [MediaKind.movie, MediaKind.episode]
        : [kind == MediaKind.movie ? MediaKind.movie : MediaKind.episode];
    // Try zh, then the fallback language; within each, with the year filter and
    // then without (filenames are often a year off).
    for (final lang in {config.language, config.fallbackLanguage}) {
      for (final yy in {y, null}) {
        final hits = [
          for (final list in await Future.wait(
            kinds.map((k) => _searchKind(k, q.text, lang, yy)),
          ))
            ...list,
        ];
        if (hits.isEmpty) continue;
        final scored = [
          for (var i = 0; i < hits.length; i++)
            (
              i,
              scoreCandidate(hits[i], query: query, year: y, kind: kind),
              hits[i],
            ),
        ]..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1 - b.$1);
        return [for (final s in scored) s.$3];
      }
    }
    return [];
  }

  Future<List<Candidate>> _searchKind(
    MediaKind kind,
    String text,
    String lang,
    int? year,
  ) async {
    final movie = kind == MediaKind.movie;
    Map<String, String> params(String l) => {
      'query': text,
      'language': l,
      'include_adult': 'false',
      if (year != null) (movie ? 'year' : 'first_air_date_year'): '$year',
    };
    final path = movie ? '/search/movie' : '/search/tv';
    final res = await _http.get(path, params(lang));
    final results = _list(res['results']);
    if (results.isEmpty) return [];
    // English titles: one more (cached) search, joined by id.
    final en = lang == _en ? res : await _http.get(path, params(_en));
    final enResults = _list(en['results']);
    String? original(Map<String, dynamic> r) =>
        _str(r[movie ? 'original_title' : 'original_name']);

    // TMDB also matches alternative titles ("流人" -> Slow Horses) but ranks
    // those hits low and doesn't say which title matched, so dig them out.
    final exact = [...results, ...enResults].any(
      (r) =>
          sameTitle(text, _title(r, movie)) ||
          sameTitle(text, original(r) ?? ''),
    );
    if (!exact) {
      results.addAll(await _laterPages(path, params(lang), res));
      enResults.addAll(await _laterPages(path, params(_en), en));
    }
    final enTitles = {
      for (final r in enResults) r['id'] as int: _title(r, movie),
    };
    final hits = {for (final r in results) r['id'] as int: r};
    final aliases = <int, List<String>>{};
    if (!exact) {
      final unexplained = hits.entries
          .where(
            (h) => ![
              _title(h.value, movie),
              original(h.value) ?? '',
              enTitles[h.key] ?? '',
            ].any((t) => sharesToken(text, t)),
          )
          .map((h) => h.key)
          .take(_maxAliasLookups);
      await Future.wait(
        unexplained.map((id) async => aliases[id] = await _aliases(id, movie)),
      );
    }
    return [
      for (final h in hits.entries)
        _candidate(
          h.value,
          kind,
          englishTitle: enTitles[h.key],
          aliases: aliases[h.key] ?? const [],
        ),
    ];
  }

  Future<List<Map<String, dynamic>>> _laterPages(
    String path,
    Map<String, String> params,
    Map<String, dynamic> first,
  ) async {
    final total = (first['total_pages'] as int?) ?? 1;
    final pages = await Future.wait([
      for (var p = 2; p <= total && p <= _maxPages; p++)
        _http.get(path, {...params, 'page': '$p'}),
    ]);
    return [for (final p in pages) ..._list(p['results'])];
  }

  /// The first mainland-China alternative title, when TMDB has no Chinese name.
  Future<String?> _chineseAlias(int id, String title) async {
    if (_han.hasMatch(title)) return null;
    try {
      final res = await _http.get('/tv/$id/alternative_titles', const {});
      return _list(res['results'])
          .where((t) => t['iso_3166_1'] == 'CN')
          .map((t) => _str(t['title']))
          .firstWhere((t) => t != null && _han.hasMatch(t), orElse: () => null);
    } on TmdbException {
      return null;
    }
  }

  /// Best effort: search results are still useful without aliases.
  Future<List<String>> _aliases(int id, bool movie) async {
    try {
      final res = await _http.get(
        '/${movie ? 'movie' : 'tv'}/$id/alternative_titles',
        const {},
      );
      return [
        for (final t in _list(res[movie ? 'titles' : 'results']))
          ?_str(t['title']),
      ];
    } on TmdbException {
      return const [];
    }
  }

  @override
  Future<ShowDetail> show(int tmdbId) async {
    final path = '/tv/$tmdbId';
    final res = await Future.wait([
      _http.get(path, {'language': config.language}),
      _http.get(path, {'language': _en}),
    ]);
    final alias = config.language.startsWith('zh')
        ? await _chineseAlias(tmdbId, _title(res[0], false))
        : null;
    return ShowDetail(
      info: _candidate(
        alias == null ? res[0] : {...res[0], 'name': alias},
        MediaKind.episode,
        englishTitle: _title(res[1], false),
      ),
      seasons: [
        for (final s in _list(res[0]['seasons']))
          SeasonInfo(
            number: s['season_number'] as int,
            episodeCount: (s['episode_count'] as int?) ?? 0,
            name: _str(s['name']),
            airDate: _date(s['air_date']),
            posterPath: _str(s['poster_path']),
          ),
      ],
    );
  }

  @override
  Future<List<Episode>> season(int tmdbId, int season) async {
    final res = await _http.get('/tv/$tmdbId/season/$season', {
      'language': config.language,
    });
    return [
      for (final e in _list(res['episodes']))
        Episode(
          season: (e['season_number'] as int?) ?? season,
          number: e['episode_number'] as int,
          title: _str(e['name']),
          airDate: _date(e['air_date']),
          stillPath: _str(e['still_path']),
          overview: _str(e['overview']),
          runtimeMinutes: e['runtime'] as int?,
        ),
    ];
  }

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async {
    final lang = {'language': config.language};
    final list = await _http.get('/tv/$tmdbId/episode_groups', lang);
    final ids = [for (final g in _list(list['results'])) g['id'] as String];
    final details = await Future.wait(
      ids.map((id) => _http.get('/tv/episode_group/$id', lang)),
    );
    return [
      for (final d in details)
        EpisodeGroup(
          id: d['id'] as String,
          name: (d['name'] as String?) ?? '',
          type: (d['type'] as int?) ?? 0,
          seasons: [
            for (final g in _list(d['groups'])..sort(_byOrder))
              EpisodeGroupSeason(
                order: (g['order'] as int?) ?? 0,
                name: (g['name'] as String?) ?? '',
                episodes: [
                  for (final e in _list(g['episodes'])..sort(_byOrder))
                    EpisodeRef(
                      e['season_number'] as int,
                      e['episode_number'] as int,
                    ),
                ],
              ),
          ],
        ),
    ];
  }

  @override
  Future<MovieDetail> movie(int tmdbId) async {
    final path = '/movie/$tmdbId';
    final res = await Future.wait([
      _http.get(path, {'language': config.language}),
      _http.get(path, {'language': _en}),
    ]);
    return MovieDetail(
      info: _candidate(
        res[0],
        MediaKind.movie,
        englishTitle: _title(res[1], true),
      ),
    );
  }

  static int _byOrder(Map<String, dynamic> a, Map<String, dynamic> b) =>
      ((a['order'] as int?) ?? 0).compareTo((b['order'] as int?) ?? 0);

  static List<Map<String, dynamic>> _list(Object? v) =>
      v is List ? v.cast<Map<String, dynamic>>().toList() : [];

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;

  static String _title(Map<String, dynamic> r, bool movie) =>
      (r[movie ? 'title' : 'name'] as String?) ?? '';

  static Candidate _candidate(
    Map<String, dynamic> r,
    MediaKind kind, {
    String? englishTitle,
    List<String> aliases = const [],
  }) {
    final movie = kind == MediaKind.movie;
    final date = _date(r[movie ? 'release_date' : 'first_air_date']);
    // TV has origin_country; movie details have production_countries instead.
    final oc = r['origin_country'];
    final pc = r['production_countries'];
    final country = oc is List && oc.isNotEmpty
        ? oc.first as String
        : pc is List && pc.isNotEmpty
        ? (pc.first as Map)['iso_3166_1'] as String?
        : null;
    return Candidate(
      tmdbId: r['id'] as int,
      kind: kind,
      title: _title(r, movie),
      englishTitle: _str(englishTitle),
      originalTitle: _str(r[movie ? 'original_title' : 'original_name']),
      year: date?.year,
      posterPath: _str(r['poster_path']),
      originCountry: country,
      voteAverage: (r['vote_average'] as num?)?.toDouble(),
      overview: _str(r['overview']),
      backdropPath: _str(r['backdrop_path']),
      genres: [for (final g in _list(r['genres'])) ?_str(g['name'])],
      aliases: aliases,
    );
  }
}
