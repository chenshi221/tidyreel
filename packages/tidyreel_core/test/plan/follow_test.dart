import 'package:test/test.dart';
import 'package:tidyreel_core/src/model/media.dart';
import 'package:tidyreel_core/src/model/scan.dart';
import 'package:tidyreel_core/src/plan/follow.dart';

import 'helpers.dart';

ScanFile _sub(
  String path, {
  int? season,
  int? episode,
  int? absolute,
  int? year,
  String? lang,
}) => ScanFile(
  path: path,
  name: path.split('/').last,
  size: 1,
  role: FileRole.subtitle,
  parsed: ParsedName(
    season: season,
    episodes: episode == null ? const [] : [episode],
    absolute: absolute,
    year: year,
    lang: lang,
    confidence: 0.9,
  ),
);

ScanFile _movie(String path, {int? year, String? title}) => ScanFile(
  path: path,
  name: path.split('/').last,
  size: 1,
  role: FileRole.video,
  parsed: ParsedName(
    title: title,
    year: year,
    kind: MediaKind.movie,
    confidence: 0.9,
  ),
);

void main() {
  group('normalizeLang', () {
    test('normalizes hyphen and underscore locale codes', () {
      for (final t in [
        'zh-CN',
        'zh_CN',
        'zh-Hans',
        'zh_Hans',
        'zh_SG',
        'chs',
        'SC',
        '简体',
        '中英双语',
        '中字双语',
      ]) {
        expect(normalizeLang(t), 'zh-Hans', reason: t);
      }
      for (final t in [
        'zh-TW',
        'zh_TW',
        'zh-Hant',
        'zh_Hant',
        'zh_HK',
        'cht',
        'TC',
        '繁體中文',
        'big5',
      ]) {
        expect(normalizeLang(t), 'zh-Hant', reason: t);
      }
      for (final t in ['en', 'eng', 'en-US', 'en_US', 'en-GB', 'en_GB']) {
        expect(normalizeLang(t), 'en', reason: t);
      }
      expect(normalizeLang('ja'), 'ja');
      expect(normalizeLang('jpn'), 'ja');
      expect(normalizeLang('ko'), 'ko');
      expect(normalizeLang('kor'), 'ko');
      expect(normalizeLang('zh_TW&en_US'), 'zh-Hant');
      expect(normalizeLang('unknown'), isNull);
    });
  });

  group('langFromRemainder', () {
    test(
      'handles underscore locale tags without misreading zh_TW as zh-Hans',
      () {
        expect(langFromRemainder('.zh_CN'), 'zh-Hans');
        expect(langFromRemainder('.zh_TW'), 'zh-Hant');
        expect(langFromRemainder('.zh_TW.forced'), 'zh-Hant');
        expect(langFromRemainder('_zh_TW_forced'), 'zh-Hant');
        expect(langFromRemainder('.zh_Hant.sdh'), 'zh-Hant');
        expect(langFromRemainder('.zh_Hans.default'), 'zh-Hans');
        expect(langFromRemainder('.en_US.sdh'), 'en');
        expect(langFromRemainder('.en_GB.forced'), 'en');
        expect(langFromRemainder('-zh-TW-forced'), 'zh-Hant');
        expect(langFromRemainder('.chs&eng'), 'zh-Hans');
        expect(langFromRemainder('-poster'), isNull);
        expect(langFromRemainder(''), isNull);
      },
    );
  });

  group('subFlagsFromRemainder', () {
    test('extracts forced, default, sdh, and bilingual in canonical order', () {
      expect(subFlagsFromRemainder('.forced'), ['forced']);
      expect(subFlagsFromRemainder('.force'), ['forced']);
      expect(subFlagsFromRemainder('.强制'), ['forced']);
      expect(subFlagsFromRemainder('.default'), ['default']);
      expect(subFlagsFromRemainder('.默认'), ['default']);
      expect(subFlagsFromRemainder('.sdh'), ['sdh']);
      expect(subFlagsFromRemainder('.hi'), ['sdh']);
      expect(subFlagsFromRemainder('.cc'), ['sdh']);
      expect(subFlagsFromRemainder('.听障'), ['sdh']);
      expect(subFlagsFromRemainder('.bilingual'), ['bilingual']);
      expect(subFlagsFromRemainder('.dual'), ['bilingual']);
      expect(subFlagsFromRemainder('.双语'), ['bilingual']);
      expect(subFlagsFromRemainder('.雙語'), ['bilingual']);
      expect(subFlagsFromRemainder('.中英'), ['bilingual']);
      expect(subFlagsFromRemainder('.中英双语'), ['bilingual']);
      expect(subFlagsFromRemainder('.中英雙語'), ['bilingual']);
      expect(subFlagsFromRemainder('.简英'), ['bilingual']);
      expect(subFlagsFromRemainder('.繁英'), ['bilingual']);
      expect(subFlagsFromRemainder('.简日'), ['bilingual']);
      expect(subFlagsFromRemainder('.繁日'), ['bilingual']);
      expect(subFlagsFromRemainder('.简繁'), ['bilingual']);
      expect(subFlagsFromRemainder('.中字双语'), ['bilingual']);
    });

    test('detects bilingual from compound or multiple distinct languages', () {
      for (final rem in [
        '.chs&eng',
        '.cht&eng',
        '.chs+jpn',
        '.sc&jp',
        '.tc+en',
        '.zh&en',
        '.chs.eng',
        '.zh_CN.en_US',
        '.chs.cht',
        '.jpsc',
        '.jptc',
      ]) {
        expect(subFlagsFromRemainder(rem), ['bilingual'], reason: rem);
      }

      // Same language repeated in different aliases is NOT bilingual.
      expect(subFlagsFromRemainder('.zh_CN.chs'), isEmpty);
      expect(subFlagsFromRemainder('.en.eng'), isEmpty);
      expect(subFlagsFromRemainder('.zh_TW'), isEmpty);

      // "Dual Audio" is a video release tag, not a bilingual subtitle flag.
      expect(subFlagsFromRemainder('.Dual.Audio.en'), isEmpty);
    });

    test('deduplicates and sorts flags deterministically', () {
      expect(subFlagsFromRemainder('.default.forced.hi.cc.chs&eng.双语.force'), [
        'bilingual',
        'sdh',
        'forced',
        'default',
      ]);
      expect(subFlagsFromRemainder(''), isEmpty);
    });
  });

  group('matchVideo', () {
    test(
      'Step 1: exact prefix match prefers longest match and same folder',
      () {
        final v1 = video('/a/Show.S01E01.mkv', season: 1, episode: 1);
        final vOther = video('/b/Show.S01E01.mkv', season: 1, episode: 1);
        final sub = _sub('/a/Show.S01E01.zh_CN.forced.srt');
        final m = matchVideo(sub, [vOther, v1]);
        expect(m?.video.path, '/a/Show.S01E01.mkv');
        expect(m?.remainder, '.zh_CN.forced');
      },
    );

    test(
      'Step 2: episode number fallback matches across sibling Subs folder',
      () {
        final v1 = video('/show/Show.S01E01.mkv', season: 1, episode: 1);
        final v2 = video('/show/Show.S01E02.mkv', season: 1, episode: 2);
        final sub = _sub(
          '/show/Subs/Different.S01E02.chs.ass',
          season: 1,
          episode: 2,
        );
        final m = matchVideo(sub, [v1, v2]);
        expect(m?.video.path, '/show/Show.S01E02.mkv');
      },
    );

    test(
      'Step 3a: single video in same folder matches third-party subtitle',
      () {
        final v = _movie(
          '/movies/Inception/Inception.2010.2160p.UHD.BluRay.REMUX.mkv',
          year: 2010,
          title: 'Inception',
        );
        final sub = _sub(
          '/movies/Inception/shooter_sub_9912.chs&eng.forced.srt',
        );
        final m = matchVideo(sub, [v]);
        expect(m?.video.path, v.path);
        expect(langFromRemainder(m!.remainder), 'zh-Hans');
        expect(subFlagsFromRemainder(m.remainder), ['bilingual', 'forced']);

        // Sidecar in the same folder does NOT use subtitle fuzzy fallback.
        final sidecar = other('/movies/Inception/poster.jpg', FileRole.sidecar);
        expect(matchVideo(sidecar, [v]), isNull);

        // Subtitle in a different folder does NOT use single-video-in-dir fallback.
        final otherDirSub = _sub('/other/shooter_sub_9912.chs.srt');
        expect(matchVideo(otherDirSub, [v]), isNull);
      },
    );

    test('Step 3a: avoids false forced flag when title contains Force', () {
      final v = _movie(
        '/movies/Force/The.Force.Awakens.2015.2160p.mkv',
        year: 2015,
        title: 'The Force Awakens',
      );
      final sub = _sub('/movies/Force/Force.Awakens.2015.chs.srt');
      final m = matchVideo(sub, [v]);
      expect(m?.video.path, v.path);
      expect(langFromRemainder(m!.remainder), 'zh-Hans');
      expect(subFlagsFromRemainder(m.remainder), isEmpty);
    });

    test(
      'Step 3b: multi-video same folder matches by meaningful token overlap',
      () {
        final m1 = _movie(
          '/movies/The.Matrix.1999.2160p.UHD.BluRay.REMUX.mkv',
          year: 1999,
          title: 'The Matrix',
        );
        final m2 = _movie(
          '/movies/The.Matrix.Reloaded.2003.2160p.UHD.BluRay.REMUX.mkv',
          year: 2003,
          title: 'The Matrix Reloaded',
        );
        final subReloaded = _sub(
          '/movies/The.Matrix.Reloaded.2003.1080p.WEB-DL.zh_TW.sdh.srt',
        );
        final res = matchVideo(subReloaded, [m1, m2]);
        expect(res?.video.path, m2.path);
        expect(langFromRemainder(res!.remainder), 'zh-Hant');
        expect(subFlagsFromRemainder(res.remainder), ['sdh']);

        // Traditional Chinese subtitle matches Simplified Chinese video.
        final cn1 = _movie(
          '/movies/盗梦空间.2010.BluRay.mkv',
          year: 2010,
          title: '盗梦空间',
        );
        final cn2 = _movie(
          '/movies/星际穿越.2014.BluRay.mkv',
          year: 2014,
          title: '星际穿越',
        );
        final cnSub = _sub('/movies/盜夢空間.WEB-DL.中英双语.ass');
        final cnRes = matchVideo(cnSub, [cn1, cn2]);
        expect(cnRes?.video.path, cn1.path);
        expect(subFlagsFromRemainder(cnRes!.remainder), ['bilingual']);
      },
    );

    test('Step 3 guards: never cross-matches conflicting episodes or ambiguous ties', () {
      final ep1 = video('/tv/Show.S01E01.mkv', season: 1, episode: 1);
      final ep2 = video('/tv/Show.S01E02.mkv', season: 1, episode: 2);

      // Different episode subtitle must never match E01 alone or [E01, E02].
      final ep3Sub = _sub('/tv/Show.S01E03.chs.srt');
      expect(matchVideo(ep3Sub, [ep1]), isNull);
      expect(matchVideo(ep3Sub, [ep1, ep2]), isNull);

      // Episode subtitle must not match a lone movie in the same folder.
      final movie = _movie(
        '/mixed/Inception.2010.mkv',
        year: 2010,
        title: 'Inception',
      );
      expect(matchVideo(_sub('/mixed/Show.S01E01.chs.srt'), [movie]), isNull);

      // Ambiguous subtitle with identical overlap to two episodes returns null.
      final ambigSub = _sub('/tv/Show.chs.srt');
      expect(matchVideo(ambigSub, [ep1, ep2]), isNull);

      // Two unrelated movies sharing only a year do not falsely match a third 2020 film.
      final f1 = _movie(
        '/m/Tenet.2020.1080p.BluRay.mkv',
        year: 2020,
        title: 'Tenet',
      );
      final f2 = _movie(
        '/m/Soul.2020.1080p.BluRay.mkv',
        year: 2020,
        title: 'Soul',
      );
      final f3Sub = _sub('/m/Mulan.2020.1080p.BluRay.chs.srt');
      expect(matchVideo(f3Sub, [f1, f2]), isNull);
    });
  });
}
