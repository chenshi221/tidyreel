import '../model/media.dart';
import '../plan/follow.dart' show subFlagsFromRemainder;
import 'numerals.dart';

// ---------------------------------------------------------------- classify

const videoExtensions = {
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
const subtitleExtensions = {
  'srt',
  'ass',
  'ssa',
  'sub',
  'idx',
  'sup',
  'vtt',
  'smi',
  'lrc',
};
const _videoExt = videoExtensions;
const _subExt = subtitleExtensions;
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
// Unambiguous TLDs that may appear as bare domains (dytt8.com, bbs.xxx.com).
// Common English words (.in, .us, .me, .tv, .co, .la, .fun, .top, .club) are
// excluded here so titles like All.In.mkv / About.Us.mkv / Love.Me.mkv /
// Apple.TV.mkv / Stand.By.Me.srt are never misclassified as ad URLs.
const _bareTld = 'com|net|org|cn|cc|xyz|vip|pw|site';
const _bareDomainPat =
    '[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.(?:$_bareTld)(?:\\.(?:cn|uk|jp|tw|hk))?(?![A-Za-z0-9])';
const _schemeOrWwwPat =
    'https?://\\S+|www\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*(?![A-Za-z0-9])';
final _urlRe = RegExp(
  '(?:$_schemeOrWwwPat|$_bareDomainPat)',
  caseSensitive: false,
);
final _wwwRe = RegExp('(?:$_schemeOrWwwPat)', caseSensitive: false);
final _leadDomainRe = RegExp(
  '^\\s*$_bareDomainPat[\\s._-]*',
  caseSensitive: false,
);
final _anyBracket = RegExp(r'\[[^\]]*\]|\([^)]*\)');
final _letterOrDigitRe = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _sampleRe = RegExp(r'^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]');
final _extRe = RegExp(r'^[a-z0-9!]+$');

bool _isAd(String c) => _adKw.hasMatch(c) || _urlRe.hasMatch(c);

final _schemeRe = RegExp(r'https?://', caseSensitive: false);

String _basename(String fileName) {
  final s = fileName.replaceAll('\\', '/');
  final m = _schemeRe.firstMatch(s);
  if (m != null) {
    final slashBefore = s.lastIndexOf('/', m.start);
    return slashBefore < 0 ? s : s.substring(slashBefore + 1);
  }
  return s.split('/').last;
}

FileRole classifyFile(String fileName) {
  final base = fold(_basename(fileName));
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
  final hadAd = _urlRe.hasMatch(rest) || _adKw.hasMatch(rest) || rest != stem;
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
  int? loneFourDigit; // "1080.mkv": only counts with folder context
  bool explicitEp = false;
  bool sxe = false;
  bool batch = false; // "全39集": a whole-season pack, not one episode
  DateTime? airDate; // "20240503" / "2024-05-03"
  bool specialKw = false, extraKw = false, movieKw = false, hasTech = false;
  String? res, group, lang, extra;
  String? edition;
  int? part;
  String? partLabel;
  List<String> subFlags = const [];
  ExternalId? externalId;
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

const _cnNum = r'[0-9]+|[零〇一二三四五六七八九十百千两兩]+';

// ---- external catalog IDs ({tmdb-27205}, [tmdbid=27205], {imdb-tt1375666},
//      (tt1375666), {tvdb-81189}, etc.)
final _extIdBracketedRe = RegExp(
  r'[\{\[\(]\s*(?:(tmdb|tvdb)(?:id)?\s*[-=:]\s*(\d+)|(imdb)(?:id)?\s*[-=:]\s*(tt\d{7,9})|(tt\d{7,9}))\s*[\}\]\)]',
  caseSensitive: false,
);
final _extIdBareRe = RegExp(
  r'(?<![A-Za-z0-9])(?:(tmdb|tvdb)(?:id)?\s*[-=:]\s*(\d+)|(imdb)(?:id)?\s*[-=:]\s*(tt\d{7,9})|(tt\d{7,9}))(?![A-Za-z0-9])',
  caseSensitive: false,
);

int _extIdPriority(String source) => switch (source) {
  'tmdb' => 3,
  'imdb' => 2,
  'tvdb' => 1,
  _ => 0,
};

ExternalId? _pickExtId(ExternalId? current, ExternalId candidate) {
  if (current == null) return candidate;
  return _extIdPriority(candidate.source) > _extIdPriority(current.source)
      ? candidate
      : current;
}

final _dateRe = RegExp(
  r'(?<![0-9])(?:(?:19|20)\d\d[-._ ](?:0[1-9]|1[0-2])[-._ ](?:0[1-9]|[12]\d|3[01])|(?:19|20)\d\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))(?![0-9])',
);
final _leadBracket = RegExp(r'^\s*[\[(]([^\]\)]*)[\])]');
final _midBracket = RegExp(r'\[([^\]]*)\]|\(([^)]*)\)');
final _crcRe = RegExp(r'^[0-9A-Fa-f]{8}$');

const _techWords =
    r'webdl|webrip|webhd|bluray|bdrip|brrip|bdremux|remux|hdtv|pdtv|dvdrip|dvdscr|dvd|hdrip|hdcam|bd|'
    r'amzn|nf|dsnp|hmax|atvp|hulu|x26[45]|h26[45]|hevc|avc|xvid|divx|av1|vc1|10bits?|8bits?|hi10p?|'
    r'(?:ddp?|ddplus|aac|ac3|eac3|dts|dtshd|dtsx|flac|truehd|atmos|opus|lpcm|mp3)\d*|ch\d\d|'
    r'hdr10(?:plus)?|hdr|dv|dovi|hlg|sdr|imax|hsbs|halfsbs|hou|halfou|proper|repack|rerip|extended|unrated|remastered|'
    r'internal|multi|dual|dubbed|subbed|complete|batch|limited|hybrid|mkv|mp4|avi';
final _techRe = RegExp(
  '(?<![A-Za-z0-9])(?:$_techWords|\\d{3,4}x\\d{3,4}|[248]k|uhd|fhd)(?![A-Za-z0-9])'
  '|(?<![0-9])\\d{3,4}[pi](?![A-Za-z0-9])', // "BD1080P" is common in CN releases
  caseSensitive: false,
);
final _techOnlyRe = RegExp(
  '^(?:$_techWords|\\d{3,4}[pi]|\\d{3,4}x\\d{3,4}|[248]k|uhd|fhd|web|tv|big5|gb|chs|cht|sc|tc|'
  'dc|3d|hsbs|sbs|hou|criterion|theatrical|forced|sdh|bilingual|default|'
  'mkv|mp4|v\\d|\\d{1,3}[-~]\\d{1,3}|\\d{4}|[\\s,&+/_.-])+\$',
  caseSensitive: false,
);
final _cnNoise = RegExp(
  '国粤双语|國粵雙語|国语版|國語版|粤语版|粵語版|国配|國配|粤配|粵配|'
  '加长版|加長版|未分级版|未分級版|导演剪辑版?|導演剪輯版?|导剪版|導剪版|'
  '国语|粤语|国粤|中字|中英|简繁|简体|繁体|繁體|高清|超清|蓝光|原盘|完整版|无删减|全集|合集|内封|内嵌|外挂|双语|字幕|修复版|珍藏版|新版|首发|重制版',
);

// ---- .5 recap patterns (anime specials, e.g. S01E12.5, E12.5, 第12.5话, - 12.5)
final _seHalfRe = RegExp(
  r'(?<![A-Za-z0-9])S(\d{1,2}) ?E(\d{1,4})\.5(?![0-9])',
  caseSensitive: false,
);
final _cnEpHalfRe = RegExp(r'第 ?(\d{1,4})\.5 ?[集话話期回]');
final _epHalfRe = RegExp(
  r'(?<![A-Za-z0-9])(?:(?:EP|Episode) ?|E)(\d{1,4})\.5(?![0-9])',
  caseSensitive: false,
);
final _dashHalfRe = RegExp(
  r'(?:^| )- ?(\d{1,4})\.5(?:v\d{1,2})?(?![A-Za-z0-9])',
);
final _bareHalfRe = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,4})\.5(?:v\d)?(?![A-Za-z0-9])',
);

final _seRe = RegExp(
  r'(?<![A-Za-z0-9])S(\d{1,2}) ?E(\d{1,4})((?: ?- ?E?\d{1,4}| ?~ ?E?\d{1,4}| ?E\d{1,4})*)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _xRe = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])',
  caseSensitive: false,
);
// "第01集", "第01-02集", "第3期上", "第3期下"
final _cnEpRe = RegExp(
  '第 ?($_cnNum)(?: ?[-~] ?($_cnNum))? ?[集话話期回](?: ?([上中下])(?:集|部)?(?![一-鿿]))?',
);
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
final _volRe = RegExp(
  r'(?<![A-Za-z0-9])Vol(?:ume)? ?(\d{1,3})(?![A-Za-z0-9])',
  caseSensitive: false,
);
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
  r'(?<![A-Za-z0-9])(?:OVA|OAD|SPs?|Specials?) ?(\d{1,3})?(?![A-Za-z0-9])|(?:特别篇|特別篇|番外篇?|先导片|先導片) ?(\d{1,3})?',
  caseSensitive: false,
);
// Case-sensitive acronyms (PV/CM/OP/ED) and CJK extra words.
final _extraCsRe = RegExp(
  r'(?<![A-Za-z0-9])(?:PV|CM) ?\d{0,2}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?:OP|ED) ?\d{1,2}(?![A-Za-z0-9])|'
  r'未播花絮|未播片段|加更版|纯享版|純享版|衍生版|花絮|幕后|特典|预告片?|宣传片|访谈|片头曲|片尾曲|特辑|彩蛋',
);
// Case-insensitive extra words (consolidated once; not duplicated in _extraCsRe).
final _extraCiRe = RegExp(
  r'(?<![A-Za-z0-9])(?:NCOP|NCED|Creditless ?(?:Opening|Ending)|Trailers?|Teaser|Menu|Making(?: of)?|Featurettes?|Interviews?|Behind The Scenes|Deleted Scenes?|Extras?|Bonus) ?\d{0,2}(?![A-Za-z0-9])',
  caseSensitive: false,
);
// Unambiguous extra markers that are never standalone English movie titles.
final _strictExtraRe = RegExp(
  r'^(?:NCOP|NCED|PV|CM|OP|ED|未播花絮|未播片段|加更版|纯享版|純享版|衍生版|花絮|幕后|特典|预告|宣传片|访谈|片头曲|片尾曲|特辑|彩蛋)',
);
final _theTitlePrefixRe = RegExp(r'^\s*the\s+$', caseSensitive: false);
final _cjkMovieRe = RegExp(r'剧场版|劇場版|电影版|Gekijouban', caseSensitive: false);
final _theMovieRe = RegExp(
  r'(?<![A-Za-z])The Movie(?![A-Za-z])',
  caseSensitive: false,
);
final _afterTheatricalTitleRe = RegExp(r'[\u3400-\u9fff]{2,}|[A-Za-z]{3,}');

// ---- Release editions
final _edDirectorsCutRe = RegExp(
  r"(?<![A-Za-z0-9])Director'?s? Cut(?![A-Za-z0-9])|导演剪辑版?|導演剪輯版?|导剪版|導剪版",
  caseSensitive: false,
);
final _edDcTagRe = RegExp(r'(?<![A-Za-z0-9])DC(?![A-Za-z0-9])');
final _edFinalCutRe = RegExp(
  r'(?<![A-Za-z0-9])(?:The )?Final Cut(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _edExtendedRe = RegExp(
  r'(?<![A-Za-z0-9])Extended(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])|加长版|加長版',
  caseSensitive: false,
);
final _edUnratedRe = RegExp(
  r'(?<![A-Za-z0-9])Unrated(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])|未分级版|未分級版',
  caseSensitive: false,
);
final _edTheatricalRe = RegExp(
  r'(?<![A-Za-z0-9])Theatrical(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _edCriterionRe = RegExp(
  r'(?<![A-Za-z0-9])Criterion(?: Collection)?(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _edImaxRe = RegExp(
  r'(?<![A-Za-z0-9])IMAX(?: Enhanced)?(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _ed3dExplicitRe = RegExp(
  r'(?<![A-Za-z0-9])(?:H-?SBS|Half[- ]?SBS|HalfSBS|H-?OU|Half[- ]?OU|HalfOU)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _ed3dRe = RegExp(
  r'(?<![A-Za-z0-9])3D(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _edRemuxRe = RegExp(
  r'(?<![A-Za-z0-9])(?:BD)?REMUX(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _edCnDualDubRe = RegExp(r'国粤双语|國粵雙語');
final _edCnMandarinRe = RegExp(r'国语版|國語版|国配|國配');
final _edCnCantoneseRe = RegExp(r'粤语版|粵語版|粤配|粵配');

// ---- Multi-part movie / split tags
final _partCdRe = RegExp(
  r'(?<![A-Za-z0-9])CD ?([1-9])(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _partDiscRe = RegExp(
  r'(?<![A-Za-z0-9])(?:Disc|Disk) ?([1-9])(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _partPtRe = RegExp(
  r'(?<![A-Za-z0-9])Pt ?([1-9])(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _partWordRe = RegExp(
  r'(?<![A-Za-z0-9])Part ?([1-9])(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _partCnJiRe = RegExp(r'(?<=.)([上中下])集(?![一-鿿])');
final _partCnBracketedRe = RegExp(r'\u0001 ([上中下])(?:集|部)?(?=[\s\u0001]|$)');
final _partCnLooseRe = RegExp(
  r'(?<=[\s\u0001])([上中下])(?:\s*$|(?=\s*(?:\u0001|(?:19|20)\d\d|\d{3,4}[pi]|[248]k|BD|WEB|HD|UHD|BluRay|Remux|国|粤|中|简|繁|双语|字幕|高清|超清|蓝光|原盘)))',
  caseSensitive: false,
);

// Not glued to CJK on the left: "请回答1988" keeps its number in the title.
final _yearRe = RegExp(r'(?<![A-Za-z0-9㐀-鿿])((?:19|20)\d\d)(?![A-Za-z0-9])');
final _cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯]');
final _langRe = RegExp(
  r'(?<![A-Za-z0-9])(zh[-_ ]?(?:cn|tw|hans|hant|hk|sg)|en[-_ ]?(?:us|gb)|chs|cht|zhs|zht|chi|zho|jpsc|jptc|sc|tc|gbk|gb2312|gb|big5|english|eng|en|japanese|jpn|jap|jp|ja|korean|kor|ko|zh|cn|chinese|'
  r'简体中文|繁體中文|繁体中文|简体|繁体|繁體|简中|繁中|简日|繁日|简繁|简英|繁英|中英|中文|双语|雙語|日语|日文|韩语|韩文|英文|英语)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _subFlagTrailerRe = RegExp(
  r'^(?:forced|force|default|sdh|hi|cc|bilingual|强制|強制|默认|默認|听障|聽障)$',
  caseSensitive: false,
);
final _trailingSubFlagRe = RegExp(
  r'(?:^|[\s\u0001])(forced|default|sdh|bilingual|强制|強制|默认|默認|听障|聽障)(?=(?:[\s\u0001]+(?:forced|force|default|sdh|hi|cc|bilingual|强制|強制|默认|默認|听障|聽障))*\s*$)',
  caseSensitive: false,
);

final _fourDigitYearRe = RegExp(r'^(?:19|20)\d\d$');
final _loneFourDigitRe = RegExp(r'^(\d{4})$');
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

bool _hasExtraMarker(String c) =>
    _extraCsRe.hasMatch(c) || _extraCiRe.hasMatch(c);

RegExpMatch? _firstExtraMatch(String s) {
  final a = _extraCsRe.firstMatch(s);
  final b = _extraCiRe.firstMatch(s);
  if (a == null) return b;
  if (b == null) return a;
  return a.start <= b.start ? a : b;
}

bool _hasEpisodeMarker(String c) =>
    _seRe.hasMatch(c) ||
    _seHalfRe.hasMatch(c) ||
    _xRe.hasMatch(c) ||
    _cnEpRe.hasMatch(c) ||
    _cnEpHalfRe.hasMatch(c) ||
    _epRe.hasMatch(c) ||
    _epHalfRe.hasMatch(c) ||
    _specialRe.hasMatch(c) ||
    _hasExtraMarker(c) ||
    _seasonRes.any((r) => r.hasMatch(c));

final _webdlRe = RegExp(r'web[-. _]?dl', caseSensitive: false);
final _blurayRe = RegExp(r'blu[-. ]?ray', caseSensitive: false);
final _half3dRe = RegExp(
  r'(?<![A-Za-z0-9])(half|h)[-. _]?(sbs|ou)(?![A-Za-z0-9])',
  caseSensitive: false,
);
const _nonGroupTrailerTags = {
  '3d',
  'dc',
  'sbs',
  'ou',
  'hsbs',
  'hou',
  'criterion',
  'theatrical',
};
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
final _localeUnderscoreRe = RegExp(
  r'(?<![A-Za-z0-9])(zh)_(cn|tw|hk|sg|hans|hant)(?![A-Za-z0-9])|(?<![A-Za-z0-9])(en)_(us|gb)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _halfDotRe = RegExp(
  r'(?<![A-Za-z0-9])((?:S\d{1,2} ?E|EP?|Episode[ .]?|第 ?)?)(?!19\d\d|20\d\d)(\d{1,4})\.5(?![0-9])',
  caseSensitive: false,
);
final _dotsUnderscoresRe = RegExp(r'[._]');
final _whitespaceRe = RegExp(r'[ \t]+');

String _normalize(String s) {
  s = s.replaceAllMapped(_webdlRe, (m) => 'WEBDL');
  s = s.replaceAllMapped(_blurayRe, (m) => 'BluRay');
  s = s.replaceAllMapped(
    _half3dRe,
    (m) =>
        '${m[1]!.toLowerCase() == 'half' ? 'Half' : 'H'}${m[2]!.toUpperCase()}',
  );
  s = s.replaceAllMapped(_h26xRe, (m) => 'H26${m[1]}');
  s = s.replaceAllMapped(_hdr10PlusRe, (m) => '${m[1]}plus');
  s = s.replaceAllMapped(_audioChRe, (m) => '${m[1]}${m[2]}${m[3]}');
  s = s.replaceAllMapped(_chDigitRe, (m) => 'ch${m[1]}${m[2]}');
  s = s.replaceAllMapped(
    _localeUnderscoreRe,
    (m) => m[1] != null ? '${m[1]}\u0002${m[2]}' : '${m[3]}\u0002${m[4]}',
  );
  s = s.replaceAllMapped(_halfDotRe, (m) => '${m[1]}${m[2]}\u00035');
  s = s.replaceAll(_dotsUnderscoresRe, ' ');
  s = s.replaceAll('\u0002', '_').replaceAll('\u0003', '.');
  return s.replaceAll(_whitespaceRe, ' ').trim();
}

int _seasonNum(RegExpMatch m) => chineseToInt(m[1]!) ?? 0;

/// [first]..[last] for "EP01-EP03"; just [first] when [last] is absent or
/// not a plausible range end.
List<int> _range(int first, int? last) =>
    last == null || last <= first || last - first > 200
    ? [first]
    : [for (var i = first; i <= last; i++) i];

/// Parses an 8-digit YYYYMMDD string, returning null when the calendar date
/// does not exist (e.g. 20240231 where DateTime.utc would silently roll over).
DateTime? _tryParseCalendarDate(String digits) {
  final y = int.parse(digits.substring(0, 4));
  final mo = int.parse(digits.substring(4, 6));
  final d = int.parse(digits.substring(6, 8));
  final dt = DateTime.utc(y, mo, d);
  if (dt.year != y || dt.month != mo || dt.day != d) return null;
  return dt;
}

(int, String) _cnPart(String ch) => switch (ch) {
  '上' => (1, 'pt1'),
  '中' => (2, 'pt2'),
  _ => (2, 'pt2'),
};

final _dashDateRe = RegExp(r'[-._ ]');
final _numWithVRe = RegExp(r'^\d{1,4}(?:\.5)?(?:v\d)?$');
final _trailerGroupRe = RegExp(r'-([A-Za-z0-9]{2,16}) *(?:\[[^\]]*\] *)*$');
final _eNumRe = RegExp(r'^E?\d+$', caseSensitive: false);
final _multiSpaceRe = RegExp(r' {2,}');
final _multiEpRe = RegExp(r'( ?[-~] ?)?E?(\d+)', caseSensitive: false);
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
  r'(?<![A-Za-z0-9])(hdr10plus|hdr10|hdr|dovi|dv|hlg|imax|atmos|truehd|dts[- ]?hd|dts[- ]?x)\d*(?![A-Za-z0-9])',
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

  // Explicit external catalog IDs ({tmdb-27205}, [tmdbid=27205],
  // {imdb-tt1375666}, (tt1375666), {tvdb-81189}, etc.) — stripped early so
  // they never become release groups or pollute the title.
  String stripExtIds(String input, RegExp re) =>
      input.replaceAllMapped(re, (m) {
        final ExternalId id;
        if (m[1] != null) {
          id = ExternalId(m[1]!.toLowerCase(), m[2]!);
        } else if (m[3] != null) {
          id = ExternalId('imdb', m[4]!.toLowerCase());
        } else {
          id = ExternalId('imdb', m[5]!.toLowerCase());
        }
        a.externalId = _pickExtId(a.externalId, id);
        return ' ';
      });
  s = stripExtIds(s, _extIdBracketedRe);
  s = stripExtIds(s, _extIdBareRe);

  s = s.replaceAllMapped(_dateRe, (dm) {
    final dt = _tryParseCalendarDate(dm[0]!.replaceAll(_dashDateRe, ''));
    if (dt == null) return dm[0]!;
    a.airDate ??= dt;
    return ' \u0001 ';
  });

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
  s = s.replaceAllMapped(
    _half3dRe,
    (m) =>
        '${m[1]!.toLowerCase() == 'half' ? 'Half' : 'H'}${m[2]!.toUpperCase()}',
  );
  if (a.group == null) {
    final gm = _trailerGroupRe.firstMatch(s);
    if (gm != null) {
      final cand = gm[1]!;
      final before = _normalize(s.substring(0, gm.start));
      // Do not swallow trailing subtitle language/flag codes ("-CHS", "-forced") as group.
      final isSubMeta =
          isSub && (_langRe.hasMatch(cand) || _subFlagTrailerRe.hasMatch(cand));
      if (_techRe.hasMatch(before) &&
          !_techRe.hasMatch(cand) &&
          !_eNumRe.hasMatch(cand) &&
          !_nonGroupTrailerTags.contains(cand.toLowerCase()) &&
          !isSubMeta) {
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

  // "剧场版 名侦探柯南 ..." — anime movie prefix/mid-title is stripped as a flag.
  // When "剧场版" sits at the trailing end (after title/year, with no title words
  // after it), it is also a Theatrical edition tag.
  final cjkMovieM = _cjkMovieRe.firstMatch(s);
  if (cjkMovieM != null) {
    a.movieKw = true;
    final matched = cjkMovieM[0]!;
    final after = s
        .substring(cjkMovieM.end)
        .replaceAll(_techRe, ' ')
        .replaceAll(_cnNoise, ' ')
        .replaceAll(_yearRe, ' ')
        .replaceAll('\u0001', ' ')
        .trim();
    if (cjkMovieM.start > 0 &&
        (matched == '剧场版' || matched == '劇場版') &&
        !_afterTheatricalTitleRe.hasMatch(after)) {
      a.edition ??= 'Theatrical';
    }
    s = s
        .replaceRange(cjkMovieM.start, cjkMovieM.end, ' ')
        .replaceAll(_multiSpaceRe, ' ')
        .trim();
  } else {
    // Only strip "The Movie" when a title precedes it ("Pokemon The Movie 2019");
    // keep a real title starting with "The Movie" ("The Movie 2019.mkv") intact.
    final theMovieM = _theMovieRe.firstMatch(s);
    if (theMovieM != null && theMovieM.start > 0) {
      a.movieKw = true;
      s = s
          .replaceRange(theMovieM.start, theMovieM.end, ' ')
          .replaceAll(_multiSpaceRe, ' ')
          .trim();
    }
  }

  var cut = s.length;
  void mark(int i) {
    if (i >= 0 && i < cut) cut = i;
  }

  // ---- season / episode (check .5 recap specials first so they don't collide)
  var m = _seHalfRe.firstMatch(s);
  if (m != null) {
    a.specialKw = true;
    a.episodes = [int.parse(m[2]!)];
    a.explicitEp = a.sxe = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _cnEpHalfRe.firstMatch(s)) != null) {
    a.specialKw = true;
    a.episodes = [int.parse(m![1]!)];
    a.explicitEp = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _epHalfRe.firstMatch(s)) != null) {
    a.specialKw = true;
    a.episodes = [int.parse(m![1]!)];
    a.explicitEp = true;
    mark(m.start);
  }
  if (a.episodes.isEmpty && (m = _seRe.firstMatch(s)) != null) {
    a.season = int.parse(m![1]!);
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
      if (m[3] != null) {
        final (p, label) = _cnPart(m[3]!);
        a.part = p;
        a.partLabel = label;
      }
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

  // ---- year: last plausible release year (<= currentYear + 2) not at index 0
  final maxYear = DateTime.now().year + 2;
  final yrs = _yearRe.allMatches(s).toList();
  RegExpMatch? ym;
  for (final y in yrs) {
    final val = int.parse(y[1]!);
    if (y.start > 0 && val <= maxYear) ym = y;
  }

  // ---- volume marker ("vol.1" / "Volume 2"), unless inside a title before a year
  final vm = _volRe.firstMatch(s);
  if (vm != null && vm.start > 0 && (ym == null || vm.start > ym.start)) {
    mark(vm.start);
    if (a.episodes.isEmpty &&
        !_dashRe.hasMatch(s) &&
        !_dashHalfRe.hasMatch(s)) {
      a.episodes = [int.parse(vm[1]!)];
      a.explicitEp = true;
    }
  }

  // ---- special / extra / movie keywords
  final em = _firstExtraMatch(s);
  // A keyword before an explicit episode, running on into lowercase words
  // ("Today's Menu for the Emiya Family"), preceded by "The " ("The Menu",
  // "The Interview"), or appearing as the main title before a release year
  // ("The Menu (2022)", "Interview (2007)") is part of the title, not an extra.
  final beforeEm = em == null ? '' : s.substring(0, em.start);
  final inTitle =
      em != null &&
      ((a.explicitEp && em.start < cut) ||
          _leadLowerRe.hasMatch(s.substring(em.end)) ||
          (_theTitlePrefixRe.hasMatch(beforeEm) &&
              !_strictExtraRe.hasMatch(em[0]!)) ||
          (ym != null &&
              em.start < ym.start &&
              !beforeEm.contains('\u0001') &&
              !beforeEm.contains(' - ') &&
              !_strictExtraRe.hasMatch(em[0]!)));
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

  // ---- release editions (canonical priority; strips edition tags from title)
  void applyEdition(
    RegExp re,
    String canonical, {
    bool requireAfterCut = false,
  }) {
    final em2 = re.firstMatch(s);
    if (em2 == null) return;
    if (requireAfterCut) {
      if (em2.start < cut) return;
    } else if (em2.start == 0) {
      return;
    }
    a.edition ??= canonical;
    mark(em2.start);
  }

  applyEdition(_edDirectorsCutRe, "Director's Cut");
  applyEdition(_edDcTagRe, "Director's Cut", requireAfterCut: true);
  final fc = _edFinalCutRe.firstMatch(s);
  if (fc != null &&
      fc.start > 0 &&
      (ym == null || fc.start > ym.start) &&
      !_theTitlePrefixRe.hasMatch(s.substring(0, fc.start))) {
    a.edition ??= 'Final Cut';
    mark(fc.start);
  }
  applyEdition(_edExtendedRe, 'Extended');
  applyEdition(_edUnratedRe, 'Unrated');
  applyEdition(_edTheatricalRe, 'Theatrical');
  applyEdition(_edCriterionRe, 'Criterion');
  applyEdition(_edImaxRe, 'IMAX');
  applyEdition(_ed3dExplicitRe, '3D');
  final m3d = _ed3dRe.firstMatch(s);
  if (m3d != null && m3d.start > 0 && (ym == null || m3d.start > ym.start)) {
    a.edition ??= '3D';
    mark(m3d.start);
  }
  final remuxM = _edRemuxRe.firstMatch(s);
  if (remuxM != null) {
    a.edition ??= 'Remux';
    mark(remuxM.start);
  }
  applyEdition(_edCnDualDubRe, '国粤双语');
  applyEdition(_edCnMandarinRe, '国语');
  applyEdition(_edCnCantoneseRe, '粤语');

  // ---- multi-part movie / split tags (CD1, Disc 1, Pt 1, Part 1, 上集/下集, (上)/(下))
  if (a.part == null) {
    final cdM = _partCdRe.firstMatch(s);
    if (cdM != null && cdM.start > 0) {
      final n = int.parse(cdM[1]!);
      a.part = n;
      a.partLabel = 'cd$n';
      mark(cdM.start);
    }
  }
  if (a.part == null) {
    final discM = _partDiscRe.firstMatch(s);
    if (discM != null && discM.start > 0) {
      final n = int.parse(discM[1]!);
      a.part = n;
      a.partLabel = 'disc$n';
      mark(discM.start);
    }
  }
  if (a.part == null) {
    final ptM = _partPtRe.firstMatch(s);
    if (ptM != null && ptM.start > 0) {
      final n = int.parse(ptM[1]!);
      a.part = n;
      a.partLabel = 'pt$n';
      mark(ptM.start);
    }
  }
  if (a.part == null && a.episodes.isEmpty && !a.explicitEp) {
    for (final partM in _partWordRe.allMatches(s)) {
      if (partM.start > 0 && (ym == null || partM.start > ym.start)) {
        final n = int.parse(partM[1]!);
        a.part = n;
        a.partLabel = 'pt$n';
        mark(partM.start);
        break;
      }
    }
  }
  if (a.part == null && (a.episodes.isEmpty || _cnEpRe.hasMatch(s))) {
    final cnPartM =
        _partCnJiRe.firstMatch(s) ??
        _partCnBracketedRe.firstMatch(s) ??
        _partCnLooseRe.firstMatch(s);
    if (cnPartM != null && cnPartM.start > 0) {
      final (p, label) = _cnPart(cnPartM[1]!);
      a.part = p;
      a.partLabel = label;
      mark(cnPartM.start);
    }
  }

  // ---- subtitle language and trait flags
  if (isSub) {
    final lm = _langRe.firstMatch(s);
    if (lm != null) {
      a.lang = lm[1]!.replaceAll(' ', '-');
      mark(lm.start);
    }
    if (cut == s.length) {
      final fm = _trailingSubFlagRe.firstMatch(s);
      if (fm != null) mark(fm.start);
    }
    if (cut < s.length) {
      a.subFlags = subFlagsFromRemainder(s.substring(cut));
    }
  }

  // ---- bare numbers (including .5 anime recap episodes and lone 4-digit stems)
  final noMarker =
      a.episodes.isEmpty && !a.specialKw && !a.extraKw && !a.movieKw;
  if (noMarker && file) {
    final dhm = _dashHalfRe.firstMatch(s);
    if (dhm != null) {
      a.specialKw = true;
      a.bare = int.parse(dhm[1]!);
      a.bareFrom = 'dash';
      mark(dhm.start);
    }
    if (a.bare == null) {
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
    }
    if (a.bare == null && a.year == null) {
      final region = s.substring(0, cut);
      final halfNums = _bareHalfRe.allMatches(region).toList();
      if (halfNums.isNotEmpty) {
        final last = halfNums.last;
        final before = region.substring(0, last.start).trim();
        final after = region.substring(last.end).replaceAll(_spaceDashRe, '');
        if (after.isEmpty) {
          a.specialKw = true;
          a.bare = int.parse(last[1]!);
          a.bareFrom = before.isEmpty ? 'lone' : 'trail';
          cut = last.start;
        }
      }
    }
    if (a.bare == null && a.year == null) {
      final region = s.substring(0, cut);
      final trimmedRegion = region.trim();
      final fourM = _loneFourDigitRe.firstMatch(trimmedRegion);
      if (fourM != null) {
        final n = int.parse(fourM[1]!);
        if (n >= 1000 && n < 1900) {
          a.loneFourDigit = n;
        }
      } else {
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
  }

  // Re-evaluate subFlags if a bare number or recap moved `cut` earlier
  // (e.g. "[Group] Title - 05.jpsc.ass" where `cut` moved before `- 05`).
  if (isSub && cut < s.length && a.subFlags.isEmpty) {
    a.subFlags = subFlagsFromRemainder(s.substring(cut));
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
  // order: resolution, picture (DV/HDR), audio (Atmos/TrueHD/DTS-HD/DTS-X)
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
final _spacedCjkRe = RegExp(r'(?<![^\s])[㐀-鿿](?: [㐀-鿿](?![^\s]))+');

String _pickTitle(String region) {
  var t = region
      .replaceAll('\u0001', ' ')
      .replaceAll(_stripBracketsRe, ' ')
      .replaceAll(_anyWhitespaceRe, ' ');
  t = t.replaceAll(_edgePunctRe, '');
  // "谜.探.路.德.维.希" (dots between every character): join the run back up.
  t = t.replaceAllMapped(_spacedCjkRe, (m) => m[0]!.replaceAll(' ', ''));
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
