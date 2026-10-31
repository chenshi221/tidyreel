import '../model/media.dart';
import '../model/metadata.dart';

/// Result of [normalizeQuery].
typedef NormalizedQuery = ({String text, int? year});

final _year = RegExp(r'(?<![0-9])(19|20)\d{2}(?![0-9])');
final _res = RegExp(
  r'(?<![a-z0-9])(\d{3,4}[pi]|[248]k|uhd|hdr|web-?dl|blu-?ray|bdrip|x26[45]|hevc)(?![a-z0-9])',
  caseSensitive: false,
);
final _punct = RegExp(r'[\s._\-\[\]()【】（）「」《》:：,，;；!！?？~·・|/\\]+');

/// Strips resolution/source leftovers, punctuation and a year from a raw query.
/// The year is returned separately. A query that is only a year ("2012") is kept
/// as text (it is a title), with no year.
NormalizedQuery normalizeQuery(String raw) {
  var s = raw.replaceAll(_res, ' ');
  final years = _year.allMatches(s).toList();
  int? year;
  if (years.isNotEmpty) {
    final m = years.last;
    final without = s.replaceRange(m.start, m.end, ' ');
    if (without.replaceAll(_punct, '').isNotEmpty) {
      year = int.parse(m.group(0)!);
      s = without;
    }
  }
  return (text: s.replaceAll(_punct, ' ').trim(), year: year);
}

/// Scores how well [c] matches a user/parsed [query], in 0..1 (higher is better).
///
/// - 0.7 * title similarity: the best of comparing the query against the zh
///   title, original title and English title. Case, punctuation and
///   simplified/traditional Chinese (small built-in map) are ignored. Exact = 1,
///   substring = 0.7..1 by length ratio, otherwise character-bigram Dice.
/// - 0.2 year bonus when both years are known: same year 0.2, off by one 0.1.
///   [year] defaults to a year found inside [query].
/// - 0.1 kind bonus when [kind] matches ([MediaKind.episode] and
///   [MediaKind.special] both mean TV; other kinds never get the bonus).
double scoreCandidate(
  Candidate c, {
  required String query,
  int? year,
  MediaKind? kind,
}) {
  final q = normalizeQuery(query);
  final y = year ?? q.year;
  final qs = _fold(q.text);
  var sim = 0.0;
  for (final t in [c.title, c.originalTitle, c.englishTitle]) {
    if (t == null) continue;
    final v = _similarity(qs, _fold(t));
    if (v > sim) sim = v;
  }
  var score = 0.7 * sim;
  if (y != null && c.year != null) {
    final d = (y - c.year!).abs();
    if (d == 0) score += 0.2;
    if (d == 1) score += 0.1;
  }
  final isTv = kind == MediaKind.episode || kind == MediaKind.special;
  if ((kind == MediaKind.movie && c.kind == MediaKind.movie) ||
      (isTv && c.kind == MediaKind.episode)) {
    score += 0.1;
  }
  return score;
}

String _fold(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().replaceAll(_punct, '').runes) {
    final ch = String.fromCharCode(r);
    b.write(_tradToSimp[ch] ?? ch);
  }
  return b.toString();
}

double _similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (a.contains(b) || b.contains(a)) {
    final short = a.length < b.length ? a.length : b.length;
    final long = a.length < b.length ? b.length : a.length;
    return 0.7 + 0.3 * short / long;
  }
  Map<String, int> grams(String s) {
    if (s.length < 2) return {s: 1};
    final m = <String, int>{};
    for (var i = 0; i < s.length - 1; i++) {
      m.update(s.substring(i, i + 2), (v) => v + 1, ifAbsent: () => 1);
    }
    return m;
  }

  final ga = grams(a), gb = grams(b);
  var common = 0;
  ga.forEach((k, v) {
    final o = gb[k];
    if (o != null) common += v < o ? v : o;
  });
  final total =
      ga.values.fold(0, (x, y) => x + y) + gb.values.fold(0, (x, y) => x + y);
  // Dice, capped below the substring range so partial overlap never beats it.
  return 0.7 * 2 * common / total;
}

// shortcut: small map of common traditional chars; extend when real-world
// misses show up, or switch to a full OpenCC table.
const _tradToSimp = <String, String>{
  '愛': '爱',
  '體': '体',
  '國': '国',
  '學': '学',
  '電': '电',
  '視': '视',
  '劇': '剧',
  '門': '门',
  '間': '间',
  '風': '风',
  '雲': '云',
  '龍': '龙',
  '鳳': '凤',
  '馬': '马',
  '魚': '鱼',
  '鳥': '鸟',
  '書': '书',
  '長': '长',
  '東': '东',
  '車': '车',
  '無': '无',
  '時': '时',
  '來': '来',
  '個': '个',
  '們': '们',
  '這': '这',
  '說': '说',
  '話': '话',
  '見': '见',
  '會': '会',
  '開': '开',
  '關': '关',
  '點': '点',
  '業': '业',
  '樂': '乐',
  '機': '机',
  '傳': '传',
  '約': '约',
  '紀': '纪',
  '錄': '录',
  '戰': '战',
  '爭': '争',
  '歲': '岁',
  '週': '周',
  '寶': '宝',
  '貝': '贝',
  '總': '总',
  '幾': '几',
  '兒': '儿',
  '後': '后',
  '還': '还',
  '過': '过',
  '從': '从',
  '當': '当',
  '實': '实',
  '現': '现',
  '發': '发',
  '種': '种',
  '經': '经',
  '義': '义',
  '園': '园',
  '團': '团',
  '圖': '图',
  '壞': '坏',
  '夢': '梦',
  '奪': '夺',
  '帥': '帅',
  '師': '师',
  '帶': '带',
  '應': '应',
  '態': '态',
  '懷': '怀',
  '擊': '击',
  '數': '数',
  '斷': '断',
  '於': '于',
  '術': '术',
  '極': '极',
  '標': '标',
  '檔': '档',
  '歡': '欢',
  '歸': '归',
  '殺': '杀',
  '決': '决',
  '溫': '温',
  '滿': '满',
  '災': '灾',
  '燈': '灯',
  '爺': '爷',
  '獄': '狱',
  '獵': '猎',
  '環': '环',
  '異': '异',
  '盜': '盗',
  '監': '监',
  '眾': '众',
  '碼': '码',
  '禮': '礼',
  '禪': '禅',
  '窮': '穷',
  '築': '筑',
  '節': '节',
  '範': '范',
  '糧': '粮',
  '細': '细',
  '終': '终',
  '結': '结',
  '絕': '绝',
  '網': '网',
  '習': '习',
  '聖': '圣',
  '聲': '声',
  '職': '职',
  '腦': '脑',
  '臺': '台',
  '與': '与',
  '舊': '旧',
  '藝': '艺',
  '蟲': '虫',
  '訊': '讯',
  '記': '记',
  '許': '许',
  '設': '设',
  '請': '请',
  '謎': '谜',
  '證': '证',
  '識': '识',
  '護': '护',
  '讓': '让',
  '豐': '丰',
  '貓': '猫',
  '賽': '赛',
  '趕': '赶',
  '輪': '轮',
  '農': '农',
  '遊': '游',
  '運': '运',
  '遠': '远',
  '選': '选',
  '鄉': '乡',
  '醫': '医',
  '鐵': '铁',
  '銀': '银',
  '陰': '阴',
  '陽': '阳',
  '隊': '队',
  '雙': '双',
  '雜': '杂',
  '離': '离',
  '難': '难',
  '韓': '韩',
  '頭': '头',
  '頻': '频',
  '顏': '颜',
  '類': '类',
  '飛': '飞',
  '館': '馆',
  '驚': '惊',
  '鬥': '斗',
  '黃': '黄',
  '齊': '齐',
  '麗': '丽',
  '樓': '楼',
  '條': '条',
  '貴': '贵',
  '賓': '宾',
  '蘭': '兰',
  '歷': '历',
  '勝': '胜',
  '輝': '辉',
  '強': '强',
  '彈': '弹',
  '復': '复',
  '懸': '悬',
  '殘': '残',
  '潛': '潜',
  '壯': '壮',
  '險': '险',
  '顯': '显',
  '亂': '乱',
  '傑': '杰',
  '偉': '伟',
  '僕': '仆',
  '凱': '凯',
  '剛': '刚',
  '創': '创',
  '務': '务',
  '動': '动',
  '勞': '劳',
  '勢': '势',
  '區': '区',
  '協': '协',
  '單': '单',
  '嚴': '严',
  '堅': '坚',
  '塵': '尘',
  '奧': '奥',
  '婦': '妇',
  '孫': '孙',
  '寧': '宁',
  '審': '审',
  '將': '将',
  '專': '专',
  '尋': '寻',
  '導': '导',
  '層': '层',
  '屬': '属',
  '幫': '帮',
  '廣': '广',
  '張': '张',
  '憶': '忆',
  '戲': '戏',
  '擇': '择',
  '攝': '摄',
  '敵': '敌',
  '鬧': '闹',
  '鮮': '鲜',
  '鷹': '鹰',
  '麼': '么',
};
