import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'anilist.dart';

/// Bangumi (bgm.tv) public API alt-title lookup for anime Chinese/Japanese
/// canonical names and synonyms.
class BangumiTitles implements AltTitleSource {
  final Dio _dio;
  final bool _ownsDio;
  final Duration _minInterval;
  final String userAgent;
  final _cache = <String, Future<List<String>>>{};
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  static const _defaultMinInterval = Duration(milliseconds: 400);
  static const _maxCacheEntries = 256;
  static final _wsRe = RegExp(r'\s+');

  BangumiTitles({
    Dio? dio,
    Duration? minInterval,
    this.userAgent = 'Tidyreel/1.0 (https://github.com/tidyreel)',
  }) : _ownsDio = dio == null,
       _minInterval = minInterval ?? _defaultMinInterval,
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

  Future<void> _waitSlot() async {
    if (_minInterval <= Duration.zero) return;
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

  Future<List<String>> _fetch(String key, String query) async {
    try {
      await _waitSlot();
      final encoded = Uri.encodeComponent(query);
      final r = await _dio.get<dynamic>(
        'https://api.bgm.tv/search/subject/$encoded',
        queryParameters: const {
          'type': '2',
          'responseGroup': 'small',
          'max_results': '5',
        },
        options: Options(
          headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
          validateStatus: (_) => true,
        ),
      );
      final code = r.statusCode ?? 0;
      if (code == 404) {
        // Bangumi returns 404 when a query has no matching subjects: keep in
        // negative cache.
        return const [];
      }
      if (code != 200) {
        _cache.remove(key);
        return const [];
      }
      var body = r.data;
      if (body is String) {
        body = jsonDecode(body);
      }
      if (body is! Map) return const [];
      final list = body['list'];
      if (list is! List) return const [];
      return parseBangumi(list, query: query);
    } on Object {
      // Transient failure or malformed response: evict so it is not cached.
      _cache.remove(key);
      return const [];
    }
  }
}

/// Extracts deduplicated useful alt titles from a Bangumi search `list`,
/// prioritizing `name_cn` before `name` for each entry and excluding an
/// identical copy of [query].
List<String> parseBangumi(List<dynamic> list, {String query = ''}) {
  final wsRe = RegExp(r'\s+');
  final queryKey = query.trim().replaceAll(wsRe, ' ').toLowerCase();
  final out = <String>[];
  final seen = <String>{};

  void add(Object? raw) {
    if (raw is! String) return;
    final t = _unescapeHtml(raw).trim();
    if (t.isEmpty) return;
    final key = t.replaceAll(wsRe, ' ').toLowerCase();
    if (key.isEmpty || key == queryKey) return;
    if (seen.add(key)) out.add(t);
  }

  for (final item in list) {
    if (item is! Map) continue;
    add(item['name_cn']);
    add(item['name']);
  }
  return out;
}

String _unescapeHtml(String s) {
  if (!s.contains('&')) return s;
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

/// Chains multiple [AltTitleSource] providers in priority order, deduplicating
/// results while keeping each source resilient to errors.
class CompositeAltTitleSource implements AltTitleSource {
  final List<AltTitleSource> sources;

  const CompositeAltTitleSource(this.sources);

  @override
  Future<List<String>> altTitles(String query) async {
    final out = <String>[];
    final seen = <String>{};
    for (final src in sources) {
      try {
        for (final t in await src.altTitles(query)) {
          final k = t.trim().toLowerCase();
          if (k.isNotEmpty && seen.add(k)) out.add(t.trim());
        }
      } on Object {
        // Ignore transient failure of one alt-title provider.
      }
    }
    return out;
  }
}
