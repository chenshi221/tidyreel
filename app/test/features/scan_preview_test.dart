import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/sources/scan_preview.dart';
import 'package:tidyreel_core/testing.dart';

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
    expect(r.topDirs..sort(), ['A', 'B']);
    expect(r.videos, 2); // a1.mkv, b.mp4; y.mkv is below the limit
    expect(r.subtitles, 1);
    expect(r.others, 1);
    expect(r.bytes, 33);
    expect(r.truncated, isTrue);
    expect(previewWarnings(['/dl'], r).first, contains('根目录或一级目录'));
  });

  test('a selected video is counted without listing it', () async {
    final r = await previewScan(fs, ['/dl/B/b.mp4']);
    expect(r.videos, 1);
    expect(r.truncated, isFalse);
    expect(previewWarnings(['/dl/B/b.mp4'], r), isEmpty);
  });

  test('stops at maxDirs', () async {
    final r = await previewScan(fs, ['/dl'], maxDirs: 1);
    expect(r.truncated, isTrue);
    expect(r.dirs, 2);
  });
}
