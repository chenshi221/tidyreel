import 'dart:async';

import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Counts listings that reach the server.
class _Counting extends MemoryStorageBackend {
  final lists = <String>[];
  var closed = false;
  _Counting(super.files);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) {
    lists.add(dir);
    return super.list(dir, refresh: refresh);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late _Counting inner;
  late CachedBackend be;
  var clock = DateTime(2026);

  setUp(() {
    clock = DateTime(2026);
    inner = _Counting({'/a/x.mkv': 1, '/a/b/y.mkv': 1});
    be = CachedBackend(
      inner,
      ttl: const Duration(minutes: 10),
      now: () => clock,
    );
  });

  test('repeat and concurrent listings hit the server once', () async {
    await Future.wait([be.list('/a'), be.list('/a')]);
    await be.list('/a');
    expect(inner.lists, ['/a']);
    clock = clock.add(const Duration(minutes: 11));
    await be.list('/a');
    expect(inner.lists, ['/a', '/a']);
  });

  test('refresh and listRecent go to the server when needed', () async {
    await be.list('/a');
    await be.list('/a', refresh: true);
    expect(inner.lists.length, 2);
    await be.listRecent('/a', const Duration(minutes: 2));
    expect(inner.lists.length, 2);
    clock = clock.add(const Duration(minutes: 3));
    await be.listRecent('/a', const Duration(minutes: 2));
    expect(inner.lists.length, 3);
  });

  test('writes drop the folders they touch', () async {
    await be.list('/a');
    await be.list('/a/b');
    await be.rename('/a/b', 'c');
    final names = (await be.list('/a')).map((e) => e.name).toSet();
    expect(names, {'x.mkv', 'c'});
    await expectLater(be.list('/a/b'), throwsA(isA<StorageException>()));
  });

  test('failures are not cached', () async {
    await expectLater(be.list('/nope'), throwsA(isA<StorageException>()));
    inner.addFile('/nope/z.mkv');
    expect((await be.list('/nope')).single.name, 'z.mkv');
  });

  test('walkDirs visits every folder with bounded parallelism', () async {
    var active = 0, peak = 0;
    final seen = <String>[];
    await walkDirs(['/r'], (dir) async {
      active++;
      peak = active > peak ? active : peak;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      seen.add(dir);
      return dir.length < 6 ? ['$dir/1', '$dir/2', '$dir/3'] : const [];
    }, parallel: 3);
    expect(seen.length, 1 + 3 + 9);
    expect(peak, 3);
  });

  test('walkDirs rethrows the first error', () async {
    await expectLater(
      walkDirs(['/a'], (_) async => throw StateError('boom')),
      throwsStateError,
    );
  });

  test('walkDirs does not loop on duplicate or cyclical folders', () async {
    final visited = <String>[];
    await walkDirs(['/a', '/a', '/b'], (dir) async {
      visited.add(dir);
      return dir == '/a' ? ['/b', '/a'] : const [];
    });
    expect(visited, ['/a', '/b']);
  });

  test(
    'walkDirs guards parallel <= 0 and catches synchronous throws',
    () async {
      final visited = <String>[];
      await walkDirs(['/a'], (dir) async {
        visited.add(dir);
        return const [];
      }, parallel: 0);
      expect(visited, ['/a']);

      await expectLater(
        walkDirs(['/a'], (_) => throw StateError('sync boom')),
        throwsStateError,
      );
    },
  );

  test('normalizes keys, returns defensive copies, and exposes inner/isCached/close', () async {
    expect(be.inner, same(inner));
    expect(be.isCached('/a'), isFalse);
    final first = await be.list('/a/');
    expect(be.isCached('/a'), isTrue);
    expect(be.isCached('/a/'), isTrue);
    first.clear();
    final second = await be.list('/a');
    expect(second, hasLength(2));
    expect(inner.lists, ['/a']);
    await be.close();
    expect(inner.closed, isTrue);
  });

  test('invalidate("/") clears the entire cache', () async {
    await be.list('/');
    await be.list('/a');
    await be.list('/a/b');
    be.invalidate('/');
    expect(be.isCached('/'), isFalse);
    expect(be.isCached('/a'), isFalse);
    expect(be.isCached('/a/b'), isFalse);
  });

  test('mkdirs/write invalidate missing ancestors up to first cached parent; file mutations preserve parent', () async {
    await be.list('/');
    await be.list('/a');
    await be.list('/a/b');

    // File write inside already-cached /a/b invalidates only /a/b, not /a or /.
    await be.write('/a/b/new.nfo', [1, 2]);
    expect(be.isCached('/a/b'), isFalse);
    expect(be.isCached('/a'), isTrue);
    expect(be.isCached('/'), isTrue);

    // File rename inside /a/b invalidates only /a/b, not /a.
    await be.list('/a/b');
    await be.rename('/a/b/y.mkv', 'z.mkv');
    expect(be.isCached('/a/b'), isFalse);
    expect(be.isCached('/a'), isTrue);

    // Nested mkdirs under /a invalidates up to first cached parent (/a), keeping / cached.
    await be.mkdirs('/a/newdir/deep');
    expect(be.isCached('/a'), isFalse);
    expect(be.isCached('/'), isTrue);
  });

  test('cache evicts entries when maxEntries cap is exceeded', () async {
    final files = {for (var i = 0; i < 6; i++) '/d$i/f.mkv': 1};
    final smallInner = _Counting(files);
    final capped = CachedBackend(smallInner, maxEntries: 3, now: () => clock);
    for (var i = 0; i < 5; i++) {
      await capped.list('/d$i');
    }
    expect(capped.isCached('/d0'), isFalse);
    expect(capped.isCached('/d1'), isFalse);
    expect(capped.isCached('/d2'), isTrue);
    expect(capped.isCached('/d3'), isTrue);
    expect(capped.isCached('/d4'), isTrue);
  });
}
