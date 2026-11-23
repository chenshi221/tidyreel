import 'package:dio/dio.dart';

import '../model/media.dart';
import '../model/metadata.dart';
import '../plan/text.dart' show hasHan;
import 'scoring.dart';
import 'tmdb_client.dart';

export 'scoring.dart'
    show
        scoreCandidate,
        scoreEpisodeFit,
        normalizeQuery,
        sameTitle,
        sharesToken;
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

/// Optional direct lookup by external catalog ID (e.g. `{tmdb-27205}`,
/// `{imdb-tt1375666}`, `{tvdb-81189}`).
abstract interface class ExternalIdLookup {
  Future<Candidate?> findByExternalId(
    String source,
    String id, {
    MediaKind? kind,
  });
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

class TmdbProvider implements MetadataProvider, ExternalIdLookup {
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

  /// How deep to look when page 1 has no exact title.
  static const _maxPages = 3;
  static const _maxAliasLookups = 10;
  static const _minYearMatchScore = 0.7;

  void close() => _http.close();

  String get _primaryLang => config.language.split('-').first.toLowerCase();

  Future<Candidate?> _tryMovie(int tmdbId) async {
    try {
      return (await movie(tmdbId)).info;
    } on TmdbException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Candidate?> _tryShow(int tmdbId) async {
    try {
      return (await show(tmdbId)).info;
    } on TmdbException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Candidate?> findByExternalId(
    String source,
    String id, {
    MediaKind? kind,
  }) async {
    final src = source.trim().toLowerCase();
    final cleanId = id.trim();
    if (cleanId.isEmpty) return null;

    if (src == 'tmdb') {
      final tmdbId = int.tryParse(cleanId);
      if (tmdbId == null || tmdbId <= 0) return null;
      if (kind == MediaKind.movie) return _tryMovie(tmdbId);
      if (kind == MediaKind.episode || kind == MediaKind.special) {
        return _tryShow(tmdbId);
      }
      return await _tryMovie(tmdbId) ?? await _tryShow(tmdbId);
    }

    if (src == 'imdb' || src == 'tvdb') {
      if (src == 'tvdb' && int.tryParse(cleanId) == null) return null;
      final externalSource = src == 'imdb' ? 'imdb_id' : 'tvdb_id';
      final Map<String, dynamic> res;
      try {
        res = await _http.get('/find/${Uri.encodeComponent(cleanId)}', {
          'external_source': externalSource,
          'language': config.language,
        });
      } on TmdbException catch (e) {
        if (e.statusCode == 404 || e.statusCode == 400) return null;
        rethrow;
      }

      final movies = _list(res['movie_results']);
      final tv = _list(res['tv_results']);
      Map<String, dynamic>? hit;
      MediaKind? hitKind;
      final wantTv = kind == MediaKind.episode || kind == MediaKind.special;
      if (kind == MediaKind.movie) {
        if (movies.isNotEmpty) {
          hit = movies.first;
          hitKind = MediaKind.movie;
        } else if (tv.isNotEmpty) {
          hit = tv.first;
          hitKind = MediaKind.episode;
        }
      } else if (wantTv) {
        if (tv.isNotEmpty) {
          hit = tv.first;
          hitKind = MediaKind.episode;
        } else if (movies.isNotEmpty) {
          hit = movies.first;
          hitKind = MediaKind.movie;
        }
      } else {
        if (movies.isNotEmpty) {
          hit = movies.first;
          hitKind = MediaKind.movie;
        } else if (tv.isNotEmpty) {
          hit = tv.first;
          hitKind = MediaKind.episode;
        }
      }
      if (hit == null || hitKind == null) return null;
      final hitId = _int(hit['id']);
      if (hitId == null) return null;
      try {
        return hitKind == MediaKind.movie
            ? (await movie(hitId)).info
            : (await show(hitId)).info;
      } on TmdbException {
        return _candidate(hit, hitKind, primaryLang: _primaryLang);
      }
    }

    return null;
  }

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

    List<(int, double, double, Candidate)> rank(List<Candidate> hits) =>
        [
          for (var i = 0; i < hits.length; i++)
            (
              i,
              scoreNormalized(hits[i], normalized: q, year: y, kind: kind),
              popularityBonus(hits[i]),
              hits[i],
            ),
        ]..sort((a, b) {
          if (b.$2 != a.$2) return b.$2.compareTo(a.$2);
          if (a.$2 >= 0.5 && b.$3 != a.$3) return b.$3.compareTo(a.$3);
          return a.$1 - b.$1;
        });

    Future<List<Candidate>> run(int? yy) async => [
      for (final list in await Future.wait(
        kinds.map((k) => _searchKind(k, q.text, config.language, yy)),
      ))
        ...list,
    ];

    if (y != null) {
      final withYear = rank(await run(y));
      if (withYear.isNotEmpty && withYear.first.$2 >= _minYearMatchScore) {
        return [for (final s in withYear) s.$4];
      }
      // Filenames are often a year off or match an unrelated work from that year:
      // fall back to a yearless search and merge results.
      final withoutYear = await run(null);
      if (withoutYear.isEmpty) {
        return [for (final s in withYear) s.$4];
      }
      final merged = <(MediaKind, int), Candidate>{};
      for (final s in withYear) {
        merged[(s.$4.kind, s.$4.tmdbId)] = s.$4;
      }
      for (final c in withoutYear) {
        merged.putIfAbsent((c.kind, c.tmdbId), () => c);
      }
      return [for (final s in rank(merged.values.toList())) s.$4];
    }

    final hits = await run(null);
    return [for (final s in rank(hits)) s.$4];
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
    final langParams = params(lang);
    final enParams = params(_en);

    // Fetch primary language and English titles in parallel (skip duplicate when lang == en-US).
    final Map<String, dynamic> res;
    final Map<String, dynamic> en;
    if (lang == _en) {
      res = await _http.get(path, langParams);
      en = res;
    } else {
      final pair = await Future.wait([
        _http.get(path, langParams),
        _http.get(path, enParams),
      ]);
      res = pair[0];
      en = pair[1];
    }

    final results = _list(res['results']);
    final enResults = lang == _en ? results : _list(en['results']);
    if (results.isEmpty && enResults.isEmpty) return [];

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
      if (lang == _en) {
        results.addAll(await _laterPages(path, langParams, res));
      } else {
        final later = await Future.wait([
          _laterPages(path, langParams, res),
          _laterPages(path, enParams, en),
        ]);
        results.addAll(later[0]);
        enResults.addAll(later[1]);
      }
    }

    final enTitles = <int, String>{};
    for (final r in enResults) {
      final id = _int(r['id']);
      if (id != null) enTitles[id] = _title(r, movie);
    }
    final hits = <int, Map<String, dynamic>>{};
    for (final r in results) {
      final id = _int(r['id']);
      if (id != null) hits[id] = r;
    }
    // Include any en-US-only hits when primary language had fewer/no entries.
    for (final r in enResults) {
      final id = _int(r['id']);
      if (id != null) hits.putIfAbsent(id, () => r);
    }

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
    final total = _int(first['total_pages']) ?? 1;
    if (total <= 1) return const [];
    final pages = await Future.wait([
      for (var p = 2; p <= total && p <= _maxPages; p++)
        _http.get(path, {...params, 'page': '$p'}),
    ]);
    return [for (final p in pages) ..._list(p['results'])];
  }

  Future<Map<String, dynamic>?> _fetchOptional(String path) => _http
      .get(path, const {})
      .then<Map<String, dynamic>?>((r) => r)
      .catchError((Object _) => null, test: (e) => e is TmdbException);

  static List<({String? region, String title})> _extractAltTitles(
    Map<String, dynamic>? res,
    bool movie,
  ) => [
    for (final t in _list(res?[movie ? 'titles' : 'results']))
      if (_str(t['title']) case final title?)
        (region: _str(t['iso_3166_1']), title: title),
  ];

  /// A Chinese name when TMDB's zh-CN title is still the English one: the
  /// zh-CN / zh-SG translation, a mainland alias, then zh-TW / zh-HK, then any
  /// Chinese alias ("The Terminal List" -> "终极名单").
  Future<String?> _chineseAlias(
    int id,
    bool movie,
    String title, {
    Map<String, dynamic>? detail,
  }) async {
    if (hasHan(title)) return null;
    final kind = movie ? 'movie' : 'tv';
    final key = movie ? 'title' : 'name';
    final embeddedTrans = _map(detail?['translations']);
    final embeddedAlt = _map(detail?['alternative_titles']);
    final res = await Future.wait([
      embeddedTrans != null
          ? Future.value(embeddedTrans)
          : _fetchOptional('/$kind/$id/translations'),
      embeddedAlt != null
          ? Future.value(embeddedAlt)
          : _fetchOptional('/$kind/$id/alternative_titles'),
    ]);
    final names = <String, String>{};
    for (final t in _list(res[0]?['translations'])) {
      if (t['iso_639_1'] != 'zh') continue;
      final region = _str(t['iso_3166_1']);
      final name = _str(_map(t['data'])?[key]);
      if (region != null && name != null) names[region] = name;
    }
    final aliases = [
      for (final a in _extractAltTitles(res[1], movie))
        if (hasHan(a.title)) a,
    ];
    String? alias(String? region) => aliases
        .where((a) => region == null || a.region == region)
        .firstOrNull
        ?.title;
    return [
      names['CN'],
      names['SG'],
      alias('CN'),
      names['TW'],
      names['HK'],
      alias(null),
    ].firstWhere((n) => n != null && hasHan(n), orElse: () => null);
  }

  /// Best effort: search results are still useful without aliases.
  Future<List<String>> _aliases(int id, bool movie) async {
    final res = await _fetchOptional(
      '/${movie ? 'movie' : 'tv'}/$id/alternative_titles',
    );
    return [for (final a in _extractAltTitles(res, movie)) a.title];
  }

  Future<(Map<String, dynamic>, Map<String, dynamic>)> _fetchDetail(
    String path, {
    required bool movie,
  }) async {
    final wantZh = config.language.startsWith('zh');
    final append = [
      'credits',
      'external_ids',
      'images',
      movie ? 'release_dates' : 'content_ratings',
      'keywords',
      if (wantZh) ...['translations', 'alternative_titles'],
    ].join(',');
    final primaryLang = _primaryLang;
    final imageLangs = [
      if (primaryLang.isNotEmpty && primaryLang != 'en') primaryLang,
      'en',
      'null',
    ].join(',');
    final primaryParams = {
      'language': config.language,
      'append_to_response': append,
      'include_image_language': imageLangs,
    };
    if (config.language == _en) {
      final r = await _http.get(path, primaryParams);
      return (r, r);
    }
    final res = await Future.wait([
      _http.get(path, primaryParams),
      _http.get(path, {'language': _en}),
    ]);
    return (res[0], res[1]);
  }

  @override
  Future<ShowDetail> show(int tmdbId) async {
    final (primary, en) = await _fetchDetail('/tv/$tmdbId', movie: false);
    final alias = config.language.startsWith('zh')
        ? await _chineseAlias(
            tmdbId,
            false,
            _title(primary, false),
            detail: primary,
          )
        : null;
    return ShowDetail(
      info: _candidate(
        alias == null ? primary : {...primary, 'name': alias},
        MediaKind.episode,
        englishTitle: _title(en, false),
        primaryLang: _primaryLang,
      ),
      seasons: [
        for (final s in _list(primary['seasons']))
          if (_int(s['season_number']) case final number?)
            SeasonInfo(
              number: number,
              episodeCount: _int(s['episode_count']) ?? 0,
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
        if (_int(e['episode_number']) case final number?)
          Episode(
            season: _int(e['season_number']) ?? season,
            number: number,
            title: _str(e['name']),
            airDate: _date(e['air_date']),
            stillPath: _str(e['still_path']),
            overview: _str(e['overview']),
            runtimeMinutes: _int(e['runtime']),
          ),
    ];
  }

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async {
    final lang = {'language': config.language};
    final list = await _http.get('/tv/$tmdbId/episode_groups', lang);
    final ids = [for (final g in _list(list['results'])) ?_str(g['id'])];
    final details = await Future.wait(
      ids.map((id) => _http.get('/tv/episode_group/$id', lang)),
    );
    return [
      for (final d in details)
        if (_str(d['id']) case final groupId?)
          EpisodeGroup(
            id: groupId,
            name: _str(d['name']) ?? '',
            type: _int(d['type']) ?? 0,
            seasons: [
              for (final g in _list(d['groups'])..sort(_byOrder))
                EpisodeGroupSeason(
                  order: _int(g['order']) ?? 0,
                  name: _str(g['name']) ?? '',
                  episodes: [
                    for (final e in _list(g['episodes'])..sort(_byOrder))
                      if ((_int(e['season_number']), _int(e['episode_number']))
                          case (final sn?, final en?))
                        EpisodeRef(sn, en),
                  ],
                ),
            ],
          ),
    ];
  }

  @override
  Future<MovieDetail> movie(int tmdbId) async {
    final (primary, en) = await _fetchDetail('/movie/$tmdbId', movie: true);
    final alias = config.language.startsWith('zh')
        ? await _chineseAlias(
            tmdbId,
            true,
            _title(primary, true),
            detail: primary,
          )
        : null;
    return MovieDetail(
      info: _candidate(
        alias == null ? primary : {...primary, 'title': alias},
        MediaKind.movie,
        englishTitle: _title(en, true),
        primaryLang: _primaryLang,
      ),
    );
  }

  static int _byOrder(Map<String, dynamic> a, Map<String, dynamic> b) =>
      (_int(a['order']) ?? 0).compareTo(_int(b['order']) ?? 0);

  static Map<String, dynamic>? _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static List<Map<String, dynamic>> _list(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is Map) Map<String, dynamic>.from(e),
        ]
      : const [];

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static int? _intOrParsed(Object? v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v.trim()) : null);

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  static String? _trimmed(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;

  static String _title(Map<String, dynamic> r, bool movie) =>
      _str(r[movie ? 'title' : 'name']) ?? '';

  static List<String> _dedupe(Iterable<String> items, {int? limit}) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in items) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (seen.add(s.toLowerCase())) {
        out.add(s);
        if (limit != null && out.length >= limit) break;
      }
    }
    return out;
  }

  static String? _pickLogo(Map<String, dynamic> r, String primaryLang) {
    final logos = _list(_map(r['images'])?['logos']);
    if (logos.isEmpty) return null;
    final lang = primaryLang.toLowerCase();
    int langRank(String? iso) {
      if (iso == null) return 1;
      final l = iso.toLowerCase();
      if (l == lang) return 3;
      if (l == 'en') return 2;
      return 0;
    }

    Map<String, dynamic>? best;
    var bestTier = -1;
    var bestAvg = -1.0;
    var bestCount = -1;
    for (final item in logos) {
      if (_str(item['file_path']) == null) continue;
      final tier = langRank(_str(item['iso_639_1']));
      final avg = (item['vote_average'] as num?)?.toDouble() ?? 0.0;
      final count = _int(item['vote_count']) ?? 0;
      if (tier > bestTier ||
          (tier == bestTier &&
              (avg > bestAvg || (avg == bestAvg && count > bestCount)))) {
        best = item;
        bestTier = tier;
        bestAvg = avg;
        bestCount = count;
      }
    }
    return best == null ? null : _str(best['file_path']);
  }

  static String? _pickLandscape(Map<String, dynamic> r, String primaryLang) {
    final backdrops = _list(_map(r['images'])?['backdrops']);
    if (backdrops.isEmpty) return null;
    final lang = primaryLang.toLowerCase();
    int langRank(String? iso) {
      if (iso == null) return -1;
      final l = iso.toLowerCase();
      if (l == lang) return 2;
      if (l == 'en') return 1;
      return -1;
    }

    Map<String, dynamic>? best;
    var bestTier = -1;
    var bestAvg = -1.0;
    var bestCount = -1;
    for (final item in backdrops) {
      if (_str(item['file_path']) == null) continue;
      final aspect = (item['aspect_ratio'] as num?)?.toDouble();
      if (aspect != null && aspect < 1.5) continue;
      final tier = langRank(_str(item['iso_639_1']));
      if (tier < 0) continue;
      final avg = (item['vote_average'] as num?)?.toDouble() ?? 0.0;
      final count = _int(item['vote_count']) ?? 0;
      if (tier > bestTier ||
          (tier == bestTier &&
              (avg > bestAvg || (avg == bestAvg && count > bestCount)))) {
        best = item;
        bestTier = tier;
        bestAvg = avg;
        bestCount = count;
      }
    }
    return best == null ? null : _str(best['file_path']);
  }

  static String? _certification(Map<String, dynamic> r, bool movie) {
    if (movie) {
      final byRegion = <String, String>{};
      String? firstAny;
      for (final entry in _list(_map(r['release_dates'])?['results'])) {
        final region = _trimmed(entry['iso_3166_1'])?.toUpperCase();
        String? cert;
        for (final rd in _list(entry['release_dates'])) {
          cert = _trimmed(rd['certification']);
          if (cert != null) break;
        }
        if (cert == null) continue;
        firstAny ??= cert;
        if (region != null) byRegion.putIfAbsent(region, () => cert!);
      }
      for (final pref in const ['CN', 'HK', 'TW', 'US']) {
        if (byRegion[pref] case final c?) return c;
      }
      return firstAny;
    } else {
      final byRegion = <String, String>{};
      String? firstAny;
      for (final entry in _list(_map(r['content_ratings'])?['results'])) {
        final region = _trimmed(entry['iso_3166_1'])?.toUpperCase();
        final rating = _trimmed(entry['rating']);
        if (rating == null) continue;
        firstAny ??= rating;
        if (region != null) byRegion.putIfAbsent(region, () => rating);
      }
      for (final pref in const ['CN', 'US']) {
        if (byRegion[pref] case final c?) return c;
      }
      return firstAny;
    }
  }

  static List<String> _studios(Map<String, dynamic> r, bool movie) => _dedupe([
    if (!movie)
      for (final n in _list(r['networks'])) ?_trimmed(n['name']),
    for (final c in _list(r['production_companies'])) ?_trimmed(c['name']),
  ], limit: 5);

  static List<PersonCredit> _actors(Map<String, dynamic> r) {
    final cast = _list(_map(r['credits'])?['cast']);
    if (cast.isEmpty) return const [];
    final indexed =
        [
          for (var i = 0; i < cast.length; i++)
            (i, _int(cast[i]['order']), cast[i]),
        ]..sort((a, b) {
          final oa = a.$2 ?? (1 << 30);
          final ob = b.$2 ?? (1 << 30);
          return oa != ob ? oa.compareTo(ob) : a.$1.compareTo(b.$1);
        });
    final out = <PersonCredit>[];
    for (final entry in indexed) {
      final name = _trimmed(entry.$3['name']);
      if (name == null) continue;
      out.add(
        PersonCredit(
          name: name,
          role: _trimmed(entry.$3['character']),
          profilePath: _str(entry.$3['profile_path']),
        ),
      );
      if (out.length >= 12) break;
    }
    return out;
  }

  static List<String> _directors(Map<String, dynamic> r, bool movie) =>
      _dedupe([
        if (!movie)
          for (final c in _list(r['created_by'])) ?_trimmed(c['name']),
        for (final c in _list(_map(r['credits'])?['crew']))
          if (_trimmed(c['job']) == 'Director') ?_trimmed(c['name']),
      ]);

  static List<String> _writers(Map<String, dynamic> r) => _dedupe([
    for (final c in _list(_map(r['credits'])?['crew']))
      if (_trimmed(c['department']) == 'Writing' ||
          const {'Writer', 'Screenplay', 'Story'}.contains(_trimmed(c['job'])))
        ?_trimmed(c['name']),
  ], limit: 6);

  static List<String> _tags(Map<String, dynamic> r, bool movie) {
    final kw = _map(r['keywords']);
    return _dedupe([
      for (final k in _list(kw?[movie ? 'keywords' : 'results']))
        ?_trimmed(k['name']),
    ], limit: 10);
  }

  static Candidate _candidate(
    Map<String, dynamic> r,
    MediaKind kind, {
    String? englishTitle,
    List<String> aliases = const [],
    String primaryLang = 'zh',
  }) {
    final movie = kind == MediaKind.movie;
    final date = _date(r[movie ? 'release_date' : 'first_air_date']);
    // TV has origin_country; movie details have production_countries instead.
    final oc = r['origin_country'];
    final pc = r['production_countries'];
    final country = oc is List && oc.isNotEmpty
        ? _str(oc.first)
        : pc is List && pc.isNotEmpty
        ? _str(_map(pc.first)?['iso_3166_1'])
        : null;
    final extIds = _map(r['external_ids']);
    final collection = _map(r['belongs_to_collection']);
    return Candidate(
      tmdbId: _int(r['id']) ?? 0,
      kind: kind,
      title: _title(r, movie),
      englishTitle: _str(englishTitle),
      originalTitle: _str(r[movie ? 'original_title' : 'original_name']),
      year: date?.year,
      posterPath: _str(r['poster_path']),
      originCountry: country,
      voteAverage: (r['vote_average'] as num?)?.toDouble(),
      voteCount: _int(r['vote_count']),
      popularity: (r['popularity'] as num?)?.toDouble(),
      overview: _str(r['overview']),
      backdropPath: _str(r['backdrop_path']),
      genres: [for (final g in _list(r['genres'])) ?_str(g['name'])],
      aliases: aliases,
      imdbId: _trimmed(r['imdb_id']) ?? _trimmed(extIds?['imdb_id']),
      tvdbId: _intOrParsed(extIds?['tvdb_id']),
      collectionName: _trimmed(collection?['name']),
      collectionId: _int(collection?['id']),
      clearLogoPath: _pickLogo(r, primaryLang),
      landscapePath: _pickLandscape(r, primaryLang),
      certification: _certification(r, movie),
      studios: _studios(r, movie),
      actors: _actors(r),
      directors: _directors(r, movie),
      writers: _writers(r),
      tags: _tags(r, movie),
    );
  }
}
