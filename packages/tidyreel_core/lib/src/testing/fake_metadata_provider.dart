import '../model/media.dart';
import '../model/metadata.dart';
import '../tmdb/metadata_provider.dart';
import 'demo_data.dart';

/// Searches [Demo.candidates] by substring of any title.
class FakeMetadataProvider implements MetadataProvider {
  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    final q = query.toLowerCase();
    return Demo.candidates
        .where((c) => kind == null || c.kind == kind)
        .where(
          (c) => year == null || c.year == null || (c.year! - year).abs() <= 1,
        )
        .where(
          (c) => [
            c.title,
            c.englishTitle,
            c.originalTitle,
          ].any((t) => t != null && t.toLowerCase().contains(q)),
        )
        .toList();
  }

  Candidate _byId(int id) => Demo.candidates.firstWhere((c) => c.tmdbId == id);

  @override
  Future<ShowDetail> show(int tmdbId) async => tmdbId == Demo.dorohedoro.tmdbId
      ? Demo.dorohedoroShow
      : ShowDetail(
          info: _byId(tmdbId),
          seasons: const [SeasonInfo(number: 1, episodeCount: 24)],
        );

  @override
  Future<List<Episode>> season(int tmdbId, int season) async {
    final count = (await show(tmdbId)).seasons
        .firstWhere((s) => s.number == season)
        .episodeCount;
    return [
      for (var e = 1; e <= count; e++)
        Episode(
          season: season,
          number: e,
          title: Demo.episodeTitle(tmdbId, season, e),
          airDate: DateTime(2020, 1, 12).add(Duration(days: 7 * (e - 1))),
          runtimeMinutes: 24,
        ),
    ];
  }

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async => const [];

  @override
  Future<MovieDetail> movie(int tmdbId) async =>
      MovieDetail(info: _byId(tmdbId));
}
