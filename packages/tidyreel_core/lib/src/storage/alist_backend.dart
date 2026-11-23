import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/connection.dart';
import '../model/scan.dart';
import 'direct_lan.dart';
import 'storage_backend.dart';

/// Alist v3 / OpenList. Every endpoint answers HTTP 200 with `{code, message, data}`.
class AlistBackend implements StorageBackend, RangeReadableBackend {
  final Uri _endpoint;
  final String? _username;
  final String? _password;
  final Credentials _credentials;
  String? _token;
  final Dio _dio;
  Future<void>? _loggingIn;

  static const _perPage = 500;
  static const _maxUnrangedSkip = 512 * 1024;

  AlistBackend(ConnectionConfig config, Credentials credentials)
    : _endpoint = Uri.parse(config.endpoint),
      _username = config.username,
      _password = credentials.password,
      _credentials = credentials,
      _token = (credentials.token ?? '').isEmpty ? null : credentials.token,
      _dio = directForPrivateHosts(
        Dio(
          BaseOptions(
            baseUrl: config.endpoint.replaceFirst(RegExp(r'/+$'), ''),
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            sendTimeout: const Duration(seconds: 30),
            validateStatus: (_) => true,
          ),
        ),
      );

  /// Empty fields mean "browse as guest" rather than a login with blanks.
  bool get _canLogin =>
      (_username ?? '').isNotEmpty && (_password ?? '').isNotEmpty;

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

  Map<String, dynamic> _parseResponse(Response<dynamic> r) {
    final data = r.data;
    if (data is Map<String, dynamic> && data['code'] is int) return data;
    final status = r.statusCode ?? 0;
    if (status == 200) {
      return {
        'code': 0,
        'message': '服务器返回了非 JSON 响应（HTTP 200），请检查 Alist 地址是否正确',
      };
    }
    return {'code': status, 'message': 'HTTP $status'};
  }

  Future<Map<String, dynamic>> _post(
    String api,
    Map<String, dynamic> body,
    String? token,
  ) async {
    final Response<dynamic> r;
    try {
      r = await _dio.post<dynamic>(
        api,
        data: body,
        options: Options(
          headers: token == null ? null : {'Authorization': token},
        ),
      );
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        'Alist 请求失败（$api）：${_dioMsg(e)}',
      );
    }
    return _parseResponse(r);
  }

  Future<void> _login() =>
      _loggingIn ??= _doLogin().whenComplete(() => _loggingIn = null);

  Future<void> _doLogin() async {
    final res = await _post('/api/auth/login', {
      'username': _username,
      'password': _password,
    }, null);
    final code = res['code'] as int;
    final msg = '${res['message'] ?? ''}';
    final lower = msg.toLowerCase();
    // Alist returns code 400 for wrong password / unknown user / 2FA errors;
    // do not misclassify HTTP 500 or wrong-URL HTML 200 (code 0) as unauthorized.
    if (code == 400 &&
        (lower.contains('password') ||
            lower.contains('user') ||
            lower.contains('auth') ||
            lower.contains('credential') ||
            lower.contains('otp') ||
            lower.contains('2fa'))) {
      throw StorageException(
        StorageErrorCode.unauthorized,
        'Alist 登录失败：用户名或密码错误（$msg）',
      );
    }
    final data = _data(res, '登录');
    if (data is! Map ||
        data['token'] is! String ||
        (data['token'] as String).isEmpty) {
      throw const StorageException(
        StorageErrorCode.other,
        'Alist 登录失败：服务器未返回有效令牌',
      );
    }
    _token = data['token'] as String;
  }

  /// The `data` field of a successful reply; maps `code != 200` to [StorageException].
  dynamic _data(Map<String, dynamic> res, String what) {
    final code = res['code'] as int;
    if (code == 200) return res['data'];
    final rawMsg = res['message']?.toString();
    final msg = (rawMsg != null && rawMsg.isNotEmpty)
        ? '$what 失败：$rawMsg（code $code）'
        : '$what 失败（code $code）';
    final lower = (rawMsg ?? '').toLowerCase();
    final err = switch (code) {
      401 || 403 => StorageErrorCode.unauthorized,
      404 => StorageErrorCode.notFound,
      429 => StorageErrorCode.rateLimited,
      502 || 503 || 504 => StorageErrorCode.network,
      _ when lower.contains('not found') => StorageErrorCode.notFound,
      _ when lower.contains('already exist') => StorageErrorCode.alreadyExists,
      _ when lower.contains('too many') => StorageErrorCode.rateLimited,
      _
          when lower.contains('access is denied') ||
              lower.contains('used by another process') ||
              lower.contains('resource busy') =>
        StorageErrorCode.busy,
      _ => StorageErrorCode.other,
    };
    throw StorageException(err, msg);
  }

  /// Runs [send] with the token; on expiry (code 401) logs in again once and retries.
  Future<Map<String, dynamic>> _withAuthRaw(
    Future<Map<String, dynamic>> Function(String? token) send,
  ) async {
    for (var attempt = 0; ; attempt++) {
      if (_token == null && _canLogin) await _login();
      final used = _token;
      final res = await send(used);
      if (res['code'] == 401 && attempt == 0 && _canLogin) {
        // If the token changed, a concurrent call already refreshed it.
        if (_token == used) _token = null;
        continue;
      }
      return res;
    }
  }

  /// POST with the token; on expiry (code 401) logs in again once and retries.
  Future<dynamic> _call(String api, Map<String, dynamic> body) async =>
      _data(await _withAuthRaw((token) => _post(api, body, token)), api);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final out = <RemoteEntry>[];
    final dirPassword = _credentials.passwordForPath(dir);
    for (var page = 1; ; page++) {
      final raw = await _call('/api/fs/list', {
        'path': dir,
        'password': dirPassword,
        'page': page,
        'per_page': _perPage,
        'refresh': refresh && page == 1,
      });
      final data = raw is Map<String, dynamic>
          ? raw
          : const <String, dynamic>{};
      final content = (data['content'] as List?) ?? const [];
      for (final e in content.whereType<Map<String, dynamic>>()) {
        final name = e['name'] as String;
        out.add(
          RemoteEntry(
            path: p.posix.join(dir, name),
            name: name,
            isDir: e['is_dir'] == true,
            size: (e['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.tryParse('${e['modified']}'),
          ),
        );
      }
      // The server may cap per_page, so trust `total`, not the page size.
      if (content.isEmpty || out.length >= ((data['total'] as num?) ?? 0)) {
        return out;
      }
    }
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final res = await _call('/api/fs/get', {
        'path': path,
        'password': _credentials.passwordForPath(path),
      });
      return res is Map<String, dynamic> ? res : null;
    } on StorageException catch (e) {
      if (e.code == StorageErrorCode.notFound) return null;
      rethrow;
    }
  }

  static Map<String, Object> _extractDownloadHeaders(Object? rawHeader) {
    Object? decoded = rawHeader;
    if (decoded is String && decoded.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return const {};
      }
    }
    if (decoded is! Map) return const {};
    final out = <String, Object>{};
    for (final e in decoded.entries) {
      final k = e.key?.toString();
      final v = e.value;
      if (k == null || k.isEmpty || v == null) continue;
      if (v is String) {
        out[k] = v;
      } else if (v is List && v.isNotEmpty) {
        out[k] = v.map((x) => '$x').join(', ');
      } else {
        out[k] = '$v';
      }
    }
    return out;
  }

  static StorageErrorCode _httpStatusToCode(int status) => switch (status) {
    401 || 403 => StorageErrorCode.unauthorized,
    404 => StorageErrorCode.notFound,
    429 => StorageErrorCode.rateLimited,
    >= 500 && < 600 => StorageErrorCode.network,
    _ => StorageErrorCode.other,
  };

  static Future<void> _discardStream(ResponseBody? body) async {
    if (body == null) return;
    try {
      await body.stream.listen((_) {}).cancel();
    } on Object {
      // Ignore cleanup errors on aborted streams.
    }
  }

  static Future<List<int>> _readBoundedStream(
    Stream<Uint8List> stream, {
    required int skip,
    required int take,
  }) {
    final builder = BytesBuilder(copy: false);
    var remainingSkip = skip;
    var remainingTake = take;
    final done = Completer<List<int>>();
    late StreamSubscription<Uint8List> sub;
    var stopping = false;

    sub = stream.listen(
      (chunk) {
        if (stopping || done.isCompleted) return;
        var offset = 0;
        if (remainingSkip > 0) {
          if (chunk.length <= remainingSkip) {
            remainingSkip -= chunk.length;
            return;
          }
          offset = remainingSkip;
          remainingSkip = 0;
        }
        final avail = chunk.length - offset;
        if (avail <= 0) return;
        if (avail >= remainingTake) {
          builder.add(
            offset == 0 && remainingTake == chunk.length
                ? chunk
                : Uint8List.sublistView(chunk, offset, offset + remainingTake),
          );
          remainingTake = 0;
          stopping = true;
          sub.cancel().then<void>(
            (_) {
              if (!done.isCompleted) done.complete(builder.takeBytes());
            },
            onError: (_) {
              if (!done.isCompleted) done.complete(builder.takeBytes());
            },
          );
        } else {
          builder.add(
            offset == 0 ? chunk : Uint8List.sublistView(chunk, offset),
          );
          remainingTake -= avail;
        }
      },
      onError: (Object e, StackTrace st) {
        if (!stopping && !done.isCompleted) {
          done.completeError(e, st);
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );

    return done.future;
  }

  @override
  Future<bool> exists(String path) async => await _get(path) != null;

  @override
  Future<List<int>> read(String path) async {
    final info = await _get(path);
    final raw = info?['raw_url'];
    if (info == null || raw is! String || raw.isEmpty) {
      throw StorageException(StorageErrorCode.notFound, '文件不存在：$path');
    }
    try {
      // raw_url may be relative or point at the drive's CDN (no Alist token).
      final uri = _endpoint.resolve(raw);
      final extraHeaders = _extractDownloadHeaders(info['header']);
      final r = await _dio.getUri<List<int>>(
        uri,
        options: Options(
          responseType: ResponseType.bytes,
          headers: extraHeaders.isEmpty ? null : extraHeaders,
        ),
      );
      final status = r.statusCode ?? 0;
      if (status != 200) {
        throw StorageException(
          _httpStatusToCode(status),
          '读取文件失败（$path）：HTTP $status',
        );
      }
      return r.data ?? const [];
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        '读取文件失败（$path）：${_dioMsg(e)}',
      );
    }
  }

  @override
  Future<List<int>> readRange(String path, int start, int length) async {
    if (start < 0 || length <= 0) return const [];
    final info = await _get(path);
    final raw = info?['raw_url'];
    if (info == null || raw is! String || raw.isEmpty) {
      throw StorageException(StorageErrorCode.notFound, '文件不存在：$path');
    }
    try {
      final uri = _endpoint.resolve(raw);
      final headers = <String, Object>{
        ..._extractDownloadHeaders(info['header']),
        'Range': 'bytes=$start-${start + length - 1}',
      };
      final r = await _dio.getUri<ResponseBody>(
        uri,
        options: Options(responseType: ResponseType.stream, headers: headers),
      );
      final status = r.statusCode ?? 0;
      final body = r.data;
      if (status == 416) {
        await _discardStream(body);
        return const [];
      }
      if (status == 206) {
        if (body == null) return const [];
        return await _readBoundedStream(body.stream, skip: 0, take: length);
      }
      if (status == 200) {
        if (start > _maxUnrangedSkip) {
          await _discardStream(body);
          throw StorageException(
            StorageErrorCode.other,
            '服务器不支持分段读取（$path）：HTTP 200',
          );
        }
        if (body == null) return const [];
        return await _readBoundedStream(body.stream, skip: start, take: length);
      }
      await _discardStream(body);
      throw StorageException(
        _httpStatusToCode(status),
        '分段读取文件失败（$path）：HTTP $status',
      );
    } on StorageException {
      rethrow;
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        '分段读取文件失败（$path）：${_dioMsg(e)}',
      );
    } on Object catch (e) {
      throw StorageException(StorageErrorCode.network, '分段读取文件失败（$path）：$e');
    }
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    // Alist's put overwrites, so refuse here first.
    if (await exists(path)) {
      throw StorageException(StorageErrorCode.alreadyExists, '文件已存在：$path');
    }
    final parent = p.posix.dirname(path);
    if (parent != '/') {
      await mkdirs(parent);
    }
    final dirPassword = _credentials.passwordForPath(path);
    final res = await _withAuthRaw((token) async {
      final Response<dynamic> r;
      try {
        r = await _dio.put<dynamic>(
          '/api/fs/put',
          data: Stream.value(bytes),
          options: Options(
            headers: {
              'Authorization': ?token,
              'File-Path': Uri.encodeComponent(path),
              'As-Task': 'false',
              if (dirPassword.isNotEmpty) 'Password': dirPassword,
              Headers.contentLengthHeader: bytes.length,
              Headers.contentTypeHeader: 'application/octet-stream',
            },
          ),
        );
      } on DioException catch (e) {
        throw StorageException(
          StorageErrorCode.network,
          '上传文件失败（$path）：${_dioMsg(e)}',
        );
      }
      return _parseResponse(r);
    });
    _data(res, '上传 $path');
  }

  @override
  Future<void> mkdirs(String dir) async {
    final cur = await _get(dir);
    if (cur != null) {
      if (cur['is_dir'] == true) return;
      throw StorageException(StorageErrorCode.alreadyExists, '路径已存在且不是目录：$dir');
    }
    await _call('/api/fs/mkdir', {'path': dir}); // creates parents
  }

  @override
  Future<void> rename(String path, String newName) async {
    final dir = p.posix.dirname(path);
    final oldName = p.posix.basename(path);
    if (oldName == newName) return;
    final target = p.posix.join(dir, newName);
    // Some drivers overwrite silently, so never rely on the server to refuse.
    // On case-insensitive backends, exists(target) hits the source itself for
    // case-only renames, so check the folder listing instead.
    if (oldName.toLowerCase() == newName.toLowerCase()) {
      final have = {for (final e in await list(dir, refresh: true)) e.name};
      if (have.contains(newName)) {
        throw StorageException(StorageErrorCode.alreadyExists, '目标已存在：$target');
      }
    } else if (await exists(target)) {
      throw StorageException(StorageErrorCode.alreadyExists, '目标已存在：$target');
    }
    await _call('/api/fs/rename', {'path': path, 'name': newName});
  }

  /// One listing to check names, then `fs/batch_rename` (one request for the
  /// whole folder); servers without it get one `fs/rename` per file.
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    final effective = <String, String>{
      for (final e in names.entries)
        if (e.key != e.value) e.key: e.value,
    };
    if (effective.isEmpty) return;
    final seenTargets = <String>{};
    for (final target in effective.values) {
      if (!seenTargets.add(target)) {
        throw StorageException(
          StorageErrorCode.alreadyExists,
          '目标文件名重复：${p.posix.join(dir, target)}',
        );
      }
    }
    final have = {for (final e in await list(dir, refresh: true)) e.name};
    for (final e in effective.entries) {
      if (!have.contains(e.key)) {
        throw StorageException(
          StorageErrorCode.notFound,
          '源文件不存在：${p.posix.join(dir, e.key)}',
        );
      }
      // Some drivers overwrite silently, so never rely on the server to refuse.
      if (have.contains(e.value)) {
        throw StorageException(
          StorageErrorCode.alreadyExists,
          '目标已存在：${p.posix.join(dir, e.value)}',
        );
      }
    }
    final res = await _withAuthRaw(
      (token) => _post('/api/fs/batch_rename', {
        'src_dir': dir,
        'rename_objects': [
          for (final e in effective.entries)
            {'src_name': e.key, 'new_name': e.value},
        ],
      }, token),
    );
    final code = res['code'] as int;
    // Older Alist: the batch_rename route itself is unsupported (HTTP 404/405).
    if (code == 404 || code == 405) {
      for (final e in effective.entries) {
        await _call('/api/fs/rename', {
          'path': p.posix.join(dir, e.key),
          'name': e.value,
        });
      }
      return;
    }
    _data(res, '/api/fs/batch_rename');
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    if (names.isEmpty) return;
    final taken = {for (final e in await list(dstDir, refresh: true)) e.name};
    for (final n in names) {
      if (taken.contains(n)) {
        throw StorageException(
          StorageErrorCode.alreadyExists,
          '目标已存在：${p.posix.join(dstDir, n)}',
        );
      }
    }
    await _call('/api/fs/move', {
      'src_dir': srcDir,
      'dst_dir': dstDir,
      'names': names,
    });
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    if (names.isEmpty) return;
    // fs/remove succeeds silently for missing names; the contract says notFound.
    final have = {for (final e in await list(dir, refresh: true)) e.name};
    for (final n in names) {
      if (!have.contains(n)) {
        throw StorageException(
          StorageErrorCode.notFound,
          '文件不存在：${p.posix.join(dir, n)}',
        );
      }
    }
    await _call('/api/fs/remove', {'dir': dir, 'names': names});
  }

  @override
  Future<void> ping() async {
    // Call /api/fs/get directly without swallowing notFound so HTTP 404 / wrong URL fails.
    final res = await _call('/api/fs/get', {
      'path': '/',
      'password': _credentials.passwordForPath('/'),
    });
    if (res is! Map<String, dynamic>) {
      throw const StorageException(
        StorageErrorCode.other,
        '连接检测失败：服务器返回数据格式异常',
      );
    }
  }

  @override
  Future<void> close() async {
    _dio.close();
  }
}
