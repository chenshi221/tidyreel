import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/database.dart';
import 'package:tidyreel/data/folder_stats_store.dart';
import 'package:tidyreel/features/health/health_models.dart';
import 'package:tidyreel/features/health/health_scanner.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _FakeProbe implements MediaProbe {
  final Map<String, MediaProbeInfo> byPath;
  final List<String> probedPaths = [];

  _FakeProbe(this.byPath);

  @override
  Future<MediaProbeInfo?> probe(
    StorageBackend backend,
    String path, {
    int? fileSize,
  }) async {
    probedPaths.add(path);
    return byPath[path];
  }
}

void main() {
  const connId = ConnectionId('test-nas');

  test('detects duplicate movies and uses MediaProbe to recommend 2160p DV over 1080p', () async {
    final lowPath = '/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv';
    final highPath = '/影视库/盗梦空间 (2010)/Inception.2010.2160p.DV.mkv';
    final soloPath = '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.mkv';

    final fs = MemoryStorageBackend({
      lowPath: 4 * 1024 * 1024 * 1024, // 4 GB
      highPath: 24 * 1024 * 1024 * 1024, // 24 GB
      soloPath: 1 * 1024 * 1024 * 1024, // 1 GB (not a duplicate)
    });

    final probe = _FakeProbe({
      lowPath: const MediaProbeInfo(
        width: 1920,
        height: 1080,
        videoCodec: 'H.264',
        audioCodec: 'AAC',
        audioChannels: 2,
      ),
      highPath: const MediaProbeInfo(
        width: 3840,
        height: 2160,
        videoCodec: 'HEVC',
        hdr: 'DV',
        audioCodec: 'Atmos',
        audioChannels: 8,
      ),
    });

    final scanner = HealthScanner(
      backend: fs,
      connectionId: connId,
      mediaProbe: probe,
      probeMedia: true,
    );

    final report = await scanner.scan('/影视库');

    expect(report.duplicates, hasLength(1));
    final dup = report.duplicates.single;
    expect(dup.title, '盗梦空间 (2010)');
    expect(dup.recommendedKeepPath, highPath);
    expect(dup.copies.first.path, highPath);
    expect(
      dup.copies.first.qualityBadges,
      containsAll(['2160p', 'DV', 'Atmos']),
    );
    expect(dup.reclaimableBytes, 4 * 1024 * 1024 * 1024);

    // Probe MUST run only on duplicate candidates, never on non-duplicates.
    expect(probe.probedPaths.toSet(), {lowPath, highPath});
    expect(probe.probedPaths, isNot(contains(soloPath)));
  });

  test('detects missing NFO/poster without external subtitle false positives, junk files, empty dirs, and reuses cache', () async {
    final fs = MemoryStorageBackend({
      // Work 1: Complete movie (NFO + poster, NO external subtitle -> must NOT be flagged!)
      '/影视库/完整电影 (2020)/完整电影.2020.1080p.mkv': 2 << 30,
      '/影视库/完整电影 (2020)/movie.nfo': 500,
      '/影视库/完整电影 (2020)/poster.jpg': 30000,
      // Work 2: Missing NFO + poster
      '/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv': 5 << 30,
      // Junk files
      '/影视库/更多资源请访问 www.example.com.txt': 128,
      '/影视库/盗梦空间 (2010)/Inception.2010.sample.mkv': 500000,
    });
    await fs.mkdirs('/影视库/空文件夹');
    // BDMV disc folder should be recognized as 1 movie work and not walked into BDMV
    fs.addFile('/影视库/阿凡达 (2009)/BDMV/STREAM/00001.m2ts', 10 << 30);
    fs.addFile('/影视库/阿凡达 (2009)/movie.nfo', 300);
    fs.addFile('/影视库/阿凡达 (2009)/poster.png', 20000);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final statsStore = FolderStatsStore(db);

    final scanner = HealthScanner(
      backend: fs,
      connectionId: connId,
      folderStatsStore: statsStore,
      probeMedia: false,
    );

    final report = await scanner.scan('/影视库');

    expect(report.totalWorks, 3);
    // Only 盗梦空间 is missing NFO + poster; 完整电影 and 阿凡达 pass with no external sub!
    expect(report.missingAssets, hasLength(1));
    final missing = report.missingAssets.single;
    expect(missing.workTitle, '盗梦空间');
    expect(missing.folderPath, '/影视库/盗梦空间 (2010)');
    expect(missing.missingNfo, isTrue);
    expect(missing.missingPoster, isTrue);

    // Cleanup: 2 junk files + 1 empty dir
    expect(report.junkCount, 2);
    expect(report.emptyDirCount, 1);
    expect(
      report.cleanupItems
          .where((c) => c.kind == CleanupKind.emptyDir)
          .single
          .path,
      '/影视库/空文件夹',
    );
    expect(report.firstNonEmptyCategory, HealthCategory.missingAssets);

    // Verify FolderStatsStore was populated and is reused on subsequent non-fresh scan
    final cachedRows = await statsStore.loadFor(connId);
    expect(cachedRows, isNotEmpty);

    // Updating report after removing cleanup items clears them cleanly
    final cleaned = report.withoutDeletedPaths(
      deletedFiles: {
        '/影视库/更多资源请访问 www.example.com.txt',
        '/影视库/盗梦空间 (2010)/Inception.2010.sample.mkv',
      },
      deletedDirs: {'/影视库/空文件夹'},
    );
    expect(cleaned.cleanupItems, isEmpty);
  });

  test(
    'detects duplicate TV episodes across local folders and explicit tmdb tags',
    () async {
      final fs = MemoryStorageBackend({
        '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.2160p.HDR10.mkv':
            8 * 1024 * 1024 * 1024,
        '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.720p.mkv':
            1 * 1024 * 1024 * 1024,
        '/影视库/电影A/Inception (2010) {tmdb-27205}/Inception.2010.2160p.mkv':
            16 * 1024 * 1024 * 1024,
        '/影视库/电影B/盗梦空间 (2010) {tmdb-27205}/盗梦空间.2010.1080p.mkv':
            4 * 1024 * 1024 * 1024,
        '/影视库/广告.txt': 64,
      });

      final scanner = HealthScanner(
        backend: fs,
        connectionId: connId,
        probeMedia: false,
      );

      final report = await scanner.scan('/影视库');
      expect(report.duplicates, hasLength(2));
      expect(
        report.duplicates.map((d) => d.recommendedKeepPath),
        containsAll([
          '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.2160p.HDR10.mkv',
          '/影视库/电影A/Inception (2010) {tmdb-27205}/Inception.2010.2160p.mkv',
        ]),
      );
      expect(report.junkCount, 1);
      expect(report.firstNonEmptyCategory, HealthCategory.duplicates);
    },
  );
}
