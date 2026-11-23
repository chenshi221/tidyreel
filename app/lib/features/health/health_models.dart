import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Filter tabs on the lightweight Library Health page.
enum HealthCategory {
  duplicates('重复'),
  missingAssets('缺元数据'),
  cleanup('待清理');

  final String label;

  const HealthCategory(this.label);
}

/// Stages of a read-only local library health scan.
enum HealthScanPhase {
  walking('正在扫描目录'),
  probingDuplicates('正在比对重复片源'),
  checkingAssets('正在检查 NFO 与海报'),
  checkingCleanup('正在扫描垃圾与空目录'),
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
  final double? fraction;

  const HealthScanProgress({
    required this.phase,
    required this.message,
    this.dirsVisited = 0,
    this.filesFound = 0,
    this.fraction,
  });
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

/// Audit 1: Two or more copies of the same movie or TV episode.
@immutable
class DuplicateMediaIssue {
  final String id;
  final String title;
  final MediaKind kind;
  final int? tmdbId;
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

/// Audit 2: Work missing VidHub/Kodi metadata (NFO or poster).
@immutable
class MissingAssetIssue {
  final String workTitle;
  final MediaKind kind;

  /// Folder (or loose movie file path) submitted for 「仅刮削补全」.
  final String folderPath;
  final bool missingNfo;
  final bool missingPoster;

  const MissingAssetIssue({
    required this.workTitle,
    required this.kind,
    required this.folderPath,
    this.missingNfo = false,
    this.missingPoster = false,
  });

  List<String> get missingLabels => [
    if (missingNfo) '缺 NFO',
    if (missingPoster) '缺海报',
  ];
}

/// Kind of cleanup item detected by Audit 3.
enum CleanupKind { junkFile, emptyDir }

/// Audit 3: Junk file or empty directory safe to review and remove.
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

/// Complete lightweight audit output for one connection root.
@immutable
class HealthReport {
  final ConnectionId connection;
  final String rootDir;
  final DateTime scannedAt;
  final int scannedDirs;
  final int scannedFiles;
  final int totalWorks;
  final List<DuplicateMediaIssue> duplicates;
  final List<MissingAssetIssue> missingAssets;
  final List<CleanupIssue> cleanupItems;
  final Map<String, String> skippedDirs;

  const HealthReport({
    required this.connection,
    required this.rootDir,
    required this.scannedAt,
    required this.scannedDirs,
    required this.scannedFiles,
    required this.totalWorks,
    this.duplicates = const [],
    this.missingAssets = const [],
    this.cleanupItems = const [],
    this.skippedDirs = const {},
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
      duplicates.length + missingAssets.length + cleanupItems.length;

  /// First category that has findings, used to land directly on actionable items.
  HealthCategory? get firstNonEmptyCategory {
    if (duplicates.isNotEmpty) return HealthCategory.duplicates;
    if (missingAssets.isNotEmpty) return HealthCategory.missingAssets;
    if (cleanupItems.isNotEmpty) return HealthCategory.cleanup;
    return null;
  }

  /// Returns a new report after removing user-deleted files and empty dirs.
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

    return HealthReport(
      connection: connection,
      rootDir: rootDir,
      scannedAt: scannedAt,
      scannedDirs: scannedDirs,
      scannedFiles: math.max(0, scannedFiles - deletedFiles.length),
      totalWorks: totalWorks,
      duplicates: nextDuplicates,
      missingAssets: missingAssets,
      cleanupItems: nextCleanup,
      skippedDirs: skippedDirs,
    );
  }
}
