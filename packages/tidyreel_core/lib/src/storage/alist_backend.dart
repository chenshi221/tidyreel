import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/connection.dart';
import '../model/scan.dart';
import 'direct_lan.dart';
import 'storage_backend.dart';

/// Alist v3 / OpenList. Every endpoint answers HTTP 200 with `{code, message, data}`.
class AlistBackend implements StorageBackend {
  final String? _username;
  final String? _password;
  String? _token;
  final Dio _dio;
  Future<void>? _loggingIn;

  static const _perPage = 500;

  AlistBackend(ConnectionConfig config, Credentials credentials)
    : _username = config.username,
      _password = credentials.password,
      _token = credentials.token,
      _dio = directForPrivateHosts(
        Dio(
          BaseOptions(
            baseUrl: config.endpoint.replaceFirst(RegExp(r'/+$'), ''),
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            validateStatus: (_) => true,
          ),
        ),
      );

  /// Empty fields mean "browse as guest" rather than a login with blanks.
  bool get _canLogin =>
      (_username ?? '').isNotEmpty && (_password ?? '').isNotEmpty;

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
      throw StorageException(StorageErrorCode.network, '$api: ${e.message}');
    }
    final data = r.data;
    if (data is Map<String, dynamic> && data['code'] is int) return data;
    final status = r.statusCode ?? 0;
    return {
      'code': status == 200 ? 0 : status,
      'message': 'HTTP ${r.statusCode}',
    };
  }

  Future<void> _login() =>
      _loggingIn ??= _doLogin().whenComplete(() => _loggingIn = null);

  Future<void> _doLogin() async {
    final res = await _post('/api/auth/login', {
      'username': _username,
      'password': _password,
    }, null);
    try {
      final data = _data(res, 'login');
      if (data is! Map || data['token'] is! String) {
        throw const StorageException(
          StorageErrorCode.other,
          'login: invalid response',
        );
      }
      _token = data['token'] as String;
    } on StorageException catch (e) {
      // Bad credentials come back as code 400 "password is incorrect".
      if (e.code != StorageErrorCode.other) rethrow;
      throw StorageException(StorageErrorCode.unauthorized, e.message);
    }
  }

  /// The `data` field of a successful reply; maps `code != 200` to [StorageException].
  dynamic _data(Map<String, dynamic> res, String what) {
    final code = res['code'] as int;
    if (code == 200) return res['data'];
    final msg = '$what: ${res['message']} (code $code)';
    final lower = '${res['message']}'.toLowerCase();
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

  /// POST with the token; on expiry (code 401) logs in again once and retries.
  Future<dynamic> _call(String api, Map<String, dynamic> body) async {
    for (var attempt = 0; ; attempt++) {
      if (_token == null && _canLogin) await _login();
      final used = _token;
      final res = await _post(api, body, used);
      if (res['code'] == 401 && attempt == 0 && _canLogin) {
        // If the token changed, a concurrent call already refreshed it.
        if (_token == used) _token = null;
        continue;
      }
      return _data(res, api);
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final out = <RemoteEntry>[];
    for (var page = 1; ; page++) {
      final raw = await _call('/api/fs/list', {
        'path': dir,
        'password': '',
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
      final res = await _call('/api/fs/get', {'path': path, 'password': ''});
      return res is Map<String, dynamic> ? res : null;
    } on StorageException catch (e) {
      if (e.code == StorageErrorCode.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<bool> exists(String path) async => await _get(path) != null;

  @override
  Future<List<int>> read(String path) async {
    final info = await _get(path);
    final raw = info?['raw_url'];
    if (info == null || raw is! String || raw.isEmpty) {
      throw StorageException(StorageErrorCode.notFound, path);
    }
    try {
      // raw_url may point at the drive's CDN: no Alist token there.
      final r = await _dio.getUri<List<int>>(
        Uri.parse(raw),
        options: Options(responseType: ResponseType.bytes),
      );
      if (r.statusCode != 200) {
        throw StorageException(
          r.statusCode == 404
              ? StorageErrorCode.notFound
              : StorageErrorCode.other,
          'GET $path: HTTP ${r.statusCode}',
        );
      }
      return r.data ?? const [];
    } on DioException catch (e) {
      throw StorageException(
        StorageErrorCode.network,
        'GET $path: ${e.message}',
      );
    }
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    // Alist's put overwrites, so refuse here first.
    if (await exists(path)) {
      throw StorageException(StorageErrorCode.alreadyExists, path);
    }
    for (var attempt = 0; ; attempt++) {
      if (_token == null && _canLogin) await _login();
      final used = _token;
      final Response<dynamic> r;
      try {
        r = await _dio.put<dynamic>(
          '/api/fs/put',
          data: Stream.value(bytes),
          options: Options(
            headers: {
              'Authorization': ?used,
              'File-Path': Uri.encodeComponent(path),
              'As-Task': 'false',
              Headers.contentLengthHeader: bytes.length,
              Headers.contentTypeHeader: 'application/octet-stream',
            },
          ),
        );
      } on DioException catch (e) {
        throw StorageException(
          StorageErrorCode.network,
          'put $path: ${e.message}',
        );
      }
      final data = r.data;
      final res = data is Map<String, dynamic> && data['code'] is int
          ? data
          : {
              'code': r.statusCode == 200 ? 200 : r.statusCode ?? 0,
              'message': 'HTTP ${r.statusCode}',
            };
      if (res['code'] == 401 && attempt == 0 && _canLogin) {
        if (_token == used) _token = null;
        continue;
      }
      _data(res, 'put');
      return;
    }
  }

  @override
  Future<void> mkdirs(String dir) async {
    final cur = await _get(dir);
    if (cur != null) {
      if (cur['is_dir'] == true) return;
      throw StorageException(StorageErrorCode.alreadyExists, dir);
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
        throw StorageException(StorageErrorCode.alreadyExists, target);
      }
    } else if (await exists(target)) {
      throw StorageException(StorageErrorCode.alreadyExists, target);
    }
    await _call('/api/fs/rename', {'path': path, 'name': newName});
  }

  /// One listing to check names, then `fs/batch_rename` (one request for the
  /// whole folder); servers without it get one `fs/rename` per file.
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    final have = {for (final e in await list(dir, refresh: true)) e.name};
    for (final e in names.entries) {
      if (!have.contains(e.key)) {
        throw StorageException(
          StorageErrorCode.notFound,
          p.posix.join(dir, e.key),
        );
      }
      // Some drivers overwrite silently, so never rely on the server to refuse.
      if (have.contains(e.value)) {
        throw StorageException(
          StorageErrorCode.alreadyExists,
          p.posix.join(dir, e.value),
        );
      }
    }
    try {
      await _call('/api/fs/batch_rename', {
        'src_dir': dir,
        'rename_objects': [
          for (final e in names.entries)
            {'src_name': e.key, 'new_name': e.value},
        ],
      });
    } on StorageException catch (err) {
      // Older Alist: the route is missing (HTTP 404); the sources exist (listed above).
      if (err.code != StorageErrorCode.notFound) rethrow;
      for (final e in names.entries) {
        await _call('/api/fs/rename', {
          'path': p.posix.join(dir, e.key),
          'name': e.value,
        });
      }
    }
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    final taken = {for (final e in await list(dstDir, refresh: true)) e.name};
    for (final n in names) {
      if (taken.contains(n)) {
        throw StorageException(
          StorageErrorCode.alreadyExists,
          p.posix.join(dstDir, n),
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
    // fs/remove succeeds silently for missing names; the contract says notFound.
    final have = {for (final e in await list(dir, refresh: true)) e.name};
    for (final n in names) {
      if (!have.contains(n)) {
        throw StorageException(StorageErrorCode.notFound, p.posix.join(dir, n));
      }
    }
    await _call('/api/fs/remove', {'dir': dir, 'names': names});
  }

  @override
  Future<void> ping() async {
    await _get('/'); // authenticated round trip
  }
}
