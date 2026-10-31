import 'dart:async';

import '../model/scan.dart';
import '../storage/storage_backend.dart';

typedef Delay = Future<void> Function(Duration d);

/// Wraps a backend with PLAN §4.3 rule 5: at most one request start per
/// [minInterval] (200 ms = 5 req/s) and 3 retries (1s/2s/4s) on rate-limit/network errors.
class ThrottledBackend implements StorageBackend {
  final StorageBackend inner;
  final Duration minInterval;
  final List<Duration> backoff;
  final Delay delay;
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  ThrottledBackend(
    this.inner, {
    this.minInterval = const Duration(milliseconds: 200),
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.delay = _realDelay,
  });

  static Future<void> _realDelay(Duration d) => Future<void>.delayed(d);

  Future<void> _slot() async {
    if (minInterval == Duration.zero) return;
    final now = DateTime.now();
    final at = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = at.add(minInterval);
    final wait = at.difference(now);
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
            e.code == StorageErrorCode.network;
        if (!retryable || attempt >= backoff.length) rethrow;
        await delay(backoff[attempt]);
      }
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) =>
      _call(() => inner.list(dir, refresh: refresh));

  @override
  Future<void> mkdirs(String dir) => _call(() => inner.mkdirs(dir));

  @override
  Future<void> rename(String path, String newName) =>
      _call(() => inner.rename(path, newName));

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) =>
      _call(() => inner.move(srcDir, dstDir, names));

  @override
  Future<void> remove(String dir, List<String> names) =>
      _call(() => inner.remove(dir, names));

  @override
  Future<bool> exists(String path) => _call(() => inner.exists(path));

  @override
  Future<void> ping() => _call(inner.ping);
}
