import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

/// In-memory tree shared by the mock servers. Directories have size -1.
class MockTree {
  final Map<String, int> nodes = {'/': -1};

  MockTree(Map<String, int> files) {
    files.forEach((path, size) {
      mkdirs(p.posix.dirname(path));
      nodes[path] = size;
    });
  }

  bool isDir(String path) => nodes[path] == -1;

  void mkdirs(String dir) {
    for (
      var d = dir;
      d != '/' && !nodes.containsKey(d);
      d = p.posix.dirname(d)
    ) {
      nodes[d] = -1;
    }
  }

  List<String> children(String dir) =>
      nodes.keys.where((k) => k != '/' && p.posix.dirname(k) == dir).toList()
        ..sort();

  /// Moves a subtree, silently replacing whatever is at [to] (a lax driver).
  void relocate(String from, String to) {
    nodes.keys
        .where((k) => k == to || k.startsWith('$to/'))
        .toList()
        .forEach(nodes.remove);
    for (final k
        in nodes.keys
            .where((k) => k == from || k.startsWith('$from/'))
            .toList()) {
      nodes['$to${k.substring(from.length)}'] = nodes.remove(k)!;
    }
  }

  void delete(String path) => nodes.keys
      .where((k) => k == path || k.startsWith('$path/'))
      .toList()
      .forEach(nodes.remove);
}

class MockServer {
  final HttpServer _server;
  MockServer._(this._server);

  static Future<MockServer> start(Handler h) async =>
      MockServer._(await io.serve(h, InternetAddress.loopbackIPv4, 0));

  String get url => 'http://127.0.0.1:${_server.port}';
  Future<void> close() => _server.close(force: true);
}

/// Alist v3 look-alike. Rename/move deliberately overwrite, like some drivers do.
class MockAlist {
  final MockTree tree;
  final String password;
  String token = 'tok-1';
  int logins = 0;

  /// Caps `per_page`, like a server-side limit.
  int? maxPerPage;

  /// Makes the next `/api/fs/*` call fail with this `{code, message}`.
  (int, String)? failNext;

  final List<Map<String, dynamic>> listRequests = [];

  /// `fs/*` calls in order, e.g. `api/fs/batch_rename`.
  final List<String> calls = [];

  /// Older servers have no `fs/batch_rename` (HTTP 404).
  bool batchRename = true;

  MockAlist(Map<String, int> files, {this.password = 'pw'})
    : tree = MockTree(files);

  void expireToken() => token = 'expired-${logins + 1}';

  Response _json(int code, String message, [Object? data]) => Response.ok(
    jsonEncode({'code': code, 'message': message, 'data': data}),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<Response> handle(Request req) async {
    final api = req.url.path;
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    if (api == 'api/auth/login') {
      if (body['username'] != 'admin' || body['password'] != password) {
        return _json(400, 'password is incorrect');
      }
      logins++;
      token = 'tok-${logins + 1}';
      return _json(200, 'success', {'token': token});
    }
    if (req.headers['authorization'] != token) {
      return _json(401, 'token is invalidated');
    }
    if (failNext != null) {
      final (c, m) = failNext!;
      failNext = null;
      return _json(c, m);
    }
    const notFound = 'object not found';
    calls.add(api);
    switch (api) {
      case 'api/fs/batch_rename' when batchRename:
        final dir = body['src_dir'] as String;
        for (final o in (body['rename_objects'] as List).cast<Map>()) {
          final from = p.posix.join(dir, o['src_name'] as String);
          if (!tree.nodes.containsKey(from)) return _json(500, notFound);
          tree.relocate(from, p.posix.join(dir, o['new_name'] as String));
        }
        return _json(200, 'success');
      case 'api/fs/get':
        final path = body['path'] as String;
        return tree.nodes.containsKey(path)
            ? _json(200, 'success', {
                'name': p.posix.basename(path),
                'is_dir': tree.isDir(path),
              })
            : _json(500, 'failed get: $notFound');
      case 'api/fs/list':
        listRequests.add(body);
        final dir = body['path'] as String;
        if (!tree.isDir(dir)) return _json(500, 'failed get: $notFound');
        final all = tree.children(dir);
        final page = body['page'] as int;
        var per = body['per_page'] as int;
        if (per <= 0 || (maxPerPage != null && per > maxPerPage!)) {
          per = maxPerPage ?? all.length;
        }
        final slice = all.skip((page - 1) * per).take(per);
        return _json(200, 'success', {
          'content': [
            for (final k in slice)
              {
                'name': p.posix.basename(k),
                'is_dir': tree.isDir(k),
                'size': tree.isDir(k) ? 0 : tree.nodes[k],
                'modified': '2024-01-02T03:04:05Z',
              },
          ],
          'total': all.length,
        });
      case 'api/fs/mkdir':
        tree.mkdirs(body['path'] as String);
        return _json(200, 'success');
      case 'api/fs/rename':
        final path = body['path'] as String;
        if (!tree.nodes.containsKey(path)) return _json(500, notFound);
        tree.relocate(
          path,
          p.posix.join(p.posix.dirname(path), body['name'] as String),
        );
        return _json(200, 'success');
      case 'api/fs/move':
        final dst = body['dst_dir'] as String;
        if (!tree.isDir(dst)) return _json(500, notFound);
        for (final n in (body['names'] as List).cast<String>()) {
          final from = p.posix.join(body['src_dir'] as String, n);
          if (!tree.nodes.containsKey(from)) return _json(500, notFound);
          tree.relocate(from, p.posix.join(dst, n));
        }
        return _json(200, 'success');
      case 'api/fs/remove':
        for (final n in (body['names'] as List).cast<String>()) {
          tree.delete(p.posix.join(body['dir'] as String, n));
        }
        return _json(200, 'success');
    }
    return Response.notFound('?');
  }
}

/// Minimal WebDAV server mounted under [mount] (default `/dav`, '' = root),
/// Basic auth admin:pw. [absoluteHrefs] answers hrefs as full URLs.
class MockWebDav {
  final MockTree tree;
  final String mount;
  final bool absoluteHrefs;

  /// Like Apache / nginx: collections addressed without a trailing slash get
  /// a 301 to the slashed URL.
  final bool redirectCollections;

  MockWebDav(
    Map<String, int> files, {
    this.mount = '/dav',
    this.absoluteHrefs = false,
    this.redirectCollections = false,
  }) : tree = MockTree(files);

  Uri? _origin;

  String _decode(Uri u) {
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    return '/${segs.join('/')}';
  }

  /// `/dav/a/b` -> `/a/b`; null when outside the mount.
  String? _local(Uri u) {
    final full = _decode(u);
    if (mount.isEmpty) return full;
    if (full != mount && !full.startsWith('$mount/')) return null;
    final rest = full.substring(mount.length);
    return rest.isEmpty ? '/' : rest;
  }

  String _href(String path) {
    final segs = [
      ...mount.split('/').where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ];
    var h = "/${segs.map(Uri.encodeComponent).join("/")}";
    if (tree.isDir(path) && h != '/') h = '$h/';
    if (absoluteHrefs && _origin != null) {
      h = '${_origin!.scheme}://${_origin!.authority}$h';
    }
    return h;
  }

  String _entry(String path) {
    final isDir = tree.isDir(path);
    return '<D:response><D:href>${_href(path)}</D:href><D:propstat><D:prop>'
        '${isDir ? '<D:resourcetype><D:collection/></D:resourcetype>' : '<D:resourcetype/><D:getcontentlength>${tree.nodes[path]}</D:getcontentlength>'}'
        '<D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';
  }

  Future<Response> handle(Request req) async {
    final auth = 'Basic ${base64.encode(utf8.encode('admin:pw'))}';
    if (req.headers['authorization'] != auth) {
      return Response(401, headers: {'www-authenticate': 'Basic realm="x"'});
    }
    _origin = req.requestedUri;
    final path = _local(req.requestedUri);
    if (path == null) return Response.notFound('');
    if (redirectCollections &&
        req.method == 'PROPFIND' &&
        tree.isDir(path) &&
        !req.requestedUri.path.endsWith('/')) {
      return Response(301, headers: {'location': '${req.requestedUri.path}/'});
    }
    switch (req.method) {
      case 'PROPFIND':
        if (!tree.nodes.containsKey(path)) return Response.notFound('');
        final depth = req.headers['depth'] ?? '1';
        final paths = [path, if (depth != '0') ...tree.children(path)];
        return Response(
          207,
          body:
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
              '${paths.map(_entry).join()}</D:multistatus>',
          headers: {'content-type': 'application/xml; charset=utf-8'},
        );
      case 'MKCOL':
        if (tree.nodes.containsKey(path)) return Response(405);
        if (!tree.isDir(p.posix.dirname(path))) return Response(409);
        tree.nodes[path] = -1;
        return Response(201);
      case 'MOVE':
        if (!tree.nodes.containsKey(path)) return Response.notFound('');
        final dst = _local(Uri.parse(req.headers['destination']!));
        if (dst == null || !tree.isDir(p.posix.dirname(dst))) {
          return Response(409);
        }
        final exists = tree.nodes.containsKey(dst);
        if (exists && req.headers['overwrite'] == 'F') return Response(412);
        tree.relocate(path, dst);
        return Response(exists ? 204 : 201);
      case 'DELETE':
        if (!tree.nodes.containsKey(path)) return Response.notFound('');
        tree.delete(path);
        return Response(204);
    }
    return Response(405);
  }
}
