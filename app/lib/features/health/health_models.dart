import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Filter tabs on the Library Health & Audit page.
enum HealthCategory {
  overview('全部概览'),
  missingEpisodes('缺集'),
  duplicates('重复'),
  missingAssets('缺元数据'),
  cleanup('待清理');

  final String label;

  const HealthCategory(this.label);
}

/// Stages of a read-only library health scan.
enum HealthScanPhase {
  walking('正在扫描目录结构'),
  grouping('正在整理作品与匹配 TMDB'),
  checkingMissing('正在检测缺集与追更进度'),
  probingDuplicates('正在比对重复片源画质'),
  checkingAssets('正在检查 NFO、海报与中文字幕'),
  checkingCleanup('正在扫描垃圾文件与空目录'),
  done('体检完成');

  final String label;

  const HealthScanPhase(this.label);
}

/// Live progress snapshot emitted by [HealthScanner].
@immutable
class HealthScanProgress {
  final HealthScanPhase phase;
  final String message;
  final int dirsVisited;
  final int filesFound;
  final int worksChecked;
  final int totalWorks;
  final double? fraction;

  const HealthScanProgress({
    required this.phase,
    required this.message,
    this.dirsVisited = 0,
    this.filesFound = 0,
    this.worksChecked = 0,
    this.totalWorks = 0,
    this.fraction,
  });
}

/// One missing episode identified by comparing local episodes against TMDB.
@immutable
class MissingEpisodeRef {
  final int season;
  final int episode;
  final String? title;
  final DateTime? airDate;

  /// True when aired after the user's latest local episode (追更提醒);
  /// false when missing internally within owned episodes (缺集断档).
  final bool isNewlyAired;

  const MissingEpisodeRef({
    required this.season,
    required this.episode,
    this.title,
    this.airDate,
    this.isNewlyAired = false,
  });

  String get code =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is MissingEpisodeRef &&
      other.season == season &&
      other.episode == episode &&
      other.isNewlyAired == isNewlyAired;

  @override
  int get hashCode => Object.hash(season, episode, isNewlyAired);

  @override
  String toString() =>
      'MissingEpisodeRef($code, newlyAired=$isNewlyAired, airDate=$airDate)';
}

/// Audit 1: Missing episodes or newly aired episodes for a TV show.
@immutable
class MissingEpisodesIssue {
  final String workTitle;
  final int? tmdbId;
  final String? posterPath;
  final String rootDir;
  final int? year;
  final List<MissingEpisodeRef> internalMissing;
  final List<MissingEpisodeRef> newlyAired;
  final int localEpisodeCount;
  final int airedEpisodeCount;
  final String? latestLocalCode;
  final String? latestAiredCode;

  const MissingEpisodesIssue({
    required this.workTitle,
    this.tmdbId,
    this.posterPath,
    required this.rootDir,
    this.year,
    this.internalMissing = const [],
    this.newlyAired = const [],
    required this.localEpisodeCount,
    required this.airedEpisodeCount,
    this.latestLocalCode,
    this.latestAiredCode,
  });

  int get totalMissing => internalMissing.length + newlyAired.length;

  List<MissingEpisodeRef> get allMissing => [...internalMissing, ...newlyAired];
}

/// One file copy in a duplicate media group, enriched with optional container probe data.
@immutable
class DuplicateMediaCopy {
  final String path;
  final String name;
  final int fileSize;
  final MediaProbeInfo? probe;
  final String? parsedResolution;
  final String? parsedExtraInfo;
  final bool isDiscDir;
  final int qualityRank;

  const DuplicateMediaCopy({
    required this.path,
    required this.name,
    required this.fileSize,
    this.probe,
    this.parsedResolution,
    this.parsedExtraInfo,
    this.isDiscDir = false,
    required this.qualityRank,
  });

  /// Concise quality badges (e.g. `2160p`, `DV`, `Atmos`, `HEVC`).
  List<String> get qualityBadges {
    final badges = <String>[];
    final seen = <String>{};
    void add(String? raw) {
      if (raw == null) return;
      final t = raw.trim();
      if (t.isEmpty) return;
      if (seen.add(t.toLowerCase())) badges.add(t);
    }

    if (isDiscDir) add('原盘');
    add(probe?.resolution ?? parsedResolution);
    if (probe != null) {
      add(probe!.hdr);
      add(probe!.audioCodec);
      if (probe!.audioChannels case final ch? when ch > 0) {
        add(switch (ch) {
          8 => '7.1',
          6 => '5.1',
          2 => '2.0',
          _ => '${ch}ch',
        });
      }
      add(probe!.videoCodec);
    }
    if (parsedExtraInfo != null && parsedExtraInfo!.isNotEmpty) {
      for (final token in parsedExtraInfo!.split(RegExp(r'[\s._]+'))) {
        add(token);
      }
    }
    return badges;
  }

  /// Single-line quality summary (e.g. `2160p · DV · Atmos`).
  String get qualitySummary =>
      qualityBadges.isEmpty ? '未知画质' : qualityBadges.join(' · ');
}

/// Audit 2: Two or more copies of the same movie or TV episode.
@immutable
class DuplicateMediaIssue {
  final String id;
  final String title;
  final MediaKind kind;
  final int? tmdbId;
  final String? posterPath;
  final int? season;
  final int? episode;

  /// Copies sorted best-first; length is always >= 2.
  final List<DuplicateMediaCopy> copies;
  final String recommendedKeepPath;

  const DuplicateMediaIssue({
    required this.id,
    required this.title,
    required this.kind,
    this.tmdbId,
    this.posterPath,
    this.season,
    this.episode,
    required this.copies,
    required this.recommendedKeepPath,
  });

  List<DuplicateMediaCopy> get redundantCopies => [
    for (final c in copies)
      if (c.path != recommendedKeepPath) c,
  ];

  int get reclaimableBytes =>
      redundantCopies.fold<int>(0, (sum, c) => sum + c.fileSize);
}

/// Audit 3: Work missing VidHub/Kodi essentials (NFO, poster, or Chinese subtitle).
@immutable
class MissingAssetIssue {
  final String workTitle;
  final MediaKind kind;
  final int? tmdbId;
  final String? posterPath;

  /// Folder (or loose movie file path) submitted for 「仅刮削补全」.
  final String folderPath;
  final bool missingNfo;
  final bool missingPoster;
  final bool missingChineseSubtitle;

  const MissingAssetIssue({
    required this.workTitle,
    required this.kind,
    this.tmdbId,
    this.posterPath,
    required this.folderPath,
    this.missingNfo = false,
    this.missingPoster = false,
    this.missingChineseSubtitle = false,
  });

  /// True when 「一键仅刮削补全」 can directly generate the missing files.
  bool get canScrapeFix => missingNfo || missingPoster;

  List<String> get missingLabels => [
    if (missingNfo) '缺 NFO',
    if (missingPoster) '缺海报',
    if (missingChineseSubtitle) '无外挂中文字幕',
  ];
}

/// Kind of cleanup item detected by Audit 4.
enum CleanupKind { junkFile, emptyDir }

/// Audit 4: Junk file or empty directory safe to review and remove.
@immutable
class CleanupIssue {
  final String path;
  final String name;
  final CleanupKind kind;
  final int size;
  final String reason;

  const CleanupIssue({
    required this.path,
    required this.name,
    required this.kind,
    this.size = 0,
    required this.reason,
  });
}

/// Complete audit output for one connection root.
@immutable
class HealthReport {
  final ConnectionId connection;
  final String rootDir;
  final DateTime scannedAt;
  final int scannedDirs;
  final int scannedFiles;
  final int totalWorks;

  /// Overall library health score, 0–100.
  final int score;
  final List<MissingEpisodesIssue> missingEpisodes;
  final List<DuplicateMediaIssue> duplicates;
  final List<MissingAssetIssue> missingAssets;
  final List<CleanupIssue> cleanupItems;
  final Map<String, String> skippedDirs;
  final List<String> warnings;

  const HealthReport({
    required this.connection,
    required this.rootDir,
    required this.scannedAt,
    required this.scannedDirs,
    required this.scannedFiles,
    required this.totalWorks,
    required this.score,
    this.missingEpisodes = const [],
    this.duplicates = const [],
    this.missingAssets = const [],
    this.cleanupItems = const [],
    this.skippedDirs = const {},
    this.warnings = const [],
  });

  int get duplicateReclaimableBytes =>
      duplicates.fold<int>(0, (sum, d) => sum + d.reclaimableBytes);

  int get junkBytes => cleanupItems
      .where((c) => c.kind == CleanupKind.junkFile)
      .fold<int>(0, (sum, c) => sum + c.size);

  int get totalReclaimableBytes => duplicateReclaimableBytes + junkBytes;

  int get junkCount =>
      cleanupItems.where((c) => c.kind == CleanupKind.junkFile).length;

  int get emptyDirCount =>
      cleanupItems.where((c) => c.kind == CleanupKind.emptyDir).length;

  int get totalIssues =>
      missingEpisodes.length +
      duplicates.length +
      missingAssets.length +
      cleanupItems.length;

  /// Computes a deterministic 0–100 health score across all 4 audit categories.
  static int computeHealthScore({
    required List<MissingEpisodesIssue> missingEpisodes,
    required List<DuplicateMediaIssue> duplicates,
    required List<MissingAssetIssue> missingAssets,
    required List<CleanupIssue> cleanupItems,
  }) {
    var missingPenalty = 0;
    for (final m in missingEpisodes) {
      missingPenalty += math.min(8, 3 + m.totalMissing);
    }
    missingPenalty = math.min(30, missingPenalty);

    final duplicatePenalty = math.min(25, duplicates.length * 6);

    var assetPenalty = 0;
    for (final a in missingAssets) {
      if (a.missingNfo) assetPenalty += 4;
      if (a.missingPoster) assetPenalty += 3;
      if (a.missingChineseSubtitle) assetPenalty += 1;
    }
    assetPenalty = math.min(25, assetPenalty);

    var cleanupPenalty = 0;
    for (final c in cleanupItems) {
      cleanupPenalty += c.kind == CleanupKind.junkFile ? 2 : 1;
    }
    cleanupPenalty = math.min(20, cleanupPenalty);

    final total =
        missingPenalty + duplicatePenalty + assetPenalty + cleanupPenalty;
    return (100 - total).clamp(0, 100);
  }

  /// Returns a new report after removing user-deleted files and empty dirs,
  /// recalculating remaining duplicates and the overall health score.
  HealthReport withoutDeletedPaths({
    Set<String> deletedFiles = const {},
    Set<String> deletedDirs = const {},
  }) {
    final nextDuplicates = <DuplicateMediaIssue>[];
    for (final d in duplicates) {
      final remaining = [
        for (final c in d.copies)
          if (!deletedFiles.contains(c.path) && !deletedDirs.contains(c.path))
            c,
      ];
      if (remaining.length >= 2) {
        final keep = remaining.any((c) => c.path == d.recommendedKeepPath)
            ? d.recommendedKeepPath
            : remaining.first.path;
        nextDuplicates.add(
          DuplicateMediaIssue(
            id: d.id,
            title: d.title,
            kind: d.kind,
            tmdbId: d.tmdbId,
            posterPath: d.posterPath,
            season: d.season,
            episode: d.episode,
            copies: remaining,
            recommendedKeepPath: keep,
          ),
        );
      }
    }

    final nextCleanup = [
      for (final c in cleanupItems)
        if (!deletedFiles.contains(c.path) && !deletedDirs.contains(c.path)) c,
    ];

    final nextScore = computeHealthScore(
      missingEpisodes: missingEpisodes,
      duplicates: nextDuplicates,
      missingAssets: missingAssets,
      cleanupItems: nextCleanup,
    );

    return HealthReport(
      connection: connection,
      rootDir: rootDir,
      scannedAt: scannedAt,
      scannedDirs: scannedDirs,
      scannedFiles: math.max(0, scannedFiles - deletedFiles.length),
      totalWorks: totalWorks,
      score: nextScore,
      missingEpisodes: missingEpisodes,
      duplicates: nextDuplicates,
      missingAssets: missingAssets,
      cleanupItems: nextCleanup,
      skippedDirs: skippedDirs,
      warnings: warnings,
    );
  }
}
