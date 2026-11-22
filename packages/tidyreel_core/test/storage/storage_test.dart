import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/src/storage/local_backend.dart';
import 'package:tidyreel_core/src/storage/webdav_backend.dart';
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
  final server = await MockServer.start(mock.handle);
  mock.origin = server.url;
  return (mock, server);
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

    group('a target that resolves to the source but is its own entry', () {
      late Directory root;
      late StorageBackend be;
      setUp(() {
        root = Directory.systemTemp.createTempSync('tidyreel_links_');
        addTearDown(() => root.deleteSync(recursive: true));
        File('${root.path}/a.mkv').writeAsBytesSync([1, 2, 3]);
        be = createBackend(
          cfg(ConnectionType.local, root.path),
          const Credentials(),
        );
      });

      test('hard link is refused, both names kept', () async {
        final r = Process.runSync('ln', [
          '${root.path}/a.mkv',
          '${root.path}/b.mkv',
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        await expectLater(
          be.rename('/a.mkv', 'b.mkv'),
          throwsStorage(StorageErrorCode.alreadyExists),
        );
        expect(File('${root.path}/a.mkv').existsSync(), isTrue);
        expect(File('${root.path}/b.mkv').existsSync(), isTrue);
      }, testOn: '!windows');

      test('symlink is refused and not replaced', () async {
        Link('${root.path}/b.mkv').createSync('${root.path}/a.mkv');
        await expectLater(
          be.rename('/a.mkv', 'b.mkv'),
          throwsStorage(StorageErrorCode.alreadyExists),
        );
        expect(FileSystemEntity.isLinkSync('${root.path}/b.mkv'), isTrue);
        expect(File('${root.path}/a.mkv').existsSync(), isTrue);
      }, testOn: '!windows');
    });

    test('mapOsErrorCode distinguishes Windows and POSIX errno values', () {
      expect(
        LocalBackend.mapOsErrorCode(17, isWindows: true),
        StorageErrorCode.other,
      );
      expect(
        LocalBackend.mapOsErrorCode(39, isWindows: true),
        StorageErrorCode.other,
      );
      expect(
        LocalBackend.mapOsErrorCode(32, isWindows: true),
        StorageErrorCode.busy,
      );
      expect(
        LocalBackend.mapOsErrorCode(5, isWindows: true),
        StorageErrorCode.busy,
      );
      expect(
        LocalBackend.mapOsErrorCode(183, isWindows: true),
        StorageErrorCode.alreadyExists,
      );

      expect(
        LocalBackend.mapOsErrorCode(17, isWindows: false),
        StorageErrorCode.alreadyExists,
      );
      expect(
        LocalBackend.mapOsErrorCode(39, isWindows: false),
        StorageErrorCode.alreadyExists,
      );
      expect(
        LocalBackend.mapOsErrorCode(32, isWindows: false),
        StorageErrorCode.other,
      );
      expect(
        LocalBackend.mapOsErrorCode(13, isWindows: false),
        StorageErrorCode.unauthorized,
      );
      expect(
        LocalBackend.mapOsErrorCode(16, isWindows: false),
        StorageErrorCode.busy,
      );
    });

    test('broken symlink size is clamped to 0 and removing dir symlink keeps target', () async {
      final root = Directory.systemTemp.createTempSync('tidyreel_symlink_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/target').createSync();
      File('${root.path}/target/keep.mkv').writeAsBytesSync([1, 2, 3]);
      Link('${root.path}/broken.mkv').createSync('${root.path}/missing.mkv');
      Link('${root.path}/dir_link').createSync('${root.path}/target');

      final be = LocalBackend(root.path);
      final entries = await be.list('/');
      final broken = entries.firstWhere((e) => e.name == 'broken.mkv');
      expect(broken.size, 0);

      await be.remove('/', ['dir_link']);
      expect(File('${root.path}/target/keep.mkv').existsSync(), isTrue);
      await be.close();
    }, testOn: '!windows');

    test('list with trailing slash does not produce double slashes', () async {
      final be = await makeLocal({'/sub/a.mkv': 5});
      final entries = await be.list('/sub/');
      expect(entries.single.path, '/sub/a.mkv');
      await be.close();
    });

    test(
      'readRange slices head, middle, EOF, and rejects missing/escape paths',
      () async {
        final root = Directory.systemTemp.createTempSync('tidyreel_range_');
        addTearDown(() => root.deleteSync(recursive: true));
        File('${root.path}/data.bin')
            .writeAsBytesSync(List<int>.generate(20, (i) => i));

        final be = LocalBackend(root.path);
        expect(await be.readRange('/data.bin', 0, 5), [0, 1, 2, 3, 4]);
        expect(await be.readRange('/data.bin', 7, 4), [7, 8, 9, 10]);
        expect(await be.readRange('/data.bin', 17, 10), [17, 18, 19]);
        expect(await be.readRange('/data.bin', 20, 5), isEmpty);
        expect(await be.readRange('/data.bin', 50, 5), isEmpty);
        expect(await be.readRange('/data.bin', 0, 0), isEmpty);
        expect(await be.readRange('/data.bin', -1, 4), isEmpty);
        await expectLater(
          be.readRange('/missing.bin', 0, 4),
          throwsStorage(StorageErrorCode.notFound),
        );
        await expectLater(
          be.readRange('/../escape.bin', 0, 4),
          throwsStorage(StorageErrorCode.other),
        );
        await be.close();
      },
    );
  });

  group('Memory', () {
    test(
      'readRange slices head, middle, past EOF, and missing files',
      () async {
        final be = MemoryStorageBackend();
        await be.write('/dir/data.bin', List<int>.generate(12, (i) => i + 10));

        expect(await be.readRange('/dir/data.bin', 0, 4), [10, 11, 12, 13]);
        expect(await be.readRange('/dir/data.bin', 5, 3), [15, 16, 17]);
        expect(await be.readRange('/dir/data.bin', 10, 5), [20, 21]);
        expect(await be.readRange('/dir/data.bin', 12, 4), isEmpty);
        expect(await be.readRange('/dir/data.bin', 0, 0), isEmpty);
        expect(await be.readRange('/dir/data.bin', -2, 4), isEmpty);
        await expectLater(
          be.readRange('/nope.bin', 0, 4),
          throwsStorage(StorageErrorCode.notFound),
        );
        await expectLater(
          be.readRange('/dir', 0, 4),
          throwsStorage(StorageErrorCode.notFound),
        );
      },
    );
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

    test(
      'the executor wrapper still batch-renames behind CachedBackend',
      () async {
        final (mock, be) = await connect(files: {'/d/1': 1, '/d/2': 1});
        // What the app hands the executor: Throttled(Cached(Alist)).
        final wrapped = ThrottledBackend(
          CachedBackend(be),
          minInterval: Duration.zero,
        );
        await wrapped.renameMany('/d', {'1': 'a', '2': 'b'});
        expect(mock.tree.nodes.keys, containsAll(['/d/a', '/d/b']));
        expect(mock.calls.where((c) => c.contains('rename')), [
          'api/fs/batch_rename',
        ]);
      },
    );

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

    test('HTML 200 response from reverse proxy is StorageErrorCode.other', () async {
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
      // Wrong-URL HTML 200 on login must NOT be misclassified as unauthorized.
      final beLogin = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(password: 'pw'),
      );
      await expectLater(beLogin.ping(), throwsStorage(StorageErrorCode.other));
      await be.close();
      await beLogin.close();
    });

    test('ping fails on HTTP 404 wrong URL instead of succeeding', () async {
      final server = await MockServer.start((_) => Response.notFound('nope'));
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(token: 'tok'),
      );
      await expectLater(be.ping(), throwsStorage(StorageErrorCode.notFound));
      await be.close();
    });

    test('empty token logs in immediately without a wasted 401', () async {
      final (mock, be) = await connect(
        creds: const Credentials(password: 'pw', token: ''),
      );
      await be.ping();
      expect(mock.logins, 1);
      await be.close();
    });

    test('login HTTP 500 is not misclassified as unauthorized', () async {
      final server = await MockServer.start(
        (_) => Response.internalServerError(body: 'server exploded'),
      );
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(password: 'pw'),
      );
      await expectLater(be.ping(), throwsStorage(StorageErrorCode.other));
      await be.close();
    });

    test(
      'write fails on non-JSON HTTP 200 and calls mkdirs for parent',
      () async {
        var sawMkdir = false;
        final server = await MockServer.start((Request r) async {
          if (r.url.path == 'api/fs/get') {
            return Response.ok(
              '{"code":500,"message":"object not found","data":null}',
              headers: {'content-type': 'application/json'},
            );
          }
          if (r.url.path == 'api/fs/mkdir') {
            sawMkdir = true;
            return Response.ok(
              '{"code":200,"message":"success","data":null}',
              headers: {'content-type': 'application/json'},
            );
          }
          if (r.url.path == 'api/fs/put') {
            return Response.ok(
              '<html>gateway error</html>',
              headers: {'content-type': 'text/html'},
            );
          }
          return Response.notFound('');
        });
        addTearDown(server.close);
        final be = createBackend(
          cfg(ConnectionType.alist, server.url),
          const Credentials(token: 'tok'),
        );
        await expectLater(
          be.write('/new/dir/a.nfo', [1, 2, 3]),
          throwsStorage(StorageErrorCode.other),
        );
        expect(sawMkdir, isTrue);
        await be.close();
      },
    );

    test('read resolves relative raw_url and maps HTTP status codes', () async {
      var downloadStatus = 200;
      final server = await MockServer.start((Request r) async {
        if (r.url.path == 'api/fs/get') {
          return Response.ok(
            '{"code":200,"message":"success","data":{"name":"a.nfo","is_dir":false,"raw_url":"/d/a.nfo"}}',
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.url.path == 'd/a.nfo') {
          return downloadStatus == 200
              ? Response.ok([9, 8, 7])
              : Response(downloadStatus);
        }
        return Response.notFound('');
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(token: 'tok'),
      );
      expect(await be.read('/a.nfo'), [9, 8, 7]);
      downloadStatus = 403;
      await expectLater(
        be.read('/a.nfo'),
        throwsStorage(StorageErrorCode.unauthorized),
      );
      downloadStatus = 429;
      await expectLater(
        be.read('/a.nfo'),
        throwsStorage(StorageErrorCode.rateLimited),
      );
      downloadStatus = 502;
      await expectLater(
        be.read('/a.nfo'),
        throwsStorage(StorageErrorCode.network),
      );
      await be.close();
    });

    test('renameMany/move/remove skip empty ops, reject dup targets, and only fallback on 404/405', () async {
      final (mock, be) = await connect(files: {'/d/1': 1, '/d/2': 1});
      await be.ping();
      mock.calls.clear();

      await be.renameMany('/d', {});
      await be.renameMany('/d', {'1': '1'});
      await be.move('/d', '/d', []);
      await be.remove('/d', []);
      expect(mock.calls, isEmpty);

      await expectLater(
        be.renameMany('/d', {'1': 'same', '2': 'same'}),
        throwsStorage(StorageErrorCode.alreadyExists),
      );

      // Code 500 "object not found" during batch_rename must NOT fall back to per-file rename.
      mock.failNext = (500, 'object not found');
      await expectLater(
        be.renameMany('/d', {'1': 'a', '2': 'b'}),
        throwsStorage(StorageErrorCode.notFound),
      );
      expect(mock.calls.where((c) => c == 'api/fs/rename'), isEmpty);
      await be.close();
    });

    test('sends deepest matching directory password on list, get, and ping', () async {
      final seenListPasswords = <String, String?>{};
      final seenGetPasswords = <String, String?>{};

      final server = await MockServer.start((Request r) async {
        final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
        if (r.url.path == 'api/fs/list') {
          seenListPasswords[body['path'] as String] =
              body['password'] as String?;
          return Response.ok(
            '{"code":200,"message":"success","data":{"content":[],"total":0}}',
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.url.path == 'api/fs/get') {
          seenGetPasswords[body['path'] as String] =
              body['password'] as String?;
          return Response.ok(
            '{"code":200,"message":"success","data":{"name":"x","is_dir":true,"raw_url":""}}',
            headers: {'content-type': 'application/json'},
          );
        }
        return Response.notFound('');
      });
      addTearDown(server.close);

      final be = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(
          token: 'tok',
          dirPasswords: {
            '/': 'root-pw',
            '/私密': 'secret-1',
            '/私密/深层': 'secret-2',
          },
        ),
      );

      await be.ping();
      await be.list('/公开');
      await be.list('/私密');
      await be.list('/私密/深层/电影');
      await be.exists('/私密/a.mkv');
      await be.exists('/私密/深层/b.mkv');

      expect(seenGetPasswords['/'], 'root-pw');
      expect(seenListPasswords['/公开'], 'root-pw');
      expect(seenListPasswords['/私密'], 'secret-1');
      expect(seenListPasswords['/私密/深层/电影'], 'secret-2');
      expect(seenGetPasswords['/私密/a.mkv'], 'secret-1');
      expect(seenGetPasswords['/私密/深层/b.mkv'], 'secret-2');
      await be.close();
    });

    test('readRange supports 206 Partial Content, forwards raw_url headers, handles 416 and 200 streaming cap', () async {
      final payload = List<int>.generate(256, (i) => i);
      var mode = '206';
      String? seenRange;
      String? seenCustomHeader;
      String? seenGetPw;
      var streamedChunks = 0;

      final server = await MockServer.start((Request r) async {
        if (r.url.path == 'api/fs/get') {
          final body =
              jsonDecode(await r.readAsString()) as Map<String, dynamic>;
          seenGetPw = body['password'] as String?;
          return Response.ok(
            jsonEncode({
              'code': 200,
              'message': 'success',
              'data': {
                'name': 'movie.mkv',
                'is_dir': false,
                'raw_url': '/d/movie.mkv',
                'header': {'X-Drive-Auth': 'drive-token'},
              },
            }),
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.url.path == 'd/movie.mkv') {
          seenRange = r.headers['range'];
          seenCustomHeader = r.headers['x-drive-auth'];
          if (mode == '206') {
            final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(seenRange ?? '');
            final start = int.parse(m![1]!);
            final end = int.parse(m[2]!);
            if (start >= payload.length) {
              return Response(416);
            }
            final clampedEnd = end >= payload.length ? payload.length - 1 : end;
            return Response(
              206,
              body: payload.sublist(start, clampedEnd + 1),
              headers: {
                'content-range': 'bytes $start-$clampedEnd/${payload.length}',
              },
            );
          }
          if (mode == '200-stream') {
            streamedChunks = 0;
            // Simulate a huge multi-megabyte stream when server ignores Range.
            Stream<List<int>> huge() async* {
              for (var idx = 0; idx < 500; idx++) {
                streamedChunks++;
                yield List<int>.generate(4096, (j) => (idx * 4096 + j) & 0xFF);
                await Future<void>.delayed(Duration.zero);
              }
            }

            return Response.ok(huge());
          }
        }
        return Response.notFound('');
      });
      addTearDown(server.close);

      final be = createBackend(
        cfg(ConnectionType.alist, server.url),
        const Credentials(token: 'tok', dirPasswords: {'/vault': 'vp'}),
      ) as RangeReadableBackend;

      // 206 Partial Content
      final part = await be.readRange('/vault/movie.mkv', 10, 5);
      expect(part, [10, 11, 12, 13, 14]);
      expect(seenRange, 'bytes=10-14');
      expect(seenCustomHeader, 'drive-token');
      expect(seenGetPw, 'vp');

      // 416 Past EOF returns empty list cleanly
      expect(await be.readRange('/vault/movie.mkv', 999, 10), isEmpty);

      // 200 OK streaming cap slices safely without buffering entire multi-MB stream
      mode = '200-stream';
      final sliced = await be.readRange('/vault/movie.mkv', 100, 8);
      expect(sliced, [100, 101, 102, 103, 104, 105, 106, 107]);
      expect(streamedChunks, lessThan(50));

      // 200 OK with huge start offset refuses to download gigabytes
      await expectLater(
        be.readRange('/vault/movie.mkv', 1024 * 1024, 16),
        throwsStorage(StorageErrorCode.other),
      );
      await (be as StorageBackend).close();
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

    group('case-only rename', () {
      Future<(MockWebDav, StorageBackend)> connect(
        Map<String, int> files, {
        required bool caseInsensitive,
      }) async {
        final dav = MockWebDav(files, caseInsensitive: caseInsensitive);
        final server = await MockServer.start(dav.handle);
        addTearDown(server.close);
        return (
          dav,
          createBackend(
            cfg(ConnectionType.webdav, '${server.url}/dav'),
            const Credentials(password: 'pw'),
          ),
        );
      }

      test(
        'works on a case-insensitive server, folder contents kept',
        () async {
          final (dav, be) = await connect({
            '/the office/S01E01.mkv': 1,
          }, caseInsensitive: true);
          await be.rename('/the office', 'The Office');
          expect(dav.tree.nodes.keys, contains('/The Office/S01E01.mkv'));
          expect(dav.tree.nodes.keys, isNot(contains('/the office')));
          expect(
            dav.tree.nodes.keys.where((k) => k.contains('.tidyreel-case-')),
            isEmpty,
          );
        },
      );

      test('a separate entry with that exact name is refused', () async {
        final (dav, be) = await connect({
          '/a.mkv': 1,
          '/A.mkv': 2,
        }, caseInsensitive: false);
        await expectLater(
          be.rename('/a.mkv', 'A.mkv'),
          throwsStorage(StorageErrorCode.alreadyExists),
        );
        expect(dav.tree.nodes['/a.mkv'], 1);
        expect(dav.tree.nodes['/A.mkv'], 2);
      });
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
      await be.close();
    });

    test('omits Authorization header when credentials are empty', () async {
      String? seenAuth;
      final server = await MockServer.start((Request r) {
        seenAuth = r.headers['authorization'];
        return Response(
          207,
          body: '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"/>',
          headers: {'content-type': 'application/xml'},
        );
      });
      addTearDown(server.close);
      final be = WebDAVBackend(
        ConnectionConfig(
          id: const ConnectionId('anon'),
          name: 'anon',
          type: ConnectionType.webdav,
          endpoint: '${server.url}/dav',
          username: '',
        ),
        const Credentials(),
      );
      await be.ping();
      expect(seenAuth, isNull);
      await be.close();
    });

    test('read strips Authorization on cross-host redirect', () async {
      String? cdnAuth;
      final cdn = await MockServer.start((Request r) {
        cdnAuth = r.headers['authorization'];
        return Response.ok([42, 43]);
      });
      addTearDown(cdn.close);
      final dav = await MockServer.start((Request r) {
        return Response(302, headers: {'location': '${cdn.url}/blob'});
      });
      addTearDown(dav.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${dav.url}/dav'),
        const Credentials(password: 'pw'),
      );
      expect(await be.read('/movie.nfo'), [42, 43]);
      expect(cdnAuth, isNull);
      await be.close();
    });

    test('write follows 307 redirect via _send', () async {
      final seen = <(String, String)>[];
      var uploaded = <int>[];
      final server = await MockServer.start((Request r) async {
        seen.add((r.method, r.requestedUri.path));
        if (r.method == 'PROPFIND') return Response.notFound('');
        if (r.method == 'MKCOL') return Response(405);
        if (r.method == 'PUT' && r.requestedUri.path == '/dav/a.nfo') {
          return Response(307, headers: {'location': '/dav/final/a.nfo'});
        }
        if (r.method == 'PUT' && r.requestedUri.path == '/dav/final/a.nfo') {
          uploaded = await r.read().expand((b) => b).toList();
          return Response(201);
        }
        return Response(405);
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      );
      await be.write('/a.nfo', [1, 2, 3]);
      expect(uploaded, [1, 2, 3]);
      await be.close();
    });

    test(
      'mkdirs uses trailing slash and skips redundant parent MKCOL',
      () async {
        final mkcols = <String>[];
        final dav = MockWebDav({'/a/b/existing.txt': 1});
        final server = await MockServer.start((Request r) {
          if (r.method == 'MKCOL') mkcols.add(r.requestedUri.path);
          return dav.handle(r);
        });
        addTearDown(server.close);
        final be = createBackend(
          cfg(ConnectionType.webdav, '${server.url}/dav'),
          const Credentials(password: 'pw'),
        );
        await be.mkdirs('/a/b/newdir');
        // Parent /a/b already exists, so only /a/b/newdir/ is requested with trailing slash.
        expect(mkcols, ['/dav/a/b/newdir/']);
        await be.close();
      },
    );

    test('ignores 404 propstat blocks, avoids double-unxml/RangeError, and preserves # in href', () async {
      final server = await MockServer.start((Request r) {
        return Response(
          207,
          body:
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
              '<D:response><D:href>/dav/sub/</D:href><D:propstat><D:prop>'
              '<D:resourcetype><D:collection/></D:resourcetype>'
              '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
              '<D:response><D:href>/dav/sub/Show #1 &amp;lt; &#38;gt; &#999999999;.mkv</D:href>'
              '<D:propstat><D:prop><D:resourcetype/>'
              '<D:getcontentlength>99</D:getcontentlength>'
              '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
              '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
              '<D:getcontentlength>9999</D:getcontentlength>'
              '</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>'
              '</D:response>'
              '<D:response><D:href>http://[::bad-uri</D:href>'
              '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>'
              '</D:multistatus>',
          headers: {'content-type': 'application/xml; charset=utf-8'},
        );
      });
      addTearDown(server.close);
      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      );
      final entries = await be.list('/sub');
      expect(entries, hasLength(1));
      expect(entries.single.isDir, isFalse);
      expect(entries.single.size, 99);
      expect(entries.single.name, 'Show #1 &lt; &gt; &#999999999;.mkv');
      await be.close();
    });

    test('readRange supports 206, 416, cross-origin redirect stripping auth, and 200 streaming cap', () async {
      final payload = List<int>.generate(256, (i) => i);
      var mode = '206';
      String? cdnAuth;
      String? cdnRange;
      var streamedChunks = 0;

      final cdn = await MockServer.start((Request r) {
        cdnAuth = r.headers['authorization'];
        cdnRange = r.headers['range'];
        return Response(206, body: payload.sublist(5, 9));
      });
      addTearDown(cdn.close);

      final server = await MockServer.start((Request r) {
        final range = r.headers['range'];
        if (r.requestedUri.path == '/dav/redir.mkv') {
          return Response(302, headers: {'location': '${cdn.url}/blob'});
        }
        if (r.requestedUri.path != '/dav/movie.mkv') {
          return Response.notFound('');
        }
        if (mode == '206') {
          final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
          final start = int.parse(m![1]!);
          final end = int.parse(m[2]!);
          if (start >= payload.length) return Response(416);
          final clampedEnd = end >= payload.length ? payload.length - 1 : end;
          return Response(206, body: payload.sublist(start, clampedEnd + 1));
        }
        streamedChunks = 0;
        Stream<List<int>> huge() async* {
          for (var idx = 0; idx < 500; idx++) {
            streamedChunks++;
            yield List<int>.generate(4096, (j) => (idx * 4096 + j) & 0xFF);
            await Future<void>.delayed(Duration.zero);
          }
        }

        return Response.ok(huge());
      });
      addTearDown(server.close);

      final be = createBackend(
        cfg(ConnectionType.webdav, '${server.url}/dav'),
        const Credentials(password: 'pw'),
      ) as RangeReadableBackend;

      expect(await be.readRange('/movie.mkv', 20, 6), [20, 21, 22, 23, 24, 25]);
      expect(await be.readRange('/movie.mkv', 500, 8), isEmpty);
      await expectLater(
        be.readRange('/missing.mkv', 0, 8),
        throwsStorage(StorageErrorCode.notFound),
      );

      // Cross-origin redirect strips Authorization while keeping Range
      expect(await be.readRange('/redir.mkv', 5, 4), [5, 6, 7, 8]);
      expect(cdnAuth, isNull);
      expect(cdnRange, 'bytes=5-8');

      // HTTP 200 streaming cap
      mode = '200-stream';
      expect(await be.readRange('/movie.mkv', 50, 6), [50, 51, 52, 53, 54, 55]);
      expect(streamedChunks, lessThan(50));

      // HTTP 200 huge start refuses full download
      await expectLater(
        be.readRange('/movie.mkv', 1024 * 1024, 16),
        throwsStorage(StorageErrorCode.other),
      );
      await (be as StorageBackend).close();
    });
  });
}
