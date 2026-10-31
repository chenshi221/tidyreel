import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/connection.dart';
import '../model/scan.dart';
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
      _dio = Dio(
        BaseOptions(
          baseUrl: config.endpoint.replaceFirst(RegExp(r'/+$'), ''),
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          validateStatus: (_) => true,
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
    return {'code': r.statusCode ?? 0, 'message': 'HTTP ${r.statusCode}'};
  }

  Future<void> _login() =>
      _loggingIn ??= _doLogin().whenComplete(() => _loggingIn = null);

  Future<void> _doLogin() async {
    final res = await _post('/api/auth/login', {
      'username': _username,
      'password': _password,
    }, null);
    try {
      _token = (_data(res, 'login') as Map)['token'] as String;
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
      final data = await _call('/api/fs/list', {
        'path': dir,
        'password': '',
        'page': page,
        'per_page': _perPage,
        'refresh': refresh && page == 1,
      }) as Map<String, dynamic>;
      final content = (data['content'] as List?) ?? const [];
      for (final e in content.cast<Map<String, dynamic>>()) {
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
      return await _call('/api/fs/get', {'path': path, 'password': ''})
          as Map<String, dynamic>;
    } on StorageException catch (e) {
      if (e.code == StorageErrorCode.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<bool> exists(String path) async => await _get(path) != null;

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
    final target = p.posix.join(p.posix.dirname(path), newName);
    // Some drivers overwrite silently, so never rely on the server to refuse.
    if (await exists(target)) {
      throw StorageException(StorageErrorCode.alreadyExists, target);
    }
    await _call('/api/fs/rename', {'path': path, 'name': newName});
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
