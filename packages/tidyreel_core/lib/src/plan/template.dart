import '../model/media.dart';
import '../model/naming.dart';

/// Owner: Agent D. PLAN §3.1.
///
/// Template syntax: `{var}`, `{var:02}` (zero pad), `[ ... ]` optional segment (dropped when
/// a variable directly inside is null/empty; nested segments decide on their own),
/// `\x` escapes a literal character.

/// File-name template (no extension) for [kind] ([MediaKind.movie] or [MediaKind.episode]).
String compileTemplate(NamingOptions options, MediaKind kind) {
  final custom = options.customTemplate;
  if (custom != null && custom.isNotEmpty) return custom;

  final sep = options.separator;
  final isTv = kind != MediaKind.movie;
  final titlePiece = switch ((options.titleLanguage, options.bilingual)) {
    (TitleLanguage.chineseFirst, true) => '{title}[$sep{en_title}]',
    (TitleLanguage.chineseFirst, false) => '{title}',
    (TitleLanguage.englishFirst, true) => '{en_title}[$sep{title}]',
    (TitleLanguage.englishFirst, false) => '{en_title}',
  };
  final episodePiece = switch (options.episodeStyle) {
    EpisodeStyle.upperPadded =>
      r'S{season:02}E{episode:02}[-E{episode_end:02}]',
    EpisodeStyle.lowerPadded =>
      r's{season:02}e{episode:02}[-e{episode_end:02}]',
    EpisodeStyle.lowerShort => r's{season}e{episode}[-e{episode_end}]',
    EpisodeStyle.cross => r'{season}x{episode:02}[-{episode_end:02}]',
    EpisodeStyle.lowerDotted =>
      r's{season:02}.e{episode:02}[-e{episode_end:02}]',
  };

  final pieces = <(String, bool)>[]; // (text, always present)
  for (final f in options.order) {
    switch (f) {
      case NameField.title:
        pieces.add((titlePiece, true));
      case NameField.year:
        if (options.includeYear) {
          pieces.add((options.yearInParens ? '({year})' : '{year}', false));
        }
      case NameField.episode:
        if (isTv) pieces.add((episodePiece, false));
      case NameField.episodeTitle:
        if (isTv && options.episodeTitle) {
          pieces.add(('{episode_title}', false));
        }
      case NameField.extraInfo:
        if (options.extraInfo) pieces.add(('{extra_info}', false));
    }
  }
  if (options.tmdbIdTag) pieces.add(('{tmdb_tag}', false));

  final b = StringBuffer();
  for (var i = 0; i < pieces.length; i++) {
    final (text, always) = pieces[i];
    b.write(i == 0 && always ? text : '[${i == 0 ? '' : sep}$text]');
  }
  if (options.releaseGroup) b.write('[-{group}]');
  return b.toString();
}

/// Fills `{var}`, `{var:02}` and optional `[ ... ]` segments, then collapses repeated
/// separators and trims separators at both ends.
String renderTemplate(String template, Map<String, Object?> vars) {
  final (text, _) = _Renderer(template, vars).sequence(inOptional: false);
  return text
      .replaceAll(RegExp(r'\(\s*\)|（\s*）'), '')
      .replaceAllMapped(RegExp(r'([._\- ])\1+'), (m) => m[1]!)
      .replaceAll(RegExp(r'^[._\- ]+|[._\- ]+$'), '');
}

class _Renderer {
  final String t;
  final Map<String, Object?> vars;
  int i = 0;

  _Renderer(this.t, this.vars);

  /// Returns the rendered text and whether a direct variable was missing.
  (String, bool) sequence({required bool inOptional}) {
    final b = StringBuffer();
    var missing = false;
    while (i < t.length) {
      final c = t[i];
      if (c == r'\' && i + 1 < t.length) {
        b.write(t[i + 1]);
        i += 2;
      } else if (c == '[') {
        i++;
        final (s, m) = sequence(inOptional: true);
        if (i < t.length && t[i] == ']') i++;
        if (!m) b.write(s);
      } else if (c == ']' && inOptional) {
        return (b.toString(), missing);
      } else if (c == '{' && t.indexOf('}', i) > 0) {
        final end = t.indexOf('}', i);
        final v = _value(t.substring(i + 1, end));
        i = end + 1;
        if (v == null) {
          missing = true;
        } else {
          b.write(v);
        }
      } else {
        b.write(c);
        i++;
      }
    }
    return (b.toString(), missing);
  }

  String? _value(String spec) {
    final parts = spec.split(':');
    final s = vars[parts[0].trim()]?.toString();
    if (s == null || s.trim().isEmpty) return null;
    final width = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return (width != null && int.tryParse(s) != null)
        ? s.padLeft(width, '0')
        : s;
  }
}

const _fullWidth = {
  ':': '：',
  '?': '？',
  '*': '＊',
  '"': '＂',
  '<': '＜',
  '>': '＞',
  '|': '｜',
};

/// Replaces characters illegal on Windows / cloud drives; trims trailing dots and spaces.
String sanitizeName(String name) => name
    .replaceAll(RegExp(r'[\\/\x00-\x1f]'), '')
    .replaceAllMapped(RegExp(r'[:?*"<>|]'), (m) => _fullWidth[m[0]]!)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'[. ]+$'), '');
