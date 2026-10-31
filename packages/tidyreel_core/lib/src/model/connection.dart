import 'ids.dart';

enum ConnectionType { alist, webdav, local }

/// A saved source. Secrets (password / token) are NOT stored here; see [Credentials].
class ConnectionConfig {
  final ConnectionId id;
  final String name;
  final ConnectionType type;

  /// Server URL for alist/webdav (e.g. "http://nas:5244"), absolute folder path for local.
  final String endpoint;
  final String? username;

  /// Target root for [OrganizeMode.moveToLibrary], e.g. "/影视库".
  final String? libraryRoot;
  final List<String> favorites;

  /// Folder the file browser opens at, e.g. "/PC". Only a starting point:
  /// paths (and history) stay relative to the connection root.
  final String startDir;

  const ConnectionConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.endpoint,
    this.username,
    this.libraryRoot,
    this.favorites = const [],
    this.startDir = '/',
  });

  ConnectionConfig copyWith({
    String? name,
    ConnectionType? type,
    String? endpoint,
    String? Function()? username,
    String? Function()? libraryRoot,
    List<String>? favorites,
    String? startDir,
  }) => ConnectionConfig(
    id: id,
    name: name ?? this.name,
    type: type ?? this.type,
    endpoint: endpoint ?? this.endpoint,
    username: username != null ? username() : this.username,
    libraryRoot: libraryRoot != null ? libraryRoot() : this.libraryRoot,
    favorites: favorites ?? this.favorites,
    startDir: startDir ?? this.startDir,
  );
}

/// "/a//b/" -> "/a/b"; empty -> "/".
String normalizeDir(String path) {
  final segs = path.split('/').where((s) => s.trim().isNotEmpty);
  return segs.isEmpty ? '/' : '/${segs.join('/')}';
}

/// Secrets kept in secure storage, handed to the backend at creation time.
class Credentials {
  final String? password;
  final String? token;

  const Credentials({this.password, this.token});
}
