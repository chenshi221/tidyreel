/// Chinese / ASCII numeral → int. Handles 十二, 二十, 一百零五, 二〇, 两/兩, and digits.
int? chineseToInt(String s) {
  if (s.isEmpty) return null;
  final asInt = int.tryParse(s);
  if (asInt != null) return asInt;
  const digit = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const unit = {'十': 10, '百': 100, '千': 1000};
  final chars = s.split('');
  if (!chars.any(unit.containsKey)) {
    // positional digits: 二〇 -> 20
    var n = 0;
    for (final c in chars) {
      final d = digit[c];
      if (d == null) return null;
      n = n * 10 + d;
    }
    return n;
  }
  var total = 0;
  int? cur; // null = no pending digit; 0 = explicit 零; 1..9 = pending digit
  var lastUnit = 10000;
  for (final c in chars) {
    final d = digit[c];
    if (d != null) {
      if (cur != null) {
        // Only an explicit 零 followed by a non-zero digit is valid ("一百零五").
        if (cur == 0 && d != 0) {
          cur = d;
        } else {
          return null;
        }
      } else {
        cur = d;
      }
    } else if (unit.containsKey(c)) {
      final u = unit[c]!;
      // Units must strictly decrease (千 > 百 > 十), and explicit 零 cannot precede a unit ("零十").
      if (u >= lastUnit || cur == 0) return null;
      if (cur == null && u != 10) return null;
      total += (cur ?? 1) * u;
      cur = null;
      lastUnit = u;
    } else {
      return null;
    }
  }
  return total + (cur ?? 0);
}
