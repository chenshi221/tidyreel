import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/sources/scan_preview.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  final fs = MemoryStorageBackend({
    '/dl/A/S01/a1.mkv': 10,
    '/dl/A/S01/a1.ass': 1,
    '/dl/A/S01/deep/x/y.mkv': 5,
    '/dl/B/b.mp4': 20,
    '/dl/readme.txt': 2,
  });

  test('counts within the depth limit and flags what it skipped', () async {
    final r = await previewScan(fs, ['/dl'], maxDepth: 3);
    expect(r.topDirs..sort(), ['/dl/A', '/dl/B']);
    expect(r.videos, 2); // a1.mkv, b.mp4; y.mkv is below the limit
    expect(r.subtitles, 1);
    expect(r.others, 1);
    expect(r.bytes, 33);
    expect(r.truncated, isTrue);
    expect(previewWarnings(['/dl'], r).first, contains('根目录或一级目录'));
  });

  test(
    'a selected video is counted without listing it and uses fileSizes',
    () async {
      final r = await previewScan(
        fs,
        ['/dl/B/b.mp4', '/dl/readme.txt'],
        fileSizes: const {'/dl/B/b.mp4': 20, '/dl/readme.txt': 2},
      );
      expect(r.videos, 1);
      expect(r.others, 1);
      expect(r.bytes, 22);
      expect(r.truncated, isFalse);
      expect(previewWarnings(['/dl/B/b.mp4', '/dl/readme.txt'], r), isEmpty);
    },
  );

  test('stops at maxDirs', () async {
    final r = await previewScan(fs, ['/dl'], maxDirs: 1);
    expect(r.truncated, isTrue);
    expect(r.dirs, 2);
  });

  testWidgets(
    'multi-path organizedCount checks exact paths and selected dirs (no Cartesian product)',
    (tester) async {
      List<String>? checked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showScanPreview(
                  context,
                  backend: fs,
                  paths: const ['/dl/A', '/dl/B'],
                  mode: OrganizeMode.moveToLibrary,
                  scrape: true,
                  mediaHint: MediaHint.anime,
                  organizedCount: (dirs) async {
                    checked = dirs;
                    return 1;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(checked, isNotNull);
      // Includes the selected paths themselves AND exact child path /dl/A/S01,
      // never the bogus Cartesian path /dl/B/S01.
      expect(checked, containsAll(['/dl/A', '/dl/B', '/dl/A/S01']));
      expect(checked, isNot(contains('/dl/B/S01')));
      expect(find.text('移动到媒体库'), findsOneWidget);
      expect(find.text('刮削'), findsOneWidget);
      expect(find.text('类型：动漫'), findsOneWidget);
      expect(find.textContaining('其中 1 个文件夹已经整理过'), findsOneWidget);
    },
  );
}
