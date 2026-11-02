import '../model/media.dart';
import 'numerals.dart';

// ---------------------------------------------------------------- classify

const _videoExt = {
  'mkv',
  'mp4',
  'avi',
  'ts',
  'm2ts',
  'mts',
  'rmvb',
  'rm',
  'wmv',
  'mov',
  'flv', //
  'webm', 'iso', 'm4v', 'mpg', 'mpeg', 'vob', '3gp', 'asf', 'divx', 'ogm',
  'strm', 'bdmv', 'f4v',
};
const _subExt = {'srt', 'ass', 'ssa', 'sub', 'idx', 'sup', 'vtt', 'smi', 'lrc'};
const _sidecarExt = {
  'nfo', 'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tbn', 'xml', 'svg', //
  // External audio tracks follow their video like subtitles do.
  'mka', 'ac3', 'eac3', 'dts', 'dtshd', 'truehd',
};
const _junkExt = {
  'txt',
  'url',
  'html',
  'htm',
  'lnk',
  'exe',
  'bat',
  'chm',
  'ini',
  'db',
  'apk', //
  'website', 'webloc', 'torrent!',
};
const _knownExt = {..._videoExt, ..._subExt, ..._sidecarExt, ..._junkExt};

final _adKw = RegExp(
  '更多资源|更多精彩|更多电影|最新地址|最新网址|获取更多|公众号|扫码|发布页|永久地址|永久网址|免费下载|点击进入|关注微信',
);
const _tld =
    'com|net|org|cn|cc|xyz|top|vip|club|info|tv|me|io|la|pw|co|in|us|uk|jp|kr|tw|hk|site|fun';
final _urlRe = RegExp(
  '(?:https?://\\S+|www\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*|[A-Za-z0-9-]+\\.(?:$_tld)(?![A-Za-z0-9]))',
  caseSensitive: false,
);
final _anyBracket = RegExp(r'\[[^\]]*\]|\([^)]*\)');
final _httpUrlRe = RegExp(r'www\.|https?://', caseSensitive: false);
final _tldDomainRe = RegExp(
  '\\.(?:$_tld)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _urlCheckRe = RegExp(
  r'www\.|https?://|^[^ ]*\.(?:com|net|org|cn|cc)$',
  caseSensitive: false,
);
final _letterOrDigitRe = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _sampleRe = RegExp(r'^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]');
final _extRe = RegExp(r'^[a-z0-9!]+$');

bool _isAd(String c) =>
    _adKw.hasMatch(c) || _httpUrlRe.hasMatch(c) || _tldDomainRe.hasMatch(c);

FileRole classifyFile(String fileName) {
  final base = fold(fileName.split('/').last.split('\\').last);
  final lower = base.toLowerCase();
  if (base.startsWith('._') ||
      lower == '.ds_store' ||
      lower == 'thumbs.db' ||
      lower == 'desktop.ini') {
    return FileRole.junk;
  }
  final ext = extOf(base);
  if (ext == null || !_knownExt.contains(ext)) return FileRole.other;
  if (_junkExt.contains(ext)) return FileRole.junk;
  final stem = base.substring(0, base.length - ext.length - 1);

  // Remove ad brackets, URLs and ad phrases; nothing meaningful left → junk.
  var rest = stem.replaceAllMapped(
    _anyBracket,
    (m) => _isAd(m[0]!) ? ' ' : m[0]!,
  );
  final hadUrl = _urlRe.hasMatch(rest) && _urlCheckRe.hasMatch(rest);
  final hadAd = hadUrl || _adKw.hasMatch(rest) || rest != stem;
  rest = rest.replaceAll(_urlRe, ' ').replaceAll(_adKw, ' ');
  final empty = !_letterOrDigitRe.hasMatch(rest);

  if (_videoExt.contains(ext)) {
    final s = stem.toLowerCase();
    if (_sampleRe.hasMatch(s)) {
      return FileRole.junk;
    }
    return empty ? FileRole.junk : FileRole.video;
  }
  if (_subExt.contains(ext)) return empty ? FileRole.junk : FileRole.subtitle;
  return empty || hadAd ? FileRole.junk : FileRole.sidecar;
}

String? extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || name.length - i - 1 > 8) return null;
  final e = name.substring(i + 1).toLowerCase();
  return _extRe.hasMatch(e) ? e : null;
}

// ----------------------------------------------------------------- analyze

/// Generic container folders that never carry a show title.
final genericDir = RegExp(
  r'^(?:tv|tv ?shows?|series|movies?|films?|anime|animations?|downloads?|videos?|media|'
  r'电视剧|电影|动漫|动画|番剧|综艺|纪录片|剧集|影视|新番|国产剧|美剧|日剧|韩剧|欧美剧|港剧|电视|下载|视频)$',
  caseSensitive: false,
);

class Info {
  String title = '';
  int? year;
  int? season;
  List<int> episodes = [];
  int? bare; // bare episode/absolute number
  String bareFrom = ''; // dash | trail | lone
  int? leadNum; // "01 Pilot.mkv": only counts with folder context
  bool explicitEp = false;
  bool sxe = false;
  bool batch = false; // "全39集": a whole-season pack, not one episode
  DateTime? airDate; // "20240503" / "2024-05-03"
  bool specialKw = false, extraKw = false, movieKw = false, hasTech = false;
  String? res, group, lang, extra;
}

const _cjkQuotes = {
  0x300A, // 《
  0x300B, // 》
  0x300C, // 「
  0x300D, // 」
  0x300E, // 『
  0x300F, // 』
  0x3008, // 〈
  0x3009, // 〉
  0x201C, // “
  0x201D, // ”
};

/// Fullwidth → ASCII, CJK brackets → [], quotes removed.
String fold(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x3000) {
      b.write(' ');
    } else if (r == 0x3010 || r == 0xFF3B) {
      b.write('[');
    } else if (r == 0x3011 || r == 0xFF3D) {
      b.write(']');
    } else if (r >= 0xFF01 && r <= 0xFF5E) {
      b.writeCharCode(r - 0xFEE0);
    } else if (_cjkQuotes.contains(r)) {
      b.write(' ');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

const _cnNum = r'[0-9]+|[零〇一二三四五六七八九十百千两]+';

final _wwwRe = RegExp(
  'www\\.[A-Za-z0-9-]+\\.(?:$_tld)(?:\\.(?:cn|uk|jp|tw|hk))?(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _leadDomainRe = RegExp(
  r'^\s*[A-Za-z0-9-]+\.(?:com|net|org|cn|cc|xyz|top|vip|club|info)(?![A-Za-z0-9])[\s._-]*',
  caseSensitive: false,
);
final _dateRe = RegExp(
  r'(?<![0-9])(?:(?:19|20)\d\d[-._ ](?:0[1-9]|1[0-2])[-._ ](?:0[1-9]|[12]\d|3[01])|(?:19|20)\d\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))(?![0-9])',
);
final _leadBracket = RegExp(r'^\s*[\[(]([^\]\)]*)[\])]');
final _midBracket = RegExp(r'\[([^\]]*)\]|\(([^)]*)\)');
final _crcRe = RegExp(r'^[0-9A-Fa-f]{8}$');

const _techWords =
    r'webdl|webrip|webhd|bluray|bdrip|brrip|bdremux|remux|hdtv|pdtv|dvdrip|dvdscr|dvd|hdrip|hdcam|bd|'
    r'amzn|nf|dsnp|hmax|atvp|hulu|x26[45]|h26[45]|hevc|avc|xvid|divx|av1|vc1|10bits?|8bits?|hi10p?|'
    r'(?:ddp?|ddplus|aac|ac3|eac3|dts|dtshd|flac|truehd|atmos|opus|lpcm|mp3)\d*|ch\d\d|'
    r'hdr10(?:plus)?|hdr|dv|dovi|hlg|sdr|imax|proper|repack|rerip|extended|unrated|remastered|'
    r'internal|multi|dual|dubbed|subbed|complete|batch|limited|hybrid|mkv|mp4|avi';
final _techRe = RegExp(
  '(?<![A-Za-z0-9])(?:$_techWords|\\d{3,4}x\\d{3,4}|[248]k|uhd|fhd)(?![A-Za-z0-9])'
  '|(?<![0-9])\\d{3,4}[pi](?![A-Za-z0-9])', // "BD1080P" is common in CN releases
  caseSensitive: false,
);
final _techOnlyRe = RegExp(
  '^(?:$_techWords|\\d{3,4}[pi]|\\d{3,4}x\\d{3,4}|[248]k|uhd|fhd|web|tv|big5|gb|chs|cht|sc|tc|'
  'mkv|mp4|v\\d|\\d{1,3}[-~]\\d{1,3}|\\d{4}|[\\s,&+/_.-])+\$',
  caseSensitive: false,
);
final _cnNoise = RegExp(
  '国语|粤语|国粤|中字|中英|简繁|简体|繁体|繁體|高清|超清|蓝光|原盘|完整版|无删减|全集|合集|内封|内嵌|外挂|双语|字幕|修复版|珍藏版|导演剪辑|新版|首发|重制版',
);

final _seRe = RegExp(
  r'(?<![A-Za-z0-9])S(\d{1,2}) ?E(\d{1,4})((?: ?- ?E?\d{1,4}| ?~ ?E?\d{1,4}| ?E\d{1,4})*)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _xRe = RegExp(r'(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])');
// "第01集", "第01-02集"
final _cnEpRe = RegExp('第 ?($_cnNum)(?: ?[-~] ?($_cnNum))? ?[集话話期回]');
final _batchRe = RegExp(r'[全共] ?\d+ ?[集话期]|更新?至 ?\d+ ?[集话期]');
// "EP01", "E01", "Episode 1", ranges "EP01-EP02" / "E01-02"
final _epRe = RegExp(
  r'(?<![A-Za-z0-9])(?:(?:EP|Episode) ?|E)(\d{1,4})(?: ?[-~] ?(?:(?:EP|Episode) ?|E)?(\d{1,4}))?(?![A-Za-z0-9])',
  caseSensitive: false,
);
// Mini-series "1of6" / "1 of 6" (Sonarr): episode 1.
final _ofRe = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,2}) ?of ?(\d{1,2})(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _hashRe = RegExp(r'#(\d{1,4})(?![0-9])');
final _dashRe = RegExp(r'(?:^| )- ?(\d{1,4})(?:v\d{1,2})?(?![A-Za-z0-9])');
final _seasonRes = <RegExp>[
  RegExp(r'(?<![A-Za-z0-9])S(\d{1,2})(?![A-Za-z0-9])', caseSensitive: false),
  RegExp(
    r'(?<![A-Za-z])(?:Season|Saison|Series) ?(\d{1,2})(?![0-9]| ?of)',
    caseSensitive: false,
  ),
  RegExp(r'(\d{1,2})(?:st|nd|rd|th) Season', caseSensitive: false),
  RegExp('第 ?($_cnNum) ?季'),
];
final _specialRe = RegExp(
  r'(?<![A-Za-z0-9])(?:OVA|OAD|SPs?|Specials?) ?(\d{1,3})?(?![A-Za-z0-9])|(?:特别篇|特別篇|番外篇?) ?(\d{1,3})?',
  caseSensitive: false,
);
final _extraRe = RegExp(
  r'(?<![A-Za-z0-9])(?:NCOP|NCED|Creditless ?(?:Opening|Ending)|Trailers?|Teaser|PV|CM|Menu|Making(?: of)?|Featurettes?|Interviews?|Behind The Scenes|Deleted Scenes?|Extras?|Bonus) ?\d{0,2}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?:OP|ED) ?\d{1,2}(?![A-Za-z0-9])|花絮|幕后|特典|预告片?|宣传片|访谈|片头曲|片尾曲|特辑|彩蛋',
);
final _extraCi = RegExp(
  r'(?<![A-Za-z0-9])(?:NCOP|NCED|Creditless ?(?:Opening|Ending)|Trailers?|Teaser|Menu|Making(?: of)?|Featurettes?|Interviews?|Behind The Scenes|Deleted Scenes?|Extras?|Bonus) ?\d{0,2}(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _movieRe = RegExp(
  r'剧场版|劇場版|电影版|Gekijouban|(?<![A-Za-z])The Movie(?![A-Za-z])',
  caseSensitive: false,
);
// Not glued to CJK on the left: "请回答1988" keeps its number in the title.
final _yearRe = RegExp(r'(?<![A-Za-z0-9㐀-鿿])((?:19|20)\d\d)(?![A-Za-z0-9])');
final _cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯]');
final _langRe = RegExp(
  r'(?<![A-Za-z0-9])(zh[- ]?(?:cn|tw|hans|hant|hk|sg)|chs|cht|zhs|zht|chi|zho|jpsc|jptc|sc|tc|gbk|gb2312|gb|big5|english|eng|en|japanese|jpn|jap|jp|ja|korean|kor|ko|zh|cn|chinese|'
  r'简体中文|繁體中文|繁体中文|简体|繁体|繁體|简中|繁中|简日|繁日|简繁|简英|繁英|中英|中文|双语|雙語|日语|日文|韩语|韩文|英文|英语)(?![A-Za-z0-9])',
  caseSensitive: false,
);

final _fourDigitYearRe = RegExp(r'^(?:19|20)\d\d$');
final _cnNoiseTagRe = RegExp(r'[一-鿿]{0,2}(?:字幕|画质|版|语|字)(?![一-鿿])');
final _splitNoiseRe = RegExp(r'[\s,&+/_.-]+');

/// Words that, alone in a leading bracket, mean "not a group".
bool _noiseBracket(String c) {
  if (c.isEmpty) return true;
  if (_crcRe.hasMatch(c)) return true;
  if (_fourDigitYearRe.hasMatch(c)) return true;
  final stripped = c
      .replaceAll(_cnNoise, ' ')
      .replaceAll(_cnNoiseTagRe, ' ')
      .trim();
  if (stripped.isEmpty) return true;
  final toks = stripped.split(_splitNoiseRe).where((t) => t.isNotEmpty);
  return toks.every((t) => _techOnlyRe.hasMatch(t));
}

bool _hasEpisodeMarker(String c) =>
    _seRe.hasMatch(c) ||
    _xRe.hasMatch(c) ||
    _cnEpRe.hasMatch(c) ||
    _epRe.hasMatch(c) ||
    _specialRe.hasMatch(c) ||
    _extraRe.hasMatch(c) ||
    _seasonRes.any((r) => r.hasMatch(c));

final _webdlRe = RegExp(r'web[-. _]?dl', caseSensitive: false);
final _blurayRe = RegExp(r'blu[-. ]?ray', caseSensitive: false);
final _h26xRe = RegExp(
  r'(?<![A-Za-z0-9])h[. ]?26([45])(?![0-9])',
  caseSensitive: false,
);
final _hdr10PlusRe = RegExp(r'(hdr10|ddp?|eac3)\+', caseSensitive: false);
final _audioChRe = RegExp(
  r'(?<![A-Za-z0-9])(dd|ddp|ddplus|aac|ac3|eac3|dts|flac|truehd|atmos|opus|lpcm)[ .]?(\d)\.(\d)',
  caseSensitive: false,
);
final _chDigitRe = RegExp(r'(?<![0-9.])([2567])\.([01])(?![0-9])');
final _dotsUnderscoresRe = RegExp(r'[._]');
final _whitespaceRe = RegExp(r'[ \t]+');

String _normalize(String s) {
  s = s.replaceAllMapped(_webdlRe, (m) => 'WEBDL');
  s = s.replaceAllMapped(_blurayRe, (m) => 'BluRay');
  s = s.replaceAllMapped(_h26xRe, (m) => 'H26${m[1]}');
  s = s.replaceAllMapped(_hdr10PlusRe, (m) => '${m[1]}plus');
  s = s.replaceAllMapped(_audioChRe, (m) => '${m[1]}${m[2]}${m[3]}');
  s = s.replaceAllMapped(_chDigitRe, (m) => 'ch${m[1]}${m[2]}');
  s = s.replaceAll(_dotsUnderscoresRe, ' ');
  return s.replaceAll(_whitespaceRe, ' ').trim();
}

int _seasonNum(RegExpMatch m) => chineseToInt(m[1]!) ?? 0;

/// [first]..[last] for "EP01-EP03"; just [first] when [last] is absent or
/// not a plausible range end.
List<int> _range(int first, int? last) =>
    last == null || last <= first || last - first > 200
    ? [first]
    : [for (var i = first; i <= last; i++) i];

final _dashDateRe = RegExp(r'[-._ ]');
final _numWithVRe = RegExp(r'^\d{1,4}(?:v\d)?$');
final _trailerGroupRe = RegExp(r'-([A-Za-z0-9]{2,16}) *(?:\[[^\]]*\] *)*$');
final _eNumRe = RegExp(r'^E?\d+$', caseSensitive: false);
final _multiSpaceRe = RegExp(r' {2,}');
final _multiEpRe = RegExp(r'( ?[-~] ?)?E?(\d+)');
final _leadLowerRe = RegExp(r'^ [a-z]');
final _bareRegionRe = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,3})(?:v\d)?(?![A-Za-z0-9])',
);
final _spaceDashRe = RegExp(r'[\s-]');
final _resPiRe = RegExp(
  r'(?<![0-9])(\d{3,4})[pi](?![A-Za-z0-9])',
  caseSensitive: false,
);
final _resXRe = RegExp(r'(?<![A-Za-z0-9])\d{3,4}x(\d{3,4})(?![A-Za-z0-9])');
final _resKRe = RegExp(
  r'(?<![A-Za-z0-9])([248])k(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _hdrAudioRe = RegExp(
  r'(?<![A-Za-z0-9])(hdr10plus|hdr10|hdr|dovi|dv|hlg|imax|atmos|truehd|dts-?hd|dts-?x)\d*(?![A-Za-z0-9])',
  caseSensitive: false,
);

Info analyze(String raw, {required bool file}) {
  final a = Info();
  var s = fold(raw);
  var isSub = false;
  if (file) {
    final e = extOf(s);
    if (e != null && _knownExt.contains(e)) {
      s = s.substring(0, s.length - e.length - 1);
      isSub = _subExt.contains(e);
    }
  }
  s = s.replaceAll(_wwwRe, ' ').replaceFirst(_leadDomainRe, '');
  final dm = _dateRe.firstMatch(s);
  if (dm != null) {
    final d = dm[0]!.replaceAll(_dashDateRe, '');
    a.airDate = DateTime.utc(
      int.parse(d.substring(0, 4)),
      int.parse(d.substring(4, 6)),
      int.parse(d.substring(6, 8)),
    );
  }
  s = s.replaceAll(_dateRe, ' \u0001 ');

  // Leading brackets: first non-noise one is the group; noise is kept for
  // resolution / extra-info parsing.
  final tail = StringBuffer();
  String?
  altTitle; // "[Group][Title][01][1080p]" style: second bracket is the title
  while (true) {
    final m = _leadBracket.firstMatch(s);
    if (m == null) break;
    final c = m[1]!.trim();
    final isSquare = m[0]!.trimLeft().startsWith('[');
    s = s.substring(m.end);
    if (_isAd(c) || _crcRe.hasMatch(c)) continue;
    if (_numWithVRe.hasMatch(c) && !_fourDigitYearRe.hasMatch(c)) {
      tail.write(' - $c ');
      continue;
    }
    if (_noiseBracket(c) || _hasEpisodeMarker(c)) {
      tail.write(' $c');
      continue;
    }
    if (a.group == null && isSquare) {
      a.group = c;
    } else if (altTitle == null && isSquare) {
      altTitle = c;
    }
  }

  // Protect release tokens before the trailing "-GROUP" is looked for.
  s = s.replaceAllMapped(_webdlRe, (m) => 'WEBDL');
  s = s.replaceAllMapped(_blurayRe, (m) => 'BluRay');
  if (a.group == null) {
    final gm = _trailerGroupRe.firstMatch(s);
    if (gm != null) {
      final cand = gm[1]!;
      final before = _normalize(s.substring(0, gm.start));
      if (_techRe.hasMatch(before) &&
          !_techRe.hasMatch(cand) &&
          !_eNumRe.hasMatch(cand)) {
        a.group = cand;
        s = s.substring(0, gm.start) + s.substring(gm.start + 1 + cand.length);
      }
    }
  }

  // Remaining brackets: ad → drop; pure number → " - N"; anything else ends the title.
  s = s.replaceAllMapped(_midBracket, (m) {
    final c = (m[1] ?? m[2]!).trim();
    if (_isAd(c) || _crcRe.hasMatch(c)) return ' ';
    if (_numWithVRe.hasMatch(c) && !_fourDigitYearRe.hasMatch(c)) {
      return ' - $c ';
    }
    return ' \u0001 $c ';
  });
  s = _normalize('$s ${tail.toString()}');

  // "剧场版 名侦探柯南 ..." — the keyword is only a flag; the rest is the title.
  if (_movieRe.hasMatch(s)) {
    a.movieKw = true;
    s = s.replaceFirst(_movieRe, ' ').replaceAll(_multiSpaceRe, ' ').trim();
  }

  var cut = s.length;
  void mark(int i) {
    if (i >= 0 && i < cut) cut = i;
  }

  // ---- season / episode
  var m = _seRe.firstMatch(s);
  if (m != null) {
    a.season = int.parse(m[1]!);
    final nums = <int>[int.parse(m[2]!)];
    for (final t in _multiEpRe.allMatches(m[3] ?? '')) {
      final n = int.parse(t[2]!);
      if (t[1] != null && n > nums.last && n - nums.last <= 200) {
        nums.addAll([for (var i = nums.last + 1; i <= n; i++) i]);
      } else {
        nums.add(n);
      }
    }
    a.episodes = nums;
    a.explicitEp = a.sxe = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _xRe.firstMatch(s)) != null) {
    a.season = int.parse(m![1]!);
    a.episodes = [int.parse(m[2]!)];
    a.explicitEp = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _cnEpRe.firstMatch(s)) != null) {
    final n = chineseToInt(m![1]!);
    if (n != null) {
      a.episodes = _range(n, m[2] == null ? null : chineseToInt(m[2]!));
      a.explicitEp = true;
      mark(m.start);
    }
  }
  if (a.episodes.isEmpty && (m = _epRe.firstMatch(s)) != null) {
    a.episodes = _range(
      int.parse(m![1]!),
      m[2] == null ? null : int.parse(m[2]!),
    );
    a.explicitEp = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _ofRe.firstMatch(s)) != null) {
    final n = int.parse(m![1]!);
    if (n >= 1 && n <= int.parse(m[2]!)) {
      a.episodes = [n];
      a.explicitEp = true;
      mark(m.start);
    }
  }
  if (a.episodes.isEmpty && (m = _hashRe.firstMatch(s)) != null) {
    a.episodes = [int.parse(m![1]!)];
    a.explicitEp = true;
    mark(m.start);
  }
  if ((m = _batchRe.firstMatch(s)) != null) {
    a.batch = true;
    mark(m!.start);
  }
  for (final re in _seasonRes) {
    final sm = re.firstMatch(s);
    if (sm != null) {
      a.season ??= _seasonNum(sm);
      mark(sm.start);
      break;
    }
  }

  // ---- special / extra / movie keywords
  final em = _extraRe.firstMatch(s) ?? _extraCi.firstMatch(s);
  // A keyword before an explicit episode, or one running on into more words
  // ("Today's Menu for the Emiya Family S01E01"), is part of the title.
  final inTitle =
      em != null &&
      ((a.explicitEp && em.start < cut) ||
          _leadLowerRe.hasMatch(s.substring(em.end)));
  if (em != null && !inTitle) {
    a.extraKw = true;
    mark(em.start);
  }
  final sp = _specialRe.firstMatch(s);
  if (sp != null && !a.extraKw) {
    a.specialKw = true;
    final n = sp[1] ?? sp[2];
    if (n != null && a.episodes.isEmpty) a.episodes = [int.parse(n)];
    mark(sp.start);
  }

  // ---- year: last candidate that is not the very first token
  final yrs = _yearRe.allMatches(s).toList();
  RegExpMatch? ym;
  for (final y in yrs) {
    if (y.start > 0) ym = y;
  }
  if (ym != null) {
    a.year = int.parse(ym[1]!);
    mark(ym.start);
  }

  // ---- release tokens
  final tm = _techRe.firstMatch(s);
  if (tm != null) {
    a.hasTech = true;
    mark(tm.start);
  }
  final nm = _cnNoise.firstMatch(s);
  if (nm != null) mark(nm.start);
  final um = s.indexOf('\u0001');
  if (um >= 0) mark(um);

  // ---- subtitle language
  if (isSub) {
    final lm = _langRe.firstMatch(s);
    if (lm != null) {
      a.lang = lm[1]!.replaceAll(' ', '-');
      mark(lm.start);
    }
  }

  // ---- bare numbers
  final noMarker =
      a.episodes.isEmpty && !a.specialKw && !a.extraKw && !a.movieKw;
  if (noMarker && file) {
    final dm = _dashRe.firstMatch(s);
    if (dm != null) {
      final n = int.parse(dm[1]!);
      final isYear = dm[1]!.length == 4 && n >= 1900 && n <= 2099;
      if (!isYear) {
        a.bare = n;
        a.bareFrom = 'dash';
        mark(dm.start);
      }
    }
    if (a.bare == null && a.year == null) {
      final region = s.substring(0, cut);
      final nums = _bareRegionRe.allMatches(region).toList();
      if (nums.isNotEmpty) {
        final last = nums.last;
        final before = region.substring(0, last.start).trim();
        final after = region.substring(last.end).replaceAll(_spaceDashRe, '');
        final n = int.parse(last[1]!);
        if (before.isEmpty && after.isEmpty) {
          a.bare = n;
          a.bareFrom = 'lone';
          cut = last.start;
        } else if (after.isEmpty && before.replaceAll('-', '').isNotEmpty) {
          a.bare = n;
          a.bareFrom = 'trail';
          cut = last.start;
        } else if (before.isEmpty) {
          a.leadNum = n;
        }
      }
    }
  }

  // ---- title
  a.title = _pickTitle(s.substring(0, cut));
  if (a.title.isEmpty && altTitle != null) {
    a.title = _pickTitle(_normalize(altTitle));
  }

  // ---- resolution / extra info (whole string, so bracketed [1080p] counts)
  final rm = _resPiRe.firstMatch(s);
  if (rm != null) {
    a.res = '${rm[1]}${rm[0]!.toLowerCase().endsWith('i') ? 'i' : 'p'}';
  } else {
    final xm = _resXRe.firstMatch(s);
    final km = _resKRe.firstMatch(s);
    if (xm != null) {
      a.res = '${xm[1]}p';
    } else if (km != null) {
      a.res = const {'2': '1440p', '4': '2160p', '8': '4320p'}[km[1]];
    }
  }
  // order: resolution, picture (DV/HDR), audio (Atmos/TrueHD/DTS-HD)
  final picture = <String>{}, audio = <String>{};
  for (final t in _hdrAudioRe.allMatches(s)) {
    final k = _canonExtra(t[1]!);
    (const {'Atmos', 'TrueHD', 'DTS-HD', 'DTS-X'}.contains(k) ? audio : picture)
        .add(k);
  }
  final extras = [if (a.res != null) a.res!, ...picture, ...audio];
  if (extras.isNotEmpty) a.extra = extras.join('.');
  return a;
}

String _canonExtra(String t) => switch (t.toLowerCase()) {
  'hdr10plus' => 'HDR10+',
  'hdr10' => 'HDR10',
  'hdr' => 'HDR',
  'dovi' || 'dv' => 'DV',
  'hlg' => 'HLG',
  'imax' => 'IMAX',
  'atmos' => 'Atmos',
  'truehd' => 'TrueHD',
  final x when x.startsWith('dts') && x.endsWith('x') => 'DTS-X',
  _ => 'DTS-HD',
};

final _stripBracketsRe = RegExp(r'[\[\]()]');
final _anyWhitespaceRe = RegExp(r'\s+');
final _edgePunctRe = RegExp(r'^[\s\-_.~,;:|/&+@]+|[\s\-_.~,;:|/&+@]+$');
final _latinThreeWordRe = RegExp(r'[A-Za-z]{3,}');

String _pickTitle(String region) {
  var t = region
      .replaceAll('\u0001', ' ')
      .replaceAll(_stripBracketsRe, ' ')
      .replaceAll(_anyWhitespaceRe, ' ');
  t = t.replaceAll(_edgePunctRe, '');
  // Bilingual: keep CJK block when a Latin block with a 3+ letter word is at one edge.
  final toks = t.split(' ').where((x) => x.isNotEmpty).toList();
  if (toks.length > 1 && toks.any(_cjk.hasMatch)) {
    final isLatin = [for (final x in toks) !_cjk.hasMatch(x)];
    final first = isLatin.indexOf(false), last = isLatin.lastIndexOf(false);
    final contiguous = !isLatin.sublist(first, last + 1).contains(true);
    final latin = [
      for (var i = 0; i < toks.length; i++)
        if (isLatin[i]) toks[i],
    ];
    if (contiguous &&
        latin.isNotEmpty &&
        latin.any((x) => _latinThreeWordRe.hasMatch(x))) {
      t = toks.sublist(first, last + 1).join(' ');
    }
  }
  return t;
}
