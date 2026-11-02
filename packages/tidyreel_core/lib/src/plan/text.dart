import 'dart:math';

final _nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Lower-cased title with everything but letters / digits removed and
/// common Traditional Chinese characters folded to Simplified, for comparing titles.
String normTitle(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().replaceAll(_nonWord, '').runes) {
    final ch = String.fromCharCode(r);
    b.write(tradToSimp[ch] ?? ch);
  }
  return b.toString();
}

// Small map of common traditional chars; shared by recognizer, planner and TMDB scoring.
const tradToSimp = <String, String>{
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

/// 0..1 similarity of two titles: exact, containment ratio, or bigram Dice.
double similarity(String a, String b) {
  final na = normTitle(a), nb = normTitle(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  final contain = (na.contains(nb) || nb.contains(na))
      ? min(na.length, nb.length) / max(na.length, nb.length)
      : 0.0;
  return max(contain, _dice(na, nb));
}

double _dice(String a, String b) {
  if (a.length < 2 || b.length < 2) return 0;
  final ga = <String, int>{}, gb = <String, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    ga.update(a.substring(i, i + 2), (v) => v + 1, ifAbsent: () => 1);
  }
  for (var i = 0; i < b.length - 1; i++) {
    gb.update(b.substring(i, i + 2), (v) => v + 1, ifAbsent: () => 1);
  }
  var inter = 0;
  ga.forEach((k, v) => inter += min(v, gb[k] ?? 0));
  return 2 * inter / (a.length + b.length - 2);
}

/// Deterministic hex hash (two FNV-1a runs) for stable ids.
String stableHash(String s) {
  var h1 = 0x811c9dc5, h2 = 0x01000193;
  for (final c in s.codeUnits) {
    h1 = ((h1 ^ c) * 16777619) & 0xFFFFFFFF;
    h2 = ((h2 ^ c) * 2166136261) & 0xFFFFFFFF;
  }
  return h1.toRadixString(16).padLeft(8, '0') +
      h2.toRadixString(16).padLeft(8, '0');
}

String dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

String baseOf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// File name without its last extension.
String stem(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(i + 1) : '';
}

String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';
