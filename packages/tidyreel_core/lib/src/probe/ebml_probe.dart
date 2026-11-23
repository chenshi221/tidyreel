import 'dart:convert';
import 'dart:typed_data';

import '../model/probe.dart';
import 'probe_reader.dart';

// EBML / Matroska element IDs (with VINT marker bits retained).
const _idEbml = 0x1A45DFA3;
const _idDocType = 0x4282;
const _idSegment = 0x18538067;
const _idSeekHead = 0x114D9B74;
const _idSeek = 0x4DBB;
const _idSeekId = 0x53AB;
const _idSeekPosition = 0x53AC;
const _idInfo = 0x1549A966;
const _idTimestampScale = 0x2AD7B1;
const _idDuration = 0x4489;
const _idTracks = 0x1654AE6B;
const _idTrackEntry = 0xAE;
const _idTrackType = 0x83;
const _idCodecId = 0x86;
const _idCodecPrivate = 0x63A2;
const _idTrackName = 0x536E;
const _idVideo = 0xE0;
const _idPixelWidth = 0xB0;
const _idPixelHeight = 0xBA;
const _idColour = 0x55B0;
const _idTransferCharacteristics = 0x55BA;
const _idBlockAdditionMapping = 0x41E4;
const _idBlockAddIdType = 0x41E7;
const _idAudio = 0xE1;
const _idChannels = 0x9F;
const _idCluster = 0x1F43B675;
const _idVoid = 0xEC;
const _idCrc32 = 0xBF;

const _dvccType = 0x64766343; // 'dvcC'
const _dvvcType = 0x64767643; // 'dvvC'

const _maxTopElements = 64;
const _maxSeekHeadSize = 64 * 1024;
const _maxInfoSize = 64 * 1024;
const _maxTracksSize = 256 * 1024;
const _maxSafeSize = 0x00FFFFFFFFFFFF00;

final _dtsXRe = RegExp(r'dts[\s:_-]*x(?![a-z0-9])', caseSensitive: false);
final _dtsHdRe = RegExp(
  r'dts[\s:_-]*hd|\bma\b|master\s*audio',
  caseSensitive: false,
);
final _hdr10PlusRe = RegExp(
  r'hdr\s*10\s*\+|hdr10plus|smpte\s*2094',
  caseSensitive: false,
);

/// Probes an MKV / WebM (EBML) container using [reader].
///
/// [head] must already start with the EBML magic bytes `1A 45 DF A3`.
Future<MediaProbeInfo?> probeEbml(
  ProbeRangeReader reader,
  Uint8List head, {
  required String? ext,
  required int? fileSize,
}) async {
  reader.seed(0, head);

  final ebmlHeader = _readElementHeader(head, 0, head.length);
  if (ebmlHeader == null || ebmlHeader.id != _idEbml) return null;
  final ebmlSize = ebmlHeader.size;
  if (ebmlSize == null || ebmlSize > _maxInfoSize) return null;

  final ebmlDataStart = ebmlHeader.headerLen;
  final ebmlData = await reader.window(ebmlDataStart, ebmlSize);
  if (ebmlData == null) return null;
  final docType = _parseDocType(
    ebmlData,
    0,
    ebmlSize < ebmlData.length ? ebmlSize : ebmlData.length,
  );

  // Locate the Segment element (skipping optional Void / CRC-32 elements).
  var pos = ebmlDataStart + ebmlSize;
  int? segmentDataStart;
  int? segmentEnd;
  for (var i = 0; i < 16; i++) {
    final win = await reader.window(pos, 16);
    if (win == null || win.length < 2) return null;
    final hdr = _readElementHeader(win, 0, win.length);
    if (hdr == null) return null;
    if (hdr.id == _idSegment) {
      segmentDataStart = pos + hdr.headerLen;
      if (hdr.size != null && hdr.size! <= _maxSafeSize) {
        final end = segmentDataStart + hdr.size!;
        if (end >= segmentDataStart) segmentEnd = end;
      }
      break;
    }
    if ((hdr.id == _idVoid || hdr.id == _idCrc32) && hdr.size != null) {
      final next = pos + hdr.headerLen + hdr.size!;
      if (next <= pos) return null;
      pos = next;
      continue;
    }
    return null;
  }
  if (segmentDataStart == null) return null;

  final parsed = _EbmlResult();
  final seekTargets = <int, int>{};
  final secondarySeekHeads = <int>[];

  Future<void> parseElementAt(int fileOffset, {int? expectedId}) async {
    final hdrWin = await reader.window(fileOffset, 16);
    if (hdrWin == null || hdrWin.length < 2) return;
    final hdr = _readElementHeader(hdrWin, 0, hdrWin.length);
    if (hdr == null) return;
    if (expectedId != null && hdr.id != expectedId) return;
    final dataStart = fileOffset + hdr.headerLen;
    final maxCap = switch (hdr.id) {
      _idSeekHead => _maxSeekHeadSize,
      _idInfo => _maxInfoSize,
      _idTracks => _maxTracksSize,
      _ => _maxInfoSize,
    };
    final wantLen = hdr.size == null
        ? maxCap
        : (hdr.size! > maxCap ? maxCap : hdr.size!);
    if (wantLen <= 0) return;
    final payload = await reader.window(
      dataStart,
      wantLen,
      preferredLength: wantLen > 64 * 1024 ? wantLen : 64 * 1024,
    );
    if (payload == null || payload.isEmpty) return;
    final avail = wantLen < payload.length ? wantLen : payload.length;
    switch (hdr.id) {
      case _idSeekHead:
        _parseSeekHead(
          payload,
          0,
          avail,
          segmentDataStart!,
          seekTargets,
          secondarySeekHeads,
        );
      case _idInfo:
        _parseInfo(payload, 0, avail, parsed);
        parsed.infoSeen = true;
      case _idTracks:
        _parseTracks(payload, 0, avail, parsed);
        parsed.tracksSeen = true;
    }
  }

  // Sequential scan from Segment start until both Info and Tracks are parsed
  // or the first Cluster is encountered.
  var cursor = segmentDataStart;
  for (var i = 0; i < _maxTopElements; i++) {
    if (segmentEnd != null && cursor >= segmentEnd) break;
    if (fileSize != null && cursor >= fileSize) break;
    final win = await reader.window(cursor, 16);
    if (win == null || win.length < 2) break;
    final hdr = _readElementHeader(win, 0, win.length);
    if (hdr == null) break;
    if (hdr.id == _idCluster) break;

    final dataStart = cursor + hdr.headerLen;
    if (hdr.id == _idSeekHead &&
        hdr.size != null &&
        hdr.size! > 0 &&
        hdr.size! <= _maxSeekHeadSize) {
      final payload = await reader.window(dataStart, hdr.size!);
      if (payload != null) {
        final avail = hdr.size! < payload.length ? hdr.size! : payload.length;
        _parseSeekHead(
          payload,
          0,
          avail,
          segmentDataStart,
          seekTargets,
          secondarySeekHeads,
        );
      }
    } else if (hdr.id == _idInfo && !parsed.infoSeen) {
      final wantLen = hdr.size == null
          ? _maxInfoSize
          : (hdr.size! > _maxInfoSize ? _maxInfoSize : hdr.size!);
      if (wantLen > 0) {
        final payload = await reader.window(dataStart, wantLen);
        if (payload != null) {
          final avail = wantLen < payload.length ? wantLen : payload.length;
          _parseInfo(payload, 0, avail, parsed);
          parsed.infoSeen = true;
        }
      }
    } else if (hdr.id == _idTracks && !parsed.tracksSeen) {
      final wantLen = hdr.size == null
          ? _maxTracksSize
          : (hdr.size! > _maxTracksSize ? _maxTracksSize : hdr.size!);
      if (wantLen > 0) {
        final payload = await reader.window(
          dataStart,
          wantLen,
          preferredLength: wantLen > 64 * 1024 ? wantLen : 64 * 1024,
        );
        if (payload != null) {
          final avail = wantLen < payload.length ? wantLen : payload.length;
          _parseTracks(payload, 0, avail, parsed);
          parsed.tracksSeen = true;
        }
      }
    }

    if (parsed.infoSeen && parsed.tracksSeen) break;
    if (hdr.size == null || hdr.size! > _maxSafeSize) break;
    final nextCursor = dataStart + hdr.size!;
    if (nextCursor <= cursor) break;

    // If we already have SeekHead targets for every still-missing section and
    // the next sequential element lies beyond our buffered chunk (e.g. a huge
    // Attachments/Void block), jump directly via SeekHead instead of scanning.
    final haveNeededTargets =
        (parsed.infoSeen || seekTargets.containsKey(_idInfo)) &&
        (parsed.tracksSeen || seekTargets.containsKey(_idTracks));
    if (haveNeededTargets && nextCursor > cursor + win.length) {
      break;
    }

    cursor = nextCursor;
  }

  // Follow secondary SeekHead once if Info or Tracks is still missing.
  if ((!parsed.infoSeen && !seekTargets.containsKey(_idInfo)) ||
      (!parsed.tracksSeen && !seekTargets.containsKey(_idTracks))) {
    if (secondarySeekHeads.isNotEmpty) {
      await parseElementAt(secondarySeekHeads.first, expectedId: _idSeekHead);
    }
  }

  if (!parsed.infoSeen) {
    final infoOffset = seekTargets[_idInfo];
    if (infoOffset != null) {
      await parseElementAt(infoOffset, expectedId: _idInfo);
    }
  }
  if (!parsed.tracksSeen) {
    final tracksOffset = seekTargets[_idTracks];
    if (tracksOffset != null) {
      await parseElementAt(tracksOffset, expectedId: _idTracks);
    }
  }

  if (!parsed.hasAnyMetadata) return null;

  final container = (ext == 'webm' || (ext == null && docType == 'webm'))
      ? 'webm'
      : 'mkv';

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

class _EbmlResult {
  bool infoSeen = false;
  bool tracksSeen = false;

  int? width;
  int? height;
  String? videoCodec;
  String? hdr;
  String? audioCodec;
  int? audioChannels;
  Duration? duration;

  bool get hasAnyMetadata =>
      width != null ||
      height != null ||
      videoCodec != null ||
      hdr != null ||
      audioCodec != null ||
      audioChannels != null ||
      duration != null;
}

class _EbmlHeader {
  final int id;
  final int? size; // null means EBML unknown size
  final int headerLen;
  const _EbmlHeader(this.id, this.size, this.headerLen);
}

_EbmlHeader? _readElementHeader(Uint8List data, int offset, int end) {
  if (offset >= end) return null;

  // Element ID: 1..4 octets, VINT marker bit is kept as part of the ID.
  final b0 = data[offset];
  if (b0 == 0) return null;
  int idLen;
  if ((b0 & 0x80) != 0) {
    idLen = 1;
  } else if ((b0 & 0x40) != 0) {
    idLen = 2;
  } else if ((b0 & 0x20) != 0) {
    idLen = 3;
  } else if ((b0 & 0x10) != 0) {
    idLen = 4;
  } else {
    return null;
  }
  if (offset + idLen > end) return null;
  var id = 0;
  for (var i = 0; i < idLen; i++) {
    id = (id << 8) | data[offset + i];
  }

  // Element Data Size: 1..8 octets, VINT marker bit is stripped.
  final sizeOff = offset + idLen;
  if (sizeOff >= end) return null;
  final s0 = data[sizeOff];
  if (s0 == 0) return null;
  var sizeLen = 0;
  for (var i = 0; i < 8; i++) {
    if ((s0 & (0x80 >> i)) != 0) {
      sizeLen = i + 1;
      break;
    }
  }
  if (sizeLen == 0 || sizeOff + sizeLen > end) return null;

  final mask = (1 << (8 - sizeLen)) - 1;
  var size = s0 & mask;
  for (var i = 1; i < sizeLen; i++) {
    size = (size << 8) | data[sizeOff + i];
  }

  // Unknown-size sentinel: all VINT_DATA bits are 1.
  final unknownSentinel = (1 << (7 * sizeLen)) - 1;
  final resolvedSize = size == unknownSentinel ? null : size;
  return _EbmlHeader(id, resolvedSize, idLen + sizeLen);
}

int _readUint(Uint8List data, int start, int length) {
  final n = length > 8 ? 8 : length;
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | data[start + i];
  }
  return v;
}

double? _readFloat(Uint8List data, int start, int length) {
  if (length == 0) return 0.0;
  if (length == 4) {
    return ByteData.sublistView(
      data,
      start,
      start + 4,
    ).getFloat32(0, Endian.big);
  }
  if (length == 8) {
    return ByteData.sublistView(
      data,
      start,
      start + 8,
    ).getFloat64(0, Endian.big);
  }
  return null;
}

String _readString(Uint8List data, int start, int length) {
  var end = start + length;
  while (end > start && data[end - 1] == 0) {
    end--;
  }
  return utf8.decode(
    Uint8List.sublistView(data, start, end),
    allowMalformed: true,
  );
}

String? _parseDocType(Uint8List data, int start, int end) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idDocType) {
      return _readString(data, dataStart, hdr.size!).toLowerCase();
    }
    pos = dataEnd;
  }
  return null;
}

void _parseSeekHead(
  Uint8List data,
  int start,
  int end,
  int segmentDataStart,
  Map<int, int> targets,
  List<int> secondarySeekHeads,
) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idSeek) {
      int? seekId;
      int? seekPos;
      var inner = dataStart;
      while (inner < dataEnd) {
        final ih = _readElementHeader(data, inner, dataEnd);
        if (ih == null || ih.size == null) break;
        final iStart = inner + ih.headerLen;
        final iEnd = iStart + ih.size!;
        if (iEnd > dataEnd || iEnd < iStart) break;
        if (ih.id == _idSeekId && ih.size! >= 1 && ih.size! <= 4) {
          seekId = _readUint(data, iStart, ih.size!);
        } else if (ih.id == _idSeekPosition && ih.size! <= 8) {
          seekPos = _readUint(data, iStart, ih.size!);
        }
        inner = iEnd;
      }
      if (seekId != null && seekPos != null && seekPos <= _maxSafeSize) {
        final absPos = segmentDataStart + seekPos;
        if (absPos >= segmentDataStart) {
          if (seekId == _idSeekHead) {
            secondarySeekHeads.add(absPos);
          } else {
            targets.putIfAbsent(seekId, () => absPos);
          }
        }
      }
    }
    pos = dataEnd;
  }
}

void _parseInfo(Uint8List data, int start, int end, _EbmlResult out) {
  var timestampScale = 1000000;
  double? rawDuration;
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idTimestampScale && hdr.size! <= 8) {
      final scale = _readUint(data, dataStart, hdr.size!);
      if (scale > 0) timestampScale = scale;
    } else if (hdr.id == _idDuration) {
      rawDuration = _readFloat(data, dataStart, hdr.size!);
    }
    pos = dataEnd;
  }
  if (rawDuration != null && rawDuration.isFinite && rawDuration > 0) {
    final microsDouble = (rawDuration * timestampScale) / 1000.0;
    if (microsDouble.isFinite &&
        microsDouble > 0 &&
        microsDouble < 1e15 /* ~31 years */ ) {
      out.duration = Duration(microseconds: microsDouble.round());
    }
  }
}

void _parseTracks(Uint8List data, int start, int end, _EbmlResult out) {
  var pos = start;
  var videoFound = false;
  var bestAudioRank = -1;

  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd < dataStart) break;
    final clampedEnd = dataEnd > end ? end : dataEnd;

    if (hdr.id == _idTrackEntry) {
      final track = _parseTrackEntry(data, dataStart, clampedEnd);
      if (track.trackType == 1 && !videoFound) {
        final codec = _mapVideoCodec(track.codecId);
        if (codec != null || track.width != null || track.height != null) {
          videoFound = true;
          out.width = track.width;
          out.height = track.height;
          out.videoCodec = codec;
          out.hdr = _resolveVideoHdr(track);
        }
      } else if (track.trackType == 2) {
        final codec = _mapAudioCodec(track.codecId, track.name);
        final rank = audioCodecRank(codec);
        if (codec != null || track.channels != null) {
          if (bestAudioRank < 0 || rank > bestAudioRank) {
            bestAudioRank = rank;
            out.audioCodec = codec;
            out.audioChannels = track.channels;
          }
        }
      }
    }

    if (dataEnd > end) break;
    pos = dataEnd;
  }
}

class _TrackInfo {
  int? trackType;
  String? codecId;
  String? name;
  Uint8List? codecPrivate;
  int? width;
  int? height;
  int? transferCharacteristics;
  bool hasDolbyVision = false;
  int? channels;
}

_TrackInfo _parseTrackEntry(Uint8List data, int start, int end) {
  final info = _TrackInfo();
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;

    switch (hdr.id) {
      case _idTrackType when hdr.size! <= 8:
        info.trackType = _readUint(data, dataStart, hdr.size!);
      case _idCodecId:
        info.codecId = _readString(data, dataStart, hdr.size!);
      case _idTrackName:
        info.name = _readString(data, dataStart, hdr.size!);
      case _idCodecPrivate:
        info.codecPrivate = Uint8List.sublistView(data, dataStart, dataEnd);
      case _idVideo:
        _parseVideoElement(data, dataStart, dataEnd, info);
      case _idAudio:
        _parseAudioElement(data, dataStart, dataEnd, info);
      case _idBlockAdditionMapping:
        if (_hasDolbyVisionMapping(data, dataStart, dataEnd)) {
          info.hasDolbyVision = true;
        }
    }
    pos = dataEnd;
  }
  return info;
}

void _parseVideoElement(Uint8List data, int start, int end, _TrackInfo info) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    switch (hdr.id) {
      case _idPixelWidth when hdr.size! <= 8:
        final w = _readUint(data, dataStart, hdr.size!);
        if (w > 0) info.width = w;
      case _idPixelHeight when hdr.size! <= 8:
        final h = _readUint(data, dataStart, hdr.size!);
        if (h > 0) info.height = h;
      case _idColour:
        _parseColourElement(data, dataStart, dataEnd, info);
    }
    pos = dataEnd;
  }
}

void _parseColourElement(Uint8List data, int start, int end, _TrackInfo info) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idTransferCharacteristics && hdr.size! <= 8) {
      info.transferCharacteristics = _readUint(data, dataStart, hdr.size!);
    }
    pos = dataEnd;
  }
}

bool _hasDolbyVisionMapping(Uint8List data, int start, int end) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idBlockAddIdType && hdr.size! <= 8) {
      final type = _readUint(data, dataStart, hdr.size!);
      if (type == _dvccType || type == _dvvcType) return true;
    }
    pos = dataEnd;
  }
  return false;
}

void _parseAudioElement(Uint8List data, int start, int end, _TrackInfo info) {
  var pos = start;
  while (pos < end) {
    final hdr = _readElementHeader(data, pos, end);
    if (hdr == null || hdr.size == null) break;
    final dataStart = pos + hdr.headerLen;
    final dataEnd = dataStart + hdr.size!;
    if (dataEnd > end || dataEnd < dataStart) break;
    if (hdr.id == _idChannels && hdr.size! <= 8) {
      final ch = _readUint(data, dataStart, hdr.size!);
      if (ch > 0) info.channels = ch;
    }
    pos = dataEnd;
  }
}

String? _resolveVideoHdr(_TrackInfo track) {
  if (track.hasDolbyVision) return 'DV';
  final name = track.name;
  if (name != null && _hdr10PlusRe.hasMatch(name)) {
    return 'HDR10+';
  }
  final priv = track.codecPrivate;
  if (priv != null && priv.isNotEmpty) {
    final text = utf8.decode(priv, allowMalformed: true);
    if (_hdr10PlusRe.hasMatch(text)) return 'HDR10+';
  }
  return switch (track.transferCharacteristics) {
    16 => 'HDR10',
    18 => 'HLG',
    _ => null,
  };
}

String? _mapVideoCodec(String? codecId) {
  if (codecId == null || codecId.isEmpty) return null;
  if (codecId == 'V_MPEG4/ISO/AVC' || codecId.startsWith('V_MPEG4/ISO/AVC/')) {
    return 'H.264';
  }
  if (codecId == 'V_MPEGH/ISO/HEVC' ||
      codecId.startsWith('V_MPEGH/ISO/HEVC/')) {
    return 'HEVC';
  }
  if (codecId == 'V_AV1') return 'AV1';
  if (codecId == 'V_VP9') return 'VP9';
  if (codecId == 'V_VP8') return 'VP8';
  if (codecId == 'V_MPEG2') return 'MPEG-2';
  return null;
}

String? _mapAudioCodec(String? codecId, String? name) {
  if (codecId == null || codecId.isEmpty) return null;
  final hasAtmos = name != null && name.toLowerCase().contains('atmos');
  if (codecId == 'A_TRUEHD') return hasAtmos ? 'Atmos' : 'TrueHD';
  if (codecId == 'A_EAC3') return hasAtmos ? 'Atmos' : 'EAC3';
  if (codecId == 'A_AC3') return 'AC3';
  if (codecId == 'A_DTS' || codecId.startsWith('A_DTS/')) {
    if (name != null && _dtsXRe.hasMatch(name)) return 'DTS-X';
    if (codecId == 'A_DTS/LOSSLESS' ||
        (name != null && _dtsHdRe.hasMatch(name))) {
      return 'DTS-HD';
    }
    return 'DTS';
  }
  if (codecId == 'A_AAC' || codecId.startsWith('A_AAC/')) return 'AAC';
  if (codecId == 'A_FLAC') return 'FLAC';
  if (codecId == 'A_OPUS') return 'Opus';
  return null;
}
