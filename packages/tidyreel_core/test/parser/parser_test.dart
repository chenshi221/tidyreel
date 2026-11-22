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

  group('explicit external ID extraction', () {
    test('extracts TMDB, IMDb, and TVDB tags and strips them from title', () {
      const cases = <String, (String, ExternalId)>{
        'Inception (2010) {tmdb-27205}.mkv': (
          'Inception',
          ExternalId('tmdb', '27205'),
        ),
        'Inception (2010) [tmdb-27205].mkv': (
          'Inception',
          ExternalId('tmdb', '27205'),
        ),
        'Inception (2010) [tmdbid=27205].mkv': (
          'Inception',
          ExternalId('tmdb', '27205'),
        ),
        'Inception (2010) {tmdbid=27205}.mkv': (
          'Inception',
          ExternalId('tmdb', '27205'),
        ),
        'Inception (2010) (tmdb-27205).mkv': (
          'Inception',
          ExternalId('tmdb', '27205'),
        ),
        'Inception (2010) {imdb-tt1375666}.mkv': (
          'Inception',
          ExternalId('imdb', 'tt1375666'),
        ),
        'Inception (2010) [imdb-tt1375666].mkv': (
          'Inception',
          ExternalId('imdb', 'tt1375666'),
        ),
        'Inception (2010) [imdbid=tt1375666].mkv': (
          'Inception',
          ExternalId('imdb', 'tt1375666'),
        ),
        'Inception (2010) (tt1375666).mkv': (
          'Inception',
          ExternalId('imdb', 'tt1375666'),
        ),
        'Inception.2010.tt1375666.1080p.mkv': (
          'Inception',
          ExternalId('imdb', 'tt1375666'),
        ),
        'Breaking.Bad.{tvdb-81189}.S01E01.mkv': (
          'Breaking Bad',
          ExternalId('tvdb', '81189'),
        ),
        'Breaking Bad [tvdb-81189] S01E01.mkv': (
          'Breaking Bad',
          ExternalId('tvdb', '81189'),
        ),
        '[tvdbid=81189] Breaking Bad S01E01.mkv': (
          'Breaking Bad',
          ExternalId('tvdb', '81189'),
        ),
      };
      cases.forEach((name, want) {
        final r = _parser.parse(name);
        expect(r.title, want.$1, reason: name);
        expect(r.externalId, want.$2, reason: name);
        expect(r.group, isNull, reason: name);
      });
    });

    test(
      'inherits external ID from parent folders and avoids false positives',
      () {
        final fromDir = _parser.parse(
          'S01E01.mkv',
          parentDirs: const ['Season 1', 'Breaking Bad {tvdb-81189}'],
        );
        expect(fromDir.title, 'Breaking Bad');
        expect(fromDir.season, 1);
        expect(fromDir.episodes, [1]);
        expect(fromDir.externalId, const ExternalId('tvdb', '81189'));

        final fileWins = _parser.parse(
          'Inception (2010) {tmdb-27205}.mkv',
          parentDirs: const ['Inception {imdb-tt1375666}'],
        );
        expect(fileWins.externalId, const ExternalId('tmdb', '27205'));

        final multiInName = _parser.parse(
          'Inception (2010) {imdb-tt1375666} {tmdb-27205}.mkv',
        );
        expect(multiInName.title, 'Inception');
        expect(multiInName.externalId, const ExternalId('tmdb', '27205'));

        final normalWord = _parser.parse('Battlestar.Galactica.2004.mkv');
        expect(normalWord.title, 'Battlestar Galactica');
        expect(normalWord.externalId, isNull);

        final shortTt = _parser.parse('Movie.2020.tt12345.mkv');
        expect(shortTt.externalId, isNull);
      },
    );
  });

  group('release edition tags', () {
    test('extracts canonical editions without polluting title', () {
      const cases = <String, (String, String)>{
        "Alien.1979.Director's.Cut.1080p.mkv": ('Alien', "Director's Cut"),
        'Alien.1979.Directors.Cut.1080p.mkv': ('Alien', "Director's Cut"),
        'Alien.1979.DC.1080p.BluRay.mkv': ('Alien', "Director's Cut"),
        '异形.1979.导演剪辑版.1080p.mkv': ('异形', "Director's Cut"),
        'Lord.of.the.Rings.2001.Extended.Edition.2160p.mkv': (
          'Lord of the Rings',
          'Extended',
        ),
        'Fast.Five.2011.EXTENDED.1080p.BluRay.mkv': ('Fast Five', 'Extended'),
        '指环王.2001.加长版.1080p.mkv': ('指环王', 'Extended'),
        'Deadpool.2016.Unrated.1080p.mkv': ('Deadpool', 'Unrated'),
        '死侍.2016.未分级版.1080p.mkv': ('死侍', 'Unrated'),
        'Lord.of.the.Rings.2001.Theatrical.Cut.1080p.mkv': (
          'Lord of the Rings',
          'Theatrical',
        ),
        '指环王.2001.剧场版.1080p.mkv': ('指环王', 'Theatrical'),
        'Interstellar.2014.IMAX.Enhanced.2160p.mkv': ('Interstellar', 'IMAX'),
        'Avatar.2009.3D.1080p.mkv': ('Avatar', '3D'),
        'Avatar.2009.HSBS.1080p.mkv': ('Avatar', '3D'),
        'Avatar.2009.1080p.Half-SBS.mkv': ('Avatar', '3D'),
        'Avatar.2009.1080p.Half-OU.mkv': ('Avatar', '3D'),
        'Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GRP.mkv': (
          'Oppenheimer',
          'Remux',
        ),
        'In.the.Mood.for.Love.2000.Criterion.Collection.1080p.mkv': (
          'In the Mood for Love',
          'Criterion',
        ),
        'In.the.Mood.for.Love.2000.Criterion.1080p.mkv': (
          'In the Mood for Love',
          'Criterion',
        ),
        'Blade.Runner.1982.Final.Cut.2160p.mkv': ('Blade Runner', 'Final Cut'),
        '让子弹飞.2010.BD1080P.国粤双语.中字.mkv': ('让子弹飞', '国粤双语'),
        '千与千寻.2001.1080p.国语版.mkv': ('千与千寻', '国语'),
        '千与千寻.2001.1080p.国配.mkv': ('千与千寻', '国语'),
        '无间道.2002.1080p.粤语版.mkv': ('无间道', '粤语'),
        '无间道.2002.1080p.粤配.mkv': ('无间道', '粤语'),
      };
      cases.forEach((name, want) {
        final r = _parser.parse(name);
        expect(r.title, want.$1, reason: name);
        expect(r.edition, want.$2, reason: name);
      });
    });

    test('protects titles containing DC, Final Cut, 3D, CC, and anime 剧场版', () {
      final dcComics = _parser.parse('DC.Comics.2020.1080p.mkv');
      expect(dcComics.title, 'DC Comics');
      expect(dcComics.edition, isNull);

      final dcPets = _parser.parse('DC.League.of.Super-Pets.2022.1080p.mkv');
      expect(dcPets.title, 'DC League of Super-Pets');
      expect(dcPets.edition, isNull);

      final theFinalCut = _parser.parse('The.Final.Cut.2004.1080p.mkv');
      expect(theFinalCut.title, 'The Final Cut');
      expect(theFinalCut.year, 2004);
      expect(theFinalCut.edition, isNull);

      final stepUp = _parser.parse('Step.Up.3D.2010.1080p.mkv');
      expect(stepUp.title, 'Step Up 3D');
      expect(stepUp.year, 2010);
      expect(stepUp.edition, isNull);

      final bareCc = _parser.parse('Movie.2020.CC.1080p.mkv');
      expect(bareCc.edition, isNull);

      final halfSbsNoGroup = _parser.parse('Avatar.2009.1080p.Half-SBS.mkv');
      expect(halfSbsNoGroup.group, isNull);
      expect(halfSbsNoGroup.edition, '3D');

      final animeMovie = _parser.parse('海贼王 剧场版 红发歌姬 2022.mkv');
      expect(animeMovie.title, '海贼王 红发歌姬');
      expect(animeMovie.kind, MediaKind.movie);
      expect(animeMovie.edition, isNull);

      // Cut edition wins over Remux when both are present.
      final cutRemux = _parser.parse(
        'Alien.1979.Directors.Cut.1080p.BluRay.REMUX.mkv',
      );
      expect(cutRemux.edition, "Director's Cut");
    });
  });

  group('multi-part movie tags', () {
    test('extracts CD / Part / Pt / Disc / Chinese split markers cleanly', () {
      const cases = <String, (String, int, String)>{
        'Titanic.1997.CD1.1080p.mkv': ('Titanic', 1, 'cd1'),
        'Titanic.1997.CD2.1080p.mkv': ('Titanic', 2, 'cd2'),
        'Titanic.1997.Part.1.1080p.mkv': ('Titanic', 1, 'pt1'),
        'Titanic.1997.Part 2.1080p.mkv': ('Titanic', 2, 'pt2'),
        'Titanic.1997.Pt1.mkv': ('Titanic', 1, 'pt1'),
        'Titanic.1997.Pt.2.mkv': ('Titanic', 2, 'pt2'),
        'Lord.of.the.Rings.2001.Disc.1.BluRay.mkv': (
          'Lord of the Rings',
          1,
          'disc1',
        ),
        'Lord.of.the.Rings.2001.Disk.2.BluRay.mkv': (
          'Lord of the Rings',
          2,
          'disc2',
        ),
        '赤壁.2008.上集.1080p.mkv': ('赤壁', 1, 'pt1'),
        '赤壁.2008.下集.1080p.mkv': ('赤壁', 2, 'pt2'),
        '赤壁(上).2008.1080p.mkv': ('赤壁', 1, 'pt1'),
        '赤壁(下).2008.1080p.mkv': ('赤壁', 2, 'pt2'),
        '赤壁.2008.上.1080p.mkv': ('赤壁', 1, 'pt1'),
        '赤壁.2008.下.1080p.mkv': ('赤壁', 2, 'pt2'),
        '赤壁.中.mkv': ('赤壁', 2, 'pt2'),
      };
      cases.forEach((name, want) {
        final r = _parser.parse(name);
        expect(r.title, want.$1, reason: name);
        expect(r.part, want.$2, reason: name);
        expect(r.partLabel, want.$3, reason: name);
        expect(r.kind, MediaKind.movie, reason: name);
      });
    });

    test('does not split real movie titles containing Part N or 上/下', () {
      final hp = _parser.parse(
        'Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.mkv',
      );
      expect(hp.title, 'Harry Potter and the Deathly Hallows Part 2');
      expect(hp.part, isNull);
      expect(hp.partLabel, isNull);

      final cn1 = _parser.parse('华灯初上.2021.1080p.mkv');
      expect(cn1.title, '华灯初上');
      expect(cn1.part, isNull);

      final cn2 = _parser.parse('海上钢琴师.1998.1080p.mkv');
      expect(cn2.title, '海上钢琴师');
      expect(cn2.part, isNull);
    });
  });

  group('Chinese variety and anime .5 recap specials', () {
    test('parses variety specials, extras, and split episodes', () {
      final pilot = _parser.parse('向往的生活 第7季 先导片.mp4');
      expect(pilot.title, '向往的生活');
      expect(pilot.kind, MediaKind.special);
      expect(pilot.season, 0);

      for (final extraName in [
        '向往的生活 第3期 加更版.mp4',
        '乘风破浪的姐姐.纯享版.1080p.mp4',
        '奔跑吧 衍生版 01.mp4',
        '奔跑吧.2024.未播花絮.mp4',
      ]) {
        final r = _parser.parse(extraName);
        expect(r.kind, MediaKind.extra, reason: extraName);
        expect(r.title, isNot(contains('加更')), reason: extraName);
        expect(r.title, isNot(contains('纯享')), reason: extraName);
        expect(r.title, isNot(contains('衍生')), reason: extraName);
        expect(r.title, isNot(contains('未播')), reason: extraName);
      }

      final partUp = _parser.parse('向往的生活 第3期上.mp4');
      expect(partUp.title, '向往的生活');
      expect(partUp.kind, MediaKind.episode);
      expect(partUp.episodes, [3]);
      expect(partUp.part, 1);
      expect(partUp.partLabel, 'pt1');

      final partDown = _parser.parse('向往的生活 第3期下.mp4');
      expect(partDown.title, '向往的生活');
      expect(partDown.episodes, [3]);
      expect(partDown.part, 2);
      expect(partDown.partLabel, 'pt2');

      final partParen = _parser.parse('向往的生活 第10期(下).1080p.mp4');
      expect(partParen.title, '向往的生活');
      expect(partParen.episodes, [10]);
      expect(partParen.part, 2);
      expect(partParen.partLabel, 'pt2');

      final notPart = _parser.parse('向往的生活 第3期 上山采蘑菇.mp4');
      expect(notPart.title, '向往的生活');
      expect(notPart.episodes, [3]);
      expect(notPart.part, isNull);
    });

    test('parses anime .5 recap episodes as special season 0', () {
      final dashHalf = _parser.parse('[Group] 鬼灭之刃 - 12.5 [1080p].mkv');
      expect(dashHalf.title, '鬼灭之刃');
      expect(dashHalf.kind, MediaKind.special);
      expect(dashHalf.season, 0);
      expect(dashHalf.absolute, 12);

      final eHalf = _parser.parse('Show.E12.5.1080p.mkv');
      expect(eHalf.title, 'Show');
      expect(eHalf.kind, MediaKind.special);
      expect(eHalf.season, 0);
      expect(eHalf.episodes, [12]);

      final seHalf = _parser.parse('Show.S01E12.5.1080p.mkv');
      expect(seHalf.title, 'Show');
      expect(seHalf.kind, MediaKind.special);
      expect(seHalf.season, 0);
      expect(seHalf.episodes, [12]);

      final cnHalf = _parser.parse('鬼灭之刃 第12.5话.mkv');
      expect(cnHalf.title, '鬼灭之刃');
      expect(cnHalf.kind, MediaKind.special);
      expect(cnHalf.season, 0);
      expect(cnHalf.episodes, [12]);

      final bareHalf = _parser.parse('12.5.mkv', parentDirs: const ['鬼灭之刃']);
      expect(bareHalf.title, '鬼灭之刃');
      expect(bareHalf.kind, MediaKind.special);
      expect(bareHalf.season, 0);
      expect(bareHalf.absolute, 12);
    });
  });

  group('subtitle flags and resolved KNOWN_FAILURES guards', () {
    test('populates subFlags on subtitle files and leaves videos empty', () {
      final bi = _parser.parse('Show.S01E01.chs&eng.forced.srt');
      expect(bi.subFlags, ['bilingual', 'forced']);

      final sdhDefault = _parser.parse('Show.S01E01.en.sdh.default.ass');
      expect(sdhDefault.subFlags, ['sdh', 'default']);

      final cnBi = _parser.parse('Show.S01E01.中英双语.默认.vtt');
      expect(cnBi.subFlags, ['bilingual', 'default']);

      final jpsc = _parser.parse('[Group] Title - 05.jpsc.ass');
      expect(jpsc.subFlags, ['bilingual']);

      final noFalseTitle = _parser.parse('The.Force.Awakens.2015.chs.srt');
      expect(noFalseTitle.title, 'The Force Awakens');
      expect(noFalseTitle.subFlags, isEmpty);

      final videoFile = _parser.parse('Show.S01E01.chs.eng.forced.mkv');
      expect(videoFile.subFlags, isEmpty);
    });

    test('guards vol.1, 1080p, The Movie, Blade Runner 2049, and zh_TW', () {
      final killBill = _parser.parse('Kill.Bill.Vol.1.2003.1080p.mkv');
      expect(killBill.title, 'Kill Bill Vol 1');
      expect(killBill.year, 2003);
      expect(killBill.kind, MediaKind.movie);

      final resNotEp = _parser.parse('1080p.mkv', parentDirs: const ['海贼王']);
      expect(resNotEp.absolute, isNull);
      expect(resNotEp.resolution, '1080p');

      final standalone1080 = _parser.parse('1080.mkv');
      expect(standalone1080.absolute, isNull);
      expect(standalone1080.title, '1080');

      final animeTheMovie = _parser.parse('Pokemon The Movie 2019.mkv');
      expect(animeTheMovie.title, 'Pokemon');
      expect(animeTheMovie.year, 2019);
      expect(animeTheMovie.kind, MediaKind.movie);

      final zhTw = _parser.parse('Show.S01E01.zh_TW.forced.srt');
      expect(zhTw.lang, 'zh_TW');
      expect(zhTw.subFlags, ['forced']);
    });
  });
}
