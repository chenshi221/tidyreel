import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/scan.dart';
import 'storage_backend.dart';

/// Local folder backend; [root] is the connection endpoint.
class LocalBackend implements StorageBackend, RangeReadableBackend {
  final String root;

  LocalBackend(this.root);

  /// Maps an OS error code to [StorageErrorCode], distinguishing Windows
  /// Win32 error codes from POSIX errno values.
  static StorageErrorCode mapOsErrorCode(
    int? errorCode, {
    required bool isWindows,
  }) {
    if (isWindows) {
      return switch (errorCode) {
        2 || 3 => StorageErrorCode.notFound, // ERROR_FILE/PATH_NOT_FOUND
        80 ||
        183 => StorageErrorCode.alreadyExists, // ERROR_FILE/ALREADY_EXISTS
        5 ||
        32 ||
        33 => StorageErrorCode.busy, // ACCESS_DENIED / SHARING / LOCK
        _ => StorageErrorCode.other,
      };
    }
    return switch (errorCode) {
      2 => StorageErrorCode.notFound, // ENOENT
      1 || 13 => StorageErrorCode.unauthorized, // EPERM / EACCES
      16 => StorageErrorCode.busy, // EBUSY
      17 || 39 || 66 => StorageErrorCode.alreadyExists, // EEXIST / ENOTEMPTY
      _ => StorageErrorCode.other,
    };
  }

  /// Maps a '/'-rooted path to a real path, refusing anything that escapes [root].
  String _real(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segs = normalized.split('/').where((s) => s.isNotEmpty && s != '.');
    if (segs.contains('..')) {
      throw StorageException(StorageErrorCode.other, '路径超出根目录范围：$path');
    }
    final resolved = p.joinAll([root, ...segs]);
    if (!p.isWithin(root, resolved) && resolved != root) {
      throw StorageException(StorageErrorCode.other, '路径超出根目录范围：$path');
    }
    return resolved;
  }

  String _virtual(String dir, String name) => p.posix.join(dir, name);

  Future<bool> _present(String real) async =>
      await FileSystemEntity.type(real, followLinks: false) !=
      FileSystemEntityType.notFound;

  Future<T> _io<T>(String path, Future<T> Function() op) async {
    try {
      return await op();
    } on FileSystemException catch (e) {
      final code = mapOsErrorCode(
        e.osError?.errorCode,
        isWindows: Platform.isWindows,
      );
      final osMsg = e.osError?.message;
      final detail = osMsg != null && osMsg.isNotEmpty
          ? '${e.message}（$osMsg）'
          : e.message;
      throw StorageException(code, '本地存储操作失败（$path）：$detail');
    }
  }

  @override
  Future<List<int>> read(String path) async =>
      _io(path, () => File(_real(path)).readAsBytes());

  @override
  Future<List<int>> readRange(String path, int start, int length) async {
    final real = _real(path);
    if (start < 0 || length <= 0) return const [];
    return _io(path, () async {
      final raf = await File(real).open(mode: FileMode.read);
      try {
        final fileLen = await raf.length();
        if (start >= fileLen) return const <int>[];
        final toRead = length < fileLen - start ? length : fileLen - start;
        await raf.setPosition(start);
        return await raf.read(toRead);
      } finally {
        await raf.close();
      }
    });
  }

  @override
  Future<void> write(String path, List<int> bytes) => _io(path, () async {
    final f = File(_real(path));
    await f.parent.create(recursive: true);
    // exclusive: EEXIST (→ alreadyExists) instead of replacing what's there.
    await f.create(exclusive: true);
    try {
      await f.writeAsBytes(bytes, flush: true);
    } on Object {
      try {
        await f.delete();
      } on Object {
        // best-effort cleanup of empty file
      }
      rethrow;
    }
  });

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    final d = Directory(_real(dir));
    if (!await d.exists()) {
      throw StorageException(StorageErrorCode.notFound, '目录不存在：$dir');
    }
    return _io(dir, () async {
      final out = <RemoteEntry>[];
      await for (final e in d.list(followLinks: false)) {
        final isDir = e is Directory;
        final st = await e.stat();
        final size = isDir ? 0 : (st.size < 0 ? 0 : st.size);
        out.add(
          RemoteEntry(
            path: _virtual(dir, p.basename(e.path)),
            name: p.basename(e.path),
            isDir: isDir,
            size: size,
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
    final type = await FileSystemEntity.type(real, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StorageException(StorageErrorCode.alreadyExists, '路径已存在且不是目录：$dir');
    }
    await _io(dir, () => Directory(real).create(recursive: true));
  }

  Future<void> _relocate(String from, String to) async {
    final src = _real(from), dst = _real(to);
    final srcType = await FileSystemEntity.type(src, followLinks: false);
    if (srcType == FileSystemEntityType.notFound) {
      throw StorageException(StorageErrorCode.notFound, '源路径不存在：$from');
    }
    if (from == to) return;
    // rename(2) silently overwrites, so check first.
    if (await _present(dst) && !await _sameEntry(src, dst)) {
      throw StorageException(StorageErrorCode.alreadyExists, '目标已存在：$to');
    }
    await _io(from, () async {
      switch (srcType) {
        case FileSystemEntityType.directory:
          await Directory(src).rename(dst);
        case FileSystemEntityType.link:
          await Link(src).rename(dst);
        default:
          await File(src).rename(dst);
      }
    });
  }

  /// Does [dst] only exist because the file system folds names (case on
  /// APFS / NTFS, Unicode normalization on macOS), i.e. it *is* [src]? Then the
  /// folder has no entry spelled exactly like [dst]. A hard link or symlink to
  /// [src] also resolves to the same file but has its own entry: rename(2)
  /// would silently do nothing (hard link) or replace the link.
  Future<bool> _sameEntry(String src, String dst) async {
    if (await FileSystemEntity.type(dst, followLinks: false) ==
        FileSystemEntityType.link) {
      return false;
    }
    if (!await FileSystemEntity.identical(src, dst)) return false;
    final name = p.basename(dst);
    await for (final e in Directory(p.dirname(dst)).list(followLinks: false)) {
      if (p.basename(e.path) == name) return false;
    }
    return true;
  }

  @override
  Future<void> rename(String path, String newName) async {
    if (newName.isEmpty ||
        newName.contains('/') ||
        newName.contains('\\') ||
        newName == '..' ||
        newName == '.') {
      throw StorageException(StorageErrorCode.other, '无效的文件名：$newName');
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
    if (names.isEmpty) return;
    if (!await Directory(_real(dstDir)).exists()) {
      throw StorageException(StorageErrorCode.notFound, '目标目录不存在：$dstDir');
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
      final type = await FileSystemEntity.type(real, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        throw StorageException(StorageErrorCode.notFound, '路径不存在：$path');
      }
      await _io(path, () async {
        switch (type) {
          case FileSystemEntityType.directory:
            await Directory(real).delete(recursive: true);
          case FileSystemEntityType.link:
            await Link(real).delete();
          default:
            await File(real).delete();
        }
      });
    }
  }

  @override
  Future<bool> exists(String path) async => _present(_real(path));

  @override
  Future<void> ping() async {
    if (!await Directory(root).exists()) {
      throw StorageException(StorageErrorCode.notFound, '本地目录不存在：$root');
    }
  }

  @override
  Future<void> close() async {}
}
