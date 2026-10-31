import 'package:path/path.dart' as p;

import '../model/scan.dart';
import '../storage/storage_backend.dart';

/// A real (in-memory) filesystem with the same semantics the remote backends must have.
/// Also the reference for Agent C's shared backend test suite.
class MemoryStorageBackend implements StorageBackend {
  /// path -> size; directories are stored with size -1.
  final Map<String, int> _nodes = {'/': -1};

  MemoryStorageBackend([Map<String, int> files = const {}]) {
    files.forEach(addFile);
  }

  void addFile(String path, [int size = 1]) {
    _mkdirsSync(p.posix.dirname(path));
    _nodes[path] = size;
  }

  /// Every file path, sorted. Handy for asserting before/after states.
  List<String> get files =>
      (_nodes.entries.where((e) => e.value >= 0).map((e) => e.key).toList()
        ..sort());

  bool _isDir(String path) => _nodes[path] == -1;

  void _mkdirsSync(String dir) {
    for (
      var d = dir;
      d != '/' && !_nodes.containsKey(d);
      d = p.posix.dirname(d)
    ) {
      _nodes[d] = -1;
    }
  }

  void _requireDir(String dir) {
    if (!_isDir(dir)) throw StorageException(StorageErrorCode.notFound, dir);
  }

  Iterable<String> _subtree(String path) =>
      _nodes.keys.where((k) => k == path || k.startsWith('$path/')).toList();

  void _relocate(String from, String to) {
    if (!_nodes.containsKey(from)) {
      throw StorageException(StorageErrorCode.notFound, from);
    }
    if (_nodes.containsKey(to)) {
      throw StorageException(StorageErrorCode.alreadyExists, to);
    }
    for (final k in _subtree(from)) {
      _nodes['$to${k.substring(from.length)}'] = _nodes.remove(k)!;
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    _requireDir(dir);
    return _nodes.entries
        .where(
          (e) => e.key != '/' && e.key != dir && p.posix.dirname(e.key) == dir,
        )
        .map(
          (e) => RemoteEntry(
            path: e.key,
            name: p.posix.basename(e.key),
            isDir: e.value == -1,
            size: e.value < 0 ? 0 : e.value,
          ),
        )
        .toList();
  }

  @override
  Future<void> mkdirs(String dir) async {
    if (_nodes.containsKey(dir) && !_isDir(dir)) {
      throw StorageException(StorageErrorCode.alreadyExists, dir);
    }
    _mkdirsSync(dir);
  }

  @override
  Future<void> rename(String path, String newName) async =>
      _relocate(path, p.posix.join(p.posix.dirname(path), newName));

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    _requireDir(dstDir);
    for (final n in names) {
      _relocate(p.posix.join(srcDir, n), p.posix.join(dstDir, n));
    }
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    for (final n in names) {
      final path = p.posix.join(dir, n);
      if (!_nodes.containsKey(path)) {
        throw StorageException(StorageErrorCode.notFound, path);
      }
      _subtree(path).forEach(_nodes.remove);
    }
  }

  @override
  Future<bool> exists(String path) async => _nodes.containsKey(path);

  @override
  Future<void> ping() async {}
}
