import 'dart:typed_data';

import '../storage/storage_backend.dart';

/// Budgeted sliding-window byte reader over [readRangeIfSupported].
///
/// Guarantees that total bytes fetched across all range reads never exceed
/// [maxBytes], and reuses already-buffered bytes when advancing sequentially.
class ProbeRangeReader {
  final StorageBackend backend;
  final String path;
  final int maxBytes;
  final int? fileSize;

  int _bytesRead = 0;
  int _bufStart = 0;
  Uint8List _buf = Uint8List(0);

  ProbeRangeReader(
    this.backend,
    this.path, {
    required this.maxBytes,
    this.fileSize,
  });

  int get bytesRead => _bytesRead;
  int get remaining => maxBytes - _bytesRead;

  /// Raw range read capped by [remaining] budget.
  Future<Uint8List?> readRaw(int start, int length) async {
    if (start < 0 || length <= 0 || remaining <= 0) return null;
    if (fileSize != null && start >= fileSize!) return Uint8List(0);
    var capped = length > remaining ? remaining : length;
    if (fileSize != null && start + capped > fileSize!) {
      capped = fileSize! - start;
    }
    if (capped <= 0) return Uint8List(0);
    final data = await readRangeIfSupported(backend, path, start, capped);
    if (data == null) return null;
    _bytesRead += data.length;
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  /// Ensures a window starting at [offset] with at least [minLength] bytes
  /// (fetching up to [preferredLength] when a new read is needed).
  ///
  /// Returns a slice starting at [offset], which may be shorter than
  /// [minLength] if EOF or the byte budget is reached, or `null` if no bytes
  /// can be read at [offset].
  Future<Uint8List?> window(
    int offset,
    int minLength, {
    int preferredLength = 64 * 1024,
  }) async {
    if (offset < 0 || minLength <= 0) return null;
    if (fileSize != null && offset >= fileSize!) return null;

    final bufEnd = _bufStart + _buf.length;
    // Fast path: fully satisfied by current buffer.
    if (offset >= _bufStart && offset + minLength <= bufEnd) {
      return Uint8List.sublistView(_buf, offset - _bufStart);
    }

    // Overlap path: keep buffered prefix and only fetch the missing tail.
    if (offset >= _bufStart && offset < bufEnd) {
      final prefixOffset = offset - _bufStart;
      final prefixLen = bufEnd - offset;
      final wantTotal = preferredLength > minLength
          ? preferredLength
          : minLength;
      final toFetch = wantTotal - prefixLen;
      final tail = await readRaw(bufEnd, toFetch);
      if (tail == null || tail.isEmpty) {
        return Uint8List.sublistView(_buf, prefixOffset);
      }
      final combined = Uint8List(prefixLen + tail.length)
        ..setRange(0, prefixLen, _buf, prefixOffset)
        ..setRange(prefixLen, prefixLen + tail.length, tail);
      _bufStart = offset;
      _buf = combined;
      return _buf;
    }

    // Disjoint jump: fetch fresh window at [offset].
    final fetchLen = preferredLength > minLength ? preferredLength : minLength;
    final chunk = await readRaw(offset, fetchLen);
    if (chunk == null || chunk.isEmpty) return null;
    _bufStart = offset;
    _buf = chunk;
    return _buf;
  }

  /// Seeds the buffer with an already-read chunk (e.g. initial probe head).
  void seed(int start, Uint8List bytes) {
    _bufStart = start;
    _buf = bytes;
  }
}

/// Priority score for selecting the primary audio track when multiple exist.
int audioCodecRank(String? codec) => switch (codec) {
  'Atmos' => 50,
  'DTS-X' => 45,
  'TrueHD' => 40,
  'DTS-HD' => 35,
  'FLAC' => 25,
  'EAC3' => 20,
  'DTS' => 18,
  'AC3' => 15,
  'Opus' => 12,
  'AAC' => 10,
  final s? when s.isNotEmpty => 5,
  _ => 0,
};
