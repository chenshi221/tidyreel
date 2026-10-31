import '../model/media.dart';
import '../model/plan.dart';

/// Owner: Agent D. PLAN §2. Pure function, fully unit tested.
///
/// [seasonEpisodeCounts]: index 0 = season 1 (specials excluded).
/// For split strategies each input's [EpisodeRef.episode] is the absolute number
/// (its season is ignored). For [SeasonStrategy.mergeIntoOne] inputs are per-season.
/// [episodeOffset] is added to the episode number before the strategy runs.
List<EpisodeRef> applyStrategy(
  SeasonStrategy strategy,
  List<EpisodeRef> input,
  List<int> seasonEpisodeCounts, {
  int episodeOffset = 0,
}) => throw UnimplementedError('Agent D');
