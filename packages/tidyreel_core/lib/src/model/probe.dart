/// Technical metadata probed from media container headers (MKV/MP4/MOV).
class MediaProbeInfo {
  final int? width;
  final int? height;

  /// Canonical video codec name: H.264, HEVC, AV1, VP9, MPEG-2, etc.
  final String? videoCodec;

  /// Dynamic range: DV, HDR10+, HDR10, HLG.
  final String? hdr;

  /// Primary audio codec: Atmos, TrueHD, DTS-HD, DTS-X, EAC3, AC3, AAC, FLAC, Opus.
  final String? audioCodec;

  /// Channel count of the primary audio track (e.g. 2, 6, 8).
  final int? audioChannels;

  /// Total media duration.
  final Duration? duration;

  /// Container format tag: mkv, webm, mp4, mov.
  final String? container;

  const MediaProbeInfo({
    this.width,
    this.height,
    this.videoCodec,
    this.hdr,
    this.audioCodec,
    this.audioChannels,
    this.duration,
    this.container,
  });

  /// Standard resolution label inferred from [width] and [height].
  String? get resolution {
    final w = width ?? 0;
    final h = height ?? 0;
    if (w <= 0 && h <= 0) return null;
    // Cinema aspect ratios (e.g. 3840x1600 or 1920x800) have smaller heights,
    // so check width thresholds alongside height.
    if (w >= 7000 || h >= 4000) return '4320p';
    if (w >= 3200 || h >= 2000) return '2160p';
    if (w >= 2400 || h >= 1350) return '1440p';
    if (w >= 1700 || h >= 960) return '1080p';
    if (w >= 1100 || h >= 650) return '720p';
    if (h >= 520) return '576p';
    if (h >= 400 || w >= 600) return '480p';
    return h > 0 ? '${h}p' : null;
  }

  /// Extra-info string compatible with `ParsedName.extraInfo`, e.g. `2160p.DV.Atmos`.
  String? get extraInfoSummary {
    const premiumAudio = {'Atmos', 'TrueHD', 'DTS-HD', 'DTS-X'};
    final parts = <String>[
      ?resolution,
      if (hdr case final h? when h.isNotEmpty) h,
      if (audioCodec case final a? when premiumAudio.contains(a)) a,
    ];
    return parts.isEmpty ? null : parts.join('.');
  }

  @override
  bool operator ==(Object other) =>
      other is MediaProbeInfo &&
      other.width == width &&
      other.height == height &&
      other.videoCodec == videoCodec &&
      other.hdr == hdr &&
      other.audioCodec == audioCodec &&
      other.audioChannels == audioChannels &&
      other.duration == duration &&
      other.container == container;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    videoCodec,
    hdr,
    audioCodec,
    audioChannels,
    duration,
    container,
  );

  @override
  String toString() =>
      'MediaProbeInfo(${width}x$height, $videoCodec, hdr=$hdr, audio=$audioCodec/${audioChannels}ch, dur=$duration)';
}
