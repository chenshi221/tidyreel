import 'dart:math';

import '../model/media.dart';
import '../model/metadata.dart';
import '../plan/text.dart' show tradToSimp;

/// Result of [normalizeQuery].
typedef NormalizedQuery = ({String text, int? year});

// Not glued directly after CJK characters ("请回答1988" keeps its number in the title).
final _year = RegExp(
  r'(?<![0-9\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af])(19|20)\d{2}(?![0-9])',
);
final _res = RegExp(
  r'(?<![a-z0-9])(\d{3,4}[pi]|[248]k|uhd|hdr|web-?dl|blu-?ray|bdrip|x26[45]|hevc)(?![a-z0-9])',
  caseSensitive: false,
);
final _punct = RegExp(
  r'''[\s._\-\[\]()【】（）「」『』《》:：,，;；!！?？~·・|/\\'"‘’“”&—–]+''',
);
// Same as _punct except apostrophes stay intact inside words when building
// TMDB search queries ("Schindler's List"), while leading/trailing quotes are stripped.
final _queryPunct = RegExp(
  r'''[\s._\-\[\]()【】（）「」『』《》:：,，;；!！?？~·・|/\\"“”&—–]+''',
);
final _edgeQuotes = RegExp(r'''^['‘’]+|['‘’]+$''');

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
  final text = s
      .replaceAll(_queryPunct, ' ')
      .trim()
      .replaceAll(_edgeQuotes, '')
      .trim();
  return (text: text, year: year);
}

/// Subtle bounded tie-breaker (`0.0..0.03`) derived from TMDB [Candidate.voteCount]
/// and [Candidate.popularity]. Returns `0.0` when both are absent or non-positive.
double popularityBonus(Candidate c) {
  final vc = c.voteCount;
  final pop = c.popularity;
  if (vc == null && pop == null) return 0.0;
  final vcBonus = vc != null && vc > 0
      ? min(0.02, (log(vc + 1) / ln10) / 4.0 * 0.02)
      : 0.0;
  final popBonus = pop != null && pop > 0 && pop.isFinite
      ? min(0.01, (log(pop + 1) / ln10) / 3.0 * 0.01)
      : 0.0;
  return min(0.03, vcBonus + popBonus);
}

/// Scores how well [c] matches an already-normalized query [normalized].
double scoreNormalized(
  Candidate c, {
  required NormalizedQuery normalized,
  int? year,
  MediaKind? kind,
}) {
  final y = year ?? normalized.year;
  final qs = _fold(normalized.text);
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
  if (sim >= 0.5) {
    score += popularityBonus(c);
  }
  return score.clamp(0.0, 1.0);
}

/// Scores how well a candidate TV show's TMDB season/episode structure matches
/// local files, returning a bonus or penalty in `-0.12 .. +0.10`.
///
/// Compares [localMaxEp] against the show's max single-season episode count and
/// total regular-season episode count (`s.number > 0`), and checks
/// [localSeasonCount] against the number of regular TMDB seasons.
double scoreEpisodeFit({
  required int localMaxEp,
  required int localSeasonCount,
  required ShowDetail show,
}) {
  final regular = [
    for (final s in show.seasons)
      if (s.number > 0 && s.episodeCount > 0) s,
  ];
  if (localMaxEp <= 0 || regular.isEmpty) return 0.0;

  final totalRegularEps = regular.fold<int>(
    0,
    (sum, s) => sum + s.episodeCount,
  );
  final maxSeasonEps = regular.fold<int>(
    0,
    (m, s) => s.episodeCount > m ? s.episodeCount : m,
  );
  final tmdbSeasonCount = regular.length;

  var score = 0.0;
  if (localMaxEp <= maxSeasonEps) {
    score += 0.06;
    if (localMaxEp >= 2 && regular.any((s) => s.episodeCount == localMaxEp)) {
      score += 0.02;
    }
  } else if (localMaxEp <= totalRegularEps) {
    score += 0.06;
    if (localMaxEp >= 2 && localMaxEp == totalRegularEps) {
      score += 0.02;
    }
  } else {
    final excess = localMaxEp - totalRegularEps;
    final ratio = localMaxEp / totalRegularEps;
    if (excess <= 2 && ratio <= 1.25) {
      score -= 0.02;
    } else if (ratio <= 2.0 && excess < 10) {
      score -= 0.06;
    } else if (ratio < 3.0 && excess < 15) {
      score -= 0.09;
    } else {
      score -= 0.12;
    }
  }

  if (localSeasonCount > 0) {
    if (localSeasonCount <= tmdbSeasonCount) {
      if (score >= 0) {
        score += (tmdbSeasonCount - localSeasonCount) <= 1 ? 0.02 : 0.01;
      }
    } else {
      final extraSeasons = localSeasonCount - tmdbSeasonCount;
      if (extraSeasons == 1) {
        score -= 0.02;
      } else if (extraSeasons == 2) {
        score -= 0.06;
      } else {
        score -= 0.10;
      }
    }
  }

  return score.clamp(-0.12, 0.10);
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
}) => scoreNormalized(
  c,
  normalized: normalizeQuery(query),
  year: year,
  kind: kind,
);

/// Same title once case, punctuation and traditional/simplified are ignored.
bool sameTitle(String a, String b) => _fold(a) == _fold(b);

/// Whether [title] shares meaningful tokens with [query]: whole word for Latin,
/// and for multi-character CJK words at least two distinct characters (or exact
/// containment) so single common characters like "的" or "人" don't falsely match.
bool sharesToken(String query, String title) {
  final t = _fold(title);
  if (t.isEmpty) return false;
  final tLen = t.runes.length;
  for (final word in query.split(' ')) {
    final w = _fold(word);
    if (w.isEmpty) continue;
    final isAscii = w.runes.every((r) => r < 0x80);
    if (isAscii) {
      if (t.contains(w)) return true;
    } else {
      if (t.contains(w)) return true;
      final wChars = {for (final r in w.runes) String.fromCharCode(r)};
      final need = (wChars.length >= 2 && tLen >= 2) ? 2 : 1;
      var matched = 0;
      for (final ch in wChars) {
        if (t.contains(ch) && ++matched >= need) return true;
      }
    }
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
