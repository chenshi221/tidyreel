import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/folder_stats_store.dart';
import 'health_models.dart';

/// Ranks a media copy so duplicates can be sorted best-first:
/// higher resolution > HDR/DV > lossless audio > larger file size.
int computeMediaQualityRank({
  MediaProbeInfo? probe,
  String? parsedResolution,
  String? parsedExtraInfo,
  required int fileSize,
  bool isDiscDir = false,
}) {
  final extra = (parsedExtraInfo ?? '').toLowerCase();
  final resText = (probe?.resolution ?? parsedResolution ?? extra)
      .toLowerCase();
  final resScore = _resolutionTier(resText, isDiscDir: isDiscDir);

  final hdrText = (probe?.hdr ?? extra).toLowerCase();
  final hdrScore = _hdrTier(hdrText);

  final audioText = (probe?.audioCodec ?? extra).toLowerCase();
  final audioScore = _audioTier(audioText);

  final sizeScore = fileSize <= 0
      ? 0
      : math.min(999, fileSize ~/ (100 * 1024 * 1024));

  return resScore * 1000000 + hdrScore * 10000 + audioScore * 1000 + sizeScore;
}

int _resolutionTier(String text, {required bool isDiscDir}) {
  if (text.contains('4320') || text.contains('8k')) return 70;
  if (text.contains('2160') || text.contains('4k') || text.contains('uhd')) {
    return 60;
  }
  if (text.contains('1440') || text.contains('2k')) return 45;
  if (text.contains('1080') || text.contains('fhd')) return 40;
  if (text.contains('720')) return 30;
  if (text.contains('576')) return 20;
  if (text.contains('480')) return 15;
  return isDiscDir ? 45 : 10;
}

int _hdrTier(String text) {
  if (RegExp(r'(?:^|[^a-z0-9])(?:dv|dovi|dolby[\s._-]?vision)(?:$|[^a-z0-9])')
      .hasMatch(text)) {
    return 40;
  }
  if (text.contains('hdr10+') || text.contains('hdr10plus')) return 30;
  if (text.contains('hdr10') ||
      RegExp(r'(?:^|[^a-z0-9])hdr(?:$|[^a-z0-9])').hasMatch(text)) {
    return 20;
  }
  if (RegExp(r'(?:^|[^a-z0-9])hlg(?:$|[^a-z0-9])').hasMatch(text)) return 10;
  return 0;
}

int _audioTier(String text) {
  if (text.contains('atmos') ||
      text.contains('dts-x') ||
      text.contains('dtsx')) {
    return 5;
  }
  if (text.contains('truehd') ||
      text.contains('dts-hd') ||
      text.contains('dtshd')) {
    return 4;
  }
  if (text.contains('flac') || text.contains('lpcm')) return 3;
  if (text.contains('eac3') ||
      text.contains('ddp') ||
      RegExp(r'(?:^|[^a-z0-9])dts(?:$|[^a-z0-9])').hasMatch(text)) {
    return 2;
  }
  if (text.contains('ac3') || text.contains('aac') || text.contains('opus')) {
    return 1;
  }
  return 0;
}

/// Lightweight, read-only local media library scanner (zero TMDB requests).
///
/// Checks only three concrete, actionable issues:
/// 1. Duplicate copies of the same movie or TV episode (with optional MediaProbe).
/// 2. Missing VidHub/Kodi NFO or poster artwork (fixable via scrape-only).
/// 3. Junk files and verified empty directories.
class HealthScanner {
  final StorageBackend backend;
  final FolderStatsStore? folderStatsStore;
  final ConnectionId connectionId;
  final FilenameParser parser;
  final MediaProbe mediaProbe;
  final bool probeMedia;
  final DateTime Function() now;
  final int parallel;

  HealthScanner({
    required this.backend,
    required this.connectionId,
    this.folderStatsStore,
    this.parser = const RuleBasedParser(),
    this.mediaProbe = const ContainerMediaProbe(),
    this.probeMedia = true,
    DateTime Function()? now,
    this.parallel = 4,
  }) : now = now ?? DateTime.now;

  static final _structuralDirRe = RegExp(
    r'^(season|series)[\s._\-]*\d+.*$|^s\d{1,2}$|^第\s*[0-9一二三四五六七八九十百]+\s*[季部].*$|'
    r'^(specials?|sp|ova|oad|extras?|featurettes?|behind the scenes|bonus|'
    r'特别篇|特典|花絮|番外|subs?|subtitles?|字幕)$|'
    r'^(\d{3,4}[pi]|[248]k|uhd|fhd|hdr(10)?\+?|dv|dolby[\s._-]?vision|杜比视界|'
    r'blu-?ray|web-?dl|remux|高清|超清|蓝光|原盘|国语|粤语|国配|中字|普通话)$',
    caseSensitive: false,
  );

  static final _genericContainerDirRe = RegExp(
    r'^(?:tv|tv ?shows?|series|movies?|films?|anime|animations?|downloads?|videos?|media|library|'
    r'电视剧|电影|动漫|动画|番剧|综艺|纪录片|剧集|影视|影视库|新番|国产剧|美剧|日剧|韩剧|欧美剧|港剧|电视|下载|完成|视频)$',
    caseSensitive: false,
  );

  static final _sampleRe = RegExp(
    r'^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]',
    caseSensitive: false,
  );
  static final _nonWordRe = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  /// Performs a fast read-only audit below [rootDir] without calling TMDB.
  Future<HealthReport> scan(
    String rootDir, {
    bool fresh = false,
    void Function(HealthScanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final normRoot = normalizeDir(rootDir);
    bool cancelled() => isCancelled?.call() ?? false;
    void emit(
      HealthScanPhase phase,
      String message, {
      int dirsVisited = 0,
      int filesFound = 0,
      double? fraction,
    }) {
      onProgress?.call(
        HealthScanProgress(
          phase: phase,
          message: message,
          dirsVisited: dirsVisited,
          filesFound: filesFound,
          fraction: fraction,
        ),
      );
    }

    // ---- Phase 1: Walk directory tree (reusing FolderStatsStore cache) ----
    emit(HealthScanPhase.walking, '正在加载目录列表…', fraction: 0.08);

    final cachedByDir = <String, List<RemoteEntry>>{};
    if (!fresh && folderStatsStore != null) {
      try {
        final rows = await folderStatsStore!.loadFor(connectionId);
        for (final row in rows) {
          cachedByDir[normalizeDir(row.dirPath)] = row.entries;
        }
      } on Object {
        // Ignore cache read failures; walk live instead.
      }
    }

    final listings = <String, List<RemoteEntry>>{};
    final skippedDirs = <String, String>{};
    final discDirs = <String>{};
    final allFiles = <RemoteEntry>[];
    final allDirs = <String>{normRoot};
    var dirsVisited = 0;

    await walkDirs(
      [normRoot],
      (dir) async {
        final normDir = normalizeDir(dir);
        List<RemoteEntry> entries;
        final cached = !fresh ? cachedByDir[normDir] : null;
        if (cached != null) {
          entries = cached;
        } else {
          try {
            entries = await backend.list(normDir, refresh: fresh);
          } on StorageException catch (e) {
            if (normDir == normRoot ||
                e.code == StorageErrorCode.unauthorized ||
                e.code == StorageErrorCode.network ||
                e.code == StorageErrorCode.rateLimited) {
              rethrow;
            }
            skippedDirs[normDir] = e.message;
            return const <String>[];
          }
          if (folderStatsStore != null) {
            try {
              await folderStatsStore!.saveDir(connectionId, normDir, entries);
            } on Object {
              // Best-effort cache write.
            }
          }
        }

        listings[normDir] = entries;
        dirsVisited++;

        // Respect Blu-ray (BDMV) / DVD (VIDEO_TS) disc folders.
        final hasDiscChild = entries.any(
          (e) =>
              e.isDir &&
              (e.name.toUpperCase() == 'BDMV' ||
                  e.name.toUpperCase() == 'VIDEO_TS'),
        );
        if (hasDiscChild && normDir != '/') {
          discDirs.add(normDir);
          for (final e in entries) {
            if (!e.isDir) allFiles.add(e);
          }
          emit(
            HealthScanPhase.walking,
            '已扫描 $dirsVisited 个目录 · ${allFiles.length} 个文件',
            dirsVisited: dirsVisited,
            filesFound: allFiles.length,
            fraction: 0.35,
          );
          return const <String>[];
        }

        final subdirs = <String>[];
        for (final e in entries) {
          if (e.isDir) {
            final childDir = normalizeDir(e.path);
            final upper = e.name.toUpperCase();
            if (upper == 'BDMV' || upper == 'VIDEO_TS') continue;
            allDirs.add(childDir);
            subdirs.add(childDir);
          } else {
            allFiles.add(e);
          }
        }

        if (dirsVisited == 1 || dirsVisited % 5 == 0) {
          emit(
            HealthScanPhase.walking,
            '已扫描 $dirsVisited 个目录 · ${allFiles.length} 个文件',
            dirsVisited: dirsVisited,
            filesFound: allFiles.length,
            fraction: 0.40,
          );
        }
        return subdirs;
      },
      parallel: parallel,
      stop: cancelled,
    );

    if (cancelled()) throw const HealthScanCancelled();

    if (folderStatsStore != null && listings.containsKey(normRoot)) {
      try {
        await folderStatsStore!.markComplete(connectionId, normRoot);
      } on Object {
        // Ignore cache mark failure.
      }
    }

    // ---- Classify & group works purely locally ----
    final filesByDir = <String, List<RemoteEntry>>{};
    final junkFiles = <RemoteEntry>[];
    final videos = <_ScannedVideo>[];

    for (final e in allFiles) {
      final dir = normalizeDir(p.posix.dirname(e.path));
      (filesByDir[dir] ??= []).add(e);

      switch (parser.classify(e.name)) {
        case FileRole.video:
          final chain = _ancestorChain(dir, normRoot);
          final parsed = parser.parse(
            e.name,
            parentDirs: [for (final d in chain) _baseOf(d)],
          );
          videos.add(
            _ScannedVideo(
              path: e.path,
              name: e.name,
              dir: dir,
              size: e.size,
              parsed: parsed,
              chain: chain,
              isDiscDir: false,
            ),
          );
        case FileRole.junk:
          junkFiles.add(e);
        case FileRole.subtitle || FileRole.sidecar || FileRole.other:
          break;
      }
    }

    // Add disc folders as indivisible movie units.
    for (final discDir in discDirs.toList()..sort()) {
      final parentDir = normalizeDir(p.posix.dirname(discDir));
      final parentChain = _ancestorChain(parentDir, normRoot);
      final parsed = parser
          .parse(
            _baseOf(discDir),
            parentDirs: [for (final d in parentChain) _baseOf(d)],
          )
          .copyWith(isDisc: true, kind: MediaKind.movie);
      final discSize = (filesByDir[discDir] ?? const <RemoteEntry>[]).fold<int>(
        0,
        (sum, e) => sum + e.size,
      );
      videos.add(
        _ScannedVideo(
          path: discDir,
          name: _baseOf(discDir),
          dir: discDir,
          size: discSize,
          parsed: parsed,
          chain: [discDir, ...parentChain],
          isDiscDir: true,
        ),
      );
    }

    final works = _groupWorks(videos, normRoot);

    // ---- Phase 2: Audit 1 — Duplicate Media & Quality Comparison ----
    emit(
      HealthScanPhase.probingDuplicates,
      '正在比对重复片源…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      fraction: 0.60,
    );

    final duplicates = await _auditDuplicates(works, isCancelled: cancelled);
    if (cancelled()) throw const HealthScanCancelled();

    // ---- Phase 3: Audit 2 — Missing NFO / Poster ----
    emit(
      HealthScanPhase.checkingAssets,
      '正在检查 NFO 与海报…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      fraction: 0.78,
    );

    final missingAssets = _auditMissingAssets(works, filesByDir: filesByDir);

    // ---- Phase 4: Audit 3 — Junk Files & Empty Directories ----
    emit(
      HealthScanPhase.checkingCleanup,
      '正在扫描垃圾文件与空目录…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      fraction: 0.90,
    );

    final cleanupItems = await _auditCleanup(
      normRoot: normRoot,
      junkFiles: junkFiles,
      listings: listings,
      allDirs: allDirs,
      discDirs: discDirs,
    );
    if (cancelled()) throw const HealthScanCancelled();

    emit(
      HealthScanPhase.done,
      '体检完成',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      fraction: 1.0,
    );

    return HealthReport(
      connection: connectionId,
      rootDir: normRoot,
      scannedAt: now(),
      scannedDirs: dirsVisited,
      scannedFiles: allFiles.length,
      totalWorks: works.length,
      duplicates: duplicates,
      missingAssets: missingAssets,
      cleanupItems: cleanupItems,
      skippedDirs: skippedDirs,
    );
  }

  // ---- Grouping -----------------------------------------------------------

  List<_Work> _groupWorks(List<_ScannedVideo> videos, String normRoot) {
    final buckets = <String, List<_ScannedVideo>>{};
    final works = <_Work>[];

    for (final v in videos) {
      if (v.isDiscDir) {
        works.add(
          _Work(
            rootDir: v.path,
            videos: [v],
            anchorTitle: v.parsed.title ?? v.name,
            anchorYear: v.parsed.year,
            kind: MediaKind.movie,
            ownsDir: true,
            tmdbId: _extractTmdbId([v]),
          ),
        );
        continue;
      }
      final titleDir = v.chain
          .where((d) => d != '/' && !_structuralDirRe.hasMatch(_baseOf(d)))
          .firstOrNull;
      final dir = titleDir ?? v.dir;
      (buckets[dir] ??= []).add(v);
    }

    for (final entry in buckets.entries) {
      final dir = entry.key;
      final vs = entry.value;
      final dirBase = _baseOf(dir);
      final isGenericOrRoot =
          dir == normRoot ||
          dir == '/' ||
          _genericContainerDirRe.hasMatch(dirBase);
      final folderParsed = isGenericOrRoot ? null : parser.parse(dirBase);
      final folderTitle = folderParsed?.title?.trim();

      final byTitle = <String, List<_ScannedVideo>>{};
      for (final v in vs) {
        final key = _normKey(v.parsed.title ?? '');
        (byTitle[key] ??= []).add(v);
      }
      final keys = byTitle.keys.where((k) => k.isNotEmpty).toList()
        ..sort((a, b) => byTitle[b]!.length.compareTo(byTitle[a]!.length));

      var shouldSplit = false;
      if (keys.length >= 2) {
        final explainedByFolder =
            folderTitle != null &&
            folderTitle.isNotEmpty &&
            keys.any((k) => _titleSimilarity(folderTitle, k) >= 0.6);
        final dominant = byTitle[keys.first]!.length / vs.length > 0.6;
        shouldSplit = isGenericOrRoot || !(explainedByFolder || dominant);
      }

      if (!shouldSplit) {
        works.add(
          _makeWork(
            rootDir: dir,
            videos: vs,
            folderTitle: folderTitle,
            folderYear: folderParsed?.year,
            folderExternalId: folderParsed?.externalId,
            ownsDir: !isGenericOrRoot || vs.length == videos.length,
          ),
        );
      } else {
        final untitled = byTitle[''] ?? const <_ScannedVideo>[];
        for (var i = 0; i < keys.length; i++) {
          final groupVs = [...byTitle[keys[i]]!, if (i == 0) ...untitled];
          works.add(
            _makeWork(
              rootDir: dir,
              videos: groupVs,
              folderTitle: null,
              folderYear: null,
              folderExternalId: null,
              ownsDir: false,
            ),
          );
        }
      }
    }

    works.sort((a, b) {
      final c = a.rootDir.compareTo(b.rootDir);
      return c != 0 ? c : a.anchorTitle.compareTo(b.anchorTitle);
    });
    return works;
  }

  _Work _makeWork({
    required String rootDir,
    required List<_ScannedVideo> videos,
    required String? folderTitle,
    required int? folderYear,
    required ExternalId? folderExternalId,
    required bool ownsDir,
  }) {
    final mainVideos = [
      for (final v in videos)
        if (v.parsed.kind != MediaKind.extra) v,
    ];
    final tvVotes = mainVideos.where((v) => _looksTv(v.parsed)).length;
    final kind = mainVideos.isNotEmpty && tvVotes * 2 > mainVideos.length
        ? MediaKind.episode
        : MediaKind.movie;

    final fileTitle = _mostCommon([
      for (final v in videos)
        if (v.parsed.title != null && v.parsed.title!.trim().isNotEmpty)
          v.parsed.title!.trim(),
    ]);
    final fileYear = _mostCommonInt([
      for (final v in videos)
        if (v.parsed.year != null) v.parsed.year!,
    ]);

    final title = (folderTitle != null && folderTitle.isNotEmpty)
        ? folderTitle
        : (fileTitle ??
              (videos.isNotEmpty
                  ? p.posix.basenameWithoutExtension(videos.first.name)
                  : _baseOf(rootDir)));
    final tmdbId =
        (folderExternalId?.source == 'tmdb'
            ? int.tryParse(folderExternalId!.id)
            : null) ??
        _extractTmdbId(videos);

    return _Work(
      rootDir: rootDir,
      videos: videos,
      anchorTitle: title,
      anchorYear: fileYear ?? folderYear,
      kind: kind,
      ownsDir: ownsDir,
      tmdbId: tmdbId,
    );
  }

  static int? _extractTmdbId(List<_ScannedVideo> videos) {
    for (final v in videos) {
      final ext = v.parsed.externalId;
      if (ext != null && ext.source == 'tmdb') {
        final id = int.tryParse(ext.id);
        if (id != null) return id;
      }
    }
    return null;
  }

  // ---- Audit 1: Duplicates & MediaProbe Quality Comparison ----------------

  Future<List<DuplicateMediaIssue>> _auditDuplicates(
    List<_Work> works, {
    required bool Function() isCancelled,
  }) async {
    final buckets = <String, _DupBucket>{};

    for (final w in works) {
      final workTitle = w.anchorTitle;
      final workYear = w.anchorYear;
      final tmdbId = w.tmdbId;

      for (final v in w.videos) {
        if (v.parsed.kind == MediaKind.extra) continue;
        final partKey = v.parsed.part ?? 0;

        if (w.kind == MediaKind.movie) {
          final normT = _normKey(workTitle);
          if (tmdbId == null && normT.isEmpty) continue;
          final key = tmdbId != null
              ? 'movie:tmdb:$tmdbId:p$partKey'
              : 'movie:title:$normT:${workYear ?? 0}:p$partKey';
          final label = workYear != null ? '$workTitle ($workYear)' : workTitle;
          final bucket = buckets.putIfAbsent(
            key,
            () => _DupBucket(
              id: 'dup-${stableHash(key)}',
              title: label,
              kind: MediaKind.movie,
              tmdbId: tmdbId,
            ),
          );
          bucket.videos[v.path] = v;
        } else {
          final showKey = tmdbId != null
              ? 'tmdb:$tmdbId'
              : 'title:${_normKey(workTitle)}';
          if (tmdbId == null && _normKey(workTitle).isEmpty) continue;

          final eps = v.parsed.episodes.isNotEmpty
              ? v.parsed.episodes
              : (v.parsed.absolute != null
                    ? [v.parsed.absolute!]
                    : const <int>[]);
          if (eps.isEmpty) continue;

          final season = v.parsed.kind == MediaKind.special
              ? 0
              : (v.parsed.season ?? 1);
          for (final ep in eps) {
            final key = 'tv:$showKey:s$season:e$ep:p$partKey';
            final code =
                'S${season.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
            final bucket = buckets.putIfAbsent(
              key,
              () => _DupBucket(
                id: 'dup-${stableHash(key)}',
                title: '$workTitle $code',
                kind: MediaKind.episode,
                tmdbId: tmdbId,
                season: season,
                episode: ep,
              ),
            );
            bucket.videos[v.path] = v;
          }
        }
      }
    }

    final candidateBuckets = [
      for (final b in buckets.values)
        if (b.videos.length >= 2) b,
    ];
    if (candidateBuckets.isEmpty) return const [];

    // Probe ONLY duplicate candidate video files (bounded concurrency).
    final probeResults = <String, MediaProbeInfo?>{};
    if (probeMedia) {
      final toProbe = <String, _ScannedVideo>{};
      for (final b in candidateBuckets) {
        for (final v in b.videos.values) {
          if (!v.isDiscDir) toProbe[v.path] = v;
        }
      }
      final list = toProbe.values.toList();
      var next = 0;
      Future<void> worker() async {
        while (!isCancelled() && next < list.length) {
          final v = list[next++];
          try {
            probeResults[v.path] = await mediaProbe.probe(
              backend,
              v.path,
              fileSize: v.size,
            );
          } on Object {
            probeResults[v.path] = null;
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < math.min(4, list.length); i++) worker(),
      ]);
    }

    final issues = <DuplicateMediaIssue>[];
    for (final b in candidateBuckets) {
      final copies =
          [
            for (final v in b.videos.values)
              DuplicateMediaCopy(
                path: v.path,
                name: v.name,
                fileSize: v.size,
                probe: probeResults[v.path],
                parsedResolution: v.parsed.resolution,
                parsedExtraInfo: v.parsed.extraInfo,
                isDiscDir: v.isDiscDir,
                qualityRank: computeMediaQualityRank(
                  probe: probeResults[v.path],
                  parsedResolution: v.parsed.resolution,
                  parsedExtraInfo: v.parsed.extraInfo,
                  fileSize: v.size,
                  isDiscDir: v.isDiscDir,
                ),
              ),
          ]..sort((a, b) {
            final rc = b.qualityRank.compareTo(a.qualityRank);
            if (rc != 0) return rc;
            final sc = b.fileSize.compareTo(a.fileSize);
            if (sc != 0) return sc;
            return a.path.compareTo(b.path);
          });

      issues.add(
        DuplicateMediaIssue(
          id: b.id,
          title: b.title,
          kind: b.kind,
          tmdbId: b.tmdbId,
          season: b.season,
          episode: b.episode,
          copies: copies,
          recommendedKeepPath: copies.first.path,
        ),
      );
    }

    issues.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));
    return issues;
  }

  // ---- Audit 2: Missing NFO / Poster --------------------------------------

  static const _posterNames = {
    'poster.jpg',
    'poster.jpeg',
    'poster.png',
    'poster.webp',
    'folder.jpg',
    'folder.jpeg',
    'folder.png',
    'folder.webp',
  };

  List<MissingAssetIssue> _auditMissingAssets(
    List<_Work> works, {
    required Map<String, List<RemoteEntry>> filesByDir,
  }) {
    final issues = <MissingAssetIssue>[];
    for (final w in works) {
      final workDirs = <String>{w.rootDir, for (final v in w.videos) v.dir};

      final rootEntries = filesByDir[w.rootDir] ?? const <RemoteEntry>[];
      final rootNamesLower = {
        for (final e in rootEntries) e.name.toLowerCase(),
      };

      final allVideoDirEntries = <RemoteEntry>[
        for (final d in workDirs) ...(filesByDir[d] ?? const <RemoteEntry>[]),
      ];
      final allVideoDirNamesLower = {
        for (final e in allVideoDirEntries) e.name.toLowerCase(),
      };

      // 1. NFO check
      final bool hasNfo;
      if (w.kind == MediaKind.episode) {
        hasNfo = rootNamesLower.contains('tvshow.nfo');
      } else {
        hasNfo =
            rootNamesLower.contains('movie.nfo') ||
            w.videos.any((v) {
              if (v.isDiscDir) return rootNamesLower.contains('movie.nfo');
              final nfoName =
                  '${p.posix.basenameWithoutExtension(v.name).toLowerCase()}.nfo';
              final dirNames = {
                for (final e in filesByDir[v.dir] ?? const <RemoteEntry>[])
                  e.name.toLowerCase(),
              };
              return dirNames.contains(nfoName) ||
                  dirNames.contains('movie.nfo');
            });
      }

      // 2. Poster check
      final hasPoster =
          rootNamesLower.any(_posterNames.contains) ||
          allVideoDirNamesLower.any(_posterNames.contains) ||
          w.videos.any((v) {
            if (v.isDiscDir) return false;
            final stemLower = p.posix
                .basenameWithoutExtension(v.name)
                .toLowerCase();
            final dirNames = {
              for (final e in filesByDir[v.dir] ?? const <RemoteEntry>[])
                e.name.toLowerCase(),
            };
            return dirNames.contains('$stemLower-poster.jpg') ||
                dirNames.contains('$stemLower-poster.jpeg') ||
                dirNames.contains('$stemLower-poster.png') ||
                dirNames.contains('$stemLower-poster.webp');
          });

      if (!hasNfo || !hasPoster) {
        final targetPath = w.ownsDir
            ? w.rootDir
            : (w.videos.length == 1 ? w.videos.first.path : w.rootDir);
        issues.add(
          MissingAssetIssue(
            workTitle: w.anchorTitle,
            kind: w.kind,
            folderPath: targetPath,
            missingNfo: !hasNfo,
            missingPoster: !hasPoster,
          ),
        );
      }
    }

    issues.sort((a, b) => a.workTitle.compareTo(b.workTitle));
    return issues;
  }

  // ---- Audit 3: Junk Files & Empty Directories ----------------------------

  Future<List<CleanupIssue>> _auditCleanup({
    required String normRoot,
    required List<RemoteEntry> junkFiles,
    required Map<String, List<RemoteEntry>> listings,
    required Set<String> allDirs,
    required Set<String> discDirs,
  }) async {
    final items = <CleanupIssue>[];

    for (final f in junkFiles) {
      final low = f.name.toLowerCase();
      final stem = p.posix.basenameWithoutExtension(f.name);
      final reason =
          low.startsWith('._') || ignorableEmptyDirFiles.contains(low)
          ? '系统隐藏垃圾'
          : _sampleRe.hasMatch(stem)
          ? '样片文件'
          : '广告 / 垃圾文件';
      items.add(
        CleanupIssue(
          path: f.path,
          name: f.name,
          kind: CleanupKind.junkFile,
          size: f.size,
          reason: reason,
        ),
      );
    }

    bool insideDisc(String dir) =>
        discDirs.any((d) => dir == d || dir.startsWith('$d/'));

    final sortedDirs =
        [
          for (final d in allDirs)
            if (d != '/' && d != normRoot && !insideDisc(d)) d,
        ]..sort(
          (a, b) =>
              '/'.allMatches(b).length.compareTo('/'.allMatches(a).length),
        );

    final likelyEmpty = <String>{};
    for (final dir in sortedDirs) {
      final entries = listings[dir];
      if (entries == null) continue;
      final isEmpty = entries.every((e) {
        if (e.isDir) return likelyEmpty.contains(normalizeDir(e.path));
        return ignorableEmptyDirFiles.contains(e.name.toLowerCase());
      });
      if (isEmpty) likelyEmpty.add(dir);
    }

    if (likelyEmpty.isNotEmpty) {
      try {
        final verifiedEmpty = await findEmptySourceDirs(
          backend,
          likelyEmpty,
          protectedRoots: {normRoot, '/'},
        );
        for (final dir in verifiedEmpty) {
          items.add(
            CleanupIssue(
              path: dir,
              name: _baseOf(dir),
              kind: CleanupKind.emptyDir,
              size: 0,
              reason: '空目录',
            ),
          );
        }
      } on Object {
        // Keep junk files even if live empty-dir verification fails.
      }
    }

    items.sort((a, b) {
      if (a.kind != b.kind) {
        return a.kind == CleanupKind.junkFile ? -1 : 1;
      }
      return a.path.compareTo(b.path);
    });
    return items;
  }

  // ---- Helpers ------------------------------------------------------------

  static bool _looksTv(ParsedName p) =>
      p.kind == MediaKind.episode ||
      p.kind == MediaKind.special ||
      p.season != null ||
      p.episodes.isNotEmpty ||
      p.absolute != null;

  static List<String> _ancestorChain(String dir, String root) {
    final chain = <String>[];
    var cur = normalizeDir(dir);
    final normRoot = normalizeDir(root);
    while (true) {
      chain.add(cur);
      if (cur == normRoot || cur == '/') break;
      final parent = normalizeDir(p.posix.dirname(cur));
      if (parent == cur) break;
      cur = parent;
    }
    return chain;
  }

  static String _baseOf(String dir) {
    if (dir == '/' || dir.isEmpty) return '';
    return p.posix.basename(dir);
  }

  static String _normKey(String s) =>
      s.toLowerCase().replaceAll(_nonWordRe, '');

  static double _titleSimilarity(String a, String b) {
    final na = _normKey(a);
    final nb = _normKey(b);
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;
    if (na.contains(nb) || nb.contains(na)) {
      final minLen = math.min(na.length, nb.length);
      final maxLen = math.max(na.length, nb.length);
      return 0.7 + 0.3 * (minLen / maxLen);
    }
    final ra = na.runes.toSet();
    final rb = nb.runes.toSet();
    final inter = ra.intersection(rb).length;
    final union = ra.union(rb).length;
    return union == 0 ? 0 : inter / union;
  }

  static String? _mostCommon(List<String> items) {
    if (items.isEmpty) return null;
    final counts = <String, int>{};
    final first = <String, String>{};
    for (final x in items) {
      final k = _normKey(x);
      if (k.isEmpty) continue;
      counts.update(k, (v) => v + 1, ifAbsent: () => 1);
      first.putIfAbsent(k, () => x);
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
    return first[best.key];
  }

  static int? _mostCommonInt(List<int> items) {
    if (items.isEmpty) return null;
    final counts = <int, int>{};
    for (final x in items) {
      counts.update(x, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}

/// Thrown internally when a health scan is cancelled by the user.
class HealthScanCancelled implements Exception {
  const HealthScanCancelled();
}

class _ScannedVideo {
  final String path;
  final String name;
  final String dir;
  final int size;
  final ParsedName parsed;
  final List<String> chain;
  final bool isDiscDir;

  const _ScannedVideo({
    required this.path,
    required this.name,
    required this.dir,
    required this.size,
    required this.parsed,
    required this.chain,
    required this.isDiscDir,
  });
}

class _Work {
  final String rootDir;
  final List<_ScannedVideo> videos;
  final String anchorTitle;
  final int? anchorYear;
  final MediaKind kind;
  final bool ownsDir;
  final int? tmdbId;

  const _Work({
    required this.rootDir,
    required this.videos,
    required this.anchorTitle,
    this.anchorYear,
    required this.kind,
    required this.ownsDir,
    this.tmdbId,
  });
}

class _DupBucket {
  final String id;
  final String title;
  final MediaKind kind;
  final int? tmdbId;
  final int? season;
  final int? episode;
  final Map<String, _ScannedVideo> videos = {};

  _DupBucket({
    required this.id,
    required this.title,
    required this.kind,
    this.tmdbId,
    this.season,
    this.episode,
  });
}
