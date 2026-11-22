import '../storage/storage_backend.dart';

/// System metadata junk names that do not count as real user content when
/// checking whether a source folder has become empty after moving files out.
const ignorableEmptyDirFiles = {'.ds_store', 'thumbs.db', 'desktop.ini'};

/// Finds directories in [candidateDirs] (deepest first) that are now empty or
/// contain only ignorable OS metadata files, never touching [protectedRoots].
/// Implemented by Worker 4 (`core-recognizer-planner`).
Future<List<String>> findEmptySourceDirs(
  StorageBackend backend,
  Iterable<String> candidateDirs, {
  Set<String> protectedRoots = const {},
}) async => const [];
