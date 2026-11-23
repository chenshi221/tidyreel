import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  group('findEmptySourceDirs', () {
    test('returns nested empty dirs deepest-first', () async {
      final be = MemoryStorageBackend();
      await be.mkdirs('/in/Show/Season 1/Sub');

      final empty = await findEmptySourceDirs(
        be,
        ['/in/Show', '/in/Show/Season 1', '/in/Show/Season 1/Sub', '/in'],
        protectedRoots: {'/in'},
      );
      expect(empty, ['/in/Show/Season 1/Sub', '/in/Show/Season 1', '/in/Show']);
    });

    test('treats dirs containing only OS junk files as empty', () async {
      final be = MemoryStorageBackend({
        '/in/Show/Season 1/.DS_Store': 1,
        '/in/Show/Thumbs.db': 1,
        '/in/Show/desktop.ini': 1,
      });

      final empty = await findEmptySourceDirs(
        be,
        ['/in/Show/Season 1', '/in/Show'],
        protectedRoots: {'/in'},
      );
      expect(empty, ['/in/Show/Season 1', '/in/Show']);
    });

    test('keeps dirs with real files and their ancestors', () async {
      final be = MemoryStorageBackend({
        '/in/Show/Season 1/keep.mkv': 10,
        '/in/Show/Season 2/.DS_Store': 1,
      });

      final empty = await findEmptySourceDirs(
        be,
        ['/in/Show/Season 1', '/in/Show/Season 2', '/in/Show'],
        protectedRoots: {'/in'},
      );
      expect(empty, ['/in/Show/Season 2']);
    });

    test(
      'never returns protected roots or "/" and skips missing dirs',
      () async {
        final be = MemoryStorageBackend();
        await be.mkdirs('/in/empty');
        await be.mkdirs('/lib');

        final empty = await findEmptySourceDirs(
          be,
          ['/', '/in/', '/in/empty/', '/in/missing', '/lib'],
          protectedRoots: {'/in/', '/lib'},
        );
        expect(empty, ['/in/empty']);
      },
    );
  });
}
