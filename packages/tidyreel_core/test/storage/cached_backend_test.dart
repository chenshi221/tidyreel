import 'dart:async';

import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Counts listings that reach the server.
class _Counting extends MemoryStorageBackend {
  final lists = <String>[];
  _Counting(super.files);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) {
    lists.add(dir);
    return super.list(dir, refresh: refresh);
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
}
