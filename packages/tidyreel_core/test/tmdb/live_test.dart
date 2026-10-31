// Checks TmdbProvider against the real TMDB API. Skipped unless TMDB_TOKEN is set:
//   TMDB_TOKEN=... dart test test/tmdb/live_test.dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  final token = Platform.environment['TMDB_TOKEN'];
  final skip = token == null || token.isEmpty ? 'TMDB_TOKEN not set' : null;
  late TmdbProvider tmdb;
  setUpAll(() {
    if (skip == null) tmdb = TmdbProvider(TmdbConfig(apiKey: token!));
  });

  test('movie search: zh title, English title, year', () async {
    final hits = await tmdb.search(
      'Inception',
      kind: MediaKind.movie,
      year: 2010,
    );
    final c = hits.first;
    expect(c.tmdbId, 27205);
    expect(c.title, '盗梦空间');
    expect(c.englishTitle, 'Inception');
    expect(c.year, 2010);
  }, skip: skip);

  test('tv search by Chinese name, show seasons and season episodes', () async {
    final hits = await tmdb.search('异兽魔都', kind: MediaKind.episode);
    final c = hits.first;
    expect(c.englishTitle, 'Dorohedoro');
    expect(c.year, 2020);
    final show = await tmdb.show(c.tmdbId);
    final s1 = show.seasons.firstWhere((s) => s.number == 1);
    expect(s1.episodeCount, greaterThanOrEqualTo(12));
    final eps = await tmdb.season(c.tmdbId, 1);
    expect(eps.first.number, 1);
  }, skip: skip);

  test('episode groups parse (One Piece has several)', () async {
    final groups = await tmdb.episodeGroups(37854);
    expect(groups, isNotEmpty);
    expect(groups.first.seasons.first.episodes, isNotEmpty);
  }, skip: skip);

  test('real parser + recognizer + planner on messy names', () async {
    const root = '/下载';
    final files = [
      '$root/[字幕组] 繁花 第01集 1080p.mp4',
      '$root/[字幕组] 繁花 第02集 1080p.mp4',
      '$root/老友记.Friends.1994.S02E03.2160p.BluRay.x265-EVO.mkv',
      '$root/Inception.2010.2160p.BluRay.x265.mkv',
      '$root/权力的游戏/Season 6/05.mkv',
    ];
    final scan = await AnchorRecognizer(const RuleBasedParser(), tmdb)
        .recognize(
          const ConnectionId('c'),
          [root],
          [
            for (final f in files)
              RemoteEntry(path: f, name: f.split('/').last, isDir: false),
          ],
        );
    final titles = {for (final g in scan.groups) g.match?.title};
    expect(titles, containsAll(['繁花', '老友记', '盗梦空间', '权力的游戏']));

    final plan = await DefaultPlanner(tmdb)
        .build(scan, {}, const PlanOptions());
    final dsts = plan.ops.map((o) => o.dst).join('\n');
    expect(dsts, contains('老友记.Friends.1994.S02E03.mkv'));
    expect(dsts, contains('盗梦空间.Inception.2010.mkv'));
    expect(dsts, contains('S06E05'));
    expect(plan.conflicts, isEmpty);
  }, skip: skip);

  test('scoring ranks the right Friends first', () async {
    final hits = await tmdb.search('老友记', kind: MediaKind.episode, year: 1994);
    expect(hits.first.tmdbId, 1668);
  }, skip: skip);
}
