import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
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

(TmdbProvider, FixtureAdapter) make({String key = 'v3key', String? baseUrl}) {
  final adapter = FixtureAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final cfg = baseUrl == null
      ? TmdbConfig(apiKey: key)
      : TmdbConfig(apiKey: key, baseUrl: baseUrl);
  return (TmdbProvider(cfg, dio: dio), adapter);
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
  });
}
