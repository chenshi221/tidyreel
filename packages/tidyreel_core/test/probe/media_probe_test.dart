import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tidyreel_core/src/storage/local_backend.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

// ---------------------------------------------------------------------------
// Binary EBML (MKV / WebM) fixture builder helpers
// ---------------------------------------------------------------------------

Uint8List _ebmlIdBytes(int id) {
  if (id <= 0xFF) return Uint8List.fromList([id]);
  if (id <= 0xFFFF) return Uint8List.fromList([(id >> 8) & 0xFF, id & 0xFF]);
  if (id <= 0xFFFFFF) {
    return Uint8List.fromList([(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF]);
  }
  return Uint8List.fromList([
    (id >> 24) & 0xFF,
    (id >> 16) & 0xFF,
    (id >> 8) & 0xFF,
    id & 0xFF,
  ]);
}

Uint8List _ebmlSizeBytes(int size) {
  if (size < 0x7F) return Uint8List.fromList([0x80 | size]);
  if (size < 0x3FFF) {
    return Uint8List.fromList([0x40 | (size >> 8), size & 0xFF]);
  }
  if (size < 0x1FFFFF) {
    return Uint8List.fromList([
      0x20 | (size >> 16),
      (size >> 8) & 0xFF,
      size & 0xFF,
    ]);
  }
  return Uint8List.fromList([
    0x10 | (size >> 24),
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
  ]);
}

Uint8List _ebmlElem(int id, List<int> payload, {bool unknownSize = false}) {
  final b = BytesBuilder(copy: false)
    ..add(_ebmlIdBytes(id))
    ..add(
      unknownSize
          ? const [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
          : _ebmlSizeBytes(payload.length),
    )
    ..add(payload);
  return b.takeBytes();
}

Uint8List _ebmlUintPayload(int value) {
  if (value == 0) return Uint8List.fromList([0]);
  final out = <int>[];
  var v = value;
  while (v > 0) {
    out.insert(0, v & 0xFF);
    v >>= 8;
  }
  return Uint8List.fromList(out);
}

Uint8List _ebmlUint(int id, int value) =>
    _ebmlElem(id, _ebmlUintPayload(value));

Uint8List _ebmlStr(int id, String value) => _ebmlElem(id, utf8.encode(value));

Uint8List _ebmlFloat32(int id, double value) {
  final bd = ByteData(4)..setFloat32(0, value, Endian.big);
  return _ebmlElem(id, bd.buffer.asUint8List());
}

Uint8List _ebmlFloat64(int id, double value) {
  final bd = ByteData(8)..setFloat64(0, value, Endian.big);
  return _ebmlElem(id, bd.buffer.asUint8List());
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

Uint8List _ebmlHeader({String docType = 'matroska'}) => _ebmlElem(
  0x1A45DFA3,
  _concat([
    _ebmlUint(0x4286, 1), // EBMLVersion
    _ebmlStr(0x4282, docType), // DocType
  ]),
);

Uint8List _mkvInfo({
  int timestampScale = 1000000,
  required double duration,
  bool float32 = false,
}) => _ebmlElem(
  0x1549A966,
  _concat([
    _ebmlUint(0x2AD7B1, timestampScale),
    float32 ? _ebmlFloat32(0x4489, duration) : _ebmlFloat64(0x4489, duration),
  ]),
);

Uint8List _mkvVideoTrack({
  required String codecId,
  required int width,
  required int height,
  int? transferCharacteristics,
  int? blockAddIdType,
  String? name,
  List<int>? codecPrivate,
}) => _ebmlElem(
  0xAE,
  _concat([
    _ebmlUint(0xD7, 1), // TrackNumber
    _ebmlUint(0x83, 1), // TrackType = video
    _ebmlStr(0x86, codecId),
    if (name != null) _ebmlStr(0x536E, name),
    if (codecPrivate != null) _ebmlElem(0x63A2, codecPrivate),
    _ebmlElem(
      0xE0,
      _concat([
        _ebmlUint(0xB0, width),
        _ebmlUint(0xBA, height),
        if (transferCharacteristics != null)
          _ebmlElem(0x55B0, _ebmlUint(0x55BA, transferCharacteristics)),
      ]),
    ),
    if (blockAddIdType != null)
      _ebmlElem(0x41E4, _ebmlUint(0x41E7, blockAddIdType)),
  ]),
);

Uint8List _mkvAudioTrack({
  required String codecId,
  required int channels,
  String? name,
  int trackNumber = 2,
}) => _ebmlElem(
  0xAE,
  _concat([
    _ebmlUint(0xD7, trackNumber),
    _ebmlUint(0x83, 2), // TrackType = audio
    _ebmlStr(0x86, codecId),
    if (name != null) _ebmlStr(0x536E, name),
    _ebmlElem(0xE1, _ebmlUint(0x9F, channels)),
  ]),
);

Uint8List _mkvSeekEntry(int targetId, int positionInSegment) => _ebmlElem(
  0x4DBB,
  _concat([
    _ebmlElem(0x53AB, _ebmlIdBytes(targetId)),
    _ebmlUint(0x53AC, positionInSegment),
  ]),
);

// ---------------------------------------------------------------------------
// Binary MP4 / MOV (ISO BMFF) fixture builder helpers
// ---------------------------------------------------------------------------

Uint8List _box(String type, List<int> payload, {bool largeSize = false}) {
  final typeBytes = ascii.encode(type);
  assert(typeBytes.length == 4);
  if (largeSize) {
    final total = 16 + payload.length;
    final hdr = ByteData(16)
      ..setUint32(0, 1, Endian.big)
      ..setUint32(8, total >> 32, Endian.big)
      ..setUint32(12, total & 0xFFFFFFFF, Endian.big);
    final hdrBytes = hdr.buffer.asUint8List()..setRange(4, 8, typeBytes);
    return _concat([hdrBytes, payload]);
  }
  final total = 8 + payload.length;
  final hdr = ByteData(8)..setUint32(0, total, Endian.big);
  final hdrBytes = hdr.buffer.asUint8List()..setRange(4, 8, typeBytes);
  return _concat([hdrBytes, payload]);
}

Uint8List _fullBox(String type, int version, int flags, List<int> body) {
  final vf = Uint8List.fromList([
    version & 0xFF,
    (flags >> 16) & 0xFF,
    (flags >> 8) & 0xFF,
    flags & 0xFF,
  ]);
  return _box(type, _concat([vf, body]));
}

Uint8List _ftypBox([String majorBrand = 'isom']) => _box(
  'ftyp',
  _concat([
    ascii.encode(majorBrand),
    const [0, 0, 2, 0],
    ascii.encode(majorBrand),
    ascii.encode('mp41'),
  ]),
);

Uint8List _mvhdV0({required int timescale, required int duration}) {
  final body = ByteData(16)
    ..setUint32(0, 0, Endian.big) // creation_time
    ..setUint32(4, 0, Endian.big) // modification_time
    ..setUint32(8, timescale, Endian.big)
    ..setUint32(12, duration, Endian.big);
  return _fullBox('mvhd', 0, 0, body.buffer.asUint8List());
}

Uint8List _mvhdV1({required int timescale, required int duration}) {
  final body = ByteData(28)
    ..setUint32(16, timescale, Endian.big)
    ..setUint32(20, duration >> 32, Endian.big)
    ..setUint32(24, duration & 0xFFFFFFFF, Endian.big);
  return _fullBox('mvhd', 1, 0, body.buffer.asUint8List());
}

Uint8List _colrBox({
  String colourType = 'nclx',
  int primaries = 9,
  required int transfer,
  int matrix = 9,
}) {
  final bd = ByteData(6)
    ..setUint16(0, primaries, Endian.big)
    ..setUint16(2, transfer, Endian.big)
    ..setUint16(4, matrix, Endian.big);
  return _box(
    'colr',
    _concat([
      ascii.encode(colourType),
      bd.buffer.asUint8List(),
      if (colourType == 'nclx') const [0],
    ]),
  );
}

Uint8List _dvccBox() => _box('dvcC', Uint8List(24));

Uint8List _dec3Box({required bool atmosJoc, int acmod = 7, int lfeon = 1}) {
  // 1 independent substream (num_ind_sub = 0), 0 dependent substreams.
  final b0 = 0x00;
  final b1 = 0x00; // num_ind_sub = 0
  final sub0 = 0x00;
  final sub1 = ((acmod & 0x07) << 1) | (lfeon & 0x01);
  final sub2 = 0x00; // num_dep_sub = 0
  return _box('dec3', [
    b0,
    b1,
    sub0,
    sub1,
    sub2,
    if (atmosJoc) ...[0x01, 0x10], // flag_ec3_extension_type_a=1, complexity=16
  ]);
}

Uint8List _videoSampleEntry(
  String fourcc, {
  required int width,
  required int height,
  List<Uint8List> children = const [],
}) {
  // VisualSampleEntry payload is 78 bytes before child boxes.
  final payload = Uint8List(78);
  final bd = ByteData.sublistView(payload);
  bd.setUint16(6, 1, Endian.big); // data_reference_index
  bd.setUint16(24, width, Endian.big);
  bd.setUint16(26, height, Endian.big);
  bd.setUint32(28, 0x00480000, Endian.big);
  bd.setUint32(32, 0x00480000, Endian.big);
  bd.setUint16(40, 1, Endian.big); // frame_count
  bd.setUint16(74, 0x0018, Endian.big); // depth
  bd.setInt16(76, -1, Endian.big);
  return _box(fourcc, _concat([payload, ...children]));
}

Uint8List _audioSampleEntry(
  String fourcc, {
  required int channels,
  List<Uint8List> children = const [],
}) {
  // AudioSampleEntry v0 payload is 28 bytes before child boxes.
  final payload = Uint8List(28);
  final bd = ByteData.sublistView(payload);
  bd.setUint16(6, 1, Endian.big); // data_reference_index
  bd.setUint16(16, channels, Endian.big);
  bd.setUint16(18, 16, Endian.big); // sample size
  bd.setUint32(24, 48000 << 16, Endian.big); // sample rate 16.16
  return _box(fourcc, _concat([payload, ...children]));
}

Uint8List _trakBox(List<Uint8List> sampleEntries) {
  final count = ByteData(4)..setUint32(0, sampleEntries.length, Endian.big);
  final stsd = _fullBox(
    'stsd',
    0,
    0,
    _concat([count.buffer.asUint8List(), ...sampleEntries]),
  );
  return _box('trak', _box('mdia', _box('minf', _box('stbl', stsd))));
}

// ---------------------------------------------------------------------------
// Virtual sparse multi-GB backend for testing trailing-moov / SeekHead jumps
// ---------------------------------------------------------------------------

class _SparseRangeBackend extends MemoryStorageBackend {
  final int virtualSize;
  final Map<int, Uint8List> segments;
  int totalBytesRead = 0;
  int readCalls = 0;

  _SparseRangeBackend(String path, this.virtualSize, this.segments) {
    addFile(path, virtualSize);
  }

  @override
  Future<List<int>> readRange(String path, int start, int length) async {
    readCalls++;
    if (start < 0 || length <= 0 || start >= virtualSize) return const [];
    final actualLen = start + length > virtualSize
        ? virtualSize - start
        : length;
    final out = Uint8List(actualLen);
    for (final MapEntry(key: segStart, value: segData) in segments.entries) {
      final segEnd = segStart + segData.length;
      final overlapStart = start > segStart ? start : segStart;
      final overlapEnd = (start + actualLen) < segEnd
          ? (start + actualLen)
          : segEnd;
      if (overlapStart < overlapEnd) {
        out.setRange(
          overlapStart - start,
          overlapEnd - start,
          segData,
          overlapStart - segStart,
        );
      }
    }
    totalBytesRead += out.length;
    return out;
  }
}

/// A minimal StorageBackend that does NOT implement RangeReadableBackend.
class _NonRangeBackend implements StorageBackend {
  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async =>
      const [];
  @override
  Future<void> mkdirs(String dir) async {}
  @override
  Future<void> rename(String path, String newName) async {}
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {}
  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {}
  @override
  Future<void> remove(String dir, List<String> names) async {}
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<List<int>> read(String path) async => const [];
  @override
  Future<void> write(String path, List<int> bytes) async {}
  @override
  Future<void> ping() async {}
  @override
  Future<void> close() async {}
}

class _ThrowingRangeBackend extends MemoryStorageBackend {
  final Object error;
  _ThrowingRangeBackend(this.error);

  @override
  Future<List<int>> readRange(String path, int start, int length) =>
      Future.error(error);
}

void main() {
  const probe = ContainerMediaProbe();

  group('MKV / WebM (EBML)', () {
    test(
      'parses 4K HEVC + Dolby Vision (dvcC) + TrueHD Atmos (8ch) + duration',
      () async {
        final info = _mkvInfo(
          timestampScale: 1000000, // 1 ms
          duration: 7542500.0, // 7542.5 s = 2h 5m 42.5s
        );
        final tracks = _ebmlElem(
          0x1654AE6B,
          _concat([
            _mkvVideoTrack(
              codecId: 'V_MPEGH/ISO/HEVC',
              width: 3840,
              height: 2160,
              transferCharacteristics: 16, // PQ (HDR10) - DV must override this
              blockAddIdType: 0x64766343, // dvcC -> DV
            ),
            // Lower-priority AAC track first; Atmos track second should be preferred.
            _mkvAudioTrack(
              codecId: 'A_AAC',
              channels: 2,
              name: 'Commentary',
              trackNumber: 2,
            ),
            _mkvAudioTrack(
              codecId: 'A_TRUEHD',
              channels: 8,
              name: 'English TrueHD Atmos 7.1',
              trackNumber: 3,
            ),
          ]),
        );
        final mkv = _concat([
          _ebmlHeader(),
          _ebmlElem(
            0x18538067,
            _concat([info, tracks, _ebmlElem(0x1F43B675, Uint8List(32))]),
          ),
        ]);

        final fs = MemoryStorageBackend();
        await fs.write('/movies/Dune.mkv', mkv);

        final result = await probe.probe(
          fs,
          '/movies/Dune.mkv',
          fileSize: mkv.length,
        );
        expect(result, isNotNull);
        expect(result!.width, 3840);
        expect(result.height, 2160);
        expect(result.resolution, '2160p');
        expect(result.videoCodec, 'HEVC');
        expect(result.hdr, 'DV');
        expect(result.audioCodec, 'Atmos');
        expect(result.audioChannels, 8);
        expect(result.extraInfoSummary, '2160p.DV.Atmos');
        expect(result.container, 'mkv');
        expect(result.duration, const Duration(milliseconds: 7542500));
      },
    );

    test(
      'parses 1080p H.264 + HDR10 + EAC3 (6ch) with float32 duration',
      () async {
        final info = _mkvInfo(
          timestampScale: 1000000,
          duration: 2700000.0, // 45 min
          float32: true,
        );
        final tracks = _ebmlElem(
          0x1654AE6B,
          _concat([
            _mkvVideoTrack(
              codecId: 'V_MPEG4/ISO/AVC',
              width: 1920,
              height: 1080,
              transferCharacteristics: 16,
            ),
            _mkvAudioTrack(codecId: 'A_EAC3', channels: 6),
          ]),
        );
        final mkv = _concat([
          _ebmlHeader(),
          _ebmlElem(0x18538067, _concat([info, tracks]), unknownSize: true),
        ]);

        final fs = MemoryStorageBackend();
        await fs.write('/tv/S01E01.mkv', mkv);

        final result = await probe.probe(fs, '/tv/S01E01.mkv');
        expect(result, isNotNull);
        expect(result!.width, 1920);
        expect(result.height, 1080);
        expect(result.resolution, '1080p');
        expect(result.videoCodec, 'H.264');
        expect(result.hdr, 'HDR10');
        expect(result.audioCodec, 'EAC3');
        expect(result.audioChannels, 6);
        expect(result.extraInfoSummary, '1080p.HDR10');
        expect(result.container, 'mkv');
        expect(result.duration, const Duration(minutes: 45));
      },
    );

    test('parses WebM VP9 + Opus + HLG', () async {
      final info = _mkvInfo(timestampScale: 1000000, duration: 120000.0);
      final tracks = _ebmlElem(
        0x1654AE6B,
        _concat([
          _mkvVideoTrack(
            codecId: 'V_VP9',
            width: 2560,
            height: 1440,
            transferCharacteristics: 18,
          ),
          _mkvAudioTrack(codecId: 'A_OPUS', channels: 2),
        ]),
      );
      final webm = _concat([
        _ebmlHeader(docType: 'webm'),
        _ebmlElem(0x18538067, _concat([info, tracks])),
      ]);

      final fs = MemoryStorageBackend();
      await fs.write('/clips/sample.webm', webm);

      final result = await probe.probe(fs, '/clips/sample.webm');
      expect(result, isNotNull);
      expect(result!.width, 2560);
      expect(result.height, 1440);
      expect(result.resolution, '1440p');
      expect(result.videoCodec, 'VP9');
      expect(result.hdr, 'HLG');
      expect(result.audioCodec, 'Opus');
      expect(result.audioChannels, 2);
      expect(result.container, 'webm');
      expect(result.duration, const Duration(minutes: 2));
    });

    test('follows SeekHead past Cluster in huge virtual MKV within 512 KiB budget and detects HDR10+ & DTS-X', () async {
      const virtualSize = 2 * 1024 * 1024 * 1024; // 2 GiB
      final ebml = _ebmlHeader();
      // Segment with unknown size: 4-byte ID + 8-byte unknown VINT = 12 bytes.
      final segHeader = _concat([
        _ebmlIdBytes(0x18538067),
        const [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
      ]);
      final segDataStart = ebml.length + segHeader.length;

      final info = _mkvInfo(duration: 3600000.0);
      final tracks = _ebmlElem(
        0x1654AE6B,
        _concat([
          _mkvVideoTrack(
            codecId: 'V_AV1',
            width: 3840,
            height: 2160,
            transferCharacteristics: 16,
            codecPrivate: ascii.encode('meta:HDR10+'),
          ),
          _mkvAudioTrack(
            codecId: 'A_DTS',
            channels: 8,
            name: 'DTS:X Master Audio',
          ),
        ]),
      );

      // Place Info and Tracks near the 2 GiB tail, referenced by SeekHead!
      final tailOffsetInFile = virtualSize - info.length - tracks.length;
      final infoRelPos = tailOffsetInFile - segDataStart;
      final tracksRelPos = infoRelPos + info.length;

      final seekHead = _ebmlElem(
        0x114D9B74,
        _concat([
          _mkvSeekEntry(0x1549A966, infoRelPos),
          _mkvSeekEntry(0x1654AE6B, tracksRelPos),
        ]),
      );
      // Cluster starts immediately after SeekHead.
      final clusterHeader = _concat([
        _ebmlIdBytes(0x1F43B675),
        const [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
      ]);

      final headBlock = _concat([ebml, segHeader, seekHead, clusterHeader]);
      final tailBlock = _concat([info, tracks]);

      final be = _SparseRangeBackend('/big.mkv', virtualSize, {
        0: headBlock,
        tailOffsetInFile: tailBlock,
      });

      final result = await probe.probe(be, '/big.mkv', fileSize: virtualSize);
      expect(result, isNotNull);
      expect(result!.videoCodec, 'AV1');
      expect(result.hdr, 'HDR10+');
      expect(result.audioCodec, 'DTS-X');
      expect(result.audioChannels, 8);
      expect(result.extraInfoSummary, '2160p.HDR10+.DTS-X');
      expect(result.duration, const Duration(hours: 1));
      expect(be.totalBytesRead, lessThanOrEqualTo(512 * 1024));
    });

    test('detects MKV by magic bytes even without extension', () async {
      final mkv = _concat([
        _ebmlHeader(),
        _ebmlElem(
          0x18538067,
          _ebmlElem(
            0x1654AE6B,
            _mkvVideoTrack(codecId: 'V_MPEG2', width: 1280, height: 720),
          ),
        ),
      ]);
      final fs = MemoryStorageBackend();
      await fs.write('/extensionless_video', mkv);
      final result = await probe.probe(fs, '/extensionless_video');
      expect(result, isNotNull);
      expect(result!.videoCodec, 'MPEG-2');
      expect(result.resolution, '720p');
      expect(result.container, 'mkv');
    });
  });

  group('MP4 / MOV / M4V (ISO BMFF)', () {
    test('parses fast-start MP4 with cinema aspect 3840x1600, colr PQ (HDR10), ec-3 6ch, mvhd v0', () async {
      final moov = _box(
        'moov',
        _concat([
          _mvhdV0(timescale: 1000, duration: 5400000), // 90 min
          _trakBox([
            _videoSampleEntry(
              'hvc1',
              width: 3840,
              height: 1600,
              children: [_colrBox(transfer: 16)],
            ),
          ]),
          _trakBox([_audioSampleEntry('ec-3', channels: 6)]),
        ]),
      );
      final mp4 = _concat([_ftypBox(), moov, _box('mdat', Uint8List(64))]);

      final fs = MemoryStorageBackend();
      await fs.write('/movies/Blade.Runner.mp4', mp4);

      final result = await probe.probe(
        fs,
        '/movies/Blade.Runner.mp4',
        fileSize: mp4.length,
      );
      expect(result, isNotNull);
      expect(result!.width, 3840);
      expect(result.height, 1600);
      expect(result.resolution, '2160p');
      expect(result.videoCodec, 'HEVC');
      expect(result.hdr, 'HDR10');
      expect(result.audioCodec, 'EAC3');
      expect(result.audioChannels, 6);
      expect(result.extraInfoSummary, '2160p.HDR10');
      expect(result.duration, const Duration(minutes: 90));
      expect(result.container, 'mp4');
    });

    test('parses trailing-moov 4 GiB MP4 within 512 KiB budget with mvhd v1 and dec3 Atmos JOC', () async {
      const mdatSize = 4 * 1024 * 1024 * 1024; // 4 GiB simulated mdat
      final ftyp = _ftypBox();

      // 64-bit largesize mdat header (16 bytes), followed by 4GiB - 16 zero bytes.
      final mdatHdr = ByteData(16)
        ..setUint32(0, 1, Endian.big)
        ..setUint32(8, mdatSize >> 32, Endian.big)
        ..setUint32(12, mdatSize & 0xFFFFFFFF, Endian.big);
      final mdatHdrBytes = mdatHdr.buffer.asUint8List()
        ..setRange(4, 8, ascii.encode('mdat'));

      final moov = _box(
        'moov',
        _concat([
          _mvhdV1(timescale: 90000, duration: 90000 * 6000), // 100 min
          _trakBox([
            _videoSampleEntry(
              'hvc1',
              width: 3840,
              height: 2160,
              children: [_colrBox(transfer: 16), _dvccBox()],
            ),
          ]),
          _trakBox([_audioSampleEntry('mp4a', channels: 2)]),
          _trakBox([
            _audioSampleEntry(
              'ec-3',
              channels: 6,
              children: [_dec3Box(atmosJoc: true)],
            ),
          ]),
        ]),
      );

      final moovOffset = ftyp.length + mdatSize;
      final totalSize = moovOffset + moov.length;
      final be = _SparseRangeBackend('/4k_tail.mp4', totalSize, {
        0: _concat([ftyp, mdatHdrBytes]),
        moovOffset: moov,
      });

      final result = await probe.probe(be, '/4k_tail.mp4', fileSize: totalSize);
      expect(result, isNotNull);
      expect(result!.width, 3840);
      expect(result.height, 2160);
      expect(result.resolution, '2160p');
      expect(result.videoCodec, 'HEVC');
      expect(result.hdr, 'DV');
      expect(result.audioCodec, 'Atmos');
      expect(result.audioChannels, 6);
      expect(result.extraInfoSummary, '2160p.DV.Atmos');
      expect(result.duration, const Duration(minutes: 100));
      expect(result.container, 'mp4');
      expect(be.totalBytesRead, lessThanOrEqualTo(512 * 1024));
      expect(be.readCalls, lessThanOrEqualTo(3));
    });

    test('parses Dolby Vision dvh1 MP4 and MOV container with HLG', () async {
      final dvMoov = _box(
        'moov',
        _concat([
          _mvhdV0(timescale: 1000, duration: 60000),
          _trakBox([_videoSampleEntry('dvh1', width: 3840, height: 2160)]),
          _trakBox([_audioSampleEntry('mlpa', channels: 8)]),
        ]),
      );
      final dvMp4 = _concat([_ftypBox(), dvMoov]);
      final fs = MemoryStorageBackend();
      await fs.write('/dv.m4v', dvMp4);

      final dvRes = await probe.probe(fs, '/dv.m4v');
      expect(dvRes, isNotNull);
      expect(dvRes!.videoCodec, 'HEVC');
      expect(dvRes.hdr, 'DV');
      expect(dvRes.audioCodec, 'TrueHD');
      expect(dvRes.audioChannels, 8);
      expect(dvRes.container, 'mp4');

      final movMoov = _box(
        'moov',
        _concat([
          _mvhdV0(timescale: 600, duration: 600 * 30),
          _trakBox([
            _videoSampleEntry(
              'avc1',
              width: 1920,
              height: 1080,
              children: [_colrBox(colourType: 'nclc', transfer: 18)],
            ),
          ]),
          _trakBox([_audioSampleEntry('fLaC', channels: 2)]),
        ]),
      );
      final mov = _concat([_ftypBox('qt  '), movMoov]);
      await fs.write('/iphone.mov', mov);

      final movRes = await probe.probe(fs, '/iphone.mov');
      expect(movRes, isNotNull);
      expect(movRes!.videoCodec, 'H.264');
      expect(movRes.hdr, 'HLG');
      expect(movRes.audioCodec, 'FLAC');
      expect(movRes.duration, const Duration(seconds: 30));
      expect(movRes.container, 'mov');
    });

    test('falls back to tail chunk scan when mdat has size == 0', () async {
      final ftyp = _ftypBox();
      // mdat with size == 0 (normally means to EOF) followed by moov at tail.
      final badMdatHdr = Uint8List.fromList([
        0,
        0,
        0,
        0,
        0x6D,
        0x64,
        0x61,
        0x74,
      ]);
      final moov = _box(
        'moov',
        _concat([
          _mvhdV0(timescale: 1000, duration: 15000),
          _trakBox([_videoSampleEntry('av01', width: 1920, height: 1080)]),
        ]),
      );
      const virtualSize = 10 * 1024 * 1024; // 10 MiB
      final moovOffset = virtualSize - moov.length;
      final be = _SparseRangeBackend('/tail_fallback.mp4', virtualSize, {
        0: _concat([ftyp, badMdatHdr]),
        moovOffset: moov,
      });

      final res = await probe.probe(
        be,
        '/tail_fallback.mp4',
        fileSize: virtualSize,
      );
      expect(res, isNotNull);
      expect(res!.videoCodec, 'AV1');
      expect(res.resolution, '1080p');
      expect(res.duration, const Duration(seconds: 15));
      expect(be.totalBytesRead, lessThanOrEqualTo(512 * 1024));
    });
  });

  group('Graceful failure & wrapper integration', () {
    test('returns null on corrupt, truncated, empty, non-video, and non-range backends', () async {
      final fs = MemoryStorageBackend();
      await fs.write('/corrupt.mkv', [0x1A, 0x45, 0xDF, 0xA3, 0xFF, 0xFF]);
      await fs.write('/truncated.mp4', [0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70]);
      await fs.write('/garbage.mp4', utf8.encode('not a video file at all!'));
      await fs.write('/empty.mkv', const []);
      await fs.write('/notes.txt', utf8.encode('hello world'));
      await fs.write('/legacy.avi', utf8.encode('RIFF....AVI '));

      expect(await probe.probe(fs, '/corrupt.mkv'), isNull);
      expect(await probe.probe(fs, '/truncated.mp4'), isNull);
      expect(await probe.probe(fs, '/garbage.mp4'), isNull);
      expect(await probe.probe(fs, '/empty.mkv'), isNull);
      expect(await probe.probe(fs, '/notes.txt'), isNull);
      expect(await probe.probe(fs, '/legacy.avi'), isNull);
      expect(await probe.probe(fs, '/missing.mkv'), isNull);

      // Non-range backends (raw, CachedBackend, ThrottledBackend) all return null safely.
      final nonRange = _NonRangeBackend();
      expect(await probe.probe(nonRange, '/movie.mkv'), isNull);
      expect(await probe.probe(CachedBackend(nonRange), '/movie.mkv'), isNull);
      expect(
        await probe.probe(
          ThrottledBackend(nonRange, minInterval: Duration.zero),
          '/movie.mkv',
        ),
        isNull,
      );

      // Throwing backend returns null without throwing.
      final throwing = _ThrowingRangeBackend(
        const StorageException(StorageErrorCode.network, 'offline'),
      );
      expect(await probe.probe(throwing, '/movie.mkv'), isNull);
    });

    test(
      'probes through LocalBackend, CachedBackend and ThrottledBackend',
      () async {
        final dir = Directory.systemTemp.createTempSync('tidyreel_probe_');
        addTearDown(() => dir.deleteSync(recursive: true));

        final mp4 = _concat([
          _ftypBox(),
          _box(
            'moov',
            _concat([
              _mvhdV0(timescale: 1000, duration: 42000),
              _trakBox([_videoSampleEntry('vp09', width: 1280, height: 720)]),
              _trakBox([_audioSampleEntry('Opus', channels: 2)]),
            ]),
          ),
        ]);
        File('${dir.path}/clip.mp4').writeAsBytesSync(mp4);

        final local = LocalBackend(dir.path);
        final wrapped = ThrottledBackend(
          CachedBackend(local),
          minInterval: Duration.zero,
        );

        final res = await probe.probe(
          wrapped,
          '/clip.mp4',
          fileSize: mp4.length,
        );
        expect(res, isNotNull);
        expect(res!.resolution, '720p');
        expect(res.videoCodec, 'VP9');
        expect(res.audioCodec, 'Opus');
        expect(res.audioChannels, 2);
        expect(res.duration, const Duration(seconds: 42));
      },
    );
  });
}
