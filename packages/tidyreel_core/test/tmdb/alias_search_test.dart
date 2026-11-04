import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Serves 'path|page' -> JSON; anything else is an empty search or a 404.
class _Adapter implements HttpClientAdapter {
  final Map<String, Object> routes;
  final requests = <String>[];
  _Adapter(this.routes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${o.path}|${o.queryParameters['page'] ?? 1}';
    requests.add(key);
    final body = routes[key];
    return ResponseBody.fromString(
      jsonEncode(body ?? {'status_message': 'not found'}),
      body == null ? 404 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object> _hit(int id, String name) => {
  'id': id,
  'name': name,
  'original_name': name,
  'first_air_date': '2022-04-01',
};

Map<String, Object> _page(List<Map<String, Object>> results, int total) => {
  'results': results,
  'total_pages': total,
};

Future<(List<Candidate>, _Adapter)> _search(
  Map<String, Object> routes,
  String q,
) async {
  final a = _Adapter(routes);
  final p = TmdbProvider(
    const TmdbConfig(apiKey: 'k'),
    dio: Dio()..httpClientAdapter = a,
  );
  return (await p.search(q, kind: MediaKind.episode), a);
}

void main() {
  test('a hit on page 2 matched by alias ranks first', () async {
    final (r, _) = await _search({
      '/search/tv|1': _page([_hit(1, '潮流合伙人'), _hit(2, '名人流浪记')], 2),
      '/search/tv|2': _page([_hit(95480, 'Slow Horses')], 2),
      '/tv/95480/alternative_titles|1': {
        'results': [
          {'title': '流人'},
          {'title': '驽马'},
        ],
      },
    }, '流人');
    expect(r.first.tmdbId, 95480);
    expect(r.first.aliases, contains('流人'));
    expect(r.map((c) => c.tmdbId), containsAll([1, 2]));
  });

  test('an exact title on page 1 costs no extra requests', () async {
    final (r, a) = await _search({
      '/search/tv|1': _page([_hit(1, '流人'), _hit(2, 'Other')], 3),
    }, '流人');
    expect(r.first.tmdbId, 1);
    expect(a.requests.toSet(), {'/search/tv|1'});
  });

  test('a failed alias lookup keeps the hit', () async {
    final (r, _) = await _search({
      '/search/tv|1': _page([_hit(7, 'Slow Horses')], 1),
    }, '流人');
    expect(r.single.aliases, isEmpty);
  });

  test('sharesToken: per character for CJK, per word for Latin', () {
    expect(sharesToken('流人', '潮流合伙人'), isTrue);
    expect(sharesToken('流人', 'Slow Horses'), isFalse);
    expect(sharesToken('slow man', 'Slow Horses'), isTrue);
    expect(sharesToken('horse', 'Cat'), isFalse);
  });
}
