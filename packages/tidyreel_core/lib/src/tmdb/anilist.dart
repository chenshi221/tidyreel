import 'package:dio/dio.dart';

import '../plan/text.dart';

/// Other names of a title, for queries TMDB can't find on their own (romaji
/// like "Futsutsuka na Akujo dewa Gozaimasu ga").
abstract interface class AltTitleSource {
  /// Native / English / synonym titles, best match first; empty when unknown
  /// or unreachable (a lookup failure must never fail a scan).
  Future<List<String>> altTitles(String query);
}

/// AniList's public GraphQL API: free, no key, knows romaji names. Only the
/// title text is sent.
class AniListTitles implements AltTitleSource {
  final Dio _dio;
  final _cache = <String, Future<List<String>>>{};

  AniListTitles({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ),
          );

  static const _query = r'''
query ($s: String) {
  Page(perPage: 2) {
    media(search: $s, type: ANIME) {
      title { native english romaji }
      synonyms
    }
  }
}''';

  @override
  Future<List<String>> altTitles(String query) =>
      _cache[query.toLowerCase()] ??= _fetch(query);

  /// AniList matches whole words, so "Akujo dewa" misses "Akujo de wa":
  /// retry with fewer words, keeping only hits that start like [query].
  Future<List<String>> _fetch(String query) async {
    final words = query.trim().split(RegExp(r'\s+'));
    try {
      for (var n = words.length; n >= 2 && n > words.length - 4; n--) {
        final r = await _dio.post<dynamic>(
          'https://graphql.anilist.co',
          data: {
            'query': _query,
            'variables': {'s': words.take(n).join(' ')},
          },
        );
        final media =
            (((r.data as Map)['data'] as Map)['Page'] as Map)['media'] as List;
        final hits = media.where((m) => plausibleAniList(query, m)).toList();
        if (hits.isNotEmpty) return parseAniList(hits);
      }
    } on Object {
      // Unreachable or changed API: no aliases.
    }
    return const [];
  }
}

/// One of [m]'s Latin titles and [query] share their start (ignoring spaces
/// and punctuation), or are near-identical.
bool plausibleAniList(String query, dynamic m) {
  final q = normTitle(query);
  if (q.isEmpty || m is! Map) return false;
  final t = (m['title'] as Map?) ?? const {};
  return [t['romaji'], t['english'], ...?(m['synonyms'] as List?)]
      .whereType<String>()
      .map(normTitle)
      .any(
        (n) =>
            n.startsWith(q) ||
            (n.length >= 6 && q.startsWith(n)) ||
            similarity(n, q) > 0.8,
      );
}

final _subtitleSep = RegExp(r'\s*[~～:：]\s*|\s+-\s+');

/// Titles from AniList `media` entries, deduplicated, in usefulness order;
/// each also without its subtitle ("Title ~Sub~" → "Title").
List<String> parseAniList(List<dynamic> media) {
  final out = <String>[];
  void add(Object? v) {
    if (v is! String) return;
    final t = v.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  for (final m in media.cast<Map<String, dynamic>>()) {
    final t = (m['title'] as Map?) ?? const {};
    for (final v in [
      t['native'],
      t['english'],
      t['romaji'],
      ...?(m['synonyms'] as List?),
    ]) {
      add(v);
      if (v is String) add(v.split(_subtitleSep).first);
    }
  }
  return out;
}
