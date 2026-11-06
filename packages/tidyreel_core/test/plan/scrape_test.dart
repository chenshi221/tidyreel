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
