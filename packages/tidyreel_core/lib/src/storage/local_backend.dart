import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/scan.dart';
import 'storage_backend.dart';

/// Local folder backend; [root] is the connection endpoint.
class LocalBackend implements StorageBackend {
  final String root;

  LocalBackend(this.root);

  /// Maps a '/'-rooted path to a real path, refusing anything that escapes [root].
  String _real(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segs = normalized.split('/').where((s) => s.isNotEmpty && s != '.');
    if (segs.contains('..')) {
      throw StorageException(
        StorageErrorCode.other,
        'path escapes root: $path',
      );
    }
    final resolved = p.joinAll([root, ...segs]);
    if (!p.isWithin(root, resolved) && resolved != root) {
      throw StorageException(
        StorageErrorCode.other,
        'path escapes root: $path',
      );
    }
    return resolved;
  }

  String _virtual(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  bool _present(String real) =>
      FileSystemEntity.typeSync(real, followLinks: false) !=
      FileSystemEntityType.notFound;

  Future<T> _io<T>(String path, Future<T> Function() op) async {
    try {
      return await op();
    } on FileSystemException catch (e) {
      final code = switch (e.osError?.errorCode) {
        2 || 3 => StorageErrorCode.notFound, // ENOENT / ERROR_PATH_NOT_FOUND
        17 || 66 || 183 => StorageErrorCode.alreadyExists,
        16 || 32 => StorageErrorCode.busy, // EBUSY / ERROR_SHARING_VIOLATION
        _ => StorageErrorCode.other,
      };
      throw StorageException(code, '$path: ${e.message}');
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final d = Directory(_real(dir));
    if (!d.existsSync()) throw StorageException(StorageErrorCode.notFound, dir);
    return _io(dir, () async {
      final out = <RemoteEntry>[];
      await for (final e in d.list(followLinks: false)) {
        final isDir = e is Directory;
        final st = e.statSync();
        out.add(
          RemoteEntry(
            path: _virtual(dir, p.basename(e.path)),
            name: p.basename(e.path),
            isDir: isDir,
            size: isDir ? 0 : st.size,
            modified: st.modified,
          ),
        );
      }
      return out;
    });
  }

  @override
  Future<void> mkdirs(String dir) async {
    final real = _real(dir);
    if (_present(real) && !Directory(real).existsSync()) {
      throw StorageException(StorageErrorCode.alreadyExists, dir);
    }
    await _io(dir, () => Directory(real).create(recursive: true));
  }

  Future<void> _relocate(String from, String to) async {
    final src = _real(from), dst = _real(to);
    if (!_present(src)) throw StorageException(StorageErrorCode.notFound, from);
    if (from == to) return;
    // rename(2) silently overwrites, so check first. On case-insensitive file
    // systems (APFS / NTFS), dst resolves to the same underlying file as src
    // for case-only renames; identicalSync distinguishes that from a distinct
    // existing target on case-sensitive file systems (ext4).
    if (_present(dst) && !FileSystemEntity.identicalSync(src, dst)) {
      throw StorageException(StorageErrorCode.alreadyExists, to);
    }
    await _io(from, () async {
      if (FileSystemEntity.isDirectorySync(src)) {
        await Directory(src).rename(dst);
      } else {
        await File(src).rename(dst);
      }
    });
  }

  @override
  Future<void> rename(String path, String newName) async {
    if (newName.isEmpty ||
        newName.contains('/') ||
        newName.contains('\\') ||
        newName == '..' ||
        newName == '.') {
      throw StorageException(StorageErrorCode.other, 'bad name: $newName');
    }
    await _relocate(path, _virtual(p.posix.dirname(path), newName));
  }

  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {
    for (final e in names.entries) {
      await rename(p.posix.join(dir, e.key), e.value);
    }
  }

  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {
    if (!Directory(_real(dstDir)).existsSync()) {
      throw StorageException(StorageErrorCode.notFound, dstDir);
    }
    for (final n in names) {
      await _relocate(_virtual(srcDir, n), _virtual(dstDir, n));
    }
  }

  @override
  Future<void> remove(String dir, List<String> names) async {
    for (final n in names) {
      final path = _virtual(dir, n);
      final real = _real(path);
      if (!_present(real)) {
        throw StorageException(StorageErrorCode.notFound, path);
      }
      await _io(path, () async {
        if (FileSystemEntity.isDirectorySync(real)) {
          await Directory(real).delete(recursive: true);
        } else {
          await File(real).delete();
        }
      });
    }
  }

  @override
  Future<bool> exists(String path) async => _present(_real(path));

  @override
  Future<void> ping() async {
    if (!Directory(root).existsSync()) {
      throw StorageException(StorageErrorCode.notFound, root);
    }
  }
}
