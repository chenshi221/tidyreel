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
      'episode_title': "The One Where Phoebe Hates PBS",
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

/// Outcome of one preview render. [text] null means "engine not wired yet"
/// ([pending]) or an invalid template ([error]).
class PreviewResult {
  final String? text;
  final bool pending;
  final String? error;

  const PreviewResult.ok(String this.text) : pending = false, error = null;
  const PreviewResult.pending() : text = null, pending = true, error = null;
  const PreviewResult.error(String this.error) : text = null, pending = false;

  /// What to show in the example card.
  String get display => text ?? (pending ? '预览：等待命名引擎接入' : '模板有误：$error');
}

/// compileTemplate + renderTemplate, tolerant of the engine still being a stub.
PreviewResult renderNaming(
  NamingOptions options,
  MediaKind kind,
  NamingSample sample,
) {
  try {
    final tpl = compileTemplate(options, kind);
    return PreviewResult.ok(
      '${renderTemplate(tpl, sample.vars)}.${sample.ext}',
    );
  } on UnimplementedError {
    return const PreviewResult.pending();
  } catch (e) {
    return PreviewResult.error('$e');
  }
}

/// Renders a folder-style template (no extension).
PreviewResult renderFolder(String template, NamingSample sample) {
  try {
    return PreviewResult.ok(renderTemplate(template, sample.vars));
  } on UnimplementedError {
    return const PreviewResult.pending();
  } catch (e) {
    return PreviewResult.error('$e');
  }
}

/// The compiled file template, or [fallback] while the engine is a stub.
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
