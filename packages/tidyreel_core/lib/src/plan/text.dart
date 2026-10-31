import 'dart:math';

final _nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Lower-cased title with everything but letters / digits removed, for comparing titles.
String normTitle(String s) => s.toLowerCase().replaceAll(_nonWord, '');

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
