import '../model/scan.dart';
import '../storage/storage_backend.dart';

/// System metadata junk names that do not count as real user content when
/// checking whether a source folder has become empty after moving files out.
const ignorableEmptyDirFiles = {'.ds_store', 'thumbs.db', 'desktop.ini'};

String _normDir(String raw) {
  var s = raw.trim();
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

int _pathDepth(String path) => '/'.allMatches(path).length;

/// Finds directories in [candidateDirs] (deepest first) that are now empty or
/// contain only ignorable OS metadata files, never touching [protectedRoots].
Future<List<String>> findEmptySourceDirs(
  StorageBackend backend,
  Iterable<String> candidateDirs, {
  Set<String> protectedRoots = const {},
}) async {
  final protected = {
    '/',
    for (final p in protectedRoots)
      if (p.trim().isNotEmpty) _normDir(p),
  };
  final candidates = <String>{
    for (final raw in candidateDirs)
      if (raw.trim().isNotEmpty) _normDir(raw),
  }..removeWhere((d) => d.isEmpty || d == '/' || protected.contains(d));

  final sorted = candidates.toList()
    ..sort((a, b) {
      final dc = _pathDepth(b).compareTo(_pathDepth(a));
      return dc != 0 ? dc : a.compareTo(b);
    });

  final willBeEmpty = <String>{};
  final result = <String>[];
  for (final dir in sorted) {
    final List<RemoteEntry> children;
    try {
      children = await backend.list(dir, refresh: true);
    } on StorageException catch (e) {
      if (e.code == StorageErrorCode.notFound) continue;
      rethrow;
    }
    final empty = children.every((e) {
      if (e.isDir) return willBeEmpty.contains(_normDir(e.path));
      return ignorableEmptyDirFiles.contains(e.name.toLowerCase());
    });
    if (empty) {
      willBeEmpty.add(dir);
      result.add(dir);
    }
  }
  return result;
}
