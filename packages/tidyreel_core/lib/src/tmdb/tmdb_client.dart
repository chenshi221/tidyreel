import 'dart:async';

import 'package:dio/dio.dart';

/// Any failure talking to TMDB. [statusCode] is null for network errors.
class TmdbException implements Exception {
  final int? statusCode;
  final String message;
  final String path;

  TmdbException(this.message, {this.statusCode, this.path = ''});

  @override
  String toString() =>
      'TmdbException(${statusCode ?? 'network'} $path): $message';
}

/// Cached, rate-limited, retrying JSON GET against the TMDB v3 API.
class TmdbClient {
  final Dio _dio;
  final bool _bearer;
  final String _apiKey;
  static const _minInterval = Duration(milliseconds: 50); // 20 req/s
  static const _maxRetries = 3;
  final _cache = <String, Future<Map<String, dynamic>>>{};
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  TmdbClient({required String apiKey, required String baseUrl, Dio? dio})
    : _dio = dio ?? Dio(),
      _apiKey = apiKey.trim(),
      _bearer = apiKey.trim().startsWith('eyJ') {
    _dio.options.baseUrl = baseUrl;
    _dio.options.validateStatus = (_) => true; // handled in _fetch
  }

  /// GET [path] with [query]; identical calls are served from memory.
  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) {
    final q = Map<String, String>.of(query ?? {});
    final key =
        '$path?${(q.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final f = _fetch(path, q);
    _cache[key] = f;
    // Never cache failures.
    f.catchError((_) {
      _cache.remove(key);
      return <String, dynamic>{};
    });
    return f;
  }

  Future<void> _waitSlot() async {
    final now = DateTime.now();
    final slot = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = slot.add(_minInterval);
    final wait = slot.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  Future<Map<String, dynamic>> _fetch(
    String path,
    Map<String, String> query,
  ) async {
    if (!_bearer) query['api_key'] = _apiKey;
    for (var attempt = 0; ; attempt++) {
      await _waitSlot();
      Response<dynamic> res;
      try {
        res = await _dio.get<dynamic>(
          path,
          queryParameters: query,
          options: Options(
            headers: {if (_bearer) 'Authorization': 'Bearer $_apiKey'},
            responseType: ResponseType.json,
          ),
        );
      } on DioException catch (e) {
        if (attempt < _maxRetries) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        throw TmdbException(e.message ?? e.type.name, path: path);
      }
      final code = res.statusCode ?? 0;
      final retryable = code == 429 || code >= 500;
      if (retryable && attempt < _maxRetries) {
        final ra = int.tryParse(res.headers.value('retry-after') ?? '');
        await Future<void>.delayed(Duration(seconds: ra ?? 1 << attempt));
        continue;
      }
      final body = res.data;
      if (code >= 200 && code < 300 && body is Map<String, dynamic>) {
        return body;
      }
      final msg = body is Map ? body['status_message'] : null;
      throw TmdbException(
        msg?.toString() ?? 'HTTP $code',
        statusCode: code,
        path: path,
      );
    }
  }
}
