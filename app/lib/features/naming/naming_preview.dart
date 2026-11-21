import 'package:tidyreel_core/tidyreel_core.dart';

/// Sample inputs for the live preview (PLAN §3.2).
class NamingSample {
  final String original;
  final String ext;
  final Map<String, Object?> vars;

  const NamingSample(this.original, this.ext, this.vars);

  static const tv = NamingSample(
    '老友记.1994.S02E03.2160p.Dolby.BluRay.x265.mp4',
    'mp4',
    {
      'title': '老友记',
      'original_title': 'Friends',
      'en_title': 'Friends',
      'year': 1994,
      'season': 2,
      'episode': 3,
      'episode_title': 'The One Where Phoebe Hates PBS',
      'tmdbid': 1668,
      'tmdb_tag': '{tmdb-1668}',
      'resolution': '2160p',
      'extra_info': '2160p.Dolby',
      'version': '',
      'group': 'EVO',
      'lang': '',
      'ext': 'mp4',
    },
  );

  /// TV sample reflecting [ShowYearSource]: Season 1 aired in 1994, Season 2 in 1995.
  static NamingSample tvFor(NamingOptions options) =>
      NamingSample(tv.original, tv.ext, {
        ...tv.vars,
        'year': options.showYear == ShowYearSource.seasonAir ? 1995 : 1994,
      });

  static const movie = NamingSample(
    'Inception.2010.2160p.BluRay.x265.mkv',
    'mkv',
    {
      'title': '盗梦空间',
      'original_title': 'Inception',
      'en_title': 'Inception',
      'year': 2010,
      'tmdbid': 27205,
      'tmdb_tag': '{tmdb-27205}',
      'resolution': '2160p',
      'extra_info': '2160p',
      'version': '',
      'group': 'EVO',
      'lang': '',
      'ext': 'mkv',
    },
  );
}

/// Outcome of one preview render. [text] null means an invalid template ([error]).
class PreviewResult {
  final String? text;
  final String? error;

  const PreviewResult.ok(String this.text) : error = null;
  const PreviewResult.error(String this.error) : text = null;

  /// What to show in the example card.
  String get display => text ?? '模板有误：$error';
}

/// compileTemplate + renderTemplate.
PreviewResult renderNaming(
  NamingOptions options,
  MediaKind kind,
  NamingSample sample,
) {
  try {
    final tpl = compileTemplate(options, kind);
    return PreviewResult.ok(
      '${applyRewrites(renderTemplate(tpl, sample.vars), options.rewrites)}.${sample.ext}',
    );
  } catch (e) {
    return PreviewResult.error('$e');
  }
}

/// Renders a folder-style template (no extension).
PreviewResult renderFolder(
  String template,
  NamingSample sample, [
  List<NameRewrite> rewrites = const [],
]) {
  try {
    return PreviewResult.ok(
      applyRewrites(renderTemplate(template, sample.vars), rewrites),
    );
  } catch (e) {
    return PreviewResult.error('$e');
  }
}

/// The compiled file template, or [fallback] on error.
String compiledOrDefault(
  NamingOptions o,
  MediaKind kind, {
  String fallback = '{title}',
}) {
  try {
    return compileTemplate(o, kind);
  } catch (_) {
    return fallback;
  }
}
