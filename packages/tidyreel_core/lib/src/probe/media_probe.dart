import '../model/probe.dart';
import '../storage/storage_backend.dart';

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
/// Implemented by Worker 1 (`core-probe-storage`).
class ContainerMediaProbe implements MediaProbe {
  const ContainerMediaProbe();

  @override
  Future<MediaProbeInfo?> probe(
    StorageBackend backend,
    String path, {
    int? fileSize,
  }) async => null;
}
