import '../model/media.dart';
import '../model/metadata.dart';

/// Owner: Agent B. PLAN §4.6.
abstract interface class MetadataProvider {
  /// [kind]: [MediaKind.movie], [MediaKind.episode] (TV) or null for both.
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year});
  Future<ShowDetail> show(int tmdbId);
  Future<List<Episode>> season(int tmdbId, int season);
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId);
  Future<MovieDetail> movie(int tmdbId);
}

class TmdbConfig {
  /// v3 api key or v4 read token (detected by length / "eyJ" prefix).
  final String apiKey;

  /// Override for users behind a proxy.
  final String baseUrl;
  final String language;
  final String fallbackLanguage;

  const TmdbConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.themoviedb.org/3',
    this.language = 'zh-CN',
    this.fallbackLanguage = 'en-US',
  });
}

class TmdbProvider implements MetadataProvider {
  final TmdbConfig config;

  TmdbProvider(this.config);

  @override
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year}) =>
      throw UnimplementedError('Agent B');

  @override
  Future<ShowDetail> show(int tmdbId) => throw UnimplementedError('Agent B');

  @override
  Future<List<Episode>> season(int tmdbId, int season) =>
      throw UnimplementedError('Agent B');

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) =>
      throw UnimplementedError('Agent B');

  @override
  Future<MovieDetail> movie(int tmdbId) => throw UnimplementedError('Agent B');
}
