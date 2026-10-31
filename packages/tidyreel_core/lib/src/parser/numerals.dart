/// Chinese / ASCII numeral → int. Handles 十二, 二十, 一百零五, 二〇, 两, and digits.
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
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const unit = {'十': 10, '百': 100, '千': 1000};
  if (!s.split('').any(unit.containsKey)) {
    // positional digits: 二〇 -> 20
    var n = 0;
    for (final c in s.split('')) {
      final d = digit[c];
      if (d == null) return null;
      n = n * 10 + d;
    }
    return n;
  }
  var total = 0, cur = 0;
  for (final c in s.split('')) {
    if (digit.containsKey(c)) {
      cur = digit[c]!;
    } else if (unit.containsKey(c)) {
      total += (cur == 0 ? 1 : cur) * unit[c]!;
      cur = 0;
    } else {
      return null;
    }
  }
  return total + cur;
}
