import 'package:test/test.dart';
import 'package:tidyreel_core/src/model/media.dart';
import 'package:tidyreel_core/src/parser/numerals.dart';
import 'package:tidyreel_core/src/parser/parser.dart';

import 'fixtures.dart';

const _parser = RuleBasedParser();

/// Returns a list of mismatch descriptions (empty = pass).
List<String> _check(Case c) {
  final r = _parser.parse(c.name, parentDirs: c.dirs);
  final bad = <String>[];
  void str(String field, String? want, String? got) {
    if (want == null) return;
    final w = want == noStr ? null : want;
    if (w != got) bad.add('$field: want $w, got $got');
  }

  void num(String field, int? want, int? got) {
    if (want == null) return;
    final w = want == none ? null : want;
    if (w != got) bad.add('$field: want $w, got $got');
  }

  str('title', c.t, r.title);
  num('year', c.y, r.year);
  num('season', c.s, r.season);
  num('absolute', c.a, r.absolute);
  str('kind', c.k, r.kind.name);
  str('resolution', c.r, r.resolution);
  str('group', c.g, r.group);
  str('lang', c.l, r.lang);
  str('extraInfo', c.x, r.extraInfo);
  if (c.e != null && c.e!.join(',') != r.episodes.join(',')) {
    bad.add('episodes: want ${c.e}, got ${r.episodes}');
  }
  if (c.hi && r.confidence < 0.9) bad.add('confidence ${r.confidence} < 0.9');
  if (c.lo && r.confidence >= 0.5) bad.add('confidence ${r.confidence} >= 0.5');
  return bad;
}

void main() {
  test('fixtures: pass rate >= 95%, only documented failures', () {
    var passed = 0;
    final unexpected = <String>[];
    final known = <String>[];
    for (final c in parseCases) {
      final bad = _check(c);
      if (bad.isEmpty) {
        passed++;
        // ignore: avoid_print
        if (c.known != null)
          print('  NOTE  now passes, drop `known`: ${c.name}');
        continue;
      }
      final line =
          '${c.name}${c.dirs.isEmpty ? '' : '  dirs=${c.dirs}'}  -> ${bad.join('; ')}';
      (c.known != null ? known : unexpected).add(line);
    }
    final total = parseCases.length;
    final rate = passed / total;
    // ignore: avoid_print
    print(
      'parser fixtures: $passed/$total = ${(rate * 100).toStringAsFixed(1)}% '
      '(${known.length} known failures, ${unexpected.length} unexpected)',
    );
    for (final l in known) {
      // ignore: avoid_print
      print('  KNOWN  $l');
    }
    expect(total, greaterThanOrEqualTo(300));
    expect(unexpected, isEmpty, reason: unexpected.join('\n'));
    expect(rate, greaterThanOrEqualTo(0.95));
  });

  test('classify fixtures', () {
    final bad = <String>[];
    classifyCases.forEach((name, role) {
      final got = _parser.classify(name).name;
      if (got != role) bad.add('$name: want $role, got $got');
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('confidence is high for explicit markers and low for guesses', () {
    final explicit = _parser.parse('The.Show.S01E01.1080p.WEB-DL.x264-GRP.mkv');
    final guess = _parser.parse('Title 05.mkv');
    expect(explicit.confidence, greaterThanOrEqualTo(0.9));
    expect(guess.confidence, lessThan(0.5));
  });

  test('absolute-numbered anime never gets an invented season', () {
    final r = _parser.parse('[Nekomoe] 海贼王 - 1080 [1080p].mkv');
    expect(r.season, isNull);
    expect(r.absolute, 1080);
    expect(r.kind, MediaKind.episode);
  });

  test('chineseToInt', () {
    const cases = {
      '十': 10,
      '十二': 12,
      '二十': 20,
      '二十三': 23,
      '一百': 100,
      '一百零五': 105,
      '一百二十': 120,
      '两': 2,
      '九': 9,
      '二〇': 20,
      '05': 5,
      '一千零一': 1001,
    };
    cases.forEach((k, v) => expect(chineseToInt(k), v, reason: k));
    expect(chineseToInt('abc'), isNull);
  });
}
