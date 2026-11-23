import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:path/path.dart' as p;
import 'package:tidyreel_core/tidyreel_core.dart';

/// Where an `smb://host[:port]/share` endpoint points.
typedef SmbTarget = ({String host, String share, String base});

/// Parses `smb://nas:445/影视[/子目录]`, `\\nas\影视` or `nas/影视`; null without
/// a share. A folder after the share becomes the backend's root ([base]).
SmbTarget? parseSmbEndpoint(String endpoint) {
  var s = endpoint.trim().replaceAll('\\', '/');
  s = s.replaceFirst(RegExp(r'^smb:', caseSensitive: false), '');
  final segs = s.split('/').where((x) => x.isNotEmpty).toList();
  if (segs.length < 2) return null;
  // %E5%BD%B1 from a URL, or plain 影视 typed in (which decodeComponent rejects).
  String dec(String x) {
    try {
      return Uri.decodeComponent(x);
    } on ArgumentError {
      return x;
    }
  }

  return (
    host: segs[0],
    share: dec(segs[1]),
    base: segs.skip(2).map(dec).join('/'),
  );
}

/// SMB2/3 share through dart_smb2 (libsmb2). Paths are relative to the share.
class SmbBackend implements StorageBackend, RangeReadableBackend {
  final ConnectionConfig _config;
  final Credentials _credentials;
  Future<Smb2Pool>? _pool;
  final String _base;

  SmbBackend(this._config, this._credentials)
    : _base = parseSmbEndpoint(_config.endpoint)?.base ?? '';

  Future<Smb2Pool> _connect() {
    final t = parseSmbEndpoint(_config.endpoint);
    if (t == null) {
      return Future.error(
        StorageException(
          StorageErrorCode.other,
          '地址应为 smb://主机/共享名：${_config.endpoint}',
        ),
      );
    }
    return Smb2Pool.connect(
      host: t.host,
      share: t.share,
      user: (_config.username ?? '').isEmpty ? null : _config.username,
      password: _credentials.password,
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> _closePool(Future<Smb2Pool>? pending) async {
    if (pending == null) return;
    try {
      final pool = await pending;
      await pool.disconnect();
    } on Object {
      // Ignore errors while tearing down a broken or failed pool.
    }
  }

  /// Runs [f] on the (lazily connected) pool; a failed connect is retried
  /// on the next call instead of being cached.
  Future<T> _run<T>(String path, Future<T> Function(Smb2Pool pool) f) async {
    final pending = _pool ??= _connect();
    final Smb2Pool pool;
    try {
      pool = await pending;
    } on Smb2Exception catch (e) {
      if (identical(_pool, pending)) _pool = null;
      throw StorageException(_code(e.type), '$path: ${e.message}');
    } on StorageException {
      if (identical(_pool, pending)) _pool = null;
      rethrow;
    } on Object {
      if (identical(_pool, pending)) _pool = null;
      rethrow;
    }
    try {
      return await f(pool);
    } on Smb2Exception catch (e) {
      if (e.type.isNetworkFailure || e.type == Smb2ErrorType.auth) {
        if (identical(_pool, pending)) {
          _pool = null;
          await _closePool(pending);
        }
      }
      throw StorageException(_code(e.type), '$path: ${e.message}');
    } on StorageException {
      if (identical(_pool, pending)) {
        _pool = null;
        await _closePool(pending);
      }
      rethrow;
    }
  }

  static StorageErrorCode _code(Smb2ErrorType t) => switch (t) {
    Smb2ErrorType.notFound ||
    Smb2ErrorType.notADirectory => StorageErrorCode.notFound,
    Smb2ErrorType.alreadyExists => StorageErrorCode.alreadyExists,
    Smb2ErrorType.auth => StorageErrorCode.unauthorized,
    Smb2ErrorType.inUse => StorageErrorCode.busy,
    _ when t.isNetworkFailure => StorageErrorCode.network,
    _ => StorageErrorCode.other,
  };

  /// '/a/b' → 'a/b' (under [_base]); '/' → '' (the share root).
  String _rel(String path) => [
    if (_base.isNotEmpty) _base,
    ...path.split('/').where((s) => s.isNotEmpty),
  ].join('/');

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) =>
      _run(dir, (pool) async {
        return [
          for (final e in await pool.listDirectory(_rel(dir)))
            if (e.name != '.' && e.name != '..')
              RemoteEntry(
                path: p.posix.join(dir, e.name),
                name: e.name,
                isDir: e.isDirectory,
                size: e.isDirectory ? 0 : e.size,
                modified: e.stat.modified,
              ),
        ];
      });

  @override
  Future<bool> exists(String path) =>
      _run(path, (pool) => pool.exists(_rel(path)));

  @override
  Future<void> mkdirs(String dir) => _run(dir, (pool) async {
    final relSegs = dir.split('/').where((s) => s.isNotEmpty).toList();
    if (_base.isEmpty) {
      await _mkdirSegs(pool, '', relSegs);
      return;
    }
    if (await pool.exists(_base)) {
      await _mkdirSegs(pool, _base, relSegs);
    } else {
      final baseSegs = _base.split('/').where((s) => s.isNotEmpty).toList();
      await _mkdirSegs(pool, '', [...baseSegs, ...relSegs]);
    }
  });

  Future<void> _mkdirSegs(
    Smb2Pool pool,
    String prefix,
    List<String> segs,
  ) async {
    var cur = prefix;
    for (final s in segs) {
      cur = cur.isEmpty ? s : '$cur/$s';
      try {
        await pool.mkdir(cur);
      } on Smb2Exception catch (e) {
        if (e.type != Smb2ErrorType.alreadyExists) rethrow;
        if (!(await pool.stat(cur)).isDirectory) rethrow;
      }
    }
  }

  /// SMB rename refuses an existing target, so this never overwrites.
  Future<void> _relocate(String from, String to) =>
      _run(from, (pool) => pool.rename(_rel(from), _rel(to)));

  @override
  Future<void> rename(String path, String newName) async {
    final oldName = p.posix.basename(path);
    if (oldName == newName) return;
    final dir = p.posix.dirname(path);
    final target = p.posix.join(dir, newName);
    if (oldName.toLowerCase() == newName.toLowerCase()) {
      final tmpName =
          '.tidyreel_tmp_${DateTime.now().microsecondsSinceEpoch}_$newName';
      final tmpPath = p.posix.join(dir, tmpName);
      await _relocate(path, tmpPath);
      try {
        await _relocate(tmpPath, target);
      } on Object {
        try {
          await _relocate(tmpPath, path);
        } on Object {
          // Best-effort rollback.
        }
        rethrow;
      }
      return;
    }
    await _relocate(path, target);
  }

  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    for (final e in names.entries) {
      await rename(p.posix.join(dir, e.key), e.value);
    }
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    for (final n in names) {
      await _relocate(p.posix.join(srcDir, n), p.posix.join(dstDir, n));
    }
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    for (final n in names) {
      final path = p.posix.join(dir, n);
      await _run(path, (pool) async {
        Future<void> rm(String rel) async {
          if ((await pool.stat(rel)).isDirectory) {
            for (final e in await pool.listDirectory(rel)) {
              if (e.name == '.' || e.name == '..') continue;
              await rm('$rel/${e.name}');
            }
            await pool.rmdir(rel);
          } else {
            await pool.deleteFile(rel);
          }
        }

        await rm(_rel(path));
      });
    }
  }

  @override
  Future<List<int>> read(String path) =>
      _run(path, (pool) => pool.readFile(_rel(path)));

  @override
  Future<List<int>> readRange(String path, int start, int length) async {
    if (start < 0 || length <= 0) return const [];
    return _run(
      path,
      (pool) => pool.readFileRange(_rel(path), offset: start, length: length),
    );
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    // writeFile replaces content, so refuse an existing file first.
    if (await exists(path)) {
      throw StorageException(StorageErrorCode.alreadyExists, path);
    }
    await mkdirs(p.posix.dirname(path));
    await _run(
      path,
      (pool) => pool.writeFile(_rel(path), Uint8List.fromList(bytes)),
    );
  }

  @override
  Future<void> ping() => _run('/', (pool) => pool.listDirectory(_rel('/')));

  @override
  Future<void> close() async {
    final p = _pool;
    _pool = null;
    await _closePool(p);
  }
}
