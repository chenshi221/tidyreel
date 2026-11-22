import 'dart:convert';
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

const _zhSubTokens = {
  'chs',
  'cht',
  'sc',
  'tc',
  'gb',
  'gbk',
  'gb2312',
  'big5',
  'jpsc',
  'jptc',
  'scjp',
  'tcjp',
  'chseng',
  'chteng',
  'sceng',
  'tceng',
  'chsjp',
  'chtjp',
  'zh',
  'zh-cn',
  'zh-tw',
  'zh-hk',
  'zh-sg',
  'zh-hans',
  'zh-hant',
  'zhs',
  'zht',
  'chi',
  'zho',
  'cn',
  'chinese',
  '中文',
  '简体',
  '繁体',
  '繁體',
  '简中',
  '繁中',
  '简体中文',
  '繁体中文',
  '繁體中文',
  '中字',
  '中英',
  '中英双语',
  '中英雙語',
  '简日',
  '繁日',
  '简英',
  '繁英',
  '简繁',
  '双语',
  '雙語',
};

const _externalSubExts = {'srt', 'ass', 'ssa', 'vtt', 'sup', 'sub', 'idx'};

/// Returns true when a subtitle filename indicates Simplified or Traditional Chinese.
bool isChineseSubtitleFile(String fileName, {String? parsedLang}) {
  final ext = _extOf(fileName);
  if (ext == null || !_externalSubExts.contains(ext)) return false;

  bool matchToken(String raw) {
    final norm = raw.trim().toLowerCase().replaceAll('_', '-');
    if (norm.isEmpty) return false;
    if (_zhSubTokens.contains(norm)) return true;
    for (final part in norm.split(RegExp(r'[&+/,]'))) {
      if (_zhSubTokens.contains(part.trim())) return true;
    }
    return false;
  }

  if (parsedLang != null && matchToken(parsedLang)) return true;

  final stem = p.posix.basenameWithoutExtension(fileName);
  final tokens = stem.split(RegExp(r'[.\s\[\]()（）【】]+'));
  for (final tok in tokens) {
    final clean = tok.replaceAll(RegExp(r'^[-_]+|[-_]+$'), '');
    if (clean.isEmpty) continue;
    if (matchToken(clean)) return true;
    final subParts = clean.toLowerCase().split(RegExp(r'[-_]'));
    for (var i = 0; i < subParts.length; i++) {
      if (i + 1 < subParts.length &&
          _zhSubTokens.contains('${subParts[i]}-${subParts[i + 1]}')) {
        return true;
      }
      if (_zhSubTokens.contains(subParts[i])) return true;
    }
  }
  return false;
}

/// Read-only media library health audit engine for VidHub / NAS libraries.
class HealthScanner {
  final StorageBackend backend;
  final MetadataProvider metadata;
  final FolderStatsStore? folderStatsStore;
  final ConnectionId connectionId;
  final FilenameParser parser;
  final MediaProbe mediaProbe;
  final bool probeMedia;
  final DateTime Function() now;
  final int parallel;
  final TitleRules titleRules;

  HealthScanner({
    required this.backend,
    required this.metadata,
    required this.connectionId,
    this.folderStatsStore,
    this.parser = const RuleBasedParser(),
    this.mediaProbe = const ContainerMediaProbe(),
    this.probeMedia = true,
    DateTime Function()? now,
    this.parallel = 4,
    this.titleRules = const TitleRules(),
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

  static final _nfoRootRe = RegExp(r'<(tvshow|movie)\b', caseSensitive: false);
  static final _nfoTmdbRe = RegExp(
    r'<uniqueid\b[^>]*type="tmdb"[^>]*>\s*(\d+)\s*<|<tmdbid>\s*(\d+)\s*<',
    caseSensitive: false,
  );
  static final _sampleRe = RegExp(
    r'^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]',
    caseSensitive: false,
  );
  static final _nonWordRe = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  /// Performs a read-only audit below [rootDir].
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
      int worksChecked = 0,
      int totalWorks = 0,
      double? fraction,
    }) {
      onProgress?.call(
        HealthScanProgress(
          phase: phase,
          message: message,
          dirsVisited: dirsVisited,
          filesFound: filesFound,
          worksChecked: worksChecked,
          totalWorks: totalWorks,
          fraction: fraction,
        ),
      );
    }

    // ---- Phase 1: Walk directory tree (reusing FolderStatsStore cache) ----
    emit(HealthScanPhase.walking, '正在加载目录列表…', fraction: 0.05);

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
            fraction: 0.15,
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
            fraction: 0.18,
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

    // ---- Phase 2: Classify, group into works, and resolve metadata ----
    emit(
      HealthScanPhase.grouping,
      '正在分类与分组媒体文件…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      fraction: 0.25,
    );

    final filesByDir = <String, List<RemoteEntry>>{};
    final nfoPaths = <String>{};
    final junkFiles = <RemoteEntry>[];
    final videos = <_ScannedVideo>[];
    final subtitles = <_ScannedSub>[];

    for (final e in allFiles) {
      final dir = normalizeDir(p.posix.dirname(e.path));
      (filesByDir[dir] ??= []).add(e);
      if (e.name.toLowerCase().endsWith('.nfo')) nfoPaths.add(e.path);

      final role = parser.classify(e.name);
      switch (role) {
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
        case FileRole.subtitle:
          final chain = _ancestorChain(dir, normRoot);
          final parsed = parser.parse(
            e.name,
            parentDirs: [for (final d in chain) _baseOf(d)],
          );
          subtitles.add(
            _ScannedSub(
              path: e.path,
              name: e.name,
              dir: dir,
              parsed: parsed,
              chain: chain,
            ),
          );
        case FileRole.junk:
          junkFiles.add(e);
        case FileRole.sidecar || FileRole.other:
          break;
      }
    }

    // Add disc folders as indivisible movie video units.
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
    final warnings = <String>[];
    var tmdbMissingKey = false;
    final showCache = <int, ShowDetail?>{};
    final movieCache = <int, MovieDetail?>{};
    final searchCache = <String, List<Candidate>>{};

    for (var i = 0; i < works.length; i++) {
      if (cancelled()) throw const HealthScanCancelled();
      final work = works[i];
      emit(
        HealthScanPhase.grouping,
        '正在识别作品 (${i + 1}/${works.length})：${work.anchorTitle}',
        dirsVisited: dirsVisited,
        filesFound: allFiles.length,
        worksChecked: i,
        totalWorks: works.length,
        fraction: 0.25 + 0.25 * (works.isEmpty ? 1 : (i + 1) / works.length),
      );
      if (tmdbMissingKey) continue;
      final missingKey = await _matchWorkMetadata(
        work,
        nfoPaths: nfoPaths,
        showCache: showCache,
        movieCache: movieCache,
        searchCache: searchCache,
      );
      if (missingKey) {
        tmdbMissingKey = true;
        warnings.add('尚未配置 TMDB API key，缺集检测已跳过，其余本地检查正常完成');
      }
    }

    // ---- Phase 3: Audit 1 — Missing Episodes Radar ----
    emit(
      HealthScanPhase.checkingMissing,
      '正在检测剧集缺集与追更更新…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      worksChecked: 0,
      totalWorks: works.length,
      fraction: 0.55,
    );

    final missingEpisodes = <MissingEpisodesIssue>[];
    if (!tmdbMissingKey) {
      final tvWorksByShow = <int, List<_Work>>{};
      for (final w in works) {
        if (w.kind == MediaKind.episode &&
            w.tmdbId != null &&
            w.showDetail != null) {
          (tvWorksByShow[w.tmdbId!] ??= []).add(w);
        }
      }

      final currentNow = now();
      final showEntries = tvWorksByShow.entries.toList();
      for (var i = 0; i < showEntries.length; i++) {
        if (cancelled()) throw const HealthScanCancelled();
        final tmdbId = showEntries[i].key;
        final groupWorks = showEntries[i].value;
        final primary = groupWorks.first;
        final detail = primary.showDetail!;

        emit(
          HealthScanPhase.checkingMissing,
          '正在核对剧集 (${i + 1}/${showEntries.length})：${detail.info.title}',
          dirsVisited: dirsVisited,
          filesFound: allFiles.length,
          worksChecked: i + 1,
          totalWorks: showEntries.length,
          fraction:
              0.55 +
              0.15 * (showEntries.isEmpty ? 1 : (i + 1) / showEntries.length),
        );

        final issue = await _auditMissingEpisodes(
          tmdbId: tmdbId,
          detail: detail,
          works: groupWorks,
          currentNow: currentNow,
        );
        if (issue != null) missingEpisodes.add(issue);
      }
      missingEpisodes.sort((a, b) => b.totalMissing.compareTo(a.totalMissing));
    }

    // ---- Phase 4: Audit 2 — Duplicate Media & Quality Comparison ----
    emit(
      HealthScanPhase.probingDuplicates,
      '正在比对重复片源画质…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      totalWorks: works.length,
      fraction: 0.72,
    );

    final duplicates = await _auditDuplicates(works, isCancelled: cancelled);
    if (cancelled()) throw const HealthScanCancelled();

    // ---- Phase 5: Audit 3 — Missing NFO / Poster / Chinese Subtitle ----
    emit(
      HealthScanPhase.checkingAssets,
      '正在检查 NFO、海报与外挂中文字幕…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      totalWorks: works.length,
      fraction: 0.85,
    );

    final missingAssets = _auditMissingAssets(
      works,
      filesByDir: filesByDir,
      subtitles: subtitles,
      normRoot: normRoot,
    );

    // ---- Phase 6: Audit 4 — Junk Files & Empty Directories ----
    emit(
      HealthScanPhase.checkingCleanup,
      '正在扫描垃圾文件与空目录…',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      totalWorks: works.length,
      fraction: 0.93,
    );

    final cleanupItems = await _auditCleanup(
      normRoot: normRoot,
      junkFiles: junkFiles,
      listings: listings,
      allDirs: allDirs,
      discDirs: discDirs,
    );
    if (cancelled()) throw const HealthScanCancelled();

    final score = HealthReport.computeHealthScore(
      missingEpisodes: missingEpisodes,
      duplicates: duplicates,
      missingAssets: missingAssets,
      cleanupItems: cleanupItems,
    );

    emit(
      HealthScanPhase.done,
      '体检完成',
      dirsVisited: dirsVisited,
      filesFound: allFiles.length,
      worksChecked: works.length,
      totalWorks: works.length,
      fraction: 1.0,
    );

    return HealthReport(
      connection: connectionId,
      rootDir: normRoot,
      scannedAt: now(),
      scannedDirs: dirsVisited,
      scannedFiles: allFiles.length,
      totalWorks: works.length,
      score: score,
      missingEpisodes: missingEpisodes,
      duplicates: duplicates,
      missingAssets: missingAssets,
      cleanupItems: cleanupItems,
      skippedDirs: skippedDirs,
      warnings: warnings,
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
    return _Work(
      rootDir: rootDir,
      videos: videos,
      anchorTitle: title,
      anchorYear: fileYear ?? folderYear,
      kind: kind,
      ownsDir: ownsDir,
    );
  }

  // ---- Metadata matching (NFO first, then external ID, then TMDB search) --

  /// Returns true when TMDB failed due to missing API key so caller can short-circuit.
  Future<bool> _matchWorkMetadata(
    _Work work, {
    required Set<String> nfoPaths,
    required Map<int, ShowDetail?> showCache,
    required Map<int, MovieDetail?> movieCache,
    required Map<String, List<Candidate>> searchCache,
  }) async {
    Future<ShowDetail?> getShow(int id) async {
      if (showCache.containsKey(id)) return showCache[id];
      final d = await metadata.show(id);
      return showCache[id] = d;
    }

    Future<MovieDetail?> getMovie(int id) async {
      if (movieCache.containsKey(id)) return movieCache[id];
      final d = await metadata.movie(id);
      return movieCache[id] = d;
    }

    try {
      // 1. Existing NFO (<tvshow>/<movie> with <tmdbid> or <uniqueid type="tmdb">)
      final candidateNfos = <String>[
        p.posix.join(work.rootDir, 'tvshow.nfo'),
        p.posix.join(work.rootDir, 'movie.nfo'),
        if (work.videos.length == 1 && !work.videos.first.isDiscDir)
          p.posix.join(
            work.videos.first.dir,
            '${p.posix.basenameWithoutExtension(work.videos.first.name)}.nfo',
          ),
      ];
      for (final nfoPath in candidateNfos) {
        if (!nfoPaths.contains(nfoPath)) continue;
        try {
          final bytes = await backend.read(nfoPath);
          final text = utf8.decode(bytes, allowMalformed: true);
          final root = _nfoRootRe.firstMatch(text)?[1]?.toLowerCase();
          final m = _nfoTmdbRe.firstMatch(text);
          final id = int.tryParse(m?[1] ?? m?[2] ?? '');
          if (root == null || id == null) continue;
          if (root == 'movie') {
            final detail = await getMovie(id);
            if (detail != null) {
              work.kind = MediaKind.movie;
              work.match = detail.info;
              return false;
            }
          } else {
            final detail = await getShow(id);
            if (detail != null) {
              work.kind = MediaKind.episode;
              work.match = detail.info;
              work.showDetail = detail;
              return false;
            }
          }
        } on StateError catch (e) {
          if (_isMissingKeyError(e)) return true;
        } on Object {
          // Malformed NFO or transient failure: fall through to search.
        }
      }

      // 2. Explicit {tmdb-xxx} tag in filename/folder name.
      for (final v in work.videos) {
        final ext = v.parsed.externalId;
        if (ext != null && ext.source == 'tmdb') {
          final id = int.tryParse(ext.id);
          if (id != null) {
            try {
              if (work.kind == MediaKind.movie) {
                final detail = await getMovie(id);
                if (detail != null) {
                  work.match = detail.info;
                  return false;
                }
              } else {
                final detail = await getShow(id);
                if (detail != null) {
                  work.match = detail.info;
                  work.showDetail = detail;
                  return false;
                }
              }
            } on StateError catch (e) {
              if (_isMissingKeyError(e)) return true;
            } on Object {
              // Fall back to search.
            }
          }
        }
      }

      // 3. Title pins from TitleRules.
      final lowAnchor = work.anchorTitle.toLowerCase();
      final pin = titleRules.pins
          .where(
            (pin) =>
                pin.keyword.trim().isNotEmpty &&
                lowAnchor.contains(pin.keyword.trim().toLowerCase()),
          )
          .firstOrNull;
      if (pin != null) {
        work.match = pin.match;
        work.kind = pin.match.kind == MediaKind.movie
            ? MediaKind.movie
            : MediaKind.episode;
        if (work.kind == MediaKind.episode) {
          work.showDetail = await getShow(pin.match.tmdbId);
        }
        return false;
      }

      // 4. Fallback: search TMDB by title (+ year).
      final queries = <String>{
        work.anchorTitle,
        for (final v in work.videos)
          if (v.parsed.title != null && v.parsed.title!.trim().isNotEmpty)
            v.parsed.title!.trim(),
        ...relaxedQueries(work.anchorTitle, _baseOf(work.rootDir)),
      }.where((q) => _normKey(q).isNotEmpty).toList();

      final searchKind = work.kind == MediaKind.movie
          ? MediaKind.movie
          : MediaKind.episode;

      for (final q in queries.take(4)) {
        for (final y in [work.anchorYear, if (work.anchorYear != null) null]) {
          final key = '${searchKind.name}|$q|$y';
          final hits = searchCache.containsKey(key)
              ? searchCache[key]!
              : searchCache[key] = await metadata.search(
                  q,
                  kind: searchKind,
                  year: y,
                );
          Candidate? best;
          var bestScore = 0.0;
          for (final c in hits.take(5)) {
            final s = _scoreCandidate(q, work.anchorYear, c);
            if (s > bestScore) {
              bestScore = s;
              best = c;
            }
          }
          if (best != null && bestScore >= 0.6) {
            work.match = best;
            if (work.kind == MediaKind.episode) {
              work.showDetail = await getShow(best.tmdbId);
            }
            return false;
          }
        }
      }
      return false;
    } on StateError catch (e) {
      return _isMissingKeyError(e);
    } on Object {
      return false;
    }
  }

  // ---- Audit 1: Missing Episodes Radar ------------------------------------

  Future<MissingEpisodesIssue?> _auditMissingEpisodes({
    required int tmdbId,
    required ShowDetail detail,
    required List<_Work> works,
    required DateTime currentNow,
  }) async {
    final regularSeasons = [
      for (final s in detail.seasons)
        if (s.number > 0 && s.episodeCount > 0) s,
    ]..sort((a, b) => a.number.compareTo(b.number));
    if (regularSeasons.isEmpty) return null;

    // Collect owned regular episodes mapped to TMDB season/episode numbers.
    final ownedBySeason = <int, Set<int>>{};
    for (final w in works) {
      for (final v in w.videos) {
        final pInfo = v.parsed;
        if (pInfo.kind == MediaKind.extra ||
            pInfo.kind == MediaKind.special ||
            pInfo.season == 0) {
          continue;
        }
        if (pInfo.episodes.isNotEmpty) {
          final s = pInfo.season ?? 1;
          (ownedBySeason[s] ??= {}).addAll(pInfo.episodes);
        } else if (pInfo.absolute != null) {
          final mapped = _mapAbsoluteToSeason(pInfo.absolute!, regularSeasons);
          if (mapped != null) {
            (ownedBySeason[mapped.$1] ??= {}).add(mapped.$2);
          }
        }
      }
    }
    if (ownedBySeason.isEmpty) return null;

    final maxOwnedSeason = ownedBySeason.keys.reduce(math.max);
    final maxOwnedEpInMaxSeason = ownedBySeason[maxOwnedSeason]!.reduce(
      math.max,
    );
    final localEpisodeCount = ownedBySeason.values.fold<int>(
      0,
      (sum, eps) => sum + eps.length,
    );

    final seasonsToCheck = [
      for (final s in regularSeasons)
        if (ownedBySeason.containsKey(s.number) ||
            (s.number > maxOwnedSeason &&
                (s.airDate == null || s.airDate!.isBefore(currentNow))))
          s,
    ];

    final internalMissing = <MissingEpisodeRef>[];
    final newlyAired = <MissingEpisodeRef>[];
    var airedCount = 0;
    (int, int)? latestAiredPair;

    for (final sInfo in seasonsToCheck) {
      List<Episode> episodes;
      try {
        episodes = await metadata.season(tmdbId, sInfo.number);
      } on Object {
        continue;
      }
      episodes = [...episodes]..sort((a, b) => a.number.compareTo(b.number));
      final owned = ownedBySeason[sInfo.number];
      final maxLocalInSeason = owned == null || owned.isEmpty
          ? 0
          : owned.reduce(math.max);

      for (final ep in episodes) {
        if (ep.number <= 0) continue;
        // Ignore future unaired episodes strictly after `currentNow`.
        if (ep.airDate != null && ep.airDate!.isAfter(currentNow)) continue;

        final isConfirmedAired =
            ep.airDate != null && ep.airDate!.isBefore(currentNow);
        if (isConfirmedAired) {
          airedCount++;
          if (latestAiredPair == null ||
              ep.season > latestAiredPair.$1 ||
              (ep.season == latestAiredPair.$1 &&
                  ep.number > latestAiredPair.$2)) {
            latestAiredPair = (ep.season, ep.number);
          }
        }

        final hasLocally = owned?.contains(ep.number) ?? false;
        if (hasLocally) continue;

        if (owned != null && ep.number < maxLocalInSeason) {
          // Internal gap inside an owned season (even if airDate is null).
          internalMissing.add(
            MissingEpisodeRef(
              season: ep.season,
              episode: ep.number,
              title: ep.title,
              airDate: ep.airDate,
              isNewlyAired: false,
            ),
          );
        } else if (isConfirmedAired) {
          // Aired episode after the user's latest local episode in this season
          // or in a newer aired season.
          newlyAired.add(
            MissingEpisodeRef(
              season: ep.season,
              episode: ep.number,
              title: ep.title,
              airDate: ep.airDate,
              isNewlyAired: true,
            ),
          );
        }
      }
    }

    if (internalMissing.isEmpty && newlyAired.isEmpty) return null;

    String fmtCode(int s, int e) =>
        'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';

    return MissingEpisodesIssue(
      workTitle: detail.info.title,
      tmdbId: tmdbId,
      posterPath: detail.info.posterPath,
      rootDir: works.first.rootDir,
      year: detail.info.year,
      internalMissing: internalMissing,
      newlyAired: newlyAired,
      localEpisodeCount: localEpisodeCount,
      airedEpisodeCount: math.max(airedCount, localEpisodeCount),
      latestLocalCode: fmtCode(maxOwnedSeason, maxOwnedEpInMaxSeason),
      latestAiredCode: latestAiredPair == null
          ? null
          : fmtCode(latestAiredPair.$1, latestAiredPair.$2),
    );
  }

  static (int, int)? _mapAbsoluteToSeason(
    int abs,
    List<SeasonInfo> regularSeasons,
  ) {
    if (abs <= 0) return null;
    var remaining = abs;
    for (final s in regularSeasons) {
      if (remaining <= s.episodeCount) return (s.number, remaining);
      remaining -= s.episodeCount;
    }
    return null;
  }

  // ---- Audit 2: Duplicates & MediaProbe Quality Comparison ----------------

  Future<List<DuplicateMediaIssue>> _auditDuplicates(
    List<_Work> works, {
    required bool Function() isCancelled,
  }) async {
    final buckets = <String, _DupBucket>{};

    for (final w in works) {
      final workTitle = w.match?.title ?? w.anchorTitle;
      final workYear = w.match?.year ?? w.anchorYear;
      final posterPath = w.match?.posterPath;
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
              posterPath: posterPath,
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
                posterPath: posterPath,
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
          posterPath: b.posterPath,
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

  // ---- Audit 3: Missing NFO / Poster / Chinese Subtitle -------------------

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
    required List<_ScannedSub> subtitles,
    required String normRoot,
  }) {
    final issues = <MissingAssetIssue>[];
    for (final w in works) {
      final workDirs = <String>{w.rootDir, for (final v in w.videos) v.dir};

      // Entries directly in w.rootDir (or in movie's own dir).
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
      bool hasNfo;
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

      // 3. Chinese external subtitle check
      final videoStemsLower = {
        for (final v in w.videos)
          p.posix.basenameWithoutExtension(v.name).toLowerCase(),
      };
      bool subBelongsToWork(_ScannedSub s) {
        if (w.ownsDir) {
          return s.dir == w.rootDir || s.dir.startsWith('${w.rootDir}/');
        }
        // Loose movie sharing root dir: match subtitle by video stem prefix.
        if (!workDirs.contains(s.dir)) return false;
        final subStem = p.posix.basenameWithoutExtension(s.name).toLowerCase();
        return videoStemsLower.any(
          (vs) =>
              subStem == vs ||
              subStem.startsWith('$vs.') ||
              subStem.startsWith('$vs '),
        );
      }

      final hasChineseSub = subtitles.any(
        (s) =>
            subBelongsToWork(s) &&
            isChineseSubtitleFile(s.name, parsedLang: s.parsed.lang),
      );

      if (!hasNfo || !hasPoster || !hasChineseSub) {
        final targetPath = w.ownsDir
            ? w.rootDir
            : (w.videos.length == 1 ? w.videos.first.path : w.rootDir);
        issues.add(
          MissingAssetIssue(
            workTitle: w.match?.title ?? w.anchorTitle,
            kind: w.kind,
            tmdbId: w.tmdbId,
            posterPath: w.match?.posterPath,
            folderPath: targetPath,
            missingNfo: !hasNfo,
            missingPoster: !hasPoster,
            missingChineseSubtitle: !hasChineseSub,
          ),
        );
      }
    }

    // Sort scrape-fixable items (missing NFO/poster) ahead of subtitle-only items.
    issues.sort((a, b) {
      final sa = a.canScrapeFix ? 0 : 1;
      final sb = b.canScrapeFix ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return a.workTitle.compareTo(b.workTitle);
    });
    return issues;
  }

  // ---- Audit 4: Junk Files & Empty Directories ----------------------------

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

    // Pre-filter candidate empty directories bottom-up from scanned listings so
    // findEmptySourceDirs only does live refresh checks on plausible empties.
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

  static bool _isMissingKeyError(StateError e) {
    final msg = e.message.toLowerCase();
    return msg.contains('tmdb') && (msg.contains('key') || msg.contains('api'));
  }

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

  static double _scoreCandidate(String query, int? year, Candidate c) {
    final titleSim = [c.title, c.englishTitle, c.originalTitle, ...c.aliases]
        .whereType<String>()
        .map((t) => _titleSimilarity(query, t))
        .fold(0.0, math.max);
    final yearScore = (year == null || c.year == null)
        ? 0.5
        : switch ((year - c.year!).abs()) {
            0 => 1.0,
            1 => 0.7,
            _ => 0.0,
          };
    return 0.75 * titleSim + 0.25 * yearScore;
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

String? _extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i >= name.length - 1) return null;
  return name.substring(i + 1).toLowerCase();
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

class _ScannedSub {
  final String path;
  final String name;
  final String dir;
  final ParsedName parsed;
  final List<String> chain;

  const _ScannedSub({
    required this.path,
    required this.name,
    required this.dir,
    required this.parsed,
    required this.chain,
  });
}

class _Work {
  final String rootDir;
  final List<_ScannedVideo> videos;
  final String anchorTitle;
  final int? anchorYear;
  MediaKind kind;
  final bool ownsDir;
  Candidate? match;
  ShowDetail? showDetail;

  _Work({
    required this.rootDir,
    required this.videos,
    required this.anchorTitle,
    required this.anchorYear,
    required this.kind,
    required this.ownsDir,
  });

  int? get tmdbId => match?.tmdbId;
}

class _DupBucket {
  final String id;
  final String title;
  final MediaKind kind;
  final int? tmdbId;
  final String? posterPath;
  final int? season;
  final int? episode;
  final videos = <String, _ScannedVideo>{};

  _DupBucket({
    required this.id,
    required this.title,
    required this.kind,
    this.tmdbId,
    this.posterPath,
    this.season,
    this.episode,
  });
}
