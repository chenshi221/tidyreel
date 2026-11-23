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

  group('enriched NFO generation', () {
    test('movieNfo writes uniqueids, mpaa, set, studios, crew, actors, tags and escapes XML', () {
      const movie = Candidate(
        tmdbId: 27205,
        kind: MediaKind.movie,
        title: '盗梦空间 & 梦境',
        originalTitle: 'Inception',
        year: 2010,
        overview: 'Dream <within> a "dream"',
        genres: ['动作', '科幻'],
        voteAverage: 8.4,
        voteCount: 36000,
        imdbId: 'tt1375666',
        tvdbId: 12345,
        collectionName: '梦境 & 幻想系列',
        certification: 'PG-13',
        studios: ['Legendary Pictures', 'Syncopy & Co'],
        directors: ['Christopher Nolan'],
        writers: ['Christopher Nolan', 'Jonathan <Nolan>'],
        actors: [
          PersonCredit(
            name: 'Leonardo DiCaprio',
            role: 'Dom "Cobb" & Thief',
            profilePath: '/leo.jpg',
          ),
          PersonCredit(name: 'Ken Watanabe'),
        ],
        tags: ['dream', 'sci-fi & heist'],
      );

      final xml = movieNfo(movie);
      expect(xml, contains('<movie>'));
      expect(xml, contains('<title>盗梦空间 &amp; 梦境</title>'));
      expect(
        xml,
        contains('<plot>Dream &lt;within&gt; a &quot;dream&quot;</plot>'),
      );
      expect(xml, contains('<mpaa>PG-13</mpaa>'));
      expect(
        xml,
        contains('<uniqueid type="tmdb" default="true">27205</uniqueid>'),
      );
      expect(xml, contains('<uniqueid type="imdb">tt1375666</uniqueid>'));
      expect(xml, contains('<uniqueid type="tvdb">12345</uniqueid>'));
      expect(xml, contains('<tmdbid>27205</tmdbid>'));
      expect(xml, contains('<imdbid>tt1375666</imdbid>'));
      expect(xml, contains('<votes>36000</votes>'));
      expect(xml, contains('<set><name>梦境 &amp; 幻想系列</name></set>'));
      expect(xml, contains('<studio>Legendary Pictures</studio>'));
      expect(xml, contains('<studio>Syncopy &amp; Co</studio>'));
      expect(xml, contains('<director>Christopher Nolan</director>'));
      expect(xml, contains('<credits>Christopher Nolan</credits>'));
      expect(xml, contains('<credits>Jonathan &lt;Nolan&gt;</credits>'));
      expect(xml, contains('<tag>dream</tag>'));
      expect(xml, contains('<tag>sci-fi &amp; heist</tag>'));
      expect(
        xml,
        contains(
          '  <actor>\n'
          '    <name>Leonardo DiCaprio</name>\n'
          '    <role>Dom &quot;Cobb&quot; &amp; Thief</role>\n'
          '    <thumb>https://image.tmdb.org/t/p/w185/leo.jpg</thumb>\n'
          '  </actor>',
        ),
      );
      expect(
        xml,
        contains(
          '  <actor>\n'
          '    <name>Ken Watanabe</name>\n'
          '  </actor>',
        ),
      );
    });

    test('tvShowNfo writes enriched TV tags without <set>', () {
      final show = ShowDetail(
        info: const Candidate(
          tmdbId: 1668,
          kind: MediaKind.episode,
          title: '老友记',
          originalTitle: 'Friends',
          year: 1994,
          imdbId: 'tt0108778',
          tvdbId: 79168,
          certification: 'TV-14',
          studios: ['NBC'],
          directors: ['David Crane'],
          writers: ['Marta Kauffman'],
          actors: [
            PersonCredit(
              name: 'Jennifer Aniston',
              role: 'Rachel Green',
              profilePath: '/jen.jpg',
            ),
          ],
          tags: ['sitcom'],
        ),
        seasons: [
          SeasonInfo(
            number: 1,
            episodeCount: 24,
            airDate: DateTime.utc(1994, 9, 22),
          ),
        ],
      );

      final xml = tvShowNfo(show);
      expect(xml, contains('<tvshow>'));
      expect(
        xml,
        contains('<uniqueid type="tmdb" default="true">1668</uniqueid>'),
      );
      expect(xml, contains('<uniqueid type="imdb">tt0108778</uniqueid>'));
      expect(xml, contains('<uniqueid type="tvdb">79168</uniqueid>'));
      expect(xml, contains('<mpaa>TV-14</mpaa>'));
      expect(xml, contains('<studio>NBC</studio>'));
      expect(xml, contains('<director>David Crane</director>'));
      expect(xml, contains('<credits>Marta Kauffman</credits>'));
      expect(xml, contains('<tag>sitcom</tag>'));
      expect(xml, contains('<premiered>1994-09-22</premiered>'));
      expect(xml, isNot(contains('<set>')));
    });

    test('episodeNfo includes runtime only when present', () {
      const show = Candidate(tmdbId: 1, kind: MediaKind.episode, title: '异兽魔都');
      final withRuntime = episodeNfo(
        show: show,
        season: 1,
        episode: 1,
        info: Episode(
          season: 1,
          number: 1,
          title: '洞窟',
          airDate: DateTime.utc(2020, 1, 12),
          runtimeMinutes: 24,
        ),
      );
      expect(withRuntime, contains('<runtime>24</runtime>'));

      final withoutRuntime = episodeNfo(show: show, season: 1, episode: 2);
      expect(withoutRuntime, isNot(contains('<runtime>')));
    });
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
