import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/database.dart';
import 'package:tidyreel/data/folder_stats_store.dart';
import 'package:tidyreel/features/health/health_models.dart';
import 'package:tidyreel/features/health/health_scanner.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _TestMetadata implements MetadataProvider {
  int searchCalls = 0;
  final Map<int, ShowDetail> shows;
  final Map<int, MovieDetail> movies;
  final Map<(int, int), List<Episode>> seasons;
  final List<Candidate> searchPool;

  _TestMetadata({
    this.shows = const {},
    this.movies = const {},
    this.seasons = const {},
    this.searchPool = const [],
  });

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    searchCalls++;
    final q = query.toLowerCase();
    return searchPool
        .where((c) => kind == null || c.kind == kind)
        .where(
          (c) => [
            c.title,
            c.englishTitle,
            c.originalTitle,
          ].any((t) => t != null && t.toLowerCase().contains(q)),
        )
        .toList();
  }

  @override
  Future<ShowDetail> show(int tmdbId) async => shows[tmdbId]!;

  @override
  Future<List<Episode>> season(int tmdbId, int season) async =>
      seasons[(tmdbId, season)] ?? const [];

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async => const [];

  @override
  Future<MovieDetail> movie(int tmdbId) async => movies[tmdbId]!;
}

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

  test('detects internal missing episodes and newly aired episodes while ignoring unaired future episodes', () async {
    final now = DateTime.utc(2026, 5, 10);
    final fs = MemoryStorageBackend({
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.1080p.mkv': 1 << 30,
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E02.1080p.mkv': 1 << 30,
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E03.1080p.mkv': 1 << 30,
      // Missing internal gap: S01E04
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E05.1080p.mkv': 1 << 30,
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.zh-Hans.ass': 20000,
      '/影视库/异兽魔都 (2020)/poster.jpg': 50000,
    });
    await fs.write(
      '/影视库/异兽魔都 (2020)/tvshow.nfo',
      utf8.encode(
        '<tvshow><title>异兽魔都</title><uniqueid type="tmdb">94954</uniqueid></tvshow>',
      ),
    );

    final meta = _TestMetadata(
      shows: {
        94954: const ShowDetail(
          info: Demo.dorohedoro,
          seasons: [SeasonInfo(number: 1, episodeCount: 8)],
        ),
      },
      seasons: {
        (94954, 1): [
          for (var e = 1; e <= 6; e++)
            Episode(
              season: 1,
              number: e,
              title: '第 $e 话',
              // E01..E06 aired before `now`
              airDate: DateTime.utc(2026, 3, 1).add(Duration(days: 7 * e)),
            ),
          // E07 aired on May 1 (before May 10) -> newly aired
          Episode(
            season: 1,
            number: 7,
            title: '第 7 话',
            airDate: DateTime.utc(2026, 5, 1),
          ),
          // E08 airs in the future (May 20 > May 10) -> MUST be ignored
          Episode(
            season: 1,
            number: 8,
            title: '第 8 话',
            airDate: DateTime.utc(2026, 5, 20),
          ),
        ],
      },
    );

    final scanner = HealthScanner(
      backend: fs,
      metadata: meta,
      connectionId: connId,
      now: () => now,
    );

    final report = await scanner.scan('/影视库');

    // tvshow.nfo had TMDB ID, so metadata.search must not be called!
    expect(meta.searchCalls, 0);
    expect(report.missingEpisodes, hasLength(1));
    final issue = report.missingEpisodes.single;
    expect(issue.workTitle, '异兽魔都');
    expect(issue.internalMissing.map((e) => e.code), ['S01E04']);
    expect(issue.newlyAired.map((e) => e.code), ['S01E06', 'S01E07']);
    expect(issue.latestLocalCode, 'S01E05');
    expect(issue.latestAiredCode, 'S01E07');
    // S01E08 is future unaired -> never included
    expect(issue.allMissing.any((e) => e.code == 'S01E08'), isFalse);
    // Show has tvshow.nfo, poster.jpg, and zh-Hans.ass -> zero missing assets
    expect(report.missingAssets, isEmpty);
  });

  test(
    'detects duplicates and uses MediaProbe to recommend 2160p DV over 1080p',
    () async {
      final lowPath = '/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv';
      final highPath = '/影视库/盗梦空间 (2010)/Inception.2010.2160p.DV.mkv';
      final soloPath = '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.mkv';

      final fs = MemoryStorageBackend({
        lowPath: 4 * 1024 * 1024 * 1024, // 4 GB
        highPath: 24 * 1024 * 1024 * 1024, // 24 GB
        soloPath: 1 * 1024 * 1024 * 1024, // 1 GB (not a duplicate)
      });
      await fs.write(
        '/影视库/盗梦空间 (2010)/movie.nfo',
        utf8.encode('<movie><tmdbid>27205</tmdbid></movie>'),
      );

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

      final meta = _TestMetadata(
        movies: {27205: const MovieDetail(info: Demo.inception)},
        shows: {94954: Demo.dorohedoroShow},
        searchPool: [Demo.dorohedoro, Demo.inception],
      );

      final scanner = HealthScanner(
        backend: fs,
        metadata: meta,
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
    },
  );

  test('detects missing NFO, poster, Chinese subtitles, junk files, empty dirs and computes health score', () async {
    final fs = MemoryStorageBackend({
      // Work 1: Complete movie (NFO + poster + zh-Hans sub)
      '/影视库/完整电影 (2020)/完整电影.2020.1080p.mkv': 2 << 30,
      '/影视库/完整电影 (2020)/movie.nfo': 500,
      '/影视库/完整电影 (2020)/poster.jpg': 30000,
      '/影视库/完整电影 (2020)/完整电影.2020.zh-Hans.srt': 15000,
      // Work 2: Missing NFO + poster + Chinese sub (only English sub present)
      '/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv': 5 << 30,
      '/影视库/盗梦空间 (2010)/Inception.2010.en.srt': 12000,
      // Junk files
      '/影视库/更多资源请访问 www.example.com.txt': 128,
      '/影视库/盗梦空间 (2010)/Inception.2010.sample.mkv': 500000,
    });
    await fs.mkdirs('/影视库/空文件夹');
    // BDMV disc folder should be recognized as 1 movie work and not walked into BDMV
    fs.addFile('/影视库/阿凡达 (2009)/BDMV/STREAM/00001.m2ts', 10 << 30);
    fs.addFile('/影视库/阿凡达 (2009)/movie.nfo', 300);
    fs.addFile('/影视库/阿凡达 (2009)/poster.png', 20000);
    fs.addFile('/影视库/阿凡达 (2009)/avatar.chs.ass', 10000);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final statsStore = FolderStatsStore(db);

    final scanner = HealthScanner(
      backend: fs,
      metadata: FakeMetadataProvider(),
      connectionId: connId,
      folderStatsStore: statsStore,
      probeMedia: false,
    );

    final report = await scanner.scan('/影视库');

    expect(report.totalWorks, 3);
    // Only 盗梦空间 is missing NFO + poster + Chinese sub
    expect(report.missingAssets, hasLength(1));
    final missing = report.missingAssets.single;
    expect(missing.workTitle, '盗梦空间');
    expect(missing.folderPath, '/影视库/盗梦空间 (2010)');
    expect(missing.missingNfo, isTrue);
    expect(missing.missingPoster, isTrue);
    expect(missing.missingChineseSubtitle, isTrue);
    expect(missing.canScrapeFix, isTrue);

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

    // Health score reflects deductions (100 - (4+3+1) - (2+2+1) = 87)
    expect(report.score, 87);

    // Verify FolderStatsStore was populated and is reused on subsequent non-fresh scan
    final cachedRows = await statsStore.loadFor(connId);
    expect(cachedRows, isNotEmpty);

    // Updating report after removing cleanup items recalculates score cleanly
    final cleaned = report.withoutDeletedPaths(
      deletedFiles: {
        '/影视库/更多资源请访问 www.example.com.txt',
        '/影视库/盗梦空间 (2010)/Inception.2010.sample.mkv',
      },
      deletedDirs: {'/影视库/空文件夹'},
    );
    expect(cleaned.cleanupItems, isEmpty);
    expect(cleaned.score, greaterThan(report.score));
  });

  test('detects duplicate TV episodes and completes local audits when TMDB API key is missing', () async {
    final fs = MemoryStorageBackend({
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.2160p.HDR10.mkv':
          8 * 1024 * 1024 * 1024,
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.720p.mkv':
          1 * 1024 * 1024 * 1024,
      '/影视库/广告.txt': 64,
    });

    final scanner = HealthScanner(
      backend: fs,
      metadata: _MissingKeyMetadataStub(),
      connectionId: connId,
      probeMedia: false,
    );

    final report = await scanner.scan('/影视库');
    expect(report.warnings, isNotEmpty);
    expect(report.missingEpisodes, isEmpty);
    expect(report.duplicates, hasLength(1));
    expect(
      report.duplicates.single.recommendedKeepPath,
      '/影视库/异兽魔都 (2020)/Season 01/Dorohedoro.S01E01.2160p.HDR10.mkv',
    );
    expect(report.junkCount, 1);
    expect(report.missingAssets, hasLength(1));
  });
}

class _MissingKeyMetadataStub implements MetadataProvider {
  Never _fail() => throw StateError('请先在「设置」里填写 TMDB API key');

  @override
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year}) =>
      _fail();

  @override
  Future<ShowDetail> show(int tmdbId) => _fail();

  @override
  Future<List<Episode>> season(int tmdbId, int season) => _fail();

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) => _fail();

  @override
  Future<MovieDetail> movie(int tmdbId) => _fail();
}
