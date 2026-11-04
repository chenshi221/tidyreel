import '../model/media.dart';
import '../model/metadata.dart';
import '../plan/text.dart' show tradToSimp;

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
///   title, original title, English title and aliases. Case, punctuation and
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
  for (final t in [c.title, c.originalTitle, c.englishTitle, ...c.aliases]) {
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

/// Same title once case, punctuation and traditional/simplified are ignored.
bool sameTitle(String a, String b) => _fold(a) == _fold(b);

/// Whether [title] has any word of [query] (any character, for CJK). TMDB
/// matches on any token, so a hit with none matched on another title.
bool sharesToken(String query, String title) {
  final t = _fold(title);
  for (final word in query.split(' ')) {
    final w = _fold(word);
    if (w.isEmpty) continue;
    final found = w.runes.every((r) => r < 0x80)
        ? t.contains(w)
        : w.runes.any((r) => t.contains(String.fromCharCode(r)));
    if (found) return true;
  }
  return false;
}

String _fold(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().replaceAll(_punct, '').runes) {
    final ch = String.fromCharCode(r);
    b.write(tradToSimp[ch] ?? ch);
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
