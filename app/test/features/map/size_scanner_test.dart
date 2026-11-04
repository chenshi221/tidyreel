import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/map/repo_map_view.dart';
import 'package:tidyreel/features/map/size_scanner.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'fake_library.dart';

/// Counts list calls so tests can tell cached from fresh.
class _Counting implements StorageBackend {
  final StorageBackend inner;
  var lists = 0;

  _Counting(this.inner);

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) {
    lists++;
    return inner.list(dir, refresh: refresh);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('read-only');
}

SizeScanner _scanner(_Counting be) => SizeScanner(
  backend: be,
  organizedOf: (paths) async => paths.where(fakeOrganized.contains).toSet(),
);

int _sumUnder(String dir) => fakeLibrary.entries
    .where((e) => e.key.startsWith('$dir/'))
    .fold(0, (s, e) => s + e.value);

void main() {
  test('totals add up every file below the folder', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    await s.scan(root);
    expect(s.isComplete(root), isTrue);
    expect(s.statsOfDir(root).total, _sumUnder(root));
    expect(s.statsOfDir(root).files, fakeLibrary.length);
    expect(s.statsOfDir('$root/剧集').total, _sumUnder('$root/剧集'));
  });

  test('block state follows organize history', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    await s.scan(root);
    BlockState of(String name) => blockStateOf(s.statsOfDir('$root/$name'));
    expect(of('电影'), BlockState.organized);
    expect(of('下载'), BlockState.unorganized);
    expect(of('待分类'), BlockState.unorganized);
    expect(of('字幕包'), BlockState.other);
    expect(of('原声音乐'), BlockState.other);
    expect(of('动漫'), BlockState.mixed);
    // Subtitles inside an organized folder still count as 非视频.
    expect(s.statsOfDir('$root/电影').other, greaterThan(0));
  });

  test('drilling into a counted folder makes no new requests', () async {
    final be = _Counting(MemoryStorageBackend(fakeLibrary));
    final s = _scanner(be);
    await s.scan(root);
    final calls = be.lists;
    await s.scan('$root/剧集');
    expect(be.lists, calls);
    expect(s.isComplete('$root/剧集/老友记 (1994)'), isTrue);
  });

  test('cancel keeps a partial count; scanning again finishes it', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    final run = s.scan(root);
    s.cancel();
    await run;
    expect(s.isComplete(root), isFalse);
    await s.scan(root);
    expect(s.isComplete(root), isTrue);
    expect(s.statsOfDir(root).total, _sumUnder(root));
  });

  test('map blocks: largest first, long tail folded into 其余', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    await s.scan(root);
    final top = mapBlocksFor(s, root);
    expect(top.map((b) => b.label), containsAll(['剧集', '电影', '下载']));
    final bytes = top.map((b) => b.bytes).toList();
    expect(bytes.fold(0, (a, b) => a + b), _sumUnder(root));

    // 字幕包: 120 near-equal tiny files → over the block cap, so 其余 appears.
    final subs = mapBlocksFor(s, '$root/字幕包');
    expect(subs.length, lessThanOrEqualTo(37));
    expect(subs.last.id, restId);
    expect(subs.last.label, startsWith('其余 '));
  });
}
