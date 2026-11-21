import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tidyreel_core/tidyreel_core.dart';

/// TMDB replies kept in one JSON file for [ttl], so re-scanning a show after a
/// restart asks TMDB nothing. Writes are batched every few seconds.
class FileTmdbCache implements TmdbResponseCache {
  final File file;
  final Duration ttl;
  final Map<String, Object?> _data;
  Timer? _flush;
  Future<void>? _flushing;

  static const _maxEntries = 5000;

  FileTmdbCache._(this.file, this.ttl, this._data);

  factory FileTmdbCache.load(
    File file, {
    Duration ttl = const Duration(days: 7),
  }) {
    var data = <String, Object?>{};
    try {
      if (file.existsSync()) {
        data = Map<String, Object?>.of(
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
        );
      }
      final cutoff = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
      data.removeWhere(
        (_, v) =>
            v is! List ||
            v.length < 2 ||
            v[0] is! num ||
            v[1] is! Map<String, dynamic> ||
            (v[0] as num) < cutoff,
      );
    } on Object {
      // A broken cache is just a cold cache.
      data = <String, Object?>{};
    }
    return FileTmdbCache._(file, ttl, data);
  }

  @override
  Map<String, dynamic>? read(String key) {
    final v = _data[key];
    if (v is! List ||
        v.length < 2 ||
        v[0] is! num ||
        v[1] is! Map<String, dynamic>) {
      return null;
    }
    final at = DateTime.fromMillisecondsSinceEpoch((v[0] as num).toInt());
    if (DateTime.now().difference(at) > ttl) {
      _data.remove(key);
      return null;
    }
    // Refresh insertion order for true LRU eviction.
    _data.remove(key);
    _data[key] = v;
    return v[1] as Map<String, dynamic>;
  }

  @override
  void write(String key, Map<String, dynamic> value) {
    _data.remove(key);
    _data[key] = [DateTime.now().millisecondsSinceEpoch, value];
    while (_data.length > _maxEntries) {
      _data.remove(_data.keys.first);
    }
    _flush ??= Timer(const Duration(seconds: 3), () => unawaited(flush()));
  }

  void clear() {
    _data.clear();
    unawaited(flush());
  }

  Future<void> flush() async {
    _flush?.cancel();
    _flush = null;
    final encoded = jsonEncode(_data);
    final prev = _flushing;
    final done = Completer<void>();
    _flushing = done.future;
    try {
      if (prev != null) await prev;
      final tmp = File('${file.path}.tmp');
      try {
        await tmp.writeAsString(encoded, flush: true);
        await tmp.rename(file.path);
      } on FileSystemException {
        try {
          if (await tmp.exists()) await tmp.delete();
        } on FileSystemException {
          // Ignore cleanup failure.
        }
        await file.writeAsString(encoded, flush: true);
      }
    } on FileSystemException {
      // Best effort: losing the cache only costs requests.
    } finally {
      if (identical(_flushing, done.future)) _flushing = null;
      done.complete();
    }
  }

  void flushSync() {
    _flush?.cancel();
    _flush = null;
    final encoded = jsonEncode(_data);
    final tmp = File('${file.path}.tmp');
    try {
      tmp.writeAsStringSync(encoded, flush: true);
      tmp.renameSync(file.path);
    } on FileSystemException {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // Ignore cleanup failure.
      }
      try {
        file.writeAsStringSync(encoded, flush: true);
      } on FileSystemException {
        // Best effort: losing the cache only costs requests.
      }
    }
  }
}
