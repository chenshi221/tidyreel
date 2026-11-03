import 'package:test/test.dart';
import 'package:tidyreel_core/src/plan/follow.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';
import 'test_parser.dart';

/// Returns a fixed (poor) search result.
class _Wrong extends FakeMetadataProvider {
  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async => [Demo.friends];
}

class _Alt implements AltTitleSource {
  final asked = <String>[];
  @override
  Future<List<String>> altTitles(String query) async {
    asked.add(query);
    return ['ドロヘドロ'];
  }
}

const conn = ConnectionId('c');
const show = '/下载/异兽魔都 2020 1080p';
const ep1 = '[Sub] Dorohedoro S01E01 [1080p]';

AnchorRecognizer recognizer([MetadataProvider? m]) =>
    AnchorRecognizer(const TestParser(), m ?? FakeMetadataProvider());

void main() {
  final files = [
    '$show/Season 1/$ep1.mkv',
    '$show/Season 1/$ep1.chs.ass',
    '$show/Season 1/[Sub] Dorohedoro S01E02 [1080p].mkv',
    '$show/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv',
    '$show/Season 2/[Sub] Dorohedoro S02E01 [1080p].nfo',
    '$show/Extras/花絮 PV.mkv',
    '$show/RARBG.txt',
    '/下载/Inception.2010.1080p.mkv',
    '/下载/Unknown Thing 2001.mkv',
  ];

  test('groups by title folder and by title for loose files', () async {
    final r = await recognizer().recognize(conn, ['/下载'], entriesOf(files));
    expect(r.groups.map((g) => (g.rootDir, g.match?.title)), [
      ('/下载', '盗梦空间'),
      ('/下载', null),
      (show, '异兽魔都'),
    ]);
    final dorohedoro = r.groups.last;
    expect(dorohedoro.kind, MediaKind.episode);
    expect(dorohedoro.anchorTitle, '异兽魔都');
    expect(dorohedoro.anchorYear, 2020);
    expect(dorohedoro.matchScore, greaterThan(0.9));
    expect(dorohedoro.show?.seasons.length, 2);
    expect(dorohedoro.files.map((f) => f.name), [
      '花絮 PV.mkv',
      '[Sub] Dorohedoro S01E01 [1080p].chs.ass',
      '[Sub] Dorohedoro S01E01 [1080p].mkv',
      '[Sub] Dorohedoro S01E02 [1080p].mkv',
      '[Sub] Dorohedoro S02E01 [1080p].mkv',
      '[Sub] Dorohedoro S02E01 [1080p].nfo',
    ]);
    expect(dorohedoro.files.first.parsed?.kind, MediaKind.extra);

    final inception = r.groups.first;
    expect(inception.kind, MediaKind.movie);
    expect(inception.anchorYear, 2010);
    expect(inception.show, isNull);
    expect(inception.files.single.name, 'Inception.2010.1080p.mkv');

    final unknown = r.groups[1];
    expect(unknown.match, isNull);
    expect(unknown.anchorTitle, 'Unknown Thing');
    expect(unknown.files.single.name, 'Unknown Thing 2001.mkv');

    expect(r.unassigned.map((f) => f.name), ['RARBG.txt']);
    expect(r.roots, ['/下载']);
  });

  test(
    'group ids are deterministic and independent of listing order',
    () async {
      final a = await recognizer().recognize(conn, ['/下载'], entriesOf(files));
      final b = await recognizer().recognize(conn, [
        '/下载',
      ], entriesOf(files.reversed));
      expect(a.groups.map((g) => g.id), b.groups.map((g) => g.id));
      expect(a.groups.map((g) => g.id).toSet().length, 3);
    },
  );

  test(
    'falls back to the most common file title when the folder name misses',
    () async {
      final r = await recognizer().recognize(
        conn,
        ['/dl'],
        entriesOf([
          '/dl/Pack/$ep1.mkv',
          '/dl/Pack/[Sub] Dorohedoro S01E02 [1080p].mkv',
          '/dl/Pack/[Sub] Dorohedoro S01E03 [1080p].mkv',
        ]),
      );
      final g = r.groups.single;
      expect(g.anchorTitle, 'Dorohedoro');
      expect(g.match?.title, '异兽魔都');
      expect(g.rootDir, '/dl/Pack');
    },
  );

  test('a poor title match is rejected (待手动识别)', () async {
    final r = await recognizer(_Wrong())
        .recognize(conn, ['/下载'], entriesOf(['$show/$ep1.mkv']));
    final g = r.groups.single;
    expect(g.match, isNull);
    expect(g.show, isNull);
    expect(g.matchScore, lessThan(0.6));
  });

  test('year mismatch lowers the score', () async {
    final good = await recognizer().recognize(conn, [
      '/x',
    ], entriesOf(['/x/Inception.2010.mkv']));
    expect(good.groups.single.matchScore, 1.0);
    // Fake search tolerates +-1 year; 2011 still matches but scores lower.
    final off = await recognizer().recognize(conn, [
      '/x',
    ], entriesOf(['/x/Inception.2011.mkv']));
    expect(off.groups.single.match?.title, '盗梦空间');
    expect(
      off.groups.single.matchScore,
      lessThan(good.groups.single.matchScore),
    );
  });

  test(
    'subtitles join the video with the same episode when names differ',
    () async {
      final r = await recognizer().recognize(
        conn,
        ['/下载'],
        entriesOf([
          '$show/$ep1.mkv',
          '$show/Subs/Dorohedoro.S01E01.zh-CN.ass',
          '$show/Subs/stray.ass',
        ]),
      );
      final g = r.groups.single;
      expect(
        g.files.map((f) => f.name),
        contains('Dorohedoro.S01E01.zh-CN.ass'),
      );
      // No name or episode match, but inside the group's folder: joins the folder's group.
      expect(g.files.map((f) => f.name), contains('stray.ass'));
    },
  );

  test('a movie folder with extras and subtitles is one movie group', () async {
    final r = await recognizer().recognize(
      conn,
      ['/dl'],
      entriesOf([
        '/dl/Inception.2010.1080p.BluRay/Inception.2010.1080p.BluRay.mkv',
        '/dl/Inception.2010.1080p.BluRay/Inception.2010.1080p.BluRay.chs.srt',
        '/dl/Inception.2010.1080p.BluRay/Extras/花絮.mkv',
        '/dl/Inception.2010.1080p.BluRay/www.site.url',
      ]),
    );
    final g = r.groups.single;
    expect(g.kind, MediaKind.movie);
    expect(g.rootDir, '/dl/Inception.2010.1080p.BluRay');
    expect(g.files.length, 3);
    expect(r.unassigned.single.name, 'www.site.url');
  });

  test('ignores directory entries', () async {
    final r = await recognizer().recognize(
      conn,
      ['/x'],
      [
        ...entriesOf(['/x/Inception.2010.mkv']),
        const RemoteEntry(path: '/x/sub', name: 'sub', isDir: true),
      ],
    );
    expect(r.groups.single.files.length, 1);
  });

  group('follower helpers', () {
    test('normalizeLang', () {
      for (final t in [
        'chs',
        'SC',
        '简体',
        'zh-CN',
        'zh-Hans',
        'gb',
        'jpsc',
        'cn',
      ]) {
        expect(normalizeLang(t), 'zh-Hans', reason: t);
      }
      for (final t in ['cht', 'tc', '繁体', 'zh-TW', 'zh-Hant', 'big5', 'jptc']) {
        expect(normalizeLang(t), 'zh-Hant', reason: t);
      }
      for (final t in ['eng', 'en', 'EN-US']) {
        expect(normalizeLang(t), 'en', reason: t);
      }
      expect(normalizeLang('jap'), 'ja');
      expect(normalizeLang('chs&eng'), 'zh-Hans');
      expect(normalizeLang('xyz'), isNull);
    });
    test('langFromRemainder', () {
      expect(langFromRemainder('.chs'), 'zh-Hans');
      expect(langFromRemainder('.zh-TW.forced'), 'zh-Hant');
      expect(langFromRemainder('-poster'), isNull);
      expect(langFromRemainder(''), isNull);
    });
    test('episode 1 does not claim episode 10 files', () {
      final v1 = video('/a/Show E1.mkv', episode: 1);
      final v10 = video('/a/Show E10.mkv', episode: 10);
      final sub = other('/a/Show E10.chs.ass', FileRole.subtitle);
      expect(matchVideo(sub, [v1, v10])?.video.name, 'Show E10.mkv');
      expect(matchVideo(sub, [v1])?.video, isNull);
    });
  });

  group('content hint and alt titles', () {
    const dir = '/下载/Doro Hedoro';
    final romaji = [
      '$dir/[Sub] Doro Hedoro - 01 [1080p].mkv',
      '$dir/[Sub] Doro Hedoro - 02 [1080p].mkv',
    ];

    test('romaji TMDB misses are matched through alt titles', () async {
      final alt = _Alt();
      final r = await AnchorRecognizer(
        const RuleBasedParser(),
        FakeMetadataProvider(),
        altTitles: alt,
      ).recognize(conn, ['/下载'], entriesOf(romaji));
      expect(r.groups.single.match?.tmdbId, Demo.dorohedoro.tmdbId);
      expect(r.groups.single.anchorTitle, 'Doro Hedoro');
      expect(alt.asked, isNotEmpty);
    });

    test('TV mode never asks for alt titles', () async {
      final alt = _Alt();
      final r = await AnchorRecognizer(
        const RuleBasedParser(),
        FakeMetadataProvider(),
        altTitles: alt,
        hint: () => MediaHint.tv,
      ).recognize(conn, ['/下载'], entriesOf(romaji));
      expect(r.groups.single.match, isNull);
      expect(alt.asked, isEmpty);
    });

    test('movie mode treats episode-looking files as movies', () async {
      final r = await AnchorRecognizer(
        const RuleBasedParser(),
        FakeMetadataProvider(),
        hint: () => MediaHint.movie,
      ).recognize(conn, ['/下载'], entriesOf(romaji));
      expect(r.groups.single.kind, MediaKind.movie);
    });
  });
}
