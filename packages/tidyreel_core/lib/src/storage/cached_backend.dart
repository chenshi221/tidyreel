import 'dart:async';

import 'package:path/path.dart' as p;

import '../model/scan.dart';
import 'storage_backend.dart';

/// Shares folder listings between the browser, the scan preview and imports, so
/// a slow server (seconds per request) is asked once per folder. Concurrent
/// lists of one folder share a request; our own writes drop the folders they
/// touch. `refresh: true` and [exists] always go to the server.
class CachedBackend implements StorageBackend {
  final StorageBackend _inner;
  final Duration ttl;
  final DateTime Function() now;
  final int maxEntries;
  final _cache = <String, ({DateTime at, Future<List<RemoteEntry>> list})>{};

  CachedBackend(
    this._inner, {
    this.ttl = const Duration(minutes: 10),
    this.now = DateTime.now,
    this.maxEntries = 500,
  });

  StorageBackend get inner => _inner;

  static String _norm(String path) {
    var s = path.trim();
    if (s.isEmpty) return '/';
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  void _prune() {
    final t = now();
    _cache.removeWhere((_, v) => t.difference(v.at) >= ttl);
    while (_cache.length >= maxEntries && _cache.isNotEmpty) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<List<RemoteEntry>> _fetch(String dir, bool refresh) {
    final key = _norm(dir);
    final f = _inner.list(key, refresh: refresh);
    if (_cache.length >= maxEntries && !_cache.containsKey(key)) {
      _prune();
    }
    _cache.remove(key);
    _cache[key] = (at: now(), list: f);
    // Failures aren't cached.
    f.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_cache[key]?.list, f)) _cache.remove(key);
      },
    );
    return f;
  }

  Future<List<RemoteEntry>>? _hit(String dir, Duration maxAge) {
    final key = _norm(dir);
    final c = _cache[key];
    if (c == null) return null;
    if (now().difference(c.at) >= maxAge) {
      if (maxAge >= ttl) _cache.remove(key);
      return null;
    }
    // Refresh LRU order.
    _cache.remove(key);
    _cache[key] = c;
    return c.list;
  }

  bool isCached(String dir) {
    final key = _norm(dir);
    final c = _cache[key];
    if (c == null) return false;
    if (now().difference(c.at) >= ttl) {
      _cache.remove(key);
      return false;
    }
    return true;
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) {
    final f = (refresh ? null : _hit(dir, ttl)) ?? _fetch(dir, refresh);
    return f.then(List<RemoteEntry>.of);
  }

  /// A listing at most [maxAge] old, else a server-refreshed one. Imports use
  /// it to reuse what the scan preview just listed.
  Future<List<RemoteEntry>> listRecent(String dir, Duration maxAge) {
    final f = _hit(dir, maxAge) ?? _fetch(dir, true);
    return f.then(List<RemoteEntry>.of);
  }

  /// Drops [path], its parent and everything below it.
  /// Invalidating `'/'` clears the entire cache.
  void invalidate(String path) {
    final norm = _norm(path);
    if (norm == '/') {
      _cache.clear();
      return;
    }
    final parent = _norm(p.posix.dirname(norm));
    _cache.removeWhere(
      (k, _) => k == norm || k == parent || k.startsWith('$norm/'),
    );
  }

  void _invalidateDirOnly(String dir) {
    _cache.remove(_norm(dir));
  }

  void _invalidateSubtree(String path) {
    final norm = _norm(path);
    if (norm == '/') {
      _cache.clear();
      return;
    }
    _cache.removeWhere((k, _) => k == norm || k.startsWith('$norm/'));
  }

  /// Drops [dir] and missing ancestors up to (and including) the first cached
  /// parent, so creating nested folders refreshes the parent that gained a child
  /// without thrashing higher ancestors.
  void _invalidateAncestors(String dir) {
    var cur = _norm(dir);
    while (true) {
      final wasCached = _cache.remove(cur) != null;
      if (wasCached || cur == '/') break;
      cur = _norm(p.posix.dirname(cur));
    }
  }

  void clear() => _cache.clear();

  @override
  Future<void> mkdirs(String dir) async {
    try {
      await _inner.mkdirs(dir);
    } finally {
      _invalidateAncestors(dir);
    }
  }

  @override
  Future<void> rename(String path, String newName) async {
    final norm = _norm(path);
    final dir = _norm(p.posix.dirname(norm));
    final target = _norm(p.posix.join(dir, newName));
    try {
      await _inner.rename(path, newName);
    } finally {
      _invalidateDirOnly(dir);
      _invalidateSubtree(norm);
      _invalidateSubtree(target);
    }
  }

  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    final normDir = _norm(dir);
    try {
      await _inner.renameMany(dir, names);
    } finally {
      _invalidateDirOnly(normDir);
      for (final e in names.entries) {
        _invalidateSubtree(p.posix.join(normDir, e.key));
        _invalidateSubtree(p.posix.join(normDir, e.value));
      }
    }
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    final normSrc = _norm(srcDir);
    final normDst = _norm(dstDir);
    try {
      await _inner.move(srcDir, dstDir, names);
    } finally {
      _invalidateDirOnly(normSrc);
      _invalidateDirOnly(normDst);
      for (final n in names) {
        _invalidateSubtree(p.posix.join(normSrc, n));
        _invalidateSubtree(p.posix.join(normDst, n));
      }
    }
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    final normDir = _norm(dir);
    try {
      await _inner.remove(dir, names);
    } finally {
      _invalidateDirOnly(normDir);
      for (final n in names) {
        _invalidateSubtree(p.posix.join(normDir, n));
      }
    }
  }

  @override
  Future<bool> exists(String path) => _inner.exists(path);

  @override
  Future<List<int>> read(String path) => _inner.read(path);

  @override
  Future<void> write(String path, List<int> bytes) async {
    try {
      await _inner.write(path, bytes);
    } finally {
      _invalidateAncestors(p.posix.dirname(_norm(path)));
    }
  }

  @override
  Future<void> ping() => _inner.ping();

  @override
  Future<void> close() => _inner.close();
}

/// `listRecent` when [be] caches, else a server-refreshed listing.
Future<List<RemoteEntry>> listFresh(
  StorageBackend be,
  String dir, {
  Duration maxAge = const Duration(minutes: 2),
}) => be is CachedBackend
    ? be.listRecent(dir, maxAge)
    : be.list(dir, refresh: true);
