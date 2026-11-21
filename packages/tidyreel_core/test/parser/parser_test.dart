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
        if (c.known != null) {
          print('  NOTE  now passes, drop `known`: ${c.name}');
        }
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
      '兩': 2,
      '兩百': 200,
      '九': 9,
      '二〇': 20,
      '05': 5,
      '一千零一': 1001,
    };
    cases.forEach((k, v) => expect(chineseToInt(k), v, reason: k));
    for (final invalid in ['abc', '零十', '零百', '一百零十', '一二十', '二十三四', '十十']) {
      expect(chineseToInt(invalid), isNull, reason: invalid);
    }
  });

  test(
    'classifyFile does not falsely mark common English dot-titles as junk',
    () {
      for (final video in [
        'All.In.mkv',
        'About.Us.mkv',
        'Love.Me.mkv',
        'Apple.TV.mkv',
        'Fight.Club.mkv',
        'On.Top.mkv',
        'Have.Fun.mkv',
      ]) {
        expect(_parser.classify(video), FileRole.video, reason: video);
      }
      expect(_parser.classify('Stand.By.Me.srt'), FileRole.subtitle);
      for (final junk in [
        'www.example.com.mp4',
        'https://example.top.mp4',
        'dytt8.com.mp4',
        '最新地址.txt',
      ]) {
        expect(_parser.classify(junk), FileRole.junk, reason: junk);
      }
    },
  );

  test(
    'parses lowercase multi-episode ranges, uppercase 1X02, and traditional 兩',
    () {
      final range = _parser.parse('Show.s01e01-e05.mkv');
      expect(range.season, 1);
      expect(range.episodes, [1, 2, 3, 4, 5]);

      final upperX = _parser.parse('Show.1X02.mkv');
      expect(upperX.season, 1);
      expect(upperX.episodes, [2]);

      final trad = _parser.parse('慶餘年 第兩季 第兩集.mkv');
      expect(trad.season, 2);
      expect(trad.episodes, [2]);
    },
  );

  test(
    'does not misclassify movie titles like The Menu / The Interview as extra',
    () {
      final menu = _parser.parse('The Menu (2022).mkv');
      expect(menu.kind, MediaKind.movie);
      expect(menu.title, 'The Menu');
      expect(menu.year, 2022);

      final interview = _parser.parse('The Interview (2014).mkv');
      expect(interview.kind, MediaKind.movie);
      expect(interview.title, 'The Interview');
      expect(interview.year, 2014);
    },
  );

  test('validates calendar dates and keeps year on dated movie files', () {
    final invalid = _parser.parse('Show.20240231.mkv');
    expect(invalid.airDate, isNull);

    final nonLeap = _parser.parse('Show.20230229.mkv');
    expect(nonLeap.airDate, isNull);

    final leap = _parser.parse('向往的生活.20240229.mp4');
    expect(leap.airDate, DateTime.utc(2024, 2, 29));

    final datedMovie = _parser.parse('剧场版 柯南 2024-04-12.mkv');
    expect(datedMovie.kind, MediaKind.movie);
    expect(datedMovie.year, 2024);
  });

  test('handles DTS HD/X after normalization, subtitle trailing -LANG, and backslash paths', () {
    final dtsHd = _parser.parse('Movie.2020.1080p.BluRay.DTS.HD.MA.5.1.mkv');
    expect(dtsHd.extraInfo, '1080p.DTS-HD');

    final dtsX = _parser.parse('Movie.2020.2160p.BluRay.DTS.X.mkv');
    expect(dtsX.extraInfo, '2160p.DTS-X');

    final subChs = _parser.parse('Show.S01E01.1080p.WEB-DL-CHS.srt');
    expect(subChs.lang, 'CHS');
    expect(subChs.group, isNull);

    final subEng = _parser.parse('Movie.2020.1080p.BluRay-ENG.ass');
    expect(subEng.lang, 'ENG');
    expect(subEng.group, isNull);

    final winPath = _parser.parse(r'C:\Movies\Inception.2010.1080p.mkv');
    expect(winPath.title, 'Inception');
    expect(winPath.year, 2010);
    expect(winPath.kind, MediaKind.movie);
  });
}
