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

/// Finds the video [f] belongs to: longest base-name prefix (same folder wins ties),
/// then the same episode number.
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
  if (pf == null || n == null) return null;
  final cands = videos.where((v) {
    final p = v.parsed;
    if (p == null) return false;
    return (p.episodes.firstOrNull ?? p.absolute) == n &&
        (pf.season == null || p.season == null || pf.season == p.season);
  }).toList();
  if (cands.isEmpty) return null;
  final same = cands.where((v) => dirOf(v.path) == fdir);
  if (same.isNotEmpty) return FollowMatch(same.first, '');
  return cands.length == 1 ? FollowMatch(cands.first, '') : null;
}

const _zhHans = {
  'chs', 'sc', 'gb', 'gbk', 'gb2312', '简体', '简中', '简', '简体中文', '简日',
  '简英', 'zh-cn', 'zh-hans', 'zh-sg', 'zhs', 'zh', 'chi', 'zho', 'chinese',
  '中文', //
};
const _zhHant = {
  'cht', 'tc', 'big5', '繁体', '繁體', '繁中', '繁', '繁体中文', '繁日', '繁英',
  'zh-tw', 'zh-hk', 'zh-hant', 'zht', //
};
const _en = {'eng', 'en', 'english', 'en-us', 'en-gb', '英文', '英语'};
const _ja = {'jpn', 'ja', 'jp', 'japanese', '日文', '日语'};
const _ko = {'kor', 'ko', 'korean', '韩文', '韩语'};

/// Maps a language tag as found in file names to zh-Hans / zh-Hant / en / ja / ko.
/// Null when unknown. Combined tags like "chs&eng" resolve to the first language.
String? normalizeLang(String token) {
  for (final part in token.toLowerCase().split(RegExp(r'[&+/,]'))) {
    final t = part.trim();
    if (_zhHans.contains(t)) return 'zh-Hans';
    if (_zhHant.contains(t)) return 'zh-Hant';
    if (_en.contains(t)) return 'en';
    if (_ja.contains(t)) return 'ja';
    if (_ko.contains(t)) return 'ko';
  }
  return null;
}

/// First known language among the dot / underscore separated tokens of [remainder].
String? langFromRemainder(String remainder) {
  for (final t in remainder.split(RegExp(r'[.\s_\[\]()（）]+'))) {
    final l = t.isEmpty ? null : normalizeLang(t);
    if (l != null) return l;
  }
  return null;
}
