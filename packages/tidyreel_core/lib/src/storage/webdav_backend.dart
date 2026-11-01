import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/connection.dart';
import '../model/scan.dart';
import 'storage_backend.dart';

/// WebDAV over raw dio (PROPFIND / MKCOL / MOVE / DELETE) with Basic auth.
///
/// `webdav_client` was not used: it surfaces errors as `DioError` without status
/// codes (so notFound / alreadyExists can't be told apart) and its MOVE retries
/// blindly on 409.
class WebDAVBackend implements StorageBackend {
  final Uri _base;
  final Dio _dio;

  WebDAVBackend(ConnectionConfig config, Credentials credentials)
    : _base = Uri.parse(config.endpoint),
      _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
          headers: {
            if (config.username != null)
              'Authorization':
                  'Basic ${base64.encode(utf8.encode('${config.username}:${credentials.password ?? ''}'))}',
          },
        ),
      );

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/>'
      '<d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';

  List<String> _segs(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  /// Percent-encoded absolute URL (Uri encodes each segment: Chinese, spaces,
  /// brackets). [dir] adds the trailing slash collections should be addressed
  /// with: Apache / nginx / Synology answer 301 without it.
  Uri _uri(String path, {bool dir = false}) {
    final segs = [
      ..._base.pathSegments.where((s) => s.isNotEmpty),
      ..._segs(path),
    ];
    if (segs.isEmpty) return _base.replace(path: '/');
    return _base.replace(pathSegments: [...segs, if (dir) '']);
  }

  StorageException _fail(Response<dynamic> r, String path) {
    final s = r.statusCode ?? 0;
    final code = switch (s) {
      401 || 403 => StorageErrorCode.unauthorized,
      404 || 409 => StorageErrorCode.notFound, // 409: parent collection missing
      412 =>
        StorageErrorCode.alreadyExists, // Overwrite: F hit an existing target
      423 => StorageErrorCode.busy, // Locked
      429 => StorageErrorCode.rateLimited,
      502 || 503 || 504 => StorageErrorCode.network,
      _ => StorageErrorCode.other,
    };
    return StorageException(code, '${r.requestOptions.method} $path: HTTP $s');
  }

  /// dart:io only follows redirects for GET/HEAD, so a 301/302/307/308 on
  /// PROPFIND etc. is followed here, once, to the same server.
  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? headers,
    String? body,
    bool dir = false,
  }) async {
    var uri = _uri(path, dir: dir);
    try {
      for (var hop = 0; ; hop++) {
        final r = await _dio.requestUri<dynamic>(
          uri,
          data: body,
          options: Options(
            method: method,
            headers: headers,
            followRedirects: false,
          ),
        );
        final location = r.headers.value('location');
        const redirects = {301, 302, 307, 308};
        if (hop > 0 || !redirects.contains(r.statusCode) || location == null) {
          return r;
        }
        final next = uri.resolve(location);
        if (next.host != uri.host || next.port != uri.port) return r;
        uri = next;
      }
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        '$method $path: ${e.message}',
      );
    }
  }

  Future<Response<dynamic>> _propfind(
    String path,
    int depth, {
    bool dir = false,
  }) => _send(
    'PROPFIND',
    path,
    headers: {'Depth': '$depth', 'Content-Type': 'application/xml'},
    body: _propfindBody,
    dir: dir,
  );

  // Namespace prefixes vary by server (D:, d:, none), so match them loosely.
  static String _tag(String name) =>
      '<(?:\\w+:)?$name\\b[^>]*>(.*?)</(?:\\w+:)?$name>';
  static final _responseRe = RegExp(_tag('response'), dotAll: true);
  static final _hrefRe = RegExp(_tag('href'), dotAll: true);
  static final _lengthRe = RegExp(_tag('getcontentlength'), dotAll: true);
  static final _modifiedRe = RegExp(_tag('getlastmodified'), dotAll: true);
  static final _collectionRe = RegExp(r'<(?:\w+:)?collection\b');

  static String _unxml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// href (absolute URL or path, percent-encoded) -> connection-relative path.
  String _relative(String href) {
    final full = Uri.decodeComponent(Uri.parse(_unxml(href.trim())).path);
    final base = Uri.decodeComponent(_base.path)
        .replaceFirst(RegExp(r'/+$'), '');
    var rel = full.startsWith(base) ? full.substring(base.length) : full;
    rel = rel.replaceFirst(RegExp(r'/+$'), '');
    return rel.isEmpty ? '/' : (rel.startsWith('/') ? rel : '/$rel');
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final r = await _propfind(dir, 1, dir: true);
    if (r.statusCode != 207) throw _fail(r, dir);
    final self = _relative(_uri(dir).path);
    final out = <RemoteEntry>[];
    for (final m in _responseRe.allMatches('${r.data}')) {
      final block = m.group(1)!;
      final href = _hrefRe.firstMatch(block)?.group(1);
      if (href == null) continue;
      final path = _relative(href);
      // PROPFIND Depth 1 includes the collection itself.
      if (path == self) continue;
      final isDir = _collectionRe.hasMatch(block);
      final len = _lengthRe.firstMatch(block)?.group(1);
      final mod = _modifiedRe.firstMatch(block)?.group(1);
      DateTime? modified;
      try {
        modified = mod == null ? null : HttpDate.parse(mod.trim());
      } on Exception {
        // unparseable date: leave null
      }
      out.add(
        RemoteEntry(
          path: path,
          name: p.posix.basename(path),
          isDir: isDir,
          size: isDir ? 0 : int.tryParse(len?.trim() ?? '') ?? 0,
          modified: modified,
        ),
      );
    }
    return out;
  }

  @override
  Future<bool> exists(String path) async {
    final r = await _propfind(path, 0);
    if (r.statusCode == 207) return true;
    if (r.statusCode == 404) return false;
    throw _fail(r, path);
  }

  @override
  Future<void> mkdirs(String dir) async {
    // shortcut: MKCOL on an existing *file* also answers 405, so that case reads as
    // "exists" here; Memory/Local throw alreadyExists. Acceptable: planner never does it.
    var cur = '';
    for (final s in _segs(dir)) {
      cur = '$cur/$s';
      final r = await _send('MKCOL', cur);
      if (r.statusCode != 201 && r.statusCode != 405) throw _fail(r, cur);
    }
  }

  Future<void> _move(String from, String to) async {
    final r = await _send(
      'MOVE',
      from,
      headers: {'Destination': _uri(to).toString(), 'Overwrite': 'F'},
    );
    final s = r.statusCode;
    if (s == 201 || s == 204) return;
    // 409 here means the destination's parent is missing; the source is checked by 404.
    throw _fail(r, from);
  }

  @override
  Future<void> rename(String path, String newName) =>
      _move(path, p.posix.join(p.posix.dirname(path), newName));

  /// WebDAV has no batch rename; each MOVE is one request anyway.
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    for (final e in names.entries) {
      await rename(p.posix.join(dir, e.key), e.value);
    }
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    for (final n in names) {
      await _move(p.posix.join(srcDir, n), p.posix.join(dstDir, n));
    }
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    for (final n in names) {
      final path = p.posix.join(dir, n);
      final r = await _send('DELETE', path);
      final s = r.statusCode;
      if (s != 200 && s != 204) throw _fail(r, path);
    }
  }

  @override
  Future<void> ping() async {
    final r = await _propfind('/', 0, dir: true);
    if (r.statusCode != 207) throw _fail(r, '/');
  }
}
