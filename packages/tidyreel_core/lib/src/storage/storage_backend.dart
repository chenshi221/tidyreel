import '../model/connection.dart';
import '../model/scan.dart';
import 'alist_backend.dart';
import 'local_backend.dart';
import 'webdav_backend.dart';

/// Owner: Agent C. PLAN §4.4.
/// All paths are absolute and '/'-separated, relative to the connection root.
abstract interface class StorageBackend {
  /// Direct children of [dir]. [refresh] bypasses server caches (Alist).
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false});

  /// Creates [dir] and missing parents. No-op if it exists.
  Future<void> mkdirs(String dir);

  /// Rename within the same directory.
  Future<void> rename(String path, String newName);

  /// Move [names] (children of [srcDir]) into [dstDir], keeping their names.
  Future<void> move(String srcDir, String dstDir, List<String> names);

  Future<void> remove(String dir, List<String> names);

  Future<bool> exists(String path);

  /// Cheap connectivity / auth check for the 已连接 badge.
  Future<void> ping();
}

/// Thrown by backends; [code] lets the executor decide whether to retry.
class StorageException implements Exception {
  final StorageErrorCode code;
  final String message;

  const StorageException(this.code, this.message);

  @override
  String toString() => 'StorageException($code): $message';
}

enum StorageErrorCode {
  notFound,
  alreadyExists,
  unauthorized,
  rateLimited,
  network,
  other,
}

/// Builds the right backend for a saved connection.
StorageBackend createBackend(
  ConnectionConfig config,
  Credentials credentials,
) => switch (config.type) {
  ConnectionType.alist => AlistBackend(config, credentials),
  ConnectionType.webdav => WebDAVBackend(config, credentials),
  ConnectionType.local => LocalBackend(config.endpoint),
};
