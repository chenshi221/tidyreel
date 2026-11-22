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

/// TMDB knows the show only by an English title plus an alias.
class _Aliased extends FakeMetadataProvider {
  static const _slow = Candidate(
    tmdbId: 95480,
    kind: MediaKind.episode,
    title: 'Slow Horses',
    aliases: ['流人'],
  );

  @override
  Future<ShowDetail> show(int tmdbId) async =>
      const ShowDetail(info: _slow, seasons: []);

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async => [_slow];
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

  test('a folder named after an alias matches the show', () async {
    final r = await recognizer(_Aliased())
        .recognize(conn, ['/下载'], entriesOf(['/下载/流人/流人 S06E01.mkv']));
    expect(r.groups.single.match?.title, 'Slow Horses');
  });

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
      expect(langFromRemainder('-chs'), 'zh-Hans');
      expect(langFromRemainder('-zh-TW'), 'zh-Hant');
      expect(langFromRemainder('-chs-forced'), 'zh-Hans');
      expect(langFromRemainder('-zh-TW-forced'), 'zh-Hant');
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

    test('AniList failure does not fail recognition', () async {
      final r = await AnchorRecognizer(
        const RuleBasedParser(),
        FakeMetadataProvider(),
        altTitles: _FailingAlt(),
      ).recognize(conn, ['/下载'], entriesOf(romaji));
      expect(r.groups, hasLength(1));
      expect(r.groups.single.match, isNull);
    });

    test('transient metadata.search failure is evicted from cache', () async {
      final meta = _FailOnceSearch();
      await expectLater(
        AnchorRecognizer(const RuleBasedParser(), meta).recognize(conn, [
          '/下载',
        ], entriesOf(['/下载/A/Inception.2010.mkv', '/下载/B/Inception.2010.mkv'])),
        throwsA(isA<StorageException>()),
      );
      // Group A failed on 'A' (or 'Inception') and evicted the rejected future;
      // Group B later queried 'Inception' fresh rather than hitting a poisoned entry.
      expect(meta.inceptionCalls, 2);
    });
  });

  group('v1.0 recognizer upgrades', () {
    test(
      'detects BDMV and VIDEO_TS disc units from dir markers and nested files',
      () async {
        // 1. Dir-marker entries (as produced by DefaultTaskManager._listAll).
        final fromMarkers =
            await AnchorRecognizer(
              const RuleBasedParser(),
              FakeMetadataProvider(),
            ).recognize(
              conn,
              ['/dl'],
              const [
                RemoteEntry(
                  path: '/dl/Inception.2010.BluRay',
                  name: 'Inception.2010.BluRay',
                  isDir: true,
                ),
                RemoteEntry(
                  path: '/dl/Inception.2010.BluRay/BDMV',
                  name: 'BDMV',
                  isDir: true,
                ),
              ],
            );
        expect(fromMarkers.groups, hasLength(1));
        final g1 = fromMarkers.groups.single;
        expect(g1.kind, MediaKind.movie);
        expect(g1.match?.tmdbId, Demo.inception.tmdbId);
        expect(g1.rootDir, '/dl/Inception.2010.BluRay');
        expect(g1.files, hasLength(1));
        expect(g1.files.single.isDiscDir, isTrue);
        expect(g1.files.single.parsed?.isDisc, isTrue);
        expect(g1.files.single.parsed?.kind, MediaKind.movie);
        expect(g1.files.single.path, '/dl/Inception.2010.BluRay');

        // 2. Full nested file listing (VIDEO_TS + BDMV streams ignored & sizes summed).
        final fromStreams =
            await AnchorRecognizer(
              const RuleBasedParser(),
              FakeMetadataProvider(),
            ).recognize(
              conn,
              ['/dl'],
              const [
                RemoteEntry(
                  path: '/dl/Inception 2010/VIDEO_TS/VTS_01_1.VOB',
                  name: 'VTS_01_1.VOB',
                  isDir: false,
                  size: 4000,
                ),
                RemoteEntry(
                  path: '/dl/Inception 2010/VIDEO_TS/VIDEO_TS.IFO',
                  name: 'VIDEO_TS.IFO',
                  isDir: false,
                  size: 200,
                ),
              ],
            );
        expect(fromStreams.groups, hasLength(1));
        final g2 = fromStreams.groups.single;
        expect(g2.files, hasLength(1));
        expect(g2.files.single.isDiscDir, isTrue);
        expect(g2.files.single.size, 4200);
        expect(g2.files.single.path, '/dl/Inception 2010');
        expect(fromStreams.unassigned, isEmpty);
      },
    );

    test('directory context inference handles bare 4-digit anime stems and prefixed sequences', () async {
      final r =
          await AnchorRecognizer(
            const RuleBasedParser(),
            FakeMetadataProvider(),
          ).recognize(
            conn,
            ['/dl'],
            entriesOf([
              '/dl/海贼王/1078.mkv',
              '/dl/海贼王/1079.mkv',
              '/dl/海贼王/1080.mkv',
            ]),
          );
      final g = r.groups.single;
      expect(g.kind, MediaKind.episode);
      expect(g.match?.tmdbId, Demo.onePiece.tmdbId);
      expect(g.files.map((f) => f.parsed?.absolute), [1078, 1079, 1080]);
      expect(g.files.every((f) => f.parsed?.title == '海贼王'), isTrue);
      expect(g.files.every((f) => (f.parsed?.confidence ?? 0) >= 0.75), isTrue);

      // Prefixed low-confidence files like OP_01 / OP_02 infer sequential episodes.
      final prefixed =
          await AnchorRecognizer(
            const RuleBasedParser(),
            FakeMetadataProvider(),
          ).recognize(conn, [
            '/dl',
          ], entriesOf(['/dl/异兽魔都/OP_01.mkv', '/dl/异兽魔都/OP_02.mkv']));
      final pg = prefixed.groups.single;
      expect(pg.kind, MediaKind.episode);
      expect(pg.files.map((f) => f.parsed?.episodes), [
        [1],
        [2],
      ]);
      expect(
        pg.files.every((f) => (f.parsed?.confidence ?? 0) >= 0.75),
        isTrue,
      );

      // Unrelated movie years are NOT turned into episodes.
      final years =
          await AnchorRecognizer(
            const RuleBasedParser(),
            FakeMetadataProvider(),
          ).recognize(conn, [
            '/dl',
          ], entriesOf(['/dl/Film.2019.mkv', '/dl/Film.2020.mkv']));
      expect(years.groups.every((g) => g.kind == MediaKind.movie), isTrue);
    });

    test('ExternalIdLookup matches {tmdb-...} and {imdb-...} directly without text search', () async {
      final meta = _ExternalOnlyMeta();
      final r = await AnchorRecognizer(const RuleBasedParser(), meta).recognize(
        conn,
        ['/dl'],
        entriesOf([
          '/dl/Random Name {tmdb-27205}/video.mkv',
          '/dl/Another Show {imdb-tt0108778}/S01E01.mkv',
        ]),
      );
      expect(meta.searchCalls, 0);
      final byDir = {for (final g in r.groups) g.rootDir: g};
      final movie = byDir['/dl/Random Name {tmdb-27205}']!;
      expect(movie.match?.tmdbId, Demo.inception.tmdbId);
      expect(movie.matchScore, 1.0);
      expect(movie.kind, MediaKind.movie);

      final tv = byDir['/dl/Another Show {imdb-tt0108778}']!;
      expect(tv.match?.tmdbId, Demo.friends.tmdbId);
      expect(tv.matchScore, 1.0);
      expect(tv.kind, MediaKind.episode);
      expect(tv.show, isNotNull);
    });

    test('cross-kind fallback recovers misclassified lone movie or show in mixed mode', () async {
      final meta = _CrossKindMeta();
      // Movie with a stray number guessed as episode (no explicit SxxExx) -> falls back to movie.
      final movieScan = await AnchorRecognizer(
        const _StrayNumberMovieParser(),
        meta,
      ).recognize(conn, ['/dl'], entriesOf(['/dl/Blade Runner 2049.mkv']));
      expect(movieScan.groups.single.kind, MediaKind.movie);
      expect(movieScan.groups.single.match?.title, '银翼杀手2049');
      expect(movieScan.groups.single.matchScore, greaterThanOrEqualTo(0.72));

      // Single video guessed as movie -> falls back to TV when strong TV hit exists.
      final tvScan = await AnchorRecognizer(
        const RuleBasedParser(),
        meta,
      ).recognize(conn, ['/dl'], entriesOf(['/dl/Friends.1994.mkv']));
      expect(tvScan.groups.single.kind, MediaKind.episode);
      expect(tvScan.groups.single.match?.tmdbId, Demo.friends.tmdbId);
      expect(tvScan.groups.single.show, isNotNull);

      // Explicit S01E01 never falls back to movie.
      final strictSxe = await AnchorRecognizer(const RuleBasedParser(), meta)
          .recognize(conn, [
            '/dl',
          ], entriesOf(['/dl/Blade Runner 2049 S01E01.mkv']));
      expect(strictSxe.groups.single.match, isNull);
    });

    test('suggests splitSequential for multi-season show with continuous absolute episodes', () async {
      // Demo.dorohedoroShow has S1=12, S2=11 (total=23).
      final absScan =
          await AnchorRecognizer(
            const RuleBasedParser(),
            FakeMetadataProvider(),
          ).recognize(
            conn,
            ['/dl'],
            entriesOf([
              '/dl/异兽魔都/[Sub] Dorohedoro - 01 [1080p].mkv',
              '/dl/异兽魔都/[Sub] Dorohedoro - 15 [1080p].mkv',
              '/dl/异兽魔都/[Sub] Dorohedoro - 23 [1080p].mkv',
            ]),
          );
      final g = absScan.groups.single;
      expect(g.suggestedStrategy, SeasonStrategy.splitSequential);
      expect(g.suggestedStrategyReason, contains('23'));
      expect(g.suggestedStrategyReason, contains('12'));

      // Properly seasoned S01 + S02 gets no strategy suggestion.
      final seasoned =
          await AnchorRecognizer(
            const TestParser(),
            FakeMetadataProvider(),
          ).recognize(
            conn,
            ['/下载'],
            entriesOf([
              '$show/Season 1/$ep1.mkv',
              '$show/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv',
            ]),
          );
      expect(seasoned.groups.single.suggestedStrategy, isNull);
      expect(seasoned.groups.single.suggestedStrategyReason, isNull);
    });

    test(
      'MediaProbe fills resolution/extraInfo and applies duration heuristics',
      () async {
        final probe = _FakeProbe({
          '/dl/Inception.2010.mkv': const MediaProbeInfo(
            width: 3840,
            height: 2160,
            videoCodec: 'HEVC',
            hdr: 'DV',
            audioCodec: 'Atmos',
            duration: Duration(minutes: 148),
          ),
          '/dl/ShortAd.2020.mkv': const MediaProbeInfo(
            width: 1920,
            height: 1080,
            duration: Duration(seconds: 30),
          ),
          '/dl/MysteryFilm.mkv': const MediaProbeInfo(
            width: 1920,
            height: 1080,
            duration: Duration(minutes: 95),
          ),
        });
        final be = MemoryStorageBackend({
          '/dl/Inception.2010.mkv': 1000,
          '/dl/ShortAd.2020.mkv': 100,
          '/dl/MysteryFilm.mkv': 900,
        });

        final r =
            await AnchorRecognizer(
              const RuleBasedParser(),
              FakeMetadataProvider(),
              mediaProbe: probe,
              probeMedia: () => true,
            ).recognize(
              conn,
              ['/dl'],
              entriesOf([
                '/dl/Inception.2010.mkv',
                '/dl/ShortAd.2020.mkv',
                '/dl/MysteryFilm.mkv',
              ]),
              backend: be,
            );
        final byPath = {
          for (final g in r.groups)
            for (final f in g.files) f.path: f,
        };
        final inc = byPath['/dl/Inception.2010.mkv']!;
        expect(inc.parsed?.resolution, '2160p');
        expect(inc.parsed?.extraInfo, '2160p.DV.Atmos');
        expect(inc.parsed?.probe?.duration, const Duration(minutes: 148));

        final shortAd = byPath['/dl/ShortAd.2020.mkv']!;
        expect(shortAd.parsed?.confidence, lessThanOrEqualTo(0.35));

        final mystery = byPath['/dl/MysteryFilm.mkv']!;
        expect(mystery.parsed?.kind, MediaKind.movie);
        expect(mystery.parsed?.confidence, greaterThan(0.25));

        // Disabled when probeMedia returns false.
        probe.calls.clear();
        await AnchorRecognizer(
          const RuleBasedParser(),
          FakeMetadataProvider(),
          mediaProbe: probe,
          probeMedia: () => false,
        ).recognize(
          conn,
          ['/dl'],
          entriesOf(['/dl/Inception.2010.mkv']),
          backend: be,
        );
        expect(probe.calls, isEmpty);
      },
    );
  });
}

class _FakeProbe implements MediaProbe {
  final Map<String, MediaProbeInfo> results;
  final calls = <String>[];
  _FakeProbe(this.results);

  @override
  Future<MediaProbeInfo?> probe(
    StorageBackend backend,
    String path, {
    int? fileSize,
  }) async {
    calls.add(path);
    return results[path];
  }
}

class _ExternalOnlyMeta extends FakeMetadataProvider {
  var searchCalls = 0;

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    searchCalls++;
    return const [];
  }

  @override
  Future<Candidate?> findByExternalId(
    String source,
    String id, {
    MediaKind? kind,
  }) async {
    if (source == 'imdb' && id == 'tt0108778') {
      return kind == MediaKind.movie ? null : Demo.friends;
    }
    return super.findByExternalId(source, id, kind: kind);
  }
}

class _CrossKindMeta extends FakeMetadataProvider {
  static const _blade = Candidate(
    tmdbId: 335984,
    kind: MediaKind.movie,
    title: '银翼杀手2049',
    englishTitle: 'Blade Runner 2049',
    year: 2017,
  );

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    if (kind == MediaKind.movie &&
        query.toLowerCase().contains('blade runner')) {
      return const [_blade];
    }
    if (kind == MediaKind.episode && query.toLowerCase().contains('friends')) {
      return const [Demo.friends];
    }
    return const [];
  }
}

class _StrayNumberMovieParser extends RuleBasedParser {
  const _StrayNumberMovieParser();

  @override
  ParsedName parse(String fileName, {List<String> parentDirs = const []}) {
    if (fileName.contains('Blade Runner 2049')) {
      return const ParsedName(
        title: 'Blade Runner 2049',
        absolute: 2049,
        kind: MediaKind.episode,
        confidence: 0.6,
      );
    }
    return super.parse(fileName, parentDirs: parentDirs);
  }
}

class _FailingAlt implements AltTitleSource {
  @override
  Future<List<String>> altTitles(String query) async =>
      throw StateError('AniList 503');
}

class _FailOnceSearch extends FakeMetadataProvider {
  var inceptionCalls = 0;

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    // Delay group B's folder-title lookup so it reaches 'Inception' after
    // group A's 'Inception' lookup has already failed and evicted from cache.
    if (query == 'B') {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return const [];
    }
    if (query == 'A') return const [];
    if (query == 'Inception' && year == 2010) {
      inceptionCalls++;
      if (inceptionCalls == 1) {
        throw const StorageException(StorageErrorCode.network, 'transient');
      }
    }
    return super.search(query, kind: kind, year: year);
  }
}
