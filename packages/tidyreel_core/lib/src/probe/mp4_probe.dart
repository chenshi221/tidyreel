import 'dart:typed_data';

import '../model/probe.dart';
import 'probe_reader.dart';

const _maxTopBoxes = 64;
const _maxTailRead = 256 * 1024;
const _maxSafeSize = 0x7FFFFFFFFFFFFF00;

const _validTopLevelTypes = {
  'ftyp',
  'moov',
  'mdat',
  'free',
  'skip',
  'wide',
  'pnot',
  'moof',
  'meta',
  'styp',
  'pdin',
};

const _moovChildTypes = {
  'mvhd',
  'trak',
  'udta',
  'iods',
  'mvex',
  'meta',
  'pssh',
  'cmov',
};

/// Whether [head] looks like an ISO BMFF (MP4 / MOV / M4V) container.
bool isLikelyMp4(Uint8List head, {required String? ext}) {
  if (head.length < 8) return false;
  final type = _readFourCC(head, 4);
  if (type == null) return false;
  if (type == 'ftyp') return true;
  // Older QuickTime MOV files may start with wide/mdat/moov/free without ftyp.
  if (ext == 'mov' || ext == 'mp4' || ext == 'm4v') {
    return _validTopLevelTypes.contains(type);
  }
  return false;
}

/// Probes an MP4 / MOV / M4V (ISO BMFF) container using [reader].
Future<MediaProbeInfo?> probeMp4(
  ProbeRangeReader reader,
  Uint8List head, {
  required String? ext,
  required int? fileSize,
}) async {
  reader.seed(0, head);

  String? majorBrand;
  Uint8List? moovBytes;

  var pos = 0;
  for (var i = 0; i < _maxTopBoxes; i++) {
    if (fileSize != null && pos >= fileSize) break;
    final win = await reader.window(pos, 16, preferredLength: _maxTailRead);
    if (win == null || win.length < 8) break;

    final hdr = _readBoxHeader(win, 0, win.length, pos, fileSize);
    if (hdr == null) break;

    final payloadStart = pos + hdr.headerSize;
    if (hdr.type == 'ftyp' &&
        majorBrand == null &&
        win.length >= hdr.headerSize + 4) {
      majorBrand = _readFourCC(win, hdr.headerSize);
    }

    if (hdr.type == 'moov') {
      final alreadyHave = win.length > hdr.headerSize
          ? win.length - hdr.headerSize
          : 0;
      final maxPossible = alreadyHave + reader.remaining;
      final remainingBox = hdr.boxSize != null
          ? hdr.boxSize! - hdr.headerSize
          : (fileSize != null ? fileSize - payloadStart : maxPossible);
      if (remainingBox <= 0) break;
      final want = remainingBox < maxPossible ? remainingBox : maxPossible;
      if (want <= 0) break;
      final moovWin = await reader.window(
        payloadStart,
        want,
        preferredLength: want,
      );
      if (moovWin != null && moovWin.isNotEmpty) {
        final len = want < moovWin.length ? want : moovWin.length;
        moovBytes = Uint8List.sublistView(moovWin, 0, len);
      }
      break;
    }

    if (hdr.boxSize == null || hdr.boxSize! > _maxSafeSize) break;
    final nextPos = pos + hdr.boxSize!;
    if (nextPos <= pos) break;
    pos = nextPos;
  }

  // Fallback for trailing moov when top-level walking could not reach it
  // (e.g. mdat had size == 0 or malformed box sizes) and fileSize is known.
  if (moovBytes == null && fileSize != null && fileSize > 16) {
    final tailWant = fileSize < _maxTailRead ? fileSize : _maxTailRead;
    final tailCap = tailWant < reader.remaining ? tailWant : reader.remaining;
    if (tailCap >= 16) {
      final tailStart = fileSize - tailCap;
      final tail = await reader.readRaw(tailStart, tailCap);
      if (tail != null && tail.length >= 16) {
        moovBytes = _scanForMoov(tail);
      }
    }
  }

  if (moovBytes == null || moovBytes.isEmpty) return null;

  final parsed = _Mp4Result();
  _parseMoov(moovBytes, 0, moovBytes.length, parsed);
  if (!parsed.hasAnyMetadata) return null;

  final container = switch (ext) {
    'mov' => 'mov',
    'mp4' || 'm4v' => 'mp4',
    _ => majorBrand == 'qt  ' ? 'mov' : 'mp4',
  };

  return MediaProbeInfo(
    width: parsed.width,
    height: parsed.height,
    videoCodec: parsed.videoCodec,
    hdr: parsed.hdr,
    audioCodec: parsed.audioCodec,
    audioChannels: parsed.audioChannels,
    duration: parsed.duration,
    container: container,
  );
}

class _Mp4Result {
  int? width;
  int? height;
  String? videoCodec;
  String? hdr;
  String? audioCodec;
  int? audioChannels;
  Duration? duration;

  bool videoFound = false;
  int bestAudioRank = -1;

  bool get hasAnyMetadata =>
      width != null ||
      height != null ||
      videoCodec != null ||
      hdr != null ||
      audioCodec != null ||
      audioChannels != null ||
      duration != null;
}

class _BoxHeader {
  final String type;
  final int headerSize;
  final int? boxSize;
  const _BoxHeader(this.type, this.headerSize, this.boxSize);
}

String? _readFourCC(Uint8List data, int offset) {
  if (offset + 4 > data.length) return null;
  final b0 = data[offset];
  final b1 = data[offset + 1];
  final b2 = data[offset + 2];
  final b3 = data[offset + 3];
  if (b0 < 0x20 ||
      b0 > 0x7E ||
      b1 < 0x20 ||
      b1 > 0x7E ||
      b2 < 0x20 ||
      b2 > 0x7E ||
      b3 < 0x20 ||
      b3 > 0x7E) {
    return null;
  }
  return String.fromCharCodes([b0, b1, b2, b3]);
}

_BoxHeader? _readBoxHeader(
  Uint8List data,
  int offset,
  int end,
  int absOffset,
  int? totalEnd,
) {
  if (offset + 8 > end) return null;
  final bd = ByteData.sublistView(data, offset, end);
  final size32 = bd.getUint32(0, Endian.big);
  final type = _readFourCC(data, offset + 4);
  if (type == null) return null;

  var headerSize = 8;
  int? boxSize;
  if (size32 == 1) {
    if (offset + 16 > end) return null;
    final hi = bd.getUint32(8, Endian.big);
    final lo = bd.getUint32(12, Endian.big);
    if (hi > 0x7FFFFFFF) return null;
    boxSize = (hi << 32) | lo;
    headerSize = 16;
    if (boxSize < 16) return null;
  } else if (size32 == 0) {
    if (totalEnd != null) {
      boxSize = totalEnd - absOffset;
      if (boxSize < 8) return null;
    } else {
      boxSize = null;
    }
  } else if (size32 >= 8) {
    boxSize = size32;
  } else {
    return null;
  }

  if (type == 'uuid') {
    if (boxSize != null && boxSize < headerSize + 16) return null;
    headerSize += 16;
  }
  return _BoxHeader(type, headerSize, boxSize);
}

Uint8List? _scanForMoov(Uint8List tail) {
  for (var i = 4; i <= tail.length - 12; i++) {
    if (tail[i] == 0x6D && // 'm'
        tail[i + 1] == 0x6F && // 'o'
        tail[i + 2] == 0x6F && // 'o'
        tail[i + 3] == 0x76) {
      // 'v'
      final boxStart = i - 4;
      final hdr = _readBoxHeader(tail, boxStart, tail.length, 0, tail.length);
      if (hdr == null || hdr.boxSize == null) continue;
      final payloadStart = boxStart + hdr.headerSize;
      final boxEnd = boxStart + hdr.boxSize!;
      if (boxEnd > tail.length || payloadStart + 8 > boxEnd) continue;
      final firstChildType = _readFourCC(tail, payloadStart + 4);
      if (firstChildType != null && _moovChildTypes.contains(firstChildType)) {
        return Uint8List.sublistView(tail, payloadStart, boxEnd);
      }
    }
  }
  return null;
}

void _walkBoxes(
  Uint8List data,
  int start,
  int end,
  void Function(String type, int payloadStart, int payloadEnd) onBox, {
  bool allowTruncatedContainer = false,
}) {
  var pos = start;
  var count = 0;
  while (pos + 8 <= end && count++ < 512) {
    final hdr = _readBoxHeader(data, pos, end, pos, end);
    if (hdr == null) break;
    final payloadStart = pos + hdr.headerSize;
    final boxEnd = hdr.boxSize == null ? end : pos + hdr.boxSize!;
    if (boxEnd < payloadStart) break;
    if (boxEnd > end) {
      if (allowTruncatedContainer && payloadStart < end) {
        onBox(hdr.type, payloadStart, end);
      }
      break;
    }
    onBox(hdr.type, payloadStart, boxEnd);
    pos = boxEnd;
  }
}

void _parseMoov(Uint8List data, int start, int end, _Mp4Result out) {
  _walkBoxes(data, start, end, (type, pStart, pEnd) {
    if (type == 'mvhd') {
      _parseMvhd(data, pStart, pEnd, out);
    } else if (type == 'trak') {
      _parseTrak(data, pStart, pEnd, out);
    }
  }, allowTruncatedContainer: true);
}

void _parseMvhd(Uint8List data, int start, int end, _Mp4Result out) {
  final len = end - start;
  if (len < 20) return;
  final bd = ByteData.sublistView(data, start, end);
  final version = bd.getUint8(0);
  int timescale;
  int durationUnits;
  if (version == 0) {
    timescale = bd.getUint32(12, Endian.big);
    durationUnits = bd.getUint32(16, Endian.big);
    if (durationUnits == 0xFFFFFFFF) return;
  } else if (version == 1) {
    if (len < 32) return;
    timescale = bd.getUint32(20, Endian.big);
    final hi = bd.getUint32(24, Endian.big);
    final lo = bd.getUint32(28, Endian.big);
    if (hi == 0xFFFFFFFF && lo == 0xFFFFFFFF) return;
    if (hi > 0x7FFFFFFF) return;
    durationUnits = (hi << 32) | lo;
  } else {
    return;
  }
  if (timescale <= 0 || durationUnits <= 0) return;
  final microsDouble = (durationUnits * 1000000.0) / timescale;
  if (microsDouble.isFinite && microsDouble > 0 && microsDouble < 1e15) {
    out.duration = Duration(microseconds: microsDouble.round());
  }
}

void _parseTrak(Uint8List data, int start, int end, _Mp4Result out) {
  _walkBoxes(data, start, end, (type, pStart, pEnd) {
    if (type == 'mdia') {
      _walkBoxes(data, pStart, pEnd, (mType, mStart, mEnd) {
        if (mType == 'minf') {
          _walkBoxes(data, mStart, mEnd, (iType, iStart, iEnd) {
            if (iType == 'stbl') {
              _walkBoxes(data, iStart, iEnd, (sType, sStart, sEnd) {
                if (sType == 'stsd') {
                  _parseStsd(data, sStart, sEnd, out);
                }
              }, allowTruncatedContainer: true);
            }
          }, allowTruncatedContainer: true);
        }
      }, allowTruncatedContainer: true);
    }
  }, allowTruncatedContainer: true);
}

void _parseStsd(Uint8List data, int start, int end, _Mp4Result out) {
  if (end - start < 8) return;
  final bd = ByteData.sublistView(data, start, end);
  final rawCount = bd.getUint32(4, Endian.big);
  final entryCount = rawCount > 16 ? 16 : rawCount;

  var pos = start + 8;
  for (var i = 0; i < entryCount && pos + 8 <= end; i++) {
    final hdr = _readBoxHeader(data, pos, end, pos, end);
    if (hdr == null || hdr.boxSize == null) break;
    final entryStart = pos + hdr.headerSize;
    final entryEnd = pos + hdr.boxSize!;
    if (entryEnd > end || entryEnd < entryStart) break;

    _parseSampleEntry(hdr.type, data, entryStart, entryEnd, out);
    pos = entryEnd;
  }
}

void _parseSampleEntry(
  String type,
  Uint8List data,
  int start,
  int end,
  _Mp4Result out,
) {
  final video = _mapVideoSampleType(type);
  if (video != null) {
    if (out.videoFound) return;
    final len = end - start;
    if (len < 28) return;
    final bd = ByteData.sublistView(data, start, end);
    final width = bd.getUint16(24, Endian.big);
    final height = bd.getUint16(26, Endian.big);

    String? hdr = video.hdr;
    if (len > 78) {
      _walkBoxes(data, start + 78, end, (childType, cStart, cEnd) {
        if (childType == 'dvcC' || childType == 'dvvC' || childType == 'dvwC') {
          hdr = 'DV';
        } else if (childType == 'colr' && hdr != 'DV') {
          final colrHdr = _parseColr(data, cStart, cEnd);
          if (colrHdr != null) hdr ??= colrHdr;
        }
      });
    }

    out.videoFound = true;
    out.videoCodec = video.codec;
    if (width > 0) out.width = width;
    if (height > 0) out.height = height;
    out.hdr = hdr;
    return;
  }

  var audioCodec = _mapAudioSampleType(type);
  if (audioCodec != null) {
    final len = end - start;
    if (len < 20) return;
    final bd = ByteData.sublistView(data, start, end);
    final version = bd.getUint16(8, Endian.big);

    int? channels;
    int childOffset;
    if (version == 2 && len >= 64) {
      final ch = bd.getUint32(32, Endian.big);
      if (ch > 0 && ch <= 64) channels = ch;
      childOffset = 64;
    } else if (version == 1 && len >= 44) {
      final ch = bd.getUint16(16, Endian.big);
      if (ch > 0) channels = ch;
      childOffset = 44;
    } else {
      final ch = bd.getUint16(16, Endian.big);
      if (ch > 0) channels = ch;
      childOffset = 28;
    }

    if (len > childOffset) {
      _walkBoxes(data, start + childOffset, end, (childType, cStart, cEnd) {
        if (childType == 'dec3') {
          final dec3 = _parseDec3(data, cStart, cEnd);
          if (dec3.isAtmos && (audioCodec == 'EAC3' || audioCodec == 'AC3')) {
            audioCodec = 'Atmos';
          }
          if ((channels == null || channels == 0) && dec3.channels != null) {
            channels = dec3.channels;
          }
        } else if (childType == 'dmlp' && audioCodec == 'TrueHD') {
          // Confirmed Dolby TrueHD (MLP) box.
        }
      });
    }

    final rank = audioCodecRank(audioCodec);
    if (out.bestAudioRank < 0 || rank > out.bestAudioRank) {
      out.bestAudioRank = rank;
      out.audioCodec = audioCodec;
      out.audioChannels = channels;
    }
  }
}

String? _parseColr(Uint8List data, int start, int end) {
  if (end - start < 8) return null;
  final colourType = _readFourCC(data, start);
  if (colourType != 'nclx' && colourType != 'nclc') return null;
  final bd = ByteData.sublistView(data, start, end);
  final transfer = bd.getUint16(6, Endian.big);
  return switch (transfer) {
    16 => 'HDR10',
    18 => 'HLG',
    _ => null,
  };
}

/// Parses an EC3SpecificBox (`dec3`) per ETSI TS 102 366 Annex F.6 and
/// Dolby Digital Plus JOC (Atmos) signaling.
({bool isAtmos, int? channels}) _parseDec3(Uint8List data, int start, int end) {
  const acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5];
  final len = end - start;
  if (len < 5) return (isAtmos: false, channels: null);

  final numIndSub = (data[start + 1] & 0x07) + 1;
  var p = start + 2;
  int? channels;

  for (var i = 0; i < numIndSub; i++) {
    if (p + 3 > end) return (isAtmos: false, channels: channels);
    if (i == 0) {
      final acmod = (data[p + 1] >> 1) & 0x07;
      final lfeon = data[p + 1] & 0x01;
      channels = acmodChannels[acmod] + lfeon;
    }
    final numDepSub = (data[p + 2] >> 1) & 0x0F;
    p += numDepSub > 0 ? 4 : 3;
  }

  final isAtmos = p < end && (data[p] & 0x01) != 0;
  return (isAtmos: isAtmos, channels: channels);
}

({String codec, String? hdr})? _mapVideoSampleType(String type) =>
    switch (type) {
      'avc1' || 'avc3' => (codec: 'H.264', hdr: null),
      'hvc1' || 'hev1' => (codec: 'HEVC', hdr: null),
      'av01' => (codec: 'AV1', hdr: null),
      'vp09' => (codec: 'VP9', hdr: null),
      'vp08' => (codec: 'VP8', hdr: null),
      'dvh1' || 'dvhe' || 'dvav' || 'dva1' => (codec: 'HEVC', hdr: 'DV'),
      'm2v1' => (codec: 'MPEG-2', hdr: null),
      _ => null,
    };

String? _mapAudioSampleType(String type) => switch (type) {
  'mp4a' => 'AAC',
  'ac-3' => 'AC3',
  'ec-3' => 'EAC3',
  'mlpa' => 'TrueHD',
  'Opus' => 'Opus',
  'fLaC' => 'FLAC',
  'dtsc' || 'dtse' => 'DTS',
  'dtsh' || 'dtsl' => 'DTS-HD',
  'dtsx' => 'DTS-X',
  _ => null,
};
