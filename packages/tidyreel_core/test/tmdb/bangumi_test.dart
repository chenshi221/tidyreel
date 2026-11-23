import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _BangumiAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions o) handler;
  final requests = <RequestOptions>[];
  _BangumiAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _FakeAltSource implements AltTitleSource {
  final List<String> titles;
  final bool shouldThrow;
  _FakeAltSource(this.titles, {this.shouldThrow = false});

  @override
  Future<List<String>> altTitles(String query) async {
    if (shouldThrow) throw StateError('boom');
    return titles;
  }
}

void main() {
  group('BangumiTitles', () {
    test(
      'returns name_cn then name, sends required User-Agent and query params',
      () async {
        final adapter = _BangumiAdapter((_) async {
          return _json({
            'results': 2,
            'list': [
              {
                'id': 400602,
                'type': 2,
                'name': '葬送のフリーレン',
                'name_cn': '葬送的芙莉莲',
              },
              {
                'id': 450000,
                'type': 2,
                'name': '葬送のフリーレン &amp; 魔法',
                'name_cn': '葬送的芙莉莲', // duplicate of entry 1
              },
            ],
          });
        });

        final bgm = BangumiTitles(
          dio: Dio()..httpClientAdapter = adapter,
          minInterval: Duration.zero,
          userAgent: 'Tidyreel/1.0-test',
        );
        final titles = await bgm.altTitles('Sousou no Frieren');
        expect(titles, ['葬送的芙莉莲', '葬送のフリーレン', '葬送のフリーレン & 魔法']);

        expect(adapter.requests, hasLength(1));
        final req = adapter.requests.single;
        expect(req.uri.host, 'api.bgm.tv');
        expect(req.uri.path, '/search/subject/Sousou%20no%20Frieren');
        expect(req.queryParameters, {
          'type': '2',
          'responseGroup': 'small',
          'max_results': '5',
        });
        expect(req.headers['User-Agent'], 'Tidyreel/1.0-test');
        bgm.close();
      },
    );

    test(
      'excludes exact copy of query so CN query yields official JP name first',
      () async {
        final adapter = _BangumiAdapter((_) async {
          return _json({
            'results': 1,
            'list': [
              {
                'id': 400602,
                'type': 2,
                'name': '葬送のフリーレン',
                'name_cn': '葬送的芙莉莲',
              },
            ],
          });
        });
        final bgm = BangumiTitles(
          dio: Dio()..httpClientAdapter = adapter,
          minInterval: Duration.zero,
        );
        expect(await bgm.altTitles('葬送的芙莉莲'), ['葬送のフリーレン']);
      },
    );

    test(
      'caches hits and empty results with whitespace/case normalization',
      () async {
        var calls = 0;
        final adapter = _BangumiAdapter((opts) async {
          calls++;
          if (opts.uri.path.contains('Frieren')) {
            return _json({
              'results': 1,
              'list': [
                {'name': '葬送のフリーレン', 'name_cn': '葬送的芙莉莲'},
              ],
            });
          }
          return _json({'results': 0, 'list': <Object>[]});
        });
        final bgm = BangumiTitles(
          dio: Dio()..httpClientAdapter = adapter,
          minInterval: Duration.zero,
        );

        final r1 = await bgm.altTitles('  Frieren  ');
        final r2 = await bgm.altTitles('frieren');
        expect(r1, ['葬送的芙莉莲', '葬送のフリーレン']);
        expect(r2, r1);
        expect(calls, 1);

        // Negative cache for empty hits.
        expect(await bgm.altTitles('Unknown Anime'), isEmpty);
        expect(await bgm.altTitles('  unknown   anime '), isEmpty);
        expect(calls, 2);

        // Blank query does not hit network.
        expect(await bgm.altTitles('   '), isEmpty);
        expect(calls, 2);
      },
    );

    test('swallows 404, 429, 500 and network errors cleanly', () async {
      var step = 0;
      final adapter = _BangumiAdapter((opts) async {
        step++;
        if (step == 1) return _json({'title': 'Not Found'}, status: 404);
        if (step == 2) {
          return _json({'title': 'Too Many Requests'}, status: 429);
        }
        if (step == 3) return _json({'title': 'Server Error'}, status: 503);
        if (step == 4) {
          throw DioException(
            requestOptions: opts,
            type: DioExceptionType.connectionTimeout,
          );
        }
        return _json({
          'results': 1,
          'list': [
            {'name': '銀魂', 'name_cn': '银魂'},
          ],
        });
      });

      final bgm = BangumiTitles(
        dio: Dio()..httpClientAdapter = adapter,
        minInterval: Duration.zero,
      );
      expect(await bgm.altTitles('Missing'), isEmpty);
      expect(await bgm.altTitles('RateLimited'), isEmpty);
      expect(await bgm.altTitles('ServerDown'), isEmpty);
      expect(await bgm.altTitles('TimedOut'), isEmpty);
      // Transient failure was evicted from cache, so retry succeeds.
      expect(await bgm.altTitles('TimedOut'), ['银魂', '銀魂']);
    });
  });

  group('CompositeAltTitleSource', () {
    test(
      'chains sources in priority order, deduplicates, and tolerates failure',
      () async {
        final composite = CompositeAltTitleSource([
          _FakeAltSource(const ['葬送的芙莉莲', 'Frieren']),
          _FakeAltSource(const ['should not happen'], shouldThrow: true),
          _FakeAltSource(const ['  frieren  ', '葬送のフリーレン', '']),
        ]);

        final res = await composite.altTitles('Sousou no Frieren');
        expect(res, ['葬送的芙莉莲', 'Frieren', '葬送のフリーレン']);
      },
    );
  });
}
