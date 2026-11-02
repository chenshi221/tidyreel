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

  // Non-/dav mounts: server root, a nested path, Chinese + space, full-URL hrefs.
  // `redirect`: Apache-style 301 for collections without a trailing slash.
  for (final (label, mount, endpointPath, absolute, redirect) in [
    ('root', '', '', false, false),
    ('root, trailing slash', '', '/', false, false),
    ('nested', '/remote.php/webdav', '/remote.php/webdav', false, false),
    ('unicode', '/网盘 1', '/网盘 1/', true, false),
    ('apache-style redirects', '/webdav', '/webdav', false, true),
  ]) {
    storageContract('WebDAV mount $label', (files) async {
      final server = await MockServer.start(
        MockWebDav(
          files,
          mount: mount,
          absoluteHrefs: absolute,
          redirectCollections: redirect,
        ).handle,
      );
      addTearDown(server.close);
      return createBackend(
        cfg(ConnectionType.webdav, '${server.url}$endpointPath'),
        const Credentials(password: 'pw'),
      );
    });
  }

  group('Local', () {
    test('refuses paths that escape the root', () async {
      final be = await makeLocal({'/a.txt': 1});
      for (final bad in [
        '/../x',
        '/a/../../x',
        '/..',
        r'/..\evil',
        r'/a\..\..\evil',
      ]) {
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
        be.rename('/a.txt', r'..\evil'),
        throwsStorage(StorageErrorCode.other),
      );
      await expectLater(
        be.rename('/a.txt', '.'),
        throwsStorage(StorageErrorCode.other),
      );
      await expectLater(
        be.rename('/a.txt', ''),
        throwsStorage(StorageErrorCode.other),
      );
      await expectLater(
        be.rename('/missing.txt', 'missing.txt'),
        throwsStorage(StorageErrorCode.notFound),
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

    test('allows case-only rename on local files', () async {
      final be = await makeLocal({'/test.txt': 5});
      await be.rename('/test.txt', 'Test.txt');
      expect(await be.exists('/Test.txt'), isTrue);
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

    test('renameMany is one batch_rename call', () async {
      final (mock, be) = await connect(files: {'/d/1': 1, '/d/2': 1});
      await be.renameMany('/d', {'1': 'a', '2': 'b'});
      expect(mock.tree.nodes.keys, containsAll(['/d/a', '/d/b']));
      expect(mock.calls.where((c) => c.contains('rename')), [
        'api/fs/batch_rename',
      ]);
    });

    test('renameMany falls back to fs/rename on older servers', () async {
      final (mock, be) = await connect(files: {'/d/1': 1, '/d/2': 1});
      mock.batchRename = false;
      await be.renameMany('/d', {'1': 'a', '2': 'b'});
      expect(mock.tree.nodes.keys, containsAll(['/d/a', '/d/b']));
      expect(mock.calls.where((c) => c == 'api/fs/rename'), hasLength(2));
    });

    test(
      'Windows "Access is denied" is busy (retried, then explained)',
      () async {
        final (mock, be) = await connect(files: {'/d/1': 1});
        mock.failNext = (500, r'rename D:\bit\d: Access is denied.');
        await expectLater(
          be.rename('/d', 'e'),
          throwsStorage(StorageErrorCode.busy),
        );
      },
    );

    test('rename refuses to overwrite even though the server would', () async {
      final (mock, be) = await connect(files: {'/a': 1, '/b': 2});
      await expectLater(
        be.rename('/a', 'b'),
        throwsStorage(StorageErrorCode.alreadyExists),
      );
      expect(mock.tree.nodes['/b'], 2);
    });

    test(
      'HTML 200 response from reverse proxy is StorageErrorCode.other',
      () async {
        final server = await MockServer.start(
          (_) => Response.ok(
            '<html><body>login gateway</body></html>',
            headers: {'content-type': 'text/html'},
          ),
        );
        addTearDown(server.close);
        final be = createBackend(
          cfg(ConnectionType.alist, server.url),
          const Credentials(token: 'tok'),
        );
        await expectLater(be.list('/'), throwsStorage(StorageErrorCode.other));
      },
    );
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

    test('resolves relative hrefs and percent signs in filenames', () async {
      final server = await MockServer.start((Request r) {
        if (r.method == 'PROPFIND') {
          return Response(
            207,
            body:
                '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
                '<D:response><D:href>/dav/sub/</D:href><D:propstat><D:prop>'
                '<D:resourcetype><D:collection/></D:resourcetype>'
                '</D:prop></D:propstat></D:response>'
                '<D:response><D:href>100%25%20Love.mkv</D:href><D:propstat><D:prop>'
                '<D:resourcetype/><D:getcontentlength>42</D:getcontentlength>'
                '</D:prop></D:propstat></D:response>'
                '<D:response><D:href>nested/</D:href><D:propstat><D:prop>'
                '<D:resourcetype><D:collection/></D:resourcetype>'
                '</D:prop></D:propstat></D:response>'
                '</D:multistatus>',
            headers: {'content-type': 'application/xml; charset=utf-8'},
          );
        }
        return Response.notFound('');
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      );
      final entries = await be.list('/sub');
      expect(entries.map((e) => (e.path, e.name, e.isDir, e.size)).toList(), [
        ('/sub/100% Love.mkv', '100% Love.mkv', false, 42),
        ('/sub/nested', 'nested', true, 0),
      ]);
    });

    test('parses custom XML namespace prefixes and numeric entities', () async {
      final server = await MockServer.start((Request r) {
        if (r.method == 'PROPFIND') {
          return Response(
            207,
            body:
                '<?xml version="1.0"?><ns-1:multistatus xmlns:ns-1="DAV:">'
                '<ns-1:response><ns-1:href>/dav/sub/</ns-1:href><ns-1:propstat><ns-1:prop>'
                '<ns-1:resourcetype><ns-1:collection/></ns-1:resourcetype>'
                '</ns-1:prop></ns-1:propstat></ns-1:response>'
                '<ns-1:response><ns-1:href>/dav/sub/Tom%20&#38;%20Jerry.mkv</ns-1:href>'
                '<ns-1:propstat><ns-1:prop><ns-1:resourcetype/>'
                '<ns-1:getcontentlength>10</ns-1:getcontentlength>'
                '</ns-1:prop></ns-1:propstat></ns-1:response>'
                '</ns-1:multistatus>',
            headers: {'content-type': 'application/xml; charset=utf-8'},
          );
        }
        return Response.notFound('');
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      );
      final entries = await be.list('/sub');
      expect(entries.single.name, 'Tom & Jerry.mkv');
    });
  });
}
