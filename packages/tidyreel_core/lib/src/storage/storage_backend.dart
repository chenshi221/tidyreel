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

  /// Renames several children of [dir] at once (old name -> new name). Never
  /// overwrites; a failure part-way may leave some renamed.
  Future<void> renameMany(String dir, Map<String, String> names);

  /// Move [names] (children of [srcDir]) into [dstDir], keeping their names.
  Future<void> move(String srcDir, String dstDir, List<String> names);

  Future<void> remove(String dir, List<String> names);

  Future<bool> exists(String path);

  /// The whole content of a (small) file: .nfo, artwork.
  Future<List<int>> read(String path);

  /// Creates file [path] (parents too) with [bytes]. Never overwrites: an
  /// existing [path] throws [StorageErrorCode.alreadyExists].
  Future<void> write(String path, List<int> bytes);

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

  /// The server's OS refused because something holds the file or folder open
  /// (Windows "Access is denied", e.g. a torrent client still seeding).
  busy,
  other,
}

/// SMB needs native libsmb2, so core leaves it to the app, which sets this at
/// startup (keeps `dart test` of core free of native build hooks).
StorageBackend Function(ConnectionConfig, Credentials)? smbBackend;

/// Builds the right backend for a saved connection.
StorageBackend createBackend(
  ConnectionConfig config,
  Credentials credentials,
) => switch (config.type) {
  ConnectionType.alist => AlistBackend(config, credentials),
  ConnectionType.webdav => WebDAVBackend(config, credentials),
  ConnectionType.smb =>
    (smbBackend ??
        (_, _) => throw const StorageException(
          StorageErrorCode.other,
          '这个版本不支持 SMB',
        ))(config, credentials),
  ConnectionType.local => LocalBackend(config.endpoint),
};
