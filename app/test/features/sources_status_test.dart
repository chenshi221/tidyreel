import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/sources/sources_providers.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _FailingBackend extends MemoryStorageBackend {
  final StorageException error;
  _FailingBackend(this.error);

  @override
  Future<void> ping() async => throw error;

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async =>
      throw error;
}

void main() {
  Future<({ConnStatus status, String? detail})> statusFor(
    ConnectionConfig c,
    StorageException error,
  ) async {
    final container = ProviderContainer(
      overrides: [
        backendForProvider.overrideWithValue((_) => _FailingBackend(error)),
      ],
    );
    addTearDown(container.dispose);
    container.read(connectionsProvider.notifier).upsert(c);
    return container.read(connectionStatusProvider(c.id).future);
  }

  test('WebDAV on an Alist root gets the /dav hint', () async {
    final s = await statusFor(
      const ConnectionConfig(
        id: ConnectionId('w'),
        name: 'w',
        type: ConnectionType.webdav,
        endpoint: 'http://127.0.0.1:5244',
      ),
      const StorageException(StorageErrorCode.other, 'PROPFIND /: HTTP 405'),
    );
    expect(s.status, ConnStatus.offline);
    expect(s.detail, contains('405'));
    expect(s.detail, contains('/dav'));
  });

  test(
    'auth failure explains case sensitivity, no /dav hint when present',
    () async {
      final s = await statusFor(
        const ConnectionConfig(
          id: ConnectionId('w'),
          name: 'w',
          type: ConnectionType.webdav,
          endpoint: 'http://127.0.0.1:5244/dav/',
        ),
        const StorageException(StorageErrorCode.unauthorized, '401'),
      );
      expect(s.status, ConnStatus.authFailed);
      expect(s.detail, contains('区分大小写'));
      expect(s.detail, isNot(contains('WebDAV 路径是 /dav')));
    },
  );

  test('other WebDAV servers on any path get no /dav hint', () async {
    for (final err in [
      'PROPFIND /: HTTP 500',
      'PROPFIND /: Connection refused',
    ]) {
      final s = await statusFor(
        const ConnectionConfig(
          id: ConnectionId('w'),
          name: 'w',
          type: ConnectionType.webdav,
          endpoint: 'https://nas:5006/webdav',
        ),
        StorageException(StorageErrorCode.other, err),
      );
      expect(s.status, ConnStatus.offline);
      expect(s.detail, err);
    }
  });
}
