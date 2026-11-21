import 'dart:async';

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
  final bool _ownsDio;
  final _cache = <String, Future<List<String>>>{};
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  static const _minInterval = Duration(milliseconds: 120);
  static const _maxCacheEntries = 1000;
  static final _wsRe = RegExp(r'\s+');

  AniListTitles({Dio? dio})
    : _ownsDio = dio == null,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              sendTimeout: const Duration(seconds: 8),
            ),
          );

  void close() {
    if (_ownsDio) _dio.close();
  }

  static const _query = r'''
query ($s: String) {
  Page(perPage: 2) {
    media(search: $s, type: ANIME) {
      title { native english romaji }
      synonyms
    }
  }
}''';

  Future<void> _waitSlot() async {
    final now = DateTime.now();
    final slot = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = slot.add(_minInterval);
    final wait = slot.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  @override
  Future<List<String>> altTitles(String query) {
    final normalized = query.trim().replaceAll(_wsRe, ' ');
    if (normalized.isEmpty) return Future.value(const []);
    final key = normalized.toLowerCase();
    final hit = _cache[key];
    if (hit != null) {
      _cache.remove(key);
      _cache[key] = hit;
      return hit;
    }
    while (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    return _cache[key] = _fetch(key, normalized);
  }

  Future<Response<dynamic>> _postQuery(String search) async {
    for (var attempt = 0; ; attempt++) {
      await _waitSlot();
      final r = await _dio.post<dynamic>(
        'https://graphql.anilist.co',
        data: {
          'query': _query,
          'variables': {'s': search},
        },
        options: Options(validateStatus: (_) => true),
      );
      if (r.statusCode == 429 && attempt == 0) {
        final ra = int.tryParse(r.headers.value('retry-after') ?? '');
        final delay = Duration(seconds: (ra ?? 2).clamp(1, 15));
        final until = DateTime.now().add(delay);
        if (until.isAfter(_nextSlot)) _nextSlot = until;
        await Future<void>.delayed(delay);
        continue;
      }
      return r;
    }
  }

  /// AniList matches whole words, so "Akujo dewa" misses "Akujo de wa":
  /// retry with fewer words (down to 1 word for single-word titles like
  /// "Frieren"), keeping only hits that start like [query].
  Future<List<String>> _fetch(String key, String query) async {
    final words = query.split(' ');
    try {
      for (var n = words.length; n >= 1 && n > words.length - 4; n--) {
        final r = await _postQuery(words.take(n).join(' '));
        if (r.statusCode != 200) {
          _cache.remove(key);
          return const [];
        }
        final body = r.data;
        if (body is! Map) break;
        final data = body['data'];
        if (data is! Map) break;
        final page = data['Page'];
        if (page is! Map) break;
        final media = page['media'];
        if (media is! List) continue;
        final hits = media.where((m) => plausibleAniList(query, m)).toList();
        if (hits.isNotEmpty) return parseAniList(hits);
      }
    } on Object {
      // Unreachable or changed API: evict so transient errors are not cached.
      _cache.remove(key);
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

  for (final m in media) {
    if (m is! Map) continue;
    final rawTitle = m['title'];
    final t = rawTitle is Map ? rawTitle : const {};
    final synonyms = m['synonyms'];
    for (final v in [
      t['native'],
      t['english'],
      t['romaji'],
      if (synonyms is List) ...synonyms,
    ]) {
      add(v);
      if (v is String) add(v.split(_subtitleSep).first);
    }
  }
  return out;
}
