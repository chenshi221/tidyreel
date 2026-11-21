import 'dart:async';
import 'dart:io' show HttpDate;

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

/// Keeps TMDB replies across app runs. Keys never contain the API key.
abstract interface class TmdbResponseCache {
  Map<String, dynamic>? read(String key);
  void write(String key, Map<String, dynamic> value);
}

/// Cached, rate-limited, retrying JSON GET against the TMDB v3 API.
class TmdbClient {
  final Dio _dio;
  final bool _ownsDio;
  final String _baseUrl;
  final bool _bearer;
  final String _apiKey;
  static const _connectTimeout = Duration(seconds: 15);
  static const _receiveTimeout = Duration(seconds: 20);
  static const _sendTimeout = Duration(seconds: 15);
  static const _minInterval = Duration(milliseconds: 50); // 20 req/s
  static const _maxRetries = 3;
  static const _maxCacheEntries = 2000;
  final _cache = <String, Future<Map<String, dynamic>>>{};
  final TmdbResponseCache? store;
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  TmdbClient({
    required String apiKey,
    required String baseUrl,
    Dio? dio,
    this.store,
  }) : _baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _ownsDio = dio == null,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl.replaceFirst(RegExp(r'/+$'), ''),
               connectTimeout: _connectTimeout,
               receiveTimeout: _receiveTimeout,
               sendTimeout: _sendTimeout,
               validateStatus: (_) => true, // handled in _fetch
             ),
           ),
       _apiKey = apiKey.trim(),
       _bearer = apiKey.trim().startsWith('eyJ');

  void close() {
    if (_ownsDio) _dio.close();
  }

  void _putCache(String key, Future<Map<String, dynamic>> value) {
    _cache.remove(key);
    while (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  /// GET [path] with [query]; identical calls are served from memory, then [store].
  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) {
    final q = Map<String, String>.of(query ?? {});
    final key =
        '$path?${(q.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';
    final hit = _cache[key];
    if (hit != null) {
      // Refresh LRU order.
      _cache.remove(key);
      _cache[key] = hit;
      return hit;
    }
    Map<String, dynamic>? stored;
    try {
      stored = store?.read(key);
    } on Object {
      stored = null;
    }
    if (stored != null) {
      final f = Future.value(stored);
      _putCache(key, f);
      return f;
    }
    final f = _fetch(path, q);
    _putCache(key, f);
    f.then((v) {
      try {
        store?.write(key, v);
      } on Object {
        // Cache persistence failure should never break TMDB responses.
      }
    }, onError: (Object _) {});
    // Never cache failures.
    f.catchError((_) {
      if (identical(_cache[key], f)) _cache.remove(key);
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

  static Duration parseRetryAfter(String? raw, int attempt) {
    if (raw != null && raw.trim().isNotEmpty) {
      final trimmed = raw.trim();
      final secs = int.tryParse(trimmed);
      if (secs != null) {
        return Duration(seconds: secs.clamp(1, 30));
      }
      try {
        final until = HttpDate.parse(trimmed);
        final diff = until.difference(DateTime.now().toUtc()).inSeconds;
        return Duration(seconds: diff.clamp(1, 30));
      } on Object {
        // Fall through to exponential backoff.
      }
    }
    return Duration(seconds: (1 << attempt).clamp(1, 30));
  }

  TmdbException _networkError(DioException e, String path) {
    final msg = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        '连接 TMDB 超时，如无法直连请在设置中配置 TMDB 代理地址（Base URL）',
      DioExceptionType.badCertificate => 'TMDB HTTPS 证书校验失败，请检查代理或网络环境',
      DioExceptionType.cancel => 'TMDB 请求已取消',
      _ =>
        '无法连接 TMDB（${e.message ?? e.type.name}），如无法直连请在设置中配置 TMDB 代理地址（Base URL）',
    };
    return TmdbException(msg, path: path);
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
        final req =
            Options(
                method: 'GET',
                headers: {if (_bearer) 'Authorization': 'Bearer $_apiKey'},
                responseType: ResponseType.json,
                validateStatus: (_) => true,
                receiveTimeout: _dio.options.receiveTimeout ?? _receiveTimeout,
                sendTimeout: _dio.options.sendTimeout ?? _sendTimeout,
              ).compose(_dio.options, path, queryParameters: query)
              ..baseUrl = _baseUrl
              ..connectTimeout ??= _connectTimeout;
        res = await _dio.fetch<dynamic>(req);
      } on DioException catch (e) {
        final nonRetryable =
            e.type == DioExceptionType.cancel ||
            e.type == DioExceptionType.badCertificate;
        if (!nonRetryable && attempt < _maxRetries) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        throw _networkError(e, path);
      }
      final code = res.statusCode ?? 0;
      final retryable = code == 429 || code >= 500;
      if (retryable && attempt < _maxRetries) {
        final delay = parseRetryAfter(
          res.headers.value('retry-after'),
          attempt,
        );
        if (code == 429) {
          final until = DateTime.now().add(delay);
          if (until.isAfter(_nextSlot)) _nextSlot = until;
        }
        await Future<void>.delayed(delay);
        continue;
      }
      final body = res.data;
      if (code >= 200 && code < 300) {
        if (body is Map<String, dynamic>) return body;
        throw TmdbException(
          'TMDB 返回了非 JSON 响应（HTTP $code），请检查 TMDB 代理地址（Base URL）是否正确',
          statusCode: code,
          path: path,
        );
      }
      if (code == 401) {
        throw TmdbException(
          'TMDB API Key 无效或已过期，请在设置中检查',
          statusCode: code,
          path: path,
        );
      }
      if (code == 429) {
        throw TmdbException(
          'TMDB 请求过于频繁（HTTP 429），请稍后重试',
          statusCode: code,
          path: path,
        );
      }
      final rawMsg = body is Map ? body['status_message']?.toString() : null;
      throw TmdbException(
        rawMsg != null && rawMsg.isNotEmpty
            ? 'TMDB 请求失败（HTTP $code）：$rawMsg'
            : 'TMDB 请求失败（HTTP $code）',
        statusCode: code,
        path: path,
      );
    }
  }
}
