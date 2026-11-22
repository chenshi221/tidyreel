import 'anilist.dart';

/// Bangumi (bgm.tv) public API alt-title lookup for anime Chinese/Japanese
/// canonical names and synonyms. Implemented by Worker 3 (`core-tmdb-bangumi`).
class BangumiTitles implements AltTitleSource {
  const BangumiTitles();

  void close() {}

  @override
  Future<List<String>> altTitles(String query) async => const [];
}

/// Chains multiple [AltTitleSource] providers in priority order, deduplicating
/// results while keeping each source resilient to errors.
class CompositeAltTitleSource implements AltTitleSource {
  final List<AltTitleSource> sources;

  const CompositeAltTitleSource(this.sources);

  @override
  Future<List<String>> altTitles(String query) async {
    final out = <String>[];
    final seen = <String>{};
    for (final src in sources) {
      try {
        for (final t in await src.altTitles(query)) {
          final k = t.trim().toLowerCase();
          if (k.isNotEmpty && seen.add(k)) out.add(t.trim());
        }
      } on Object {
        // Ignore transient failure of one alt-title provider.
      }
    }
    return out;
  }
}
