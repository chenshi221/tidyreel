import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _AniListAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions o) handler;
  final queries = <String>[];
  _AniListAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final data = options.data;
    if (data is Map && data['variables'] is Map) {
      queries.add('${(data['variables'] as Map)['s']}');
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(
  Object body, {
  int status = 200,
  Map<String, List<String>>? headers,
}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    ...?headers,
  },
);

void main() {
  test('parseAniList keeps native, english, romaji, synonyms once each', () {
    final titles = parseAniList([
      {
        'title': {
          'native': '不束者な悪女ですが',
          'english': null,
          'romaji': 'Futsutsuka na Akujo dewa Gozaimasu ga',
        },
        'synonyms': ['恶女不才', 'Futsutsuka na Akujo dewa Gozaimasu ga'],
      },
    ]);
    expect(titles, [
      '不束者な悪女ですが',
      'Futsutsuka na Akujo dewa Gozaimasu ga',
      '恶女不才',
    ]);
  });

  test('parseAniList ignores malformed non-Map items safely', () {
    final titles = parseAniList([
      null,
      'not a map',
      123,
      <dynamic, dynamic>{
        'title': {'native': '葬送のフリーレン', 'romaji': 'Sousou no Frieren'},
        'synonyms': ['葬送的芙莉莲', 42],
      },
    ]);
    expect(titles, ['葬送のフリーレン', 'Sousou no Frieren', '葬送的芙莉莲']);
  });

  test('subtitles are also tried without, and plausibility ignores spaces', () {
    final m = {
      'title': {
        'native': 'ふつつかな悪女ではございますが ~雛宮蝶鼠とりかえ伝~',
        'romaji':
            'Futsutsuka na Akujo de wa Gozaimasu ga: Suuguu Chouso Torikae Den',
      },
    };
    expect(parseAniList([m]), contains('ふつつかな悪女ではございますが'));
    expect(
      plausibleAniList('Futsutsuka na Akujo dewa Gozaimasu ga', m),
      isTrue,
    );
    expect(plausibleAniList('Futsutsuka na Shounen', m), isFalse);
  });

  test(
    'queries single-word anime titles and normalizes cache whitespace',
    () async {
      final adapter = _AniListAdapter((_) async {
        return _jsonBody({
          'data': {
            'Page': {
              'media': [
                {
                  'title': {
                    'native': '葬送のフリーレン',
                    'english': 'Frieren: Beyond Journey\'s End',
                    'romaji': 'Sousou no Frieren',
                  },
                  'synonyms': ['Frieren'],
                },
              ],
            },
          },
        });
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final anilist = AniListTitles(dio: dio);
      final res1 = await anilist.altTitles('Frieren');
      expect(res1, contains('葬送のフリーレン'));
      expect(adapter.queries, ['Frieren']);

      // Whitespace-normalized cache hit.
      final res2 = await anilist.altTitles('  frieren  ');
      expect(res2, res1);
      expect(adapter.queries, ['Frieren']);
      anilist.close();
    },
  );

  test('retries once on HTTP 429', () async {
    var calls = 0;
    final adapter = _AniListAdapter((_) async {
      calls++;
      if (calls == 1) {
        return _jsonBody(
          {
            'errors': [
              {'message': 'Too Many Requests'},
            ],
          },
          status: 429,
          headers: {
            'retry-after': ['1'],
          },
        );
      }
      return _jsonBody({
        'data': {
          'Page': {
            'media': [
              {
                'title': {
                  'native': '銀魂',
                  'english': 'Gintama',
                  'romaji': 'Gintama',
                },
                'synonyms': [],
              },
            ],
          },
        },
      });
    });
    final anilist = AniListTitles(dio: Dio()..httpClientAdapter = adapter);
    final res = await anilist.altTitles('Gintama');
    expect(res, contains('銀魂'));
    expect(calls, 2);
  });
}
