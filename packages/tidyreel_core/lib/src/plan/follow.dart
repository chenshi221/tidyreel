import '../model/media.dart';
import '../model/scan.dart';
import 'text.dart';

/// Subtitles and sidecars that follow a video (shared by the recognizer and the planner).

class FollowMatch {
  final ScanFile video;

  /// Text between the video's base name and the extension, e.g. ".chs" or "-poster".
  final String remainder;

  const FollowMatch(this.video, this.remainder);
}

final _afterBase = RegExp(r'[\s._\-\[\(]');
final _subSeRe = RegExp(
  r'(?<![A-Za-z0-9])S(\d{1,2})[\s._-]?E(\d{1,4})(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _subXRe = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _subEpRe = RegExp(
  r'(?<![A-Za-z0-9])(?:EP|Episode[\s._-]?|E)(\d{1,4})(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _subCnEpRe = RegExp(r'第\s*(\d{1,4})\s*[集话話期回]');
final _subYearRe = RegExp(
  r'(?<![A-Za-z0-9\u3400-\u9fff])((?:19|20)\d\d)(?![A-Za-z0-9])',
);

/// Finds the video [f] belongs to:
/// 1. Longest base-name prefix (same folder wins ties),
/// 2. Same episode number,
/// 3. Safe fuzzy fallback for subtitles in the same folder (single video in
///    folder or unambiguous meaningful-token overlap, never cross-matching
///    conflicting episodes).
FollowMatch? matchVideo(ScanFile f, Iterable<ScanFile> videos) {
  final fb = stem(f.name), fbl = fb.toLowerCase(), fdir = dirOf(f.path);
  FollowMatch? best;
  var bestLen = -1;
  var bestSame = false;
  for (final v in videos) {
    final vb = stem(v.name).toLowerCase();
    if (vb.isEmpty) continue;
    String? rem;
    if (fbl == vb) {
      rem = '';
    } else if (fbl.length > vb.length &&
        fbl.startsWith(vb) &&
        _afterBase.hasMatch(fbl[vb.length])) {
      rem = fb.substring(vb.length);
    }
    if (rem == null) continue;
    final same = dirOf(v.path) == fdir;
    if (vb.length > bestLen || (vb.length == bestLen && same && !bestSame)) {
      best = FollowMatch(v, rem);
      bestLen = vb.length;
      bestSame = same;
    }
  }
  if (best != null) return best;

  final pf = f.parsed;
  final n = pf == null ? null : (pf.episodes.firstOrNull ?? pf.absolute);
  if (pf != null && n != null) {
    final cands = videos.where((v) {
      final p = v.parsed;
      if (p == null) return false;
      return (p.episodes.firstOrNull ?? p.absolute) == n &&
          (pf.season == null || p.season == null || pf.season == p.season);
    }).toList();
    if (cands.isNotEmpty) {
      final same = cands.where((v) => dirOf(v.path) == fdir);
      if (same.isNotEmpty) return FollowMatch(same.first, '');
      if (cands.length == 1) return FollowMatch(cands.first, '');
      return null;
    }
  }

  // Step 3: safe fuzzy fallback for third-party subtitles in the same folder.
  if (f.role != FileRole.subtitle) return null;
  final sameDirVideos = [
    for (final v in videos)
      if (dirOf(v.path) == fdir) v,
  ];
  if (sameDirVideos.isEmpty) return null;

  if (sameDirVideos.length == 1) {
    final v = sameDirVideos.single;
    if (_episodesConflict(f, v) || _yearsConflict(f, v)) return null;
    return FollowMatch(v, _extractSubRemainder(fb, stem(v.name)));
  }

  // Multiple videos in the same folder: require unambiguous meaningful token
  // overlap and no conflicting episode numbers.
  final fTokens = _meaningfulTokens(fb);
  if (fTokens.isEmpty) return null;
  ScanFile? topVideo;
  var topScore = 0.0;
  var topShared = 0;
  var secondScore = 0.0;
  for (final v in sameDirVideos) {
    if (_episodesConflict(f, v)) continue;
    final vTokens = _meaningfulTokens(stem(v.name));
    if (vTokens.isEmpty) continue;
    final shared = fTokens.intersection(vTokens);
    if (shared.isEmpty) continue;
    // Never match solely on a shared year/number (e.g. two different 2020 films).
    if (!shared.any((t) => !_digitsOnlyRe.hasMatch(t))) continue;
    final unionLen = fTokens.length + vTokens.length - shared.length;
    final score = unionLen == 0 ? 0.0 : shared.length / unionLen;
    final qualified =
        (shared.length >= 2 && score >= 0.35) ||
        (shared.length == 1 && shared.first.length >= 4 && score >= 0.5);
    if (!qualified) continue;
    if (score > topScore || (score == topScore && shared.length > topShared)) {
      secondScore = topScore;
      topScore = score;
      topShared = shared.length;
      topVideo = v;
    } else if (score > secondScore) {
      secondScore = score;
    }
  }
  if (topVideo == null) return null;
  if (secondScore > 0 && topScore - secondScore < 0.2) return null;
  return FollowMatch(topVideo, _extractSubRemainder(fb, stem(topVideo.name)));
}

({int? season, int? episode}) _episodeKey(ScanFile file) {
  final p = file.parsed;
  final ep = p?.episodes.firstOrNull ?? p?.absolute;
  if (ep != null) return (season: p?.season, episode: ep);
  final s = stem(file.name);
  final se = _subSeRe.firstMatch(s);
  if (se != null) {
    return (season: int.parse(se[1]!), episode: int.parse(se[2]!));
  }
  final x = _subXRe.firstMatch(s);
  if (x != null) {
    return (season: int.parse(x[1]!), episode: int.parse(x[2]!));
  }
  final e = _subEpRe.firstMatch(s);
  if (e != null) {
    return (season: p?.season, episode: int.parse(e[1]!));
  }
  final cn = _subCnEpRe.firstMatch(s);
  if (cn != null) {
    return (season: p?.season, episode: int.parse(cn[1]!));
  }
  return (season: p?.season, episode: null);
}

bool _episodesConflict(ScanFile sub, ScanFile video) {
  final ks = _episodeKey(sub);
  final kv = _episodeKey(video);
  if (ks.episode != null && kv.episode != null && ks.episode != kv.episode) {
    return true;
  }
  if (ks.episode != null && kv.episode == null) return true;
  if (ks.season != null && kv.season != null && ks.season != kv.season) {
    return true;
  }
  return false;
}

int? _extractYear(ScanFile file) {
  if (file.parsed?.year != null) return file.parsed!.year;
  final s = stem(file.name);
  final maxYear = DateTime.now().year + 2;
  int? year;
  for (final m in _subYearRe.allMatches(s)) {
    if (m.start == 0) continue;
    final y = int.parse(m[1]!);
    if (y <= maxYear) year = y;
  }
  return year;
}

bool _yearsConflict(ScanFile sub, ScanFile video) {
  final ys = _extractYear(sub);
  final yv = _extractYear(video);
  return ys != null && yv != null && (ys - yv).abs() > 1;
}

const _zhHans = {
  'chs', 'sc', 'gb', 'gbk', 'gb2312', 'jpsc', 'cn', '简体', '简中', '简', '简体中文',
  '简日', '简英', '简繁', '中英', '中英双语', '中英雙語', '中字双语', '中字', '双语', '雙語',
  'zh-cn', 'zh-hans', 'zh-sg', 'zhs', 'zh', 'chi', 'zho', 'chinese', '中文', //
};
const _zhHant = {
  'cht', 'tc', 'big5', 'jptc', '繁体', '繁體', '繁中', '繁', '繁体中文', '繁體中文',
  '繁日', '繁英', 'zh-tw', 'zh-hk', 'zh-hant', 'zht', //
};
const _en = {'eng', 'en', 'english', 'en-us', 'en-gb', '英文', '英语'};
const _ja = {'jpn', 'jap', 'ja', 'jp', 'japanese', '日文', '日语'};
const _ko = {'kor', 'ko', 'korean', '韩文', '韩语'};

const _bilingualTokens = {
  'bilingual',
  'jpsc',
  'jptc',
  'scjp',
  'tcjp',
  'chseng',
  'chteng',
  'sceng',
  'tceng',
  'chsjp',
  'chtjp',
};

const _ambiguousFlagWords = {'force', 'hi', 'cc', 'dual'};

const _fuzzyNoise = {
  'web',
  'dl',
  'webdl',
  'webrip',
  'webhd',
  'bluray',
  'bdrip',
  'brrip',
  'bdremux',
  'remux',
  'hdtv',
  'pdtv',
  'dvdrip',
  'dvd',
  'hdrip',
  'bd',
  'uhd',
  'fhd',
  'hdr',
  'hdr10',
  'hdr10plus',
  'dv',
  'dovi',
  'hlg',
  'sdr',
  'imax',
  'x264',
  'x265',
  'h264',
  'h265',
  'hevc',
  'avc',
  'av1',
  'xvid',
  'divx',
  '10bit',
  '8bit',
  'hi10p',
  'aac',
  'ac3',
  'eac3',
  'ddp',
  'dd',
  'dts',
  'dtshd',
  'dtsx',
  'truehd',
  'atmos',
  'flac',
  'opus',
  'lpcm',
  'mp3',
  'proper',
  'repack',
  'rerip',
  'multi',
  'dual',
  'audio',
  'sub',
  'subs',
  'subtitle',
  'subtitles',
  'forced',
  'force',
  'default',
  'sdh',
  'hi',
  'cc',
  'bilingual',
  'mkv',
  'mp4',
  'avi',
  'srt',
  'ass',
  'ssa',
  'vtt',
  'the',
  'and',
  'of',
  'in',
  'on',
  'to',
  'for',
  'with',
  'at',
  'by',
  'from',
};

final _langPartSep = RegExp(r'[&+/,]');
final _remSep = RegExp(r'[.\s\[\]()（）【】]+');
final _dashUnderscore = RegExp(r'[-_]');
final _edgeDashUnderscore = RegExp(r'^[-_]+|[-_]+$');
final _cjkBilingualRe = RegExp(r'双语|雙語|中英|简英|繁英|簡英|简日|繁日|簡日|简繁|簡繁');
final _cjkSdhRe = RegExp(r'听障|聽障');
final _cjkForcedRe = RegExp(r'强制|強制');
final _cjkDefaultRe = RegExp(r'默认|默認');
final _digitsOnlyRe = RegExp(r'^\d+$');
final _resNoiseRe = RegExp(r'^(?:\d{3,4}[pi]|\d{3,4}x\d{3,4}|[248]k)$');
final _fuzzySplitRe = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _cjkRunRe = RegExp(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]+');
final _latinWordRe = RegExp(r'[a-z0-9]+');

String? _singleLang(String normalizedLower) {
  if (_zhHans.contains(normalizedLower)) return 'zh-Hans';
  if (_zhHant.contains(normalizedLower)) return 'zh-Hant';
  if (_en.contains(normalizedLower)) return 'en';
  if (_ja.contains(normalizedLower)) return 'ja';
  if (_ko.contains(normalizedLower)) return 'ko';
  return null;
}

/// Maps a language tag as found in file names to zh-Hans / zh-Hant / en / ja / ko.
/// Null when unknown. Combined tags like "chs&eng" resolve to the first language.
/// Supports both hyphen and underscore locale forms (`zh-CN`, `zh_CN`, `zh_TW`,
/// `zh_Hans`, `zh_Hant`, `en_US`).
String? normalizeLang(String token) {
  for (final part in token.toLowerCase().split(_langPartSep)) {
    final t = part.trim().replaceAll('_', '-');
    final lang = _singleLang(t);
    if (lang != null) return lang;
  }
  return null;
}

/// First known language among the dot / underscore / hyphen separated tokens of [remainder].
String? langFromRemainder(String remainder) {
  for (final chunk in remainder.split(_remSep)) {
    if (chunk.isEmpty) continue;
    for (final raw in chunk.split(_langPartSep)) {
      final t = raw.replaceAll(_edgeDashUnderscore, '').trim();
      if (t.isEmpty) continue;
      final direct = normalizeLang(t);
      if (direct != null) return direct;
      if (t.contains('-') || t.contains('_')) {
        final parts = t
            .toLowerCase()
            .split(_dashUnderscore)
            .where((p) => p.isNotEmpty)
            .toList();
        for (var i = 0; i < parts.length; i++) {
          if (i + 1 < parts.length) {
            final pair = _singleLang('${parts[i]}-${parts[i + 1]}');
            if (pair != null) return pair;
          }
          final single = _singleLang(parts[i]);
          if (single != null) return single;
        }
      }
    }
  }
  return null;
}

/// Extracts deduplicated canonical subtitle trait flags in deterministic order
/// (`bilingual`, `sdh`, `forced`, `default`) from [remainder] or a subtitle stem.
List<String> subFlagsFromRemainder(String remainder) {
  if (remainder.trim().isEmpty) return const [];
  var bilingual = false;
  var sdh = false;
  var forced = false;
  var isDefault = false;
  final langs = <String>{};
  final flatTokens = <String>[];

  for (final chunk in remainder.split(_remSep)) {
    if (chunk.isEmpty) continue;
    for (final raw in chunk.split(_langPartSep)) {
      final seg = raw.replaceAll(_edgeDashUnderscore, '').trim();
      if (seg.isEmpty) continue;
      if (_cjkBilingualRe.hasMatch(seg)) bilingual = true;
      if (_cjkSdhRe.hasMatch(seg)) sdh = true;
      if (_cjkForcedRe.hasMatch(seg)) forced = true;
      if (_cjkDefaultRe.hasMatch(seg)) isDefault = true;

      final parts = seg
          .toLowerCase()
          .split(_dashUnderscore)
          .where((p) => p.isNotEmpty)
          .toList();
      for (var i = 0; i < parts.length; i++) {
        if (i + 1 < parts.length) {
          final pair = '${parts[i]}-${parts[i + 1]}';
          final pairLang = _singleLang(pair);
          if (pairLang != null) {
            langs.add(pairLang);
            flatTokens.add(pair);
            i++;
            continue;
          }
        }
        flatTokens.add(parts[i]);
      }
    }
  }

  for (var i = 0; i < flatTokens.length; i++) {
    final p = flatTokens[i];
    if (p == 'forced' || p == 'force') {
      forced = true;
    } else if (p == 'default') {
      isDefault = true;
    } else if (p == 'sdh' || p == 'hi' || p == 'cc') {
      sdh = true;
    } else if (p == 'dual') {
      final nextIsAudio =
          i + 1 < flatTokens.length && flatTokens[i + 1] == 'audio';
      if (!nextIsAudio) bilingual = true;
    } else if (_bilingualTokens.contains(p)) {
      bilingual = true;
    }
    final lang = _singleLang(p);
    if (lang != null) langs.add(lang);
  }

  return [
    if (bilingual || langs.length >= 2) 'bilingual',
    if (sdh) 'sdh',
    if (forced) 'forced',
    if (isDefault) 'default',
  ];
}

/// Extracts language and subtitle-flag tokens from a third-party subtitle stem
/// [subStem] matched fuzzily to [videoStem], returning a dot-prefixed remainder
/// (or `''` if none are present). Ambiguous title words (`force`, `hi`, `cc`,
/// `dual`) that also appear in [videoStem] are skipped.
String _extractSubRemainder(String subStem, String videoStem) {
  final videoWords = {
    for (final w in videoStem.toLowerCase().split(_fuzzySplitRe))
      if (w.isNotEmpty) w,
  };
  final kept = <String>[];
  final chunks = subStem.split(_remSep).where((c) => c.isNotEmpty).toList();
  for (var ci = 0; ci < chunks.length; ci++) {
    final chunk = chunks[ci];
    final nextLower = ci + 1 < chunks.length
        ? chunks[ci + 1].toLowerCase()
        : null;
    final subParts = chunk.split(_langPartSep);
    final chunkKept = <String>[];
    for (final raw in subParts) {
      final seg = raw.replaceAll(_edgeDashUnderscore, '').trim();
      if (seg.isEmpty) continue;
      if (_cjkBilingualRe.hasMatch(seg) ||
          _cjkSdhRe.hasMatch(seg) ||
          _cjkForcedRe.hasMatch(seg) ||
          _cjkDefaultRe.hasMatch(seg) ||
          normalizeLang(seg) != null) {
        chunkKept.add(seg);
        continue;
      }
      final parts = seg
          .split(_dashUnderscore)
          .where((p) => p.isNotEmpty)
          .toList();
      final keptParts = <String>[];
      for (var i = 0; i < parts.length; i++) {
        final low = parts[i].toLowerCase();
        if (i + 1 < parts.length) {
          final pair = '$low-${parts[i + 1].toLowerCase()}';
          if (_singleLang(pair) != null) {
            keptParts.add('${parts[i]}_${parts[i + 1]}');
            i++;
            continue;
          }
        }
        final isAudioDual =
            low == 'dual' &&
            ((i + 1 < parts.length && parts[i + 1].toLowerCase() == 'audio') ||
                (i + 1 == parts.length && nextLower == 'audio'));
        if (isAudioDual) continue;
        if (_ambiguousFlagWords.contains(low) && videoWords.contains(low)) {
          continue;
        }
        if (_singleLang(low) != null ||
            low == 'forced' ||
            low == 'force' ||
            low == 'default' ||
            low == 'sdh' ||
            low == 'hi' ||
            low == 'cc' ||
            low == 'dual' ||
            _bilingualTokens.contains(low)) {
          keptParts.add(parts[i]);
        }
      }
      if (keptParts.isNotEmpty) chunkKept.add(keptParts.join('.'));
    }
    if (chunkKept.isNotEmpty) {
      kept.add(
        subParts.length > 1 && chunkKept.length > 1
            ? chunkKept.join('&')
            : chunkKept.join('.'),
      );
    }
  }
  return kept.isEmpty ? '' : '.${kept.join('.')}';
}

Set<String> _meaningfulTokens(String rawStem) {
  final folded = toSimplified(rawStem).toLowerCase();
  final out = <String>{};
  for (final m in _cjkRunRe.allMatches(folded)) {
    final run = m[0]!;
    if (_singleLang(run) != null ||
        _cjkBilingualRe.hasMatch(run) ||
        _cjkForcedRe.hasMatch(run) ||
        _cjkDefaultRe.hasMatch(run) ||
        _cjkSdhRe.hasMatch(run)) {
      continue;
    }
    final chars = run.runes.map(String.fromCharCode).toList();
    if (chars.length == 1) {
      out.add(chars.single);
    } else {
      for (var i = 0; i < chars.length - 1; i++) {
        out.add('${chars[i]}${chars[i + 1]}');
      }
    }
  }
  for (final m in _latinWordRe.allMatches(folded)) {
    final w = m[0]!;
    if (w.length < 2) continue;
    if (_fuzzyNoise.contains(w) ||
        _resNoiseRe.hasMatch(w) ||
        _singleLang(w) != null ||
        _bilingualTokens.contains(w)) {
      continue;
    }
    if (_digitsOnlyRe.hasMatch(w) && w.length != 4) continue;
    out.add(w);
  }
  return out;
}
