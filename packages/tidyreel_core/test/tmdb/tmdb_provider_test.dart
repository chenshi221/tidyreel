import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/src/tmdb/tmdb_client.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Serves recorded JSON from test/tmdb/fixtures; no network.
class FixtureAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  /// 'path|language|query' -> fixture file. Missing search = empty, else 404.
  final routes = <String, String>{
    '/search/movie|zh-CN|Inception': 'search_movie_inception_zh.json',
    '/search/movie|en-US|Inception': 'search_movie_inception_en.json',
    '/search/tv|zh-CN|老友记': 'search_tv_friends_zh.json',
    '/search/tv|en-US|老友记': 'search_tv_friends_en.json',
    '/search/tv|en-US|Dorohedoro': 'search_tv_dorohedoro_en.json',
    '/tv/1668|zh-CN|': 'tv_1668_zh.json',
    '/tv/1668|en-US|': 'tv_1668_en.json',
    '/tv/1668/season/1|zh-CN|': 'tv_1668_season_1_zh.json',
    '/tv/37854/episode_groups|zh-CN|': 'tv_37854_episode_groups_zh.json',
    '/tv/episode_group/5acf93e50e0a26080e0006ad|zh-CN|':
        'episode_group_arcs_zh.json',
    '/tv/episode_group/6bd0a4f61f1b37191f1117be|zh-CN|':
        'episode_group_absolute_zh.json',
    '/movie/27205|zh-CN|': 'movie_27205_zh.json',
    '/movie/27205|en-US|': 'movie_27205_en.json',
  };

  /// Responses to return (status, headers) before normal routing, per call.
  final overrides = <(int, Map<String, String>)>[];

  int count(String path) => requests.where((r) => r.path == path).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    ResponseBody json(String body, int status, [Map<String, String>? h]) =>
        ResponseBody.fromString(
          body,
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            for (final e in (h ?? {}).entries) e.key: [e.value],
          },
        );
    if (overrides.isNotEmpty) {
      final o = overrides.removeAt(0);
      return json('{"status_message":"Too many requests"}', o.$1, o.$2);
    }
    final q = options.queryParameters;
    final file =
        routes['${options.path}|${q['language'] ?? ''}|'
            '${q['query'] ?? ''}'];
    if (file != null) {
      return json(File('test/tmdb/fixtures/$file').readAsStringSync(), 200);
    }
    if (options.path.startsWith('/search/')) {
      return json('{"page":1,"results":[]}', 200);
    }
    return json(
      jsonEncode({'status_code': 34, 'status_message': 'not found'}),
      404,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MapCache implements TmdbResponseCache {
  final data = <String, Map<String, dynamic>>{};
  @override
  Map<String, dynamic>? read(String key) => data[key];
  @override
  void write(String key, Map<String, dynamic> value) => data[key] = value;
}

(TmdbProvider, FixtureAdapter) make({
  String key = 'v3key',
  String? baseUrl,
  TmdbResponseCache? cache,
}) {
  final adapter = FixtureAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final cfg = baseUrl == null
      ? TmdbConfig(apiKey: key)
      : TmdbConfig(apiKey: key, baseUrl: baseUrl);
  return (TmdbProvider(cfg, dio: dio, cache: cache), adapter);
}

void main() {
  group('auth and base url', () {
    test('v3 key goes in api_key query, no Authorization header', () async {
      final (p, a) = make(key: 'abc123');
      await p.movie(27205);
      final r = a.requests.first;
      expect(r.queryParameters['api_key'], 'abc123');
      expect(r.headers.containsKey('Authorization'), isFalse);
    });

    test('v4 token goes in Bearer header, no api_key', () async {
      final (p, a) = make(key: 'eyJhbGciOiJIUzI1NiJ9.payload.sig');
      await p.movie(27205);
      final r = a.requests.first;
      expect(
        r.headers['Authorization'],
        'Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig',
      );
      expect(r.queryParameters.containsKey('api_key'), isFalse);
    });

    test('base url override (proxy) is used', () async {
      final (p, a) = make(baseUrl: 'https://proxy.example.com/tmdb/3');
      await p.movie(27205);
      expect(
        a.requests.first.uri.toString(),
        startsWith('https://proxy.example.com/tmdb/3/movie/27205?'),
      );
    });

    test('HTTP errors become TmdbException with status code', () async {
      final (p, _) = make();
      expect(
        p.show(999),
        throwsA(
          isA<TmdbException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('search', () {
    test('"Inception 2010" ranks 盗梦空间 first and fills all titles', () async {
      final (p, a) = make();
      final r = await p.search('Inception 2010');
      expect(r.first.tmdbId, 27205);
      expect(r.first.title, '盗梦空间');
      expect(r.first.originalTitle, 'Inception');
      expect(r.first.englishTitle, 'Inception');
      expect(r.first.year, 2010);
      expect(r.first.kind, MediaKind.movie);
      expect(r.map((c) => c.tmdbId).toList(), [27205, 64956, 700001]);
      final movieReq = a.requests.firstWhere((x) => x.path == '/search/movie');
      expect(movieReq.queryParameters['year'], '2010');
      expect(movieReq.queryParameters['query'], 'Inception');
    });

    test('"老友记" beats similarly named titles even when listed later', () async {
      final (p, _) = make();
      final r = await p.search('老友记', kind: MediaKind.episode);
      expect(r.map((c) => c.tmdbId).toList(), [1668, 800002, 800001]);
      expect(r.first.englishTitle, 'Friends');
      expect(r.first.originCountry, 'US');
    });

    test('empty zh results fall back to en-US', () async {
      final (p, a) = make();
      final r = await p.search('Dorohedoro', kind: MediaKind.episode);
      expect(r.single.tmdbId, 85937);
      expect(r.single.title, 'Dorohedoro');
      expect(r.single.originalTitle, 'ドロヘドロ');
      expect(a.requests.map((x) => x.queryParameters['language']).toList(), [
        'zh-CN',
        'en-US',
      ]);
    });

    test('year filter is dropped when it yields nothing', () async {
      final (p, a) = make();
      final r = await p.search('Nonexistent Title 2011', kind: MediaKind.movie);
      expect(r, isEmpty);
      expect(
        a.requests.any((x) => x.queryParameters.containsKey('year')),
        isTrue,
      );
    });

    test('second identical search hits the cache', () async {
      final (p, a) = make();
      await p.search('Inception', kind: MediaKind.movie);
      final n = a.requests.length;
      await p.search('Inception', kind: MediaKind.movie);
      expect(a.requests.length, n);
    });
  });

  group('scoreCandidate', () {
    const inception = Candidate(
      tmdbId: 1,
      kind: MediaKind.movie,
      title: '盗梦空间',
      originalTitle: 'Inception',
      englishTitle: 'Inception',
      year: 2010,
    );

    test('matches any of the three titles, ignoring case and punctuation', () {
      for (final q in ['inception', 'INCEPTION!', '盗梦空间', 'Inception.1080p']) {
        expect(
          scoreCandidate(inception, query: q),
          greaterThan(0.69),
          reason: q,
        );
      }
    });

    test('traditional Chinese matches simplified title', () {
      expect(scoreCandidate(inception, query: '盜夢空間'), closeTo(0.7, 1e-9));
    });

    test('year and kind bonuses', () {
      final base = scoreCandidate(inception, query: 'Inception');
      expect(
        scoreCandidate(inception, query: 'Inception', year: 2010),
        closeTo(base + 0.2, 1e-9),
      );
      expect(
        scoreCandidate(inception, query: 'Inception', year: 2011),
        closeTo(base + 0.1, 1e-9),
      );
      expect(scoreCandidate(inception, query: 'Inception', year: 2015), base);
      expect(
        scoreCandidate(inception, query: 'Inception', kind: MediaKind.movie),
        closeTo(base + 0.1, 1e-9),
      );
      expect(
        scoreCandidate(inception, query: 'Inception', kind: MediaKind.episode),
        base,
      );
    });

    test('a year-only query is a title, not a year', () {
      expect(normalizeQuery('2012').text, '2012');
      expect(normalizeQuery('2012').year, isNull);
      expect(normalizeQuery('Movie.Name.2019.2160p.UHD').text, 'Movie Name');
      expect(normalizeQuery('Movie.Name.2019.2160p.UHD').year, 2019);
    });
  });

  group('details', () {
    test('show() includes season 0 with episode counts and en title', () async {
      final (p, _) = make();
      final s = await p.show(1668);
      expect(s.info.title, '老友记');
      expect(s.info.englishTitle, 'Friends');
      expect(s.info.kind, MediaKind.episode);
      expect(s.seasons.map((x) => (x.number, x.episodeCount)).toList(), [
        (0, 3),
        (1, 24),
        (2, 24),
      ]);
      expect(s.seasons.first.airDate, DateTime(1993));
    });

    test('season() maps episodes; empty names become null', () async {
      final (p, _) = make();
      final eps = await p.season(1668, 1);
      expect(eps.map((e) => e.number).toList(), [1, 2]);
      expect(eps.first.title, '六人行');
      expect(eps.last.title, isNull);
      expect(eps.first.season, 1);
    });

    test('movie() fills titles and country', () async {
      final (p, _) = make();
      final m = await p.movie(27205);
      expect(m.info.title, '盗梦空间');
      expect(m.info.englishTitle, 'Inception');
      expect(m.info.year, 2010);
      expect(m.info.originCountry, 'US');
    });

    test(
      'episodeGroups() maps group seasons to original EpisodeRefs in order',
      () async {
        final (p, _) = make();
        final gs = await p.episodeGroups(37854);
        expect(gs.map((g) => g.name).toList(), ['按故事篇章', '绝对顺序']);
        expect(gs.first.type, 6);
        final arcs = gs.first.seasons;
        expect(arcs.map((s) => s.name).toList(), ['第一篇', '第二篇']);
        expect(arcs[0].episodes, [
          const EpisodeRef(1, 1),
          const EpisodeRef(1, 2),
        ]);
        expect(arcs[1].episodes, [
          const EpisodeRef(2, 1),
          const EpisodeRef(2, 2),
        ]);
        expect(gs.last.seasons.single.episodes, [
          const EpisodeRef(1, 1),
          const EpisodeRef(1, 2),
          const EpisodeRef(2, 1),
        ]);
      },
    );
  });

  group('cache and retry', () {
    test('second show() makes no request', () async {
      final (p, a) = make();
      await p.show(1668);
      final n = a.requests.length;
      await p.show(1668);
      expect(a.requests.length, n);
    });

    test('a persistent cache serves a new provider without requests', () async {
      final cache = _MapCache();
      await make(cache: cache).$1.show(1668);
      expect(cache.data.keys.join(), isNot(contains('v3key')));
      final (p, a) = make(cache: cache);
      await p.show(1668);
      expect(a.requests, isEmpty);
    });

    test('429 is retried honoring Retry-After', () async {
      final (p, a) = make();
      a.overrides.add((429, {'retry-after': '0'}));
      final m = await p.movie(27205);
      expect(m.info.tmdbId, 27205);
      // 1 failed + 1 ok for zh, plus the en-US call.
      expect(a.count('/movie/27205'), 3);
    });

    test('gives up after retries and throws', () async {
      final (p, a) = make();
      for (var i = 0; i < 4; i++) {
        a.overrides.add((429, {'retry-after': '0'}));
      }
      await expectLater(
        p.season(1668, 1),
        throwsA(
          isA<TmdbException>().having((e) => e.statusCode, 'status', 429),
        ),
      );
      expect(a.count('/tv/1668/season/1'), 4);
    });

    test('does not mutate caller-supplied Dio.options', () async {
      final adapter = FixtureAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://original.example'))
        ..httpClientAdapter = adapter;
      final origValidate = dio.options.validateStatus;
      final p = TmdbProvider(
        const TmdbConfig(
          apiKey: 'v3key',
          baseUrl: 'https://proxy.example.com/tmdb/3',
        ),
        dio: dio,
      );
      await p.movie(27205);
      expect(dio.options.baseUrl, 'https://original.example');
      expect(dio.options.validateStatus, same(origValidate));
      p.close();
    });

    test('does not retry cancel or badCertificate errors', () async {
      for (final type in [
        DioExceptionType.cancel,
        DioExceptionType.badCertificate,
      ]) {
        var calls = 0;
        final dio = Dio()
          ..httpClientAdapter = _FnAdapter((opts) async {
            calls++;
            throw DioException(requestOptions: opts, type: type);
          });
        final client = TmdbClient(
          apiKey: 'k',
          baseUrl: 'https://api.themoviedb.org/3',
          dio: dio,
        );
        await expectLater(
          client.get('/movie/1'),
          throwsA(isA<TmdbException>()),
        );
        expect(calls, 1, reason: '$type should not be retried');
      }
    });

    test('parseRetryAfter parses numeric clamping and HTTP dates', () {
      expect(TmdbClient.parseRetryAfter('0', 0), const Duration(seconds: 1));
      expect(TmdbClient.parseRetryAfter('120', 0), const Duration(seconds: 30));
      expect(TmdbClient.parseRetryAfter('5', 0), const Duration(seconds: 5));
      final future = DateTime.now().toUtc().add(const Duration(seconds: 12));
      final parsed = TmdbClient.parseRetryAfter(HttpDate.format(future), 0);
      expect(parsed.inSeconds, inInclusiveRange(9, 13));
    });

    test('catches store.write errors and rejects non-JSON HTTP 200 with Chinese message', () async {
      final throwingCache = _ThrowingCache();
      final (p, _) = make(cache: throwingCache);
      expect((await p.movie(27205)).info.tmdbId, 27205);

      final htmlDio = Dio()
        ..httpClientAdapter = _FnAdapter(
          (_) async => ResponseBody.fromString(
            '<html>blocked</html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          ),
        );
      final htmlProvider = TmdbProvider(
        const TmdbConfig(apiKey: 'k'),
        dio: htmlDio,
      );
      await expectLater(
        htmlProvider.movie(27205),
        throwsA(
          isA<TmdbException>()
              .having((e) => e.statusCode, 'status', 200)
              .having((e) => e.message, 'msg', contains('非 JSON')),
        ),
      );
    });

    test('year-filtered low-score hits fall back to yearless search', () async {
      final dio = Dio()
        ..httpClientAdapter = _FnAdapter((opts) async {
          final hasYear = opts.queryParameters.containsKey('year');
          final body = hasYear
              ? {
                  'page': 1,
                  'results': [
                    {
                      'id': 1,
                      'title': 'Completely Unrelated Film',
                      'original_title': 'Completely Unrelated Film',
                      'release_date': '2011-01-01',
                    },
                  ],
                }
              : {
                  'page': 1,
                  'results': [
                    {
                      'id': 27205,
                      'title': '盗梦空间',
                      'original_title': 'Inception',
                      'release_date': '2010-07-15',
                    },
                  ],
                };
          return ResponseBody.fromString(
            jsonEncode(body),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
      final p = TmdbProvider(const TmdbConfig(apiKey: 'k'), dio: dio);
      final hits = await p.search(
        'Inception',
        kind: MediaKind.movie,
        year: 2011,
      );
      expect(hits.first.tmdbId, 27205);
    });

    test('scoring: CJK-glued year, punctuation normalization, and tightened CJK sharesToken', () {
      expect(normalizeQuery('请回答1988').text, '请回答1988');
      expect(normalizeQuery('请回答1988').year, isNull);
      expect(normalizeQuery('请回答1988 2015').text, '请回答1988');
      expect(normalizeQuery('请回答1988 2015').year, 2015);

      expect(sameTitle("Schindler's List", 'Schindlers List'), isTrue);
      expect(sameTitle('『进击的巨人』', '进击的巨人'), isTrue);
      expect(sameTitle('Mr & Mrs Smith', 'Mr Mrs Smith'), isTrue);
      expect(sameTitle('Spider—Man', 'Spider-Man'), isTrue);

      expect(sharesToken('流人', '潮流合伙人'), isTrue);
      expect(sharesToken('流人', '好人'), isFalse);
      expect(sharesToken('进击的巨人', '哈利波特的魔法石'), isFalse);
    });
  });

  group('findByExternalId', () {
    test('tmdb id looks up movie or show by kind, or falls back from movie to show', () async {
      final (p, _) = make();

      final movie = await p.findByExternalId(
        'tmdb',
        '27205',
        kind: MediaKind.movie,
      );
      expect(movie?.tmdbId, 27205);
      expect(movie?.kind, MediaKind.movie);
      expect(movie?.title, '盗梦空间');

      final tv = await p.findByExternalId(
        'tmdb',
        '1668',
        kind: MediaKind.episode,
      );
      expect(tv?.tmdbId, 1668);
      expect(tv?.kind, MediaKind.episode);
      expect(tv?.title, '老友记');

      // kind == null: tries movie(1668) -> 404, then show(1668) -> found.
      final fallbackTv = await p.findByExternalId('tmdb', '1668');
      expect(fallbackTv?.tmdbId, 1668);
      expect(fallbackTv?.kind, MediaKind.episode);

      // Not found and invalid IDs return null cleanly.
      expect(await p.findByExternalId('tmdb', '999999'), isNull);
      expect(await p.findByExternalId('tmdb', 'not-a-num'), isNull);
      expect(await p.findByExternalId('tmdb', '0'), isNull);
      expect(await p.findByExternalId('unknown', '27205'), isNull);
    });

    test('imdb and tvdb use /find, honor kind hint, and enrich via detail', () async {
      final seen = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _FnAdapter((opts) async {
          seen.add(opts);
          Object body;
          var status = 200;
          if (opts.path == '/find/tt1375666') {
            expect(opts.queryParameters['external_source'], 'imdb_id');
            expect(opts.queryParameters['language'], 'zh-CN');
            body = {
              'movie_results': [
                {'id': 27205, 'title': '盗梦空间', 'release_date': '2010-07-15'},
              ],
              'tv_results': [
                {'id': 1668, 'name': '老友记', 'first_air_date': '1994-09-22'},
              ],
            };
          } else if (opts.path == '/find/79168') {
            expect(opts.queryParameters['external_source'], 'tvdb_id');
            body = {
              'movie_results': <Object>[],
              'tv_results': [
                {'id': 1668, 'name': '老友记', 'first_air_date': '1994-09-22'},
              ],
            };
          } else if (opts.path == '/find/tt0000001') {
            body = {
              'movie_results': [
                {
                  'id': 55555,
                  'title': '回退电影',
                  'original_title': 'Fallback Film',
                  'release_date': '2023-05-01',
                  'vote_count': 42,
                },
              ],
              'tv_results': <Object>[],
            };
          } else if (opts.path == '/find/tt9999999') {
            body = {'movie_results': <Object>[], 'tv_results': <Object>[]};
          } else if (opts.path == '/movie/27205') {
            body = {
              'id': 27205,
              'title': opts.queryParameters['language'] == 'en-US'
                  ? 'Inception'
                  : '盗梦空间',
              'original_title': 'Inception',
              'release_date': '2010-07-15',
              'imdb_id': 'tt1375666',
            };
          } else if (opts.path == '/tv/1668') {
            body = {
              'id': 1668,
              'name': opts.queryParameters['language'] == 'en-US'
                  ? 'Friends'
                  : '老友记',
              'original_name': 'Friends',
              'first_air_date': '1994-09-22',
              'external_ids': {'imdb_id': 'tt0108778', 'tvdb_id': 79168},
              'seasons': <Object>[],
            };
          } else {
            status = 404;
            body = {'status_code': 34, 'status_message': 'not found'};
          }
          return ResponseBody.fromString(
            jsonEncode(body),
            status,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final p = TmdbProvider(const TmdbConfig(apiKey: 'k'), dio: dio);
      expect(p, isA<ExternalIdLookup>());

      // IMDb with movie hint picks movie_results and enriches via /movie/27205.
      final m = await p.findByExternalId(
        'imdb',
        'tt1375666',
        kind: MediaKind.movie,
      );
      expect(m?.tmdbId, 27205);
      expect(m?.englishTitle, 'Inception');
      expect(m?.imdbId, 'tt1375666');

      // IMDb with episode hint prefers tv_results and enriches via /tv/1668.
      final tv = await p.findByExternalId(
        'imdb',
        'tt1375666',
        kind: MediaKind.episode,
      );
      expect(tv?.tmdbId, 1668);
      expect(tv?.englishTitle, 'Friends');
      expect(tv?.tvdbId, 79168);

      // TVDB lookup succeeds and enriches.
      final fromTvdb = await p.findByExternalId(
        'tvdb',
        '79168',
        kind: MediaKind.episode,
      );
      expect(fromTvdb?.tmdbId, 1668);
      expect(fromTvdb?.title, '老友记');

      // Detail call failure falls back to /find candidate payload.
      final fallback = await p.findByExternalId('imdb', 'tt0000001');
      expect(fallback?.tmdbId, 55555);
      expect(fallback?.title, '回退电影');
      expect(fallback?.voteCount, 42);

      // Empty /find results and invalid TVDB id return null.
      expect(await p.findByExternalId('imdb', 'tt9999999'), isNull);
      expect(await p.findByExternalId('tvdb', 'not-numeric'), isNull);
    });
  });

  group('enriched details and search fields', () {
    test('search populates voteCount and popularity', () async {
      final (p, _) = make();
      final hits = await p.search('Inception 2010', kind: MediaKind.movie);
      expect(hits.first.voteCount, 36000);
      expect(hits.first.popularity, closeTo(83.9, 1e-6));
    });

    test('movie() parses full append_to_response detail payload', () async {
      RequestOptions? primaryReq;
      final dio = Dio()
        ..httpClientAdapter = _FnAdapter((opts) async {
          if (opts.queryParameters['language'] == 'zh-CN') {
            primaryReq = opts;
          }
          final isEn = opts.queryParameters['language'] == 'en-US';
          final body = {
            'id': 27205,
            'title': isEn ? 'Inception' : '盗梦空间',
            'original_title': 'Inception',
            'release_date': '2010-07-15',
            'vote_average': 8.4,
            'vote_count': 36000,
            'popularity': 83.9,
            'imdb_id': 'tt1375666',
            'external_ids': {'imdb_id': 'tt1375666'},
            'belongs_to_collection': {'id': 101, 'name': '梦境系列'},
            'production_companies': [
              {'name': 'Legendary Pictures'},
              {'name': 'Syncopy'},
              {'name': 'Syncopy'},
              {'name': 'Warner Bros.'},
              {'name': 'Studio 4'},
              {'name': 'Studio 5'},
              {'name': 'Studio 6'},
            ],
            'images': {
              'logos': [
                {
                  'iso_639_1': 'en',
                  'file_path': '/logo_en.png',
                  'vote_average': 9.0,
                  'vote_count': 50,
                },
                {
                  'iso_639_1': 'zh',
                  'file_path': '/logo_zh_low.png',
                  'vote_average': 5.0,
                  'vote_count': 2,
                },
                {
                  'iso_639_1': 'zh',
                  'file_path': '/logo_zh_best.png',
                  'vote_average': 5.0,
                  'vote_count': 10,
                },
                {
                  'iso_639_1': null,
                  'file_path': '/logo_null.png',
                  'vote_average': 8.0,
                  'vote_count': 20,
                },
              ],
              'backdrops': [
                {
                  'iso_639_1': null,
                  'file_path': '/fanart_textless.jpg',
                  'aspect_ratio': 1.778,
                  'vote_average': 9.5,
                  'vote_count': 100,
                },
                {
                  'iso_639_1': 'en',
                  'file_path': '/landscape_en.jpg',
                  'aspect_ratio': 1.778,
                  'vote_average': 6.0,
                  'vote_count': 20,
                },
                {
                  'iso_639_1': 'zh',
                  'file_path': '/landscape_zh.jpg',
                  'aspect_ratio': 1.778,
                  'vote_average': 5.2,
                  'vote_count': 5,
                },
              ],
            },
            'release_dates': {
              'results': [
                {
                  'iso_3166_1': 'CN',
                  'release_dates': [
                    {'certification': ''},
                  ],
                },
                {
                  'iso_3166_1': 'US',
                  'release_dates': [
                    {'certification': ''},
                    {'certification': 'PG-13'},
                  ],
                },
                {
                  'iso_3166_1': 'HK',
                  'release_dates': [
                    {'certification': 'IIA'},
                  ],
                },
              ],
            },
            'credits': {
              'cast': [
                for (var i = 14; i >= 0; i--)
                  {
                    'name': 'Actor $i',
                    'character': 'Role $i',
                    'profile_path': '/a$i.jpg',
                    'order': i,
                  },
              ],
              'crew': [
                {
                  'name': 'Christopher Nolan',
                  'job': 'Director',
                  'department': 'Directing',
                },
                {
                  'name': 'Christopher Nolan',
                  'job': 'Director',
                  'department': 'Directing',
                },
                {
                  'name': 'Christopher Nolan',
                  'job': 'Writer',
                  'department': 'Writing',
                },
                {
                  'name': 'Writer 2',
                  'job': 'Screenplay',
                  'department': 'Writing',
                },
                {'name': 'Writer 3', 'job': 'Story', 'department': 'Writing'},
                {'name': 'Writer 4', 'job': 'Novel', 'department': 'Writing'},
                {'name': 'Writer 5', 'job': 'Writer', 'department': 'Writing'},
                {'name': 'Writer 6', 'job': 'Writer', 'department': 'Writing'},
                {'name': 'Writer 7', 'job': 'Writer', 'department': 'Writing'},
              ],
            },
            'keywords': {
              'keywords': [
                for (var i = 1; i <= 12; i++) {'name': 'kw$i'},
              ],
            },
          };
          return ResponseBody.fromString(
            jsonEncode(body),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final p = TmdbProvider(const TmdbConfig(apiKey: 'k'), dio: dio);
      final detail = await p.movie(27205);
      final c = detail.info;

      expect(
        primaryReq?.queryParameters['append_to_response'],
        'credits,external_ids,images,release_dates,keywords,translations,alternative_titles',
      );
      expect(
        primaryReq?.queryParameters['include_image_language'],
        'zh,en,null',
      );

      expect(c.voteCount, 36000);
      expect(c.popularity, closeTo(83.9, 1e-6));
      expect(c.imdbId, 'tt1375666');
      expect(c.collectionName, '梦境系列');
      expect(c.collectionId, 101);
      expect(c.clearLogoPath, '/logo_zh_best.png');
      expect(c.landscapePath, '/landscape_zh.jpg');
      // CN was empty, HK outranks US.
      expect(c.certification, 'IIA');
      // Deduplicated and capped at 5.
      expect(c.studios, [
        'Legendary Pictures',
        'Syncopy',
        'Warner Bros.',
        'Studio 4',
        'Studio 5',
      ]);
      // Sorted by order, capped at 12.
      expect(c.actors, hasLength(12));
      expect(
        c.actors.first,
        const PersonCredit(
          name: 'Actor 0',
          role: 'Role 0',
          profilePath: '/a0.jpg',
        ),
      );
      expect(c.actors.last.name, 'Actor 11');
      expect(c.directors, ['Christopher Nolan']);
      expect(c.writers, hasLength(6));
      expect(c.writers.first, 'Christopher Nolan');
      expect(c.tags, hasLength(10));
      expect(c.tags.first, 'kw1');
    });

    test('show() parses TV-specific external_ids, content_ratings, networks, created_by, keywords.results', () async {
      RequestOptions? primaryReq;
      final dio = Dio()
        ..httpClientAdapter = _FnAdapter((opts) async {
          if (opts.queryParameters['language'] == 'zh-CN') {
            primaryReq = opts;
          }
          final isEn = opts.queryParameters['language'] == 'en-US';
          final body = {
            'id': 1668,
            'name': isEn ? 'Friends' : '老友记',
            'original_name': 'Friends',
            'first_air_date': '1994-09-22',
            'vote_average': 8.4,
            'vote_count': 8000,
            'popularity': 145.2,
            'external_ids': {'imdb_id': 'tt0108778', 'tvdb_id': 79168},
            'networks': [
              {'name': 'NBC'},
            ],
            'production_companies': [
              {'name': 'NBC'},
              {'name': 'Bright/Kauffman/Crane Productions'},
            ],
            'created_by': [
              {'name': 'David Crane'},
              {'name': 'Marta Kauffman'},
            ],
            'credits': {
              'cast': [
                {
                  'name': 'Jennifer Aniston',
                  'character': 'Rachel Green',
                  'order': 0,
                },
              ],
              'crew': [
                {
                  'name': 'David Crane',
                  'job': 'Director',
                  'department': 'Directing',
                },
                {
                  'name': 'Gary Halvorson',
                  'job': 'Director',
                  'department': 'Directing',
                },
              ],
            },
            'content_ratings': {
              'results': [
                {'iso_3166_1': 'GB', 'rating': '12'},
                {'iso_3166_1': 'US', 'rating': 'TV-14'},
              ],
            },
            'images': {
              'logos': [
                {
                  'iso_639_1': null,
                  'file_path': '/logo_textless.png',
                  'vote_average': 5.0,
                },
              ],
              'backdrops': [
                {
                  'iso_639_1': null,
                  'file_path': '/fanart_only.jpg',
                  'aspect_ratio': 1.778,
                },
              ],
            },
            'keywords': {
              'results': [
                {'name': 'new york city'},
                {'name': 'sitcom'},
              ],
            },
            'seasons': [
              {'season_number': 1, 'episode_count': 24, 'name': 'Season 1'},
            ],
          };
          return ResponseBody.fromString(
            jsonEncode(body),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final p = TmdbProvider(const TmdbConfig(apiKey: 'k'), dio: dio);
      final s = await p.show(1668);
      final c = s.info;

      expect(
        primaryReq?.queryParameters['append_to_response'],
        'credits,external_ids,images,content_ratings,keywords,translations,alternative_titles',
      );
      expect(c.imdbId, 'tt0108778');
      expect(c.tvdbId, 79168);
      expect(c.certification, 'TV-14');
      expect(c.studios, ['NBC', 'Bright/Kauffman/Crane Productions']);
      expect(c.directors, ['David Crane', 'Marta Kauffman', 'Gary Halvorson']);
      expect(c.clearLogoPath, '/logo_textless.png');
      // Textless backdrop is NOT selected as landscapePath.
      expect(c.landscapePath, isNull);
      expect(c.tags, ['new york city', 'sitcom']);
      expect(c.actors, const [
        PersonCredit(name: 'Jennifer Aniston', role: 'Rachel Green'),
      ]);
    });

    test(
      'minimal detail payload omits optional fields without throwing',
      () async {
        final (p, _) = make();
        final m = await p.movie(27205);
        expect(m.info.imdbId, isNull);
        expect(m.info.tvdbId, isNull);
        expect(m.info.collectionName, isNull);
        expect(m.info.clearLogoPath, isNull);
        expect(m.info.landscapePath, isNull);
        expect(m.info.certification, isNull);
        expect(m.info.studios, isEmpty);
        expect(m.info.actors, isEmpty);
        expect(m.info.directors, isEmpty);
        expect(m.info.writers, isEmpty);
        expect(m.info.tags, isEmpty);
      },
    );

    test('en-US detail omits translations/alternative_titles and deduplicates image language', () async {
      final adapter = FixtureAdapter();
      final p = TmdbProvider(
        const TmdbConfig(apiKey: 'k', language: 'en-US'),
        dio: Dio()..httpClientAdapter = adapter,
      );
      await p.movie(27205);
      expect(adapter.requests, hasLength(1));
      final q = adapter.requests.single.queryParameters;
      expect(
        q['append_to_response'],
        'credits,external_ids,images,release_dates,keywords',
      );
      expect(q['include_image_language'], 'en,null');
    });
  });
}

class _ThrowingCache implements TmdbResponseCache {
  @override
  Map<String, dynamic>? read(String key) => null;
  @override
  void write(String key, Map<String, dynamic> value) =>
      throw StateError('disk full');
}

class _FnAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) fn;
  _FnAdapter(this.fn);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => fn(options);

  @override
  void close({bool force = false}) {}
}
