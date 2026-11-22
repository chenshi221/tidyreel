import 'dart:async';

import 'package:path/path.dart' as p;

import '../model/scan.dart';
import '../storage/alist_backend.dart';
import '../storage/cached_backend.dart';
import '../storage/storage_backend.dart';

typedef Delay = Future<void> Function(Duration d);

/// Wraps a backend with PLAN §4.3 rule 5: at most one request start per
/// [minInterval] (200 ms = 5 req/s) and 3 retries (1s/2s/4s) on rate-limit,
/// network and busy (file in use) errors.
class ThrottledBackend implements StorageBackend, RangeReadableBackend {
  final StorageBackend inner;
  final Duration minInterval;

  /// Optional live provider overriding [minInterval] on every request so
  /// runtime settings changes take effect immediately.
  final Duration Function()? minIntervalProvider;
  final List<Duration> backoff;
  final Delay delay;
  final DateTime Function() now;
  DateTime _lastSlot = DateTime.fromMillisecondsSinceEpoch(0);

  ThrottledBackend(
    this.inner, {
    this.minInterval = const Duration(milliseconds: 200),
    this.minIntervalProvider,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.delay = _realDelay,
    this.now = DateTime.now,
  });

  static Future<void> _realDelay(Duration d) => Future<void>.delayed(d);

  Duration get _effectiveMinInterval {
    final d = minIntervalProvider?.call() ?? minInterval;
    return d.isNegative ? Duration.zero : d;
  }

  Future<void> _slot() async {
    final interval = _effectiveMinInterval;
    if (interval == Duration.zero) return;
    final current = now();
    final nextAllowed = _lastSlot.add(interval);
    final at = nextAllowed.isAfter(current) ? nextAllowed : current;
    _lastSlot = at;
    final wait = at.difference(current);
    if (wait > Duration.zero) await delay(wait);
  }

  Future<T> _call<T>(Future<T> Function() fn) async {
    for (var attempt = 0; ; attempt++) {
      await _slot();
      try {
        return await fn();
      } on StorageException catch (e) {
        final retryable =
            e.code == StorageErrorCode.rateLimited ||
            e.code == StorageErrorCode.network ||
            e.code == StorageErrorCode.busy;
        if (!retryable || attempt >= backoff.length) rethrow;
        await delay(backoff[attempt]);
      }
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) {
    final b = inner;
    if (!refresh && b is CachedBackend && b.isCached(dir)) {
      return b.list(dir, refresh: false);
    }
    return _call(() => inner.list(dir, refresh: refresh));
  }

  @override
  Future<void> mkdirs(String dir) => _call(() => inner.mkdirs(dir));

  @override
  Future<void> rename(String path, String newName) =>
      _call(() => inner.rename(path, newName));

  /// Alist does it in one request; other backends do one request per file, so
  /// each is paced on its own.
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    if (_unwrapped(inner) is AlistBackend) {
      return _call(() => inner.renameMany(dir, names));
    }
    for (final e in names.entries) {
      await rename(p.posix.join(dir, e.key), e.value);
    }
  }

  /// The app hands us `CachedBackend(AlistBackend)`; calls still go through
  /// [inner] so the cache drops what we touch.
  static StorageBackend _unwrapped(StorageBackend b) => switch (b) {
    CachedBackend(:final inner) => _unwrapped(inner),
    ThrottledBackend(:final inner) => _unwrapped(inner),
    _ => b,
  };

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) =>
      _call(() => inner.move(srcDir, dstDir, names));

  @override
  Future<void> remove(String dir, List<String> names) =>
      _call(() => inner.remove(dir, names));

  @override
  Future<bool> exists(String path) => _call(() => inner.exists(path));

  @override
  Future<List<int>> read(String path) => _call(() => inner.read(path));

  @override
  Future<List<int>> readRange(String path, int start, int length) {
    if (inner case final RangeReadableBackend range) {
      return _call(() => range.readRange(path, start, length));
    }
    return Future.error(
      const StorageException(StorageErrorCode.other, '不支持分段读取'),
    );
  }

  @override
  Future<void> write(String path, List<int> bytes) =>
      _call(() => inner.write(path, bytes));

  @override
  Future<void> ping() => _call(inner.ping);

  @override
  Future<void> close() => inner.close();
}
