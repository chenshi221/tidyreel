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

  const ConnectionConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.endpoint,
    this.username,
    this.libraryRoot,
    this.favorites = const [],
  });
}

/// Secrets kept in secure storage, handed to the backend at creation time.
class Credentials {
  final String? password;
  final String? token;

  const Credentials({this.password, this.token});
}
