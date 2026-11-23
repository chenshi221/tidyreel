import 'dart:typed_data';

import '../model/probe.dart';
import '../storage/storage_backend.dart';
import 'ebml_probe.dart';
import 'mp4_probe.dart';
import 'probe_reader.dart';

/// Probes technical metadata (resolution, codec, HDR, audio, duration) by
/// reading container headers only (zero external binaries, sandbox-safe).
abstract interface class MediaProbe {
  /// Probes [path] on [backend] using range reads. Returns null when the format
  /// is unsupported, range reading is unavailable, or header parsing fails.
  Future<MediaProbeInfo?> probe(
    StorageBackend backend,
    String path, {
    int? fileSize,
  });
}

/// Pure-Dart container header probe for MKV/WebM (EBML) and MP4/MOV/M4V (ISO BMFF).
class ContainerMediaProbe implements MediaProbe {
  /// Default hard cap on total bytes read per file across all range requests.
  static const int defaultMaxReadBytes = 512 * 1024;
  static const int _initialChunkBytes = 64 * 1024;

  static const _supportedExts = {
    'mkv',
    'mka',
    'mks',
    'webm',
    'mp4',
    'm4v',
    'mov',
  };

  /// Maximum total bytes to read from storage per [probe] call.
  final int maxReadBytes;

  const ContainerMediaProbe({this.maxReadBytes = defaultMaxReadBytes});

  static String? _extensionOf(String path) {
    final norm = path.replaceAll('\\', '/');
    final slash = norm.lastIndexOf('/');
    final base = slash >= 0 ? norm.substring(slash + 1) : norm;
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || dot >= base.length - 1) return null;
    return base.substring(dot + 1).toLowerCase();
  }

  static bool _isEbmlMagic(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0x1A &&
      b[1] == 0x45 &&
      b[2] == 0xDF &&
      b[3] == 0xA3;

  @override
  Future<MediaProbeInfo?> probe(
    StorageBackend backend,
    String path, {
    int? fileSize,
  }) async {
    try {
      if (backend is! RangeReadableBackend) return null;
      final ext = _extensionOf(path);
      if (ext != null && !_supportedExts.contains(ext)) return null;

      final reader = ProbeRangeReader(
        backend,
        path,
        maxBytes: maxReadBytes,
        fileSize: fileSize,
      );
      final initialLen =
          fileSize != null && fileSize > 0 && fileSize < _initialChunkBytes
          ? fileSize
          : _initialChunkBytes;
      final head = await reader.readRaw(0, initialLen);
      if (head == null || head.length < 8) return null;

      if (_isEbmlMagic(head)) {
        return await probeEbml(reader, head, ext: ext, fileSize: fileSize);
      }
      if (isLikelyMp4(head, ext: ext)) {
        return await probeMp4(reader, head, ext: ext, fileSize: fileSize);
      }
      return null;
    } on Object {
      return null;
    }
  }
}
