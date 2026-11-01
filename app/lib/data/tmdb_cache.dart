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

  static const _maxEntries = 5000;

  FileTmdbCache._(this.file, this.ttl, this._data);

  factory FileTmdbCache.load(
    File file, {
    Duration ttl = const Duration(days: 7),
  }) {
    var data = <String, Object?>{};
    try {
      if (file.existsSync()) {
        data = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      }
    } on Object {
      // A broken cache is just a cold cache.
    }
    final cutoff = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    data.removeWhere((_, v) => v is! List || (v[0] as num) < cutoff);
    return FileTmdbCache._(file, ttl, data);
  }

  @override
  Map<String, dynamic>? read(String key) {
    final v = _data[key];
    if (v is! List) return null;
    final at = DateTime.fromMillisecondsSinceEpoch((v[0] as num).toInt());
    if (DateTime.now().difference(at) > ttl) return null;
    return v[1] as Map<String, dynamic>;
  }

  @override
  void write(String key, Map<String, dynamic> value) {
    _data[key] = [DateTime.now().millisecondsSinceEpoch, value];
    if (_data.length > _maxEntries) {
      // Oldest first: insertion order roughly follows write time.
      _data.remove(_data.keys.first);
    }
    _flush ??= Timer(const Duration(seconds: 3), flush);
  }

  void clear() {
    _data.clear();
    flush();
  }

  void flush() {
    _flush?.cancel();
    _flush = null;
    try {
      file.writeAsStringSync(jsonEncode(_data));
    } on FileSystemException {
      // Best effort: losing the cache only costs requests.
    }
  }
}
