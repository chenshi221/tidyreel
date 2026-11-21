import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

const root = '/d/异兽魔都 S01';
const out = '/d/异兽魔都 (2020)';

class _Meta extends FakeMetadataProvider {
  @override
  Future<ShowDetail> show(int tmdbId) async => const ShowDetail(
    info: Candidate(
      tmdbId: 1,
      kind: MediaKind.episode,
      title: '异兽魔都',
      year: 2020,
      overview: '魔法使 & 怪物',
      posterPath: '/p.jpg',
      backdropPath: '/b.jpg',
      genres: ['动画'],
      voteAverage: 8.25,
    ),
    seasons: [SeasonInfo(number: 1, episodeCount: 12, posterPath: '/s1.jpg')],
  );

  @override
  Future<List<Episode>> season(int tmdbId, int season) async => [
    Episode(
      season: 1,
      number: 1,
      title: '洞窟',
      overview: '第一集',
      airDate: DateTime.utc(2020, 1, 12),
      stillPath: '/e1.jpg',
    ),
  ];
}

Future<RenamePlan> plan({Set<String> existing = const {}}) =>
    DefaultPlanner(_Meta()).build(
      scanOf([
        tvGroup(
          [video('$root/E01.mkv', season: 1, episode: 1)],
          rootDir: root,
          show: null,
        ),
      ]),
      const {},
      const PlanOptions(scrape: true),
      existing: existing,
    );

void main() {
  test('刮削: nfo and artwork land in the final folders', () async {
    final p = await plan();
    final writes = {
      for (final o in p.ops)
        if (o.kind == OpKind.write) o.dst: o.src,
    };
    expect(
      writes.keys,
      containsAll([
        '$out/tvshow.nfo',
        '$out/poster.jpg',
        '$out/fanart.jpg',
        '$out/season01-poster.jpg',
      ]),
    );
    final epNfo = writes.keys.singleWhere((k) => k.endsWith('S01E01.nfo'));
    expect(epNfo, startsWith('$out/Season 01/'));
    expect(writes.keys.where((k) => k.endsWith('-thumb.jpg')), hasLength(1));
    expect(writes['$out/poster.jpg'], 'https://image.tmdb.org/t/p/w780/p.jpg');
    final show = writes['$out/tvshow.nfo']!;
    expect(show, startsWith(writeTextPrefix));
    expect(show, contains('<uniqueid type="tmdb" default="true">1</uniqueid>'));
    expect(show, contains('<plot>魔法使 &amp; 怪物</plot>'));
    expect(writes[epNfo], contains('<title>洞窟</title>'));
    expect(writes[epNfo], contains('<aired>2020-01-12</aired>'));

    // Applied, the plan leaves a folder the next scan matches by its nfo.
    final be = MemoryStorageBackend({'$root/E01.mkv': 1});
    await applyPlan(p, be);
    expect(be.textOf('$out/tvshow.nfo'), contains('<tvshow>'));
  });

  test('an existing poster is kept, not overwritten', () async {
    final p = await plan(existing: {'$out/poster.jpg'});
    final poster = p.ops.singleWhere((o) => o.dst == '$out/poster.jpg');
    expect(poster.selected, isFalse);
    expect(poster.warning, '已存在，保留原文件');
    expect(p.canExecute, isTrue);
  });

  test('in-place rename keeps pre-rename existing nfo and artwork', () async {
    final p = await plan(existing: {'$root/poster.jpg', '$root/tvshow.nfo'});
    final poster = p.ops.singleWhere((o) => o.dst == '$out/poster.jpg');
    final nfo = p.ops.singleWhere((o) => o.dst == '$out/tvshow.nfo');
    expect(poster.selected, isFalse);
    expect(poster.warning, '已存在，保留原文件');
    expect(nfo.selected, isFalse);
    expect(nfo.warning, '已存在，保留原文件');
    expect(p.canExecute, isTrue);
  });

  test(
    'scrape passes episode group title to episodeNfo and shares caches',
    () async {
      final meta = _CountingMeta();
      final epGroup = EpisodeGroup(
        id: 'eg1',
        name: 'DVD',
        type: 3,
        seasons: [
          const EpisodeGroupSeason(
            order: 0,
            name: 'Specials',
            episodes: [EpisodeRef(0, 1)],
          ),
          const EpisodeGroupSeason(
            order: 1,
            name: 'S1',
            episodes: [EpisodeRef(1, 1)],
          ),
        ],
      );
      final p = await DefaultPlanner(meta).build(
        scanOf([
          tvGroup(
            [video('$root/E01.mkv', season: 1, episode: 1)],
            rootDir: root,
            show: null,
          ),
        ]),
        {const GroupId('g1'): GroupDecision(episodeGroupId: epGroup.id)},
        const PlanOptions(scrape: true),
      );
      final epNfo = p.ops.singleWhere(
        (o) => o.kind == OpKind.write && o.dst.endsWith('S01E01.nfo'),
      );
      expect(epNfo.src, contains('<title>洞窟</title>'));
      expect(meta.seasonCalls, 1);

      // Movie scrape + non-Chinese title lookup calls metadata.movie() at most once.
      final movieMeta = _CountingMeta();
      await DefaultPlanner(movieMeta).build(
        scanOf([
          MediaGroup(
            id: const GroupId('m1'),
            kind: MediaKind.movie,
            anchorTitle: 'Inception',
            rootDir: '/d/Inception',
            files: [
              video('/d/Inception/Inception.2010.mkv', kind: MediaKind.movie),
            ],
            match: const Candidate(
              tmdbId: 27205,
              kind: MediaKind.movie,
              title: 'Inception',
              year: 2010,
              posterPath: '/mp.jpg',
            ),
            matchScore: 0.95,
          ),
        ]),
        const {},
        const PlanOptions(scrape: true),
      );
      expect(movieMeta.movieCalls, 1);
    },
  );

  test('scrape off writes nothing', () async {
    final p = await DefaultPlanner(_Meta()).build(
      scanOf([
        tvGroup(
          [video('$root/E01.mkv', season: 1, episode: 1)],
          rootDir: root,
          show: null,
        ),
      ]),
      const {},
      const PlanOptions(),
    );
    expect(p.ops.where((o) => o.kind == OpKind.write), isEmpty);
  });
}

class _CountingMeta extends _Meta {
  var seasonCalls = 0;
  var movieCalls = 0;

  @override
  Future<List<Episode>> season(int tmdbId, int season) {
    seasonCalls++;
    return super.season(tmdbId, season);
  }

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async => const [
    EpisodeGroup(
      id: 'eg1',
      name: 'DVD',
      type: 3,
      seasons: [
        EpisodeGroupSeason(
          order: 0,
          name: 'Specials',
          episodes: [EpisodeRef(0, 1)],
        ),
        EpisodeGroupSeason(order: 1, name: 'S1', episodes: [EpisodeRef(1, 1)]),
      ],
    ),
  ];

  @override
  Future<MovieDetail> movie(int tmdbId) async {
    movieCalls++;
    return const MovieDetail(
      info: Candidate(
        tmdbId: 27205,
        kind: MediaKind.movie,
        title: '盗梦空间',
        englishTitle: 'Inception',
        year: 2010,
        posterPath: '/mp.jpg',
      ),
    );
  }
}
