import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/connection.dart';
import '../model/scan.dart';
import 'direct_lan.dart';
import 'storage_backend.dart';

/// WebDAV over raw dio (PROPFIND / MKCOL / MOVE / DELETE) with Basic auth.
///
/// `webdav_client` was not used: it surfaces errors as `DioError` without status
/// codes (so notFound / alreadyExists can't be told apart) and its MOVE retries
/// blindly on 409.
class WebDAVBackend implements StorageBackend {
  final Uri _base;
  final String? _authHeader;
  final Dio _dio;

  WebDAVBackend(ConnectionConfig config, Credentials credentials)
    : _base = Uri.parse(config.endpoint),
      _authHeader =
          ((config.username ?? '').isNotEmpty ||
              (credentials.password ?? '').isNotEmpty)
          ? 'Basic ${base64.encode(utf8.encode('${config.username ?? ''}:${credentials.password ?? ''}'))}'
          : null,
      _dio = directForPrivateHosts(
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            sendTimeout: const Duration(seconds: 30),
            validateStatus: (_) => true,
            responseType: ResponseType.plain,
          ),
        ),
      );

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/>'
      '<d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';

  static const _redirects = {301, 302, 303, 307, 308};

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

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  String _dioMsg(DioException e) {
    final detail = e.message;
    return switch (e.type) {
      DioExceptionType.connectionTimeout => '连接超时',
      DioExceptionType.sendTimeout => '发送请求超时',
      DioExceptionType.receiveTimeout => '服务器响应超时',
      DioExceptionType.badCertificate => 'HTTPS 证书校验失败',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.connectionError =>
        detail != null && detail.isNotEmpty ? '无法连接服务器（$detail）' : '无法连接服务器',
      _ => detail != null && detail.isNotEmpty ? detail : e.type.name,
    };
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
    return StorageException(
      code,
      'WebDAV ${r.requestOptions.method} $path 失败：HTTP $s',
    );
  }

  /// dart:io only follows redirects for GET/HEAD, so a 301/302/307/308 on
  /// PROPFIND / PUT / MKCOL etc. is followed here, once, to the same origin.
  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Map<String, Object>? headers,
    Object? Function()? bodyBuilder,
    bool dir = false,
  }) async {
    var uri = _uri(path, dir: dir);
    final reqHeaders = <String, Object>{
      if (_authHeader != null) 'Authorization': _authHeader,
      ...?headers,
    };
    try {
      for (var hop = 0; ; hop++) {
        final r = await _dio.requestUri<dynamic>(
          uri,
          data: bodyBuilder?.call(),
          options: Options(
            method: method,
            headers: reqHeaders,
            followRedirects: false,
          ),
        );
        final location = r.headers.value('location');
        if (hop > 0 ||
            !const {301, 302, 307, 308}.contains(r.statusCode) ||
            location == null) {
          return r;
        }
        final next = uri.resolve(location);
        if (!_sameOrigin(uri, next)) return r;
        uri = next;
      }
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        'WebDAV $method $path 失败：${_dioMsg(e)}',
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
    bodyBuilder: () => _propfindBody,
    dir: dir,
  );

  // Namespace prefixes vary by server (D:, d:, lp1:, none), so match them loosely.
  static String _tag(String name) =>
      '<(?:[\\w.-]+:)?$name\\b[^>]*>(.*?)</(?:[\\w.-]+:)?$name>';
  static final _responseRe = RegExp(_tag('response'), dotAll: true);
  static final _propstatRe = RegExp(_tag('propstat'), dotAll: true);
  static final _statusRe = RegExp(_tag('status'), dotAll: true);
  static final _http2xxRe = RegExp(r'\b2\d\d\b');
  static final _hrefRe = RegExp(_tag('href'), dotAll: true);
  static final _lengthRe = RegExp(_tag('getcontentlength'), dotAll: true);
  static final _modifiedRe = RegExp(_tag('getlastmodified'), dotAll: true);
  static final _collectionRe = RegExp(r'<(?:[\w.-]+:)?collection\b');
  static final _xmlEntityRe = RegExp(
    r'&(?:#x([0-9a-fA-F]+)|#(\d+)|(amp|lt|gt|quot|apos));',
  );

  /// Single-pass XML entity decoder: never double-unescapes and rejects
  /// out-of-range numeric character references instead of throwing RangeError.
  static String _unxml(String s) => s.replaceAllMapped(_xmlEntityRe, (m) {
    final hex = m[1];
    final dec = m[2];
    if (hex != null || dec != null) {
      final cp = hex != null
          ? int.tryParse(hex, radix: 16)
          : int.tryParse(dec!);
      if (cp != null && cp >= 0 && cp <= 0x10FFFF) {
        return String.fromCharCode(cp);
      }
      return m[0]!;
    }
    return switch (m[3]) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      _ => m[0]!,
    };
  });

  /// Converts a resolved URI to a connection-relative path (`/`-rooted).
  String _toRelativePath(Uri resolved) {
    final full = resolved.pathSegments.where((s) => s.isNotEmpty).toList();
    final base = _base.pathSegments.where((s) => s.isNotEmpty).toList();
    var matchesBase = full.length >= base.length;
    if (matchesBase) {
      for (var i = 0; i < base.length; i++) {
        if (full[i] != base[i]) {
          matchesBase = false;
          break;
        }
      }
    }
    final relSegs = matchesBase ? full.sublist(base.length) : full;
    return relSegs.isEmpty ? '/' : '/${relSegs.join('/')}';
  }

  /// href (absolute URL, path, or relative URI, percent-encoded) -> connection-relative path.
  String? _relative(String href, {Uri? scope}) {
    // WebDAV hrefs never carry HTML fragments; escape literal '#' so Uri.parse
    // doesn't truncate filenames containing '#'.
    final raw = _unxml(href.trim()).replaceAll('#', '%23');
    try {
      final parsed = Uri.parse(raw);
      final resolved = (scope ?? _base).resolveUri(parsed);
      return _toRelativePath(resolved);
    } on FormatException {
      return null;
    }
  }

  /// Combines only successful (2xx or status-less) `<propstat>` blocks so
  /// 404 missing-property blocks don't pollute parsed metadata.
  static String _okProps(String responseBlock) {
    final matches = _propstatRe.allMatches(responseBlock).toList();
    if (matches.isEmpty) return responseBlock;
    final buf = StringBuffer();
    for (final m in matches) {
      final ps = m.group(1)!;
      final status = _statusRe.firstMatch(ps)?.group(1);
      if (status != null && !_http2xxRe.hasMatch(status)) continue;
      buf.write(ps);
    }
    return buf.toString();
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final r = await _propfind(dir, 1, dir: true);
    if (r.statusCode != 207) throw _fail(r, dir);
    final reqUri = _uri(dir, dir: true);
    final self = _toRelativePath(reqUri);
    final out = <RemoteEntry>[];
    for (final m in _responseRe.allMatches('${r.data}')) {
      final block = m.group(1)!;
      final href = _hrefRe.firstMatch(block)?.group(1);
      if (href == null) continue;
      final path = _relative(href, scope: reqUri);
      if (path == null) continue;
      // PROPFIND Depth 1 includes the collection itself.
      if (path == self) continue;
      final props = _okProps(block);
      final isDir = _collectionRe.hasMatch(props);
      final len = _lengthRe.firstMatch(props)?.group(1);
      final mod = _modifiedRe.firstMatch(props)?.group(1);
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
  Future<List<int>> read(String path) async {
    var uri = _uri(path);
    try {
      for (var hop = 0; ; hop++) {
        final sendAuth = _authHeader != null && _sameOrigin(_base, uri);
        final r = await _dio.getUri<List<int>>(
          uri,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: false,
            headers: sendAuth ? {'Authorization': _authHeader} : null,
          ),
        );
        final location = r.headers.value('location');
        if (hop < 5 && _redirects.contains(r.statusCode) && location != null) {
          uri = uri.resolve(location);
          continue;
        }
        if (r.statusCode != 200) throw _fail(r, path);
        return r.data ?? const [];
      }
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        'WebDAV 读取 $path 失败：${_dioMsg(e)}',
      );
    }
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    // Not every server honours If-None-Match, so check first as well.
    if (await exists(path)) {
      throw StorageException(StorageErrorCode.alreadyExists, '文件已存在：$path');
    }
    await mkdirs(p.posix.dirname(path));
    final r = await _send(
      'PUT',
      path,
      headers: {
        'If-None-Match': '*',
        Headers.contentLengthHeader: bytes.length,
        Headers.contentTypeHeader: 'application/octet-stream',
      },
      bodyBuilder: () => Stream.value(bytes),
    );
    if (r.statusCode == 412) {
      throw StorageException(StorageErrorCode.alreadyExists, '文件已存在：$path');
    }
    if (r.statusCode != 201 && r.statusCode != 204 && r.statusCode != 200) {
      throw _fail(r, path);
    }
  }

  @override
  Future<void> mkdirs(String dir) async {
    // shortcut: MKCOL on an existing *file* also answers 405, so that case reads as
    // "exists" here; Memory/Local throw alreadyExists. Acceptable: planner never does it.
    final segs = _segs(dir);
    if (segs.isEmpty) return;
    final norm = '/${segs.join('/')}';
    final r = await _send('MKCOL', norm, dir: true);
    if (r.statusCode == 201 || r.statusCode == 405) return;
    if (r.statusCode == 409 && segs.length > 1) {
      await mkdirs(p.posix.dirname(norm));
      final retry = await _send('MKCOL', norm, dir: true);
      if (retry.statusCode == 201 || retry.statusCode == 405) return;
      throw _fail(retry, norm);
    }
    throw _fail(r, norm);
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
  Future<void> rename(String path, String newName) async {
    final dir = p.posix.dirname(path);
    final oldName = p.posix.basename(path);
    final target = p.posix.join(dir, newName);
    if (oldName == newName) return;
    if (oldName.toLowerCase() != newName.toLowerCase()) {
      return _move(path, target);
    }
    // Case-only: a case-insensitive server (IIS, NAS on NTFS/APFS) answers 412
    // since the target "exists" -- it is the source. Refuse only a separate
    // entry spelled exactly like the target, then go through a temporary name.
    if ((await list(dir)).any((e) => e.name == newName)) {
      throw StorageException(StorageErrorCode.alreadyExists, '目标已存在：$target');
    }
    final tmp = p.posix.join(
      dir,
      '.tidyreel-case-${DateTime.now().microsecondsSinceEpoch}',
    );
    await _move(path, tmp);
    try {
      await _move(tmp, target);
    } on Object {
      try {
        await _move(tmp, path);
      } on Object {
        // best effort; the original error is what matters
      }
      rethrow;
    }
  }

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

  @override
  Future<void> close() async {
    _dio.close();
  }
}
