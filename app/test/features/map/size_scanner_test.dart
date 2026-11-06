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
    // Named and foldered like a library, whoever did it.
    expect(of('动漫'), BlockState.organized);
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

  test('map blocks: every item shown until the cap, then 其余', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    await s.scan(root);
    final top = mapBlocksFor(s, root);
    expect(top.map((b) => b.label), containsAll(['剧集', '电影', '下载']));
    final bytes = top.map((b) => b.bytes).toList();
    expect(bytes.fold(0, (a, b) => a + b), _sumUnder(root));

    final subs = mapBlocksFor(s, '$root/字幕包');
    expect(subs, hasLength(120));
    expect(subs.any((b) => b.id == restId), isFalse);

    final many = _scanner(
      _Counting(
        MemoryStorageBackend({
          for (var i = 1; i <= 200; i++) '/x/f$i.mkv': 1000 + i,
        }),
      ),
    );
    await many.scan('/x');
    final blocks = mapBlocksFor(many, '/x');
    expect(blocks, hasLength(151));
    expect(blocks.last.label, '其余 50 项');
  });

  test('fresh scan lists again and sees what changed', () async {
    final mem = MemoryStorageBackend({'/x/a/1.mkv': 10});
    final be = _Counting(mem);
    final s = _scanner(be);
    await s.scan('/x');
    expect(s.statsOfDir('/x').total, 10);

    final seen = be.lists;
    await s.scan('/x');
    expect(be.lists, seen);

    await mem.remove('/x/a', ['1.mkv']);
    await s.scan('/x', fresh: true);
    expect(be.lists, greaterThan(seen));
    expect(s.statsOfDir('/x').total, 0);
  });

  test('refreshing a subfolder leaves its parent to recount', () async {
    final s = _scanner(_Counting(MemoryStorageBackend(fakeLibrary)));
    await s.scan(root);
    await s.forget('$root/下载');
    expect(s.isComplete(root), isFalse);
    expect(s.isListed('$root/剧集'), isTrue);
    await s.scan(root);
    expect(s.statsOfDir(root).total, _sumUnder(root));
  });

  test('hand marks beat everything, nearest one wins', () async {
    var marks = <String, bool>{'$root/下载': true};
    final s = SizeScanner(
      backend: MemoryStorageBackend(fakeLibrary),
      organizedOf: (paths) async => paths.where(fakeOrganized.contains).toSet(),
      marks: () => marks,
    );
    await s.scan(root);
    expect(blockStateOf(s.statsOfDir('$root/下载')), BlockState.organized);

    marks = {'$root/动漫/海贼王 (1999)': false, '$root/动漫/咒术回战 (2020)': false};
    s.marksChanged();
    expect(
      blockStateOf(s.statsOfDir('$root/动漫/海贼王 (1999)')),
      BlockState.unorganized,
    );
    expect(blockStateOf(s.statsOfDir('$root/动漫')), BlockState.mixed);
  });

  group('looksOrganized', () {
    RemoteEntry file(String path) => RemoteEntry(
      path: path,
      name: path.split('/').last,
      isDir: false,
      size: 1,
    );
    RemoteEntry dir(String path) => RemoteEntry(
      path: path,
      name: path.split('/').last,
      isDir: true,
      size: 0,
    );

    test('our layout counts', () {
      for (final p in [
        '/日漫/未来日记 (2011)/Season 01/未来日记 - S01E02.mkv',
        '/日漫/未来日记 (2011) {tmdb-1}/Season 1/未来日记 S01E02 1080p.mkv',
        '/日漫/未来日记 (2011)/Specials/未来日记 - S00E01.mkv',
        '/电影/Inception (2010) {tmdb-27205}/Inception (2010).mkv',
        '/电影/盗梦空间 (2010)/盗梦空间 (2010) - 2160p.mkv',
        '/电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv',
        // Filmix: single digits, and no season folder for one season.
        '/日漫/死神 (2004)/Season 2/死神 - S02E03.mkv',
        '/日漫/未来日记 (2011)/未来日记 - S01E02.mkv',
      ]) {
        expect(looksOrganized(file(p)), isTrue, reason: p);
      }
    });

    test('raw downloads do not', () {
      for (final p in [
        '/下载/The.Bear.S03E02.2160p.mkv',
        '/下载/Dune.Part.Two.2024.2160p.mkv',
        '/下载/[Nekomoe] Dandadan/[Nekomoe] Dandadan - 01.mkv',
        '/电影/盗梦空间 (2010)/movie.mkv',
        '/合集2020/ep1.mkv',
        // Close, but not our format.
        '/日漫/未来日记 (2011)/Season 02/未来日记 - S01E02.mkv',
        '/日漫/未来日记/Season 01/未来日记 - S01E02.mkv',
        '/日漫/未来日记 (2011)/Season 01/[Sub] 未来日记 - 02.mkv',
        '/剧/The.Bear.2022/Season 1/the.bear.s01e02.mkv',
        '/剧/老友记（1994）/老友记 1x02.mkv',
        '/电影/盗梦空间 (2010)/Inception.mkv',
      ]) {
        expect(looksOrganized(file(p)), isFalse, reason: p);
      }
    });

    test('folders go by name', () {
      expect(looksOrganized(dir('/剧/三体 (2023)')), isTrue);
      expect(looksOrganized(dir('/剧/三体 (2023)/Season 01')), isTrue);
      expect(looksOrganized(dir('/剧/The.Bear.2022')), isFalse);
      expect(looksOrganized(dir('/下载/Season 01')), isFalse);
      expect(looksOrganized(dir('/下载/The.Bear.S03.2160p')), isFalse);
      expect(looksOrganized(dir('/下载')), isFalse);
    });
  });
}
