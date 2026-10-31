import 'package:tidyreel_core/tidyreel_core.dart';
import 'package:test/test.dart';

const seed = <String, int>{
  '/剧集/示例 [1080p]/第01集.mkv': 10,
  '/剧集/示例 [1080p]/S01E02 (final).mkv': 20,
  '/a.txt': 5,
  '/b.txt': 7,
  '/空 目录/x.nfo': 1,
};

Matcher throwsStorage(StorageErrorCode code) =>
    throwsA(isA<StorageException>().having((e) => e.code, 'code', code));

Future<Map<String, int>> sizes(StorageBackend be, String dir) async => {
  for (final e in await be.list(dir)) e.name: e.isDir ? -1 : e.size,
};

/// Behaviour every backend must share with MemoryStorageBackend. [make] returns a
/// fresh backend holding [seed]-style files, and registers its own teardown.
void storageContract(
  String name,
  Future<StorageBackend> Function(Map<String, int> files) make,
) {
  group('$name contract', () {
    late StorageBackend be;
    setUp(() async => be = await make(seed));

    test(
      'list returns direct children only, with Chinese and bracket names',
      () async {
        expect(await sizes(be, '/剧集/示例 [1080p]'), {
          '第01集.mkv': 10,
          'S01E02 (final).mkv': 20,
        });
        final root = await be.list('/');
        expect(
          {for (final e in root) e.name: e.isDir},
          {'剧集': true, 'a.txt': false, 'b.txt': false, '空 目录': true},
        );
        final f = (await be.list('/剧集/示例 [1080p]'))
            .firstWhere((e) => e.name == '第01集.mkv');
        expect(f.path, '/剧集/示例 [1080p]/第01集.mkv');
      },
    );

    test('list of a missing dir is notFound', () {
      expect(be.list('/nope'), throwsStorage(StorageErrorCode.notFound));
    });

    test('exists', () async {
      expect(await be.exists('/a.txt'), isTrue);
      expect(await be.exists('/剧集/示例 [1080p]'), isTrue);
      expect(await be.exists('/剧集/示例 [1080p]/第01集.mkv'), isTrue);
      expect(await be.exists('/nope.txt'), isFalse);
      expect(await be.exists('/剧集/nope'), isFalse);
    });

    test('mkdirs creates parents and is idempotent', () async {
      await be.mkdirs('/新 库/电影 (2020)/extras');
      await be.mkdirs('/新 库/电影 (2020)/extras');
      await be.mkdirs('/剧集');
      expect(await be.list('/新 库/电影 (2020)/extras'), isEmpty);
      expect((await be.list('/新 库')).single.isDir, isTrue);
    });

    test('rename keeps the directory and never overwrites', () async {
      await be.rename('/剧集/示例 [1080p]/第01集.mkv', 'Show - S01E01 [x].mkv');
      expect(await sizes(be, '/剧集/示例 [1080p]'), {
        'Show - S01E01 [x].mkv': 10,
        'S01E02 (final).mkv': 20,
      });
      await expectLater(
        be.rename('/a.txt', 'b.txt'),
        throwsStorage(StorageErrorCode.alreadyExists),
      );
      expect(await sizes(be, '/'), containsPair('a.txt', 5));
      expect(await sizes(be, '/'), containsPair('b.txt', 7));
    });

    test('rename a missing path is notFound', () {
      expect(
        be.rename('/nope.txt', 'x.txt'),
        throwsStorage(StorageErrorCode.notFound),
      );
    });

    test('rename a directory keeps its children', () async {
      await be.rename('/空 目录', '已整理');
      expect(await be.exists('/空 目录'), isFalse);
      expect(await sizes(be, '/已整理'), {'x.nfo': 1});
    });

    test(
      'move keeps names; collision is alreadyExists and overwrites nothing',
      () async {
        await be.mkdirs('/库/电影');
        await be.move('/', '/库/电影', ['a.txt']);
        expect(await sizes(be, '/库/电影'), {'a.txt': 5});
        expect(await be.exists('/a.txt'), isFalse);

        await be.mkdirs('/c');
        await be.move('/', '/c', ['b.txt']);
        await be.rename('/c/b.txt', 'a.txt'); // c/a.txt (7)
        await expectLater(
          be.move('/c', '/库/电影', ['a.txt']),
          throwsStorage(StorageErrorCode.alreadyExists),
        );
        expect(await sizes(be, '/库/电影'), {'a.txt': 5});
        expect(await sizes(be, '/c'), {'a.txt': 7});
      },
    );

    test('move moves directories and several names at once', () async {
      await be.mkdirs('/to');
      await be.move('/', '/to', ['空 目录', 'b.txt']);
      expect(await sizes(be, '/to'), {'空 目录': -1, 'b.txt': 7});
      expect(await sizes(be, '/to/空 目录'), {'x.nfo': 1});
    });

    test('move into a missing dir is notFound', () {
      expect(
        be.move('/', '/missing', ['a.txt']),
        throwsStorage(StorageErrorCode.notFound),
      );
    });

    test('remove deletes files and directories recursively', () async {
      await be.remove('/', ['a.txt', '剧集']);
      expect(await sizes(be, '/'), {'b.txt': 7, '空 目录': -1});
      expect(await be.exists('/剧集/示例 [1080p]/第01集.mkv'), isFalse);
    });

    test('remove a missing name is notFound', () {
      expect(
        be.remove('/', ['nope.txt']),
        throwsStorage(StorageErrorCode.notFound),
      );
    });

    test('ping succeeds', () => be.ping());
  });
}
