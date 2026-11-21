import '../model/media.dart';
import '../model/plan.dart';

/// Owner: Agent D. PLAN §2. Pure function, fully unit tested.
///
/// [seasonEpisodeCounts]: index 0 = season 1 (specials excluded).
/// For split strategies each input's [EpisodeRef.episode] is the absolute number
/// (its season is ignored). For [SeasonStrategy.mergeIntoOne] inputs are per-season.
/// [episodeOffset] is added to the episode number before the strategy runs.
///
/// Numbers beyond the last season's total keep counting in the last season; the planner
/// flags those. An empty [seasonEpisodeCounts] leaves seasons/episodes as they are
/// (only the offset applies).
List<EpisodeRef> applyStrategy(
  SeasonStrategy strategy,
  List<EpisodeRef> input,
  List<int> seasonEpisodeCounts, {
  int episodeOffset = 0,
}) {
  final shifted = [
    for (final r in input) EpisodeRef(r.season, r.episode + episodeOffset),
  ];
  final counts = seasonEpisodeCounts;
  if (counts.isEmpty || strategy == SeasonStrategy.asParsed) return shifted;

  // cum[i] = episodes in seasons 1..i
  final cum = <int>[0];
  for (final c in counts) {
    cum.add(cum.last + c);
  }
  final last = counts.length;

  EpisodeRef split(EpisodeRef r) {
    final n = r.episode;
    var s = 1;
    while (s < last && n > cum[s]) {
      s++;
    }
    return EpisodeRef(
      s,
      strategy == SeasonStrategy.splitSequential ? n - cum[s - 1] : n,
    );
  }

  Map<int, int>? overflowOffset;
  if (strategy == SeasonStrategy.mergeIntoOne) {
    final extraMax = <int, int>{};
    for (final r in shifted) {
      if (r.season > last) {
        final ep = r.episode > 0 ? r.episode : 0;
        extraMax.update(r.season, (m) => ep > m ? ep : m, ifAbsent: () => ep);
      }
    }
    if (extraMax.isNotEmpty) {
      overflowOffset = {};
      var acc = cum[last];
      for (final s in extraMax.keys.toList()..sort()) {
        overflowOffset[s] = acc;
        acc += extraMax[s]!;
      }
    }
  }

  return [
    for (final r in shifted)
      strategy == SeasonStrategy.mergeIntoOne
          // Season 0 (specials) stays where it is.
          ? (r.season < 1
                ? r
                : EpisodeRef(
                    1,
                    (r.season <= last
                            ? cum[r.season - 1]
                            : overflowOffset![r.season]!) +
                        r.episode,
                  ))
          : split(r),
  ];
}
