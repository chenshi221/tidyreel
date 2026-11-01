import 'dart:async';

import 'package:path/path.dart' as p;

import '../model/scan.dart';
import 'storage_backend.dart';

/// Shares folder listings between the browser, the scan preview and imports, so
/// a slow server (seconds per request) is asked once per folder. Concurrent
/// lists of one folder share a request; our own writes drop the folders they
/// touch. `refresh: true` and [exists] always go to the server.
class CachedBackend implements StorageBackend {
  final StorageBackend inner;
  final Duration ttl;
  final DateTime Function() now;
  final _cache = <String, ({DateTime at, Future<List<RemoteEntry>> list})>{};

  CachedBackend(
    this.inner, {
    this.ttl = const Duration(minutes: 10),
    this.now = DateTime.now,
  });

  Future<List<RemoteEntry>> _fetch(String dir, bool refresh) {
    final f = inner.list(dir, refresh: refresh);
    _cache[dir] = (at: now(), list: f);
    // Failures aren't cached.
    f.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_cache[dir]?.list, f)) _cache.remove(dir);
      },
    );
    return f;
  }

  Future<List<RemoteEntry>>? _hit(String dir, Duration maxAge) {
    final c = _cache[dir];
    return c != null && now().difference(c.at) < maxAge ? c.list : null;
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) =>
      (refresh ? null : _hit(dir, ttl)) ?? _fetch(dir, refresh);

  /// A listing at most [maxAge] old, else a server-refreshed one. Imports use
  /// it to reuse what the scan preview just listed.
  Future<List<RemoteEntry>> listRecent(String dir, Duration maxAge) =>
      _hit(dir, maxAge) ?? _fetch(dir, true);

  /// Drops [path], its parent and everything below it.
  void invalidate(String path) {
    final parent = p.posix.dirname(path);
    _cache.removeWhere(
      (k, _) => k == path || k == parent || k.startsWith('$path/'),
    );
  }

  void clear() => _cache.clear();

  Future<T> _write<T>(Future<T> Function() fn, List<String> touched) async {
    try {
      return await fn();
    } finally {
      touched.forEach(invalidate);
    }
  }

  @override
  Future<void> mkdirs(String dir) => _write(() => inner.mkdirs(dir), [dir]);

  @override
  Future<void> rename(String path, String newName) => _write(
    () => inner.rename(path, newName),
    [path, p.posix.join(p.posix.dirname(path), newName)],
  );

  @override
  Future<void> renameMany(String dir, Map<String, String> names) =>
      _write(() => inner.renameMany(dir, names), [
        dir,
        for (final e in names.entries) ...[
          p.posix.join(dir, e.key),
          p.posix.join(dir, e.value),
        ],
      ]);

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) =>
      _write(() => inner.move(srcDir, dstDir, names), [
        srcDir,
        dstDir,
        for (final n in names) ...[
          p.posix.join(srcDir, n),
          p.posix.join(dstDir, n),
        ],
      ]);

  @override
  Future<void> remove(String dir, List<String> names) => _write(
    () => inner.remove(dir, names),
    [dir, for (final n in names) p.posix.join(dir, n)],
  );

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<void> ping() => inner.ping();
}

/// `listRecent` when [be] caches, else a server-refreshed listing.
Future<List<RemoteEntry>> listFresh(
  StorageBackend be,
  String dir, {
  Duration maxAge = const Duration(minutes: 2),
}) => be is CachedBackend
    ? be.listRecent(dir, maxAge)
    : be.list(dir, refresh: true);
