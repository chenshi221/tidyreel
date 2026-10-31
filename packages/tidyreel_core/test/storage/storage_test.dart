import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'contract.dart';
import 'mock_servers.dart';

ConnectionConfig cfg(ConnectionType type, String endpoint) => ConnectionConfig(
  id: const ConnectionId('t'),
  name: 't',
  type: type,
  endpoint: endpoint,
  username: 'admin',
);

Future<(MockAlist, MockServer)> startAlist(Map<String, int> files) async {
  final mock = MockAlist(files);
  return (mock, await MockServer.start(mock.handle));
}

Future<StorageBackend> makeLocal(Map<String, int> files) async {
  final dir = Directory.systemTemp.createTempSync('tidyreel_local_');
  addTearDown(() => dir.deleteSync(recursive: true));
  files.forEach((path, size) {
    final f = File('${dir.path}$path')..createSync(recursive: true);
    f.writeAsBytesSync(List.filled(size, 0));
  });
  return createBackend(
    cfg(ConnectionType.local, dir.path),
    const Credentials(),
  );
}

void main() {
  storageContract('Memory', (files) async => MemoryStorageBackend(files));
  storageContract('Local', makeLocal);

  storageContract('Alist', (files) async {
    final (_, server) = await startAlist(files);
    addTearDown(server.close);
    return createBackend(
      cfg(ConnectionType.alist, '${server.url}/'),
      const Credentials(password: 'pw'),
    );
  });

  storageContract('WebDAV', (files) async {
    final server = await MockServer.start(MockWebDav(files).handle);
    addTearDown(server.close);
    return createBackend(
      cfg(ConnectionType.webdav, '${server.url}/dav'),
      const Credentials(password: 'pw'),
    );
  });

  group('Local', () {
    test('refuses paths that escape the root', () async {
      final be = await makeLocal({'/a.txt': 1});
      for (final bad in ['/../x', '/a/../../x', '/..']) {
        await expectLater(be.list(bad), throwsStorage(StorageErrorCode.other));
        await expectLater(
          be.exists(bad),
          throwsStorage(StorageErrorCode.other),
        );
        await expectLater(
          be.mkdirs(bad),
          throwsStorage(StorageErrorCode.other),
        );
      }
      await expectLater(
        be.rename('/a.txt', '../evil'),
        throwsStorage(StorageErrorCode.other),
      );
      await expectLater(
        be.move('/', '/..', ['a.txt']),
        throwsStorage(StorageErrorCode.other),
      );
      await expectLater(
        be.remove('/..', ['x']),
        throwsStorage(StorageErrorCode.other),
      );
    });
  });

  group('Alist', () {
    Future<(MockAlist, StorageBackend)> connect({
      Map<String, int> files = const {'/a.txt': 1},
      Credentials creds = const Credentials(password: 'pw'),
    }) async {
      final (mock, server) = await startAlist(files);
      addTearDown(server.close);
      return (
        mock,
        createBackend(cfg(ConnectionType.alist, server.url), creds),
      );
    }

    test('logs in again once when the token expires', () async {
      final (mock, be) = await connect();
      await be.ping();
      expect(mock.logins, 1);
      mock.expireToken();
      expect(await be.exists('/a.txt'), isTrue);
      expect(mock.logins, 2);
    });

    test('uses a supplied token directly, without logging in', () async {
      final (mock, be) = await connect(
        creds: const Credentials(token: 'tok-1'),
      );
      await be.ping();
      expect(mock.logins, 0);
    });

    test(
      'an expired supplied token without a password is unauthorized',
      () async {
        final (_, be) = await connect(creds: const Credentials(token: 'stale'));
        await expectLater(
          be.ping(),
          throwsStorage(StorageErrorCode.unauthorized),
        );
      },
    );

    test('wrong password is unauthorized', () async {
      final (_, be) = await connect(creds: const Credentials(password: 'bad'));
      await expectLater(
        be.ping(),
        throwsStorage(StorageErrorCode.unauthorized),
      );
    });

    test('fetches every page even when the server caps per_page', () async {
      final files = {for (var i = 0; i < 23; i++) '/d/文件 $i.mkv': i};
      final (mock, be) = await connect(files: files);
      mock.maxPerPage = 10;
      final list = await be.list('/d');
      expect(list.map((e) => e.name).toSet(), {
        for (var i = 0; i < 23; i++) '文件 $i.mkv',
      });
      expect(mock.listRequests.map((r) => r['page']), [1, 2, 3]);
    });

    test('refresh is passed through on the first page only', () async {
      final (mock, be) = await connect();
      await be.list('/', refresh: true);
      await be.list('/');
      expect(mock.listRequests.map((r) => r['refresh']), [true, false]);
    });

    test('code != 200 maps to StorageErrorCode', () async {
      final (mock, be) = await connect();
      await be.ping(); // log in first
      final cases = {
        (403, 'permission denied'): StorageErrorCode.unauthorized,
        (404, 'x'): StorageErrorCode.notFound,
        (429, 'x'): StorageErrorCode.rateLimited,
        (503, 'x'): StorageErrorCode.network,
        (500, 'failed get: object not found'): StorageErrorCode.notFound,
        (500, 'storage is busy'): StorageErrorCode.other,
      };
      for (final e in cases.entries) {
        mock.failNext = e.key;
        await expectLater(
          be.list('/'),
          throwsStorage(e.value),
          reason: '${e.key}',
        );
      }
    });

    test('unreachable server is a network error', () async {
      final (_, server) = await startAlist({});
      final url = server.url;
      await server.close();
      final be = createBackend(
        cfg(ConnectionType.alist, url),
        const Credentials(password: 'pw'),
      );
      await expectLater(be.ping(), throwsStorage(StorageErrorCode.network));
    });

    test('rename refuses to overwrite even though the server would', () async {
      final (mock, be) = await connect(files: {'/a': 1, '/b': 2});
      await expectLater(
        be.rename('/a', 'b'),
        throwsStorage(StorageErrorCode.alreadyExists),
      );
      expect(mock.tree.nodes['/b'], 2);
    });
  });

  group('WebDAV', () {
    test('wrong password is unauthorized', () async {
      final server = await MockServer.start(MockWebDav({}).handle);
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'bad'),
      );
      await expectLater(
        be.ping(),
        throwsStorage(StorageErrorCode.unauthorized),
      );
    });

    test('percent-encodes paths on the wire', () async {
      final seen = <String>[];
      final dav = MockWebDav({'/电影 [1].mkv': 1});
      final server = await MockServer.start((Request r) {
        seen.add(r.requestedUri.path);
        return dav.handle(r);
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      );
      await be.rename('/电影 [1].mkv', '电影 (2020).mkv');
      expect(seen.single, '/dav/%E7%94%B5%E5%BD%B1%20%5B1%5D.mkv');
    });
  });
}
