import 'ids.dart';
import 'media.dart';
import 'metadata.dart';

/// One entry as returned by a [StorageBackend]. [path] is absolute, '/'-separated.
class RemoteEntry {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;

  const RemoteEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified,
  });
}

/// A scanned file after classification and parsing.
class ScanFile {
  final String path;
  final String name;
  final int size;
  final FileRole role;

  /// Null for junk / other files.
  final ParsedName? parsed;

  const ScanFile({
    required this.path,
    required this.name,
    required this.size,
    required this.role,
    this.parsed,
  });
}

/// One movie or one TV show found in a task (a card in the review page).
class MediaGroup {
  final GroupId id;

  /// [MediaKind.movie] or [MediaKind.episode] (TV show).
  final MediaKind kind;

  /// Anchor = what we believe the title is, from folder + most common file title.
  final String anchorTitle;
  final int? anchorYear;

  /// Folder the group was found in (deepest common parent of its files).
  final String rootDir;

  /// Videos, subtitles and sidecars belonging to this group.
  final List<ScanFile> files;

  /// Best TMDB match; null means 待手动识别.
  final Candidate? match;

  /// 0..1 match score.
  final double matchScore;

  /// TV only, for the completeness line "本地 2 季 23 集 / TMDB 2 季 23 集".
  final ShowDetail? show;

  const MediaGroup({
    required this.id,
    required this.kind,
    required this.anchorTitle,
    this.anchorYear,
    required this.rootDir,
    required this.files,
    this.match,
    this.matchScore = 0,
    this.show,
  });
}

class ScanResult {
  final ConnectionId connection;
  final List<String> roots;
  final List<MediaGroup> groups;

  /// Junk and files that belong to no group.
  final List<ScanFile> unassigned;

  const ScanResult({
    required this.connection,
    required this.roots,
    required this.groups,
    this.unassigned = const [],
  });
}
