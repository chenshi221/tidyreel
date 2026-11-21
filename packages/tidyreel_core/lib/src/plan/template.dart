import '../model/media.dart';
import '../model/naming.dart';

/// Owner: Agent D. PLAN §3.1.
///
/// Template syntax: `{var}`, `{var:02}` (zero pad), `[ ... ]` optional segment (dropped when
/// a variable directly inside is null/empty; nested segments decide on their own),
/// `\x` escapes a literal character.

final _emptyParensRe = RegExp(r'\(\s*\)|（\s*）');
final _sepRunRe = RegExp(r'([._\- ])\1+');
final _leadingSepRe = RegExp(r'^[._\- ]+');
final _trailingSepRe = RegExp(r'[._\- ]+$');
final _captureRefRe = RegExp(r'\$(\d)');
final _illegalPathCharsRe = RegExp(r'[\\/\x00-\x1f]');
final _fullWidthCharsRe = RegExp(r'[:?*"<>|]');
final _multiSpaceRe = RegExp(r'\s+');
final _trailingDotSpaceRe = RegExp(r'[. ]+$');

/// File-name template (no extension) for [kind] ([MediaKind.movie] or [MediaKind.episode]).
String compileTemplate(NamingOptions options, MediaKind kind) {
  final custom = options.customTemplate;
  if (custom != null && custom.isNotEmpty) return custom;

  final sep = options.separator;
  final isTv = kind != MediaKind.movie;
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
        switch ((options.titleLanguage, options.bilingual)) {
          case (TitleLanguage.chineseFirst, true):
            pieces.add(('{title}', true));
            pieces.add(('{en_title}', false));
          case (TitleLanguage.chineseFirst, false):
            pieces.add(('{title}', true));
          case (TitleLanguage.englishFirst, true):
            pieces.add(('{en_title}', false));
            pieces.add(('{title}', false));
          case (TitleLanguage.englishFirst, false):
            pieces.add(('{en_title}', true));
        }
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
/// separators in template literals and trims separators at both ends without altering
/// punctuation inside substituted values (such as `...` or `--` in titles).
String renderTemplate(String template, Map<String, Object?> vars) {
  final (raw, _) = _Renderer(template, vars).sequence(inOptional: false);
  final chunks = <(String, bool)>[];
  for (final (text, isValue) in raw) {
    if (text.isEmpty) continue;
    if (!isValue && chunks.isNotEmpty && !chunks.last.$2) {
      chunks[chunks.length - 1] = ('${chunks.last.$1}$text', false);
    } else {
      chunks.add((text, isValue));
    }
  }
  final cleaned = <(String, bool)>[];
  for (final (text, isValue) in chunks) {
    if (isValue) {
      cleaned.add((text, true));
    } else {
      final s = text
          .replaceAll(_emptyParensRe, '')
          .replaceAllMapped(_sepRunRe, (m) => m[1]!);
      if (s.isNotEmpty) cleaned.add((s, false));
    }
  }
  while (cleaned.isNotEmpty && !cleaned.first.$2) {
    final s = cleaned.first.$1.replaceFirst(_leadingSepRe, '');
    if (s.isEmpty) {
      cleaned.removeAt(0);
    } else {
      cleaned[0] = (s, false);
      break;
    }
  }
  while (cleaned.isNotEmpty && !cleaned.last.$2) {
    final s = cleaned.last.$1.replaceFirst(_trailingSepRe, '');
    if (s.isEmpty) {
      cleaned.removeLast();
    } else {
      cleaned[cleaned.length - 1] = (s, false);
      break;
    }
  }
  return [for (final (text, _) in cleaned) text].join();
}

/// Runs [rewrites] over [name] in order. A rule with a bad pattern is skipped
/// and one that would empty the name is ignored: a typo must not lose names.
String applyRewrites(String name, List<NameRewrite> rewrites) {
  var out = name;
  for (final r in rewrites) {
    if (r.pattern.isEmpty) continue;
    final RegExp re;
    try {
      re = RegExp(r.pattern);
    } on FormatException {
      continue;
    }
    final next = out.replaceAllMapped(
      re,
      (m) => r.replacement.replaceAllMapped(_captureRefRe, (g) {
        final i = int.parse(g[1]!);
        return i <= m.groupCount ? m[i] ?? '' : g[0]!;
      }),
    );
    if (next.trim().isNotEmpty) out = next;
  }
  return out;
}

class _Renderer {
  final String t;
  final Map<String, Object?> vars;
  int i = 0;

  _Renderer(this.t, this.vars);

  /// Returns the rendered chunks `(text, isValue)` and whether a direct variable was missing.
  (List<(String, bool)>, bool) sequence({required bool inOptional}) {
    final out = <(String, bool)>[];
    final lit = StringBuffer();
    void flushLit() {
      if (lit.isNotEmpty) {
        out.add((lit.toString(), false));
        lit.clear();
      }
    }

    var missing = false;
    while (i < t.length) {
      final c = t[i];
      if (c == r'\' && i + 1 < t.length) {
        lit.write(t[i + 1]);
        i += 2;
      } else if (c == '[') {
        i++;
        final (sub, m) = sequence(inOptional: true);
        if (i < t.length && t[i] == ']') i++;
        if (!m && sub.isNotEmpty) {
          flushLit();
          out.addAll(sub);
        }
      } else if (c == ']' && inOptional) {
        flushLit();
        return (out, missing);
      } else if (c == '{' && t.indexOf('}', i) > 0) {
        final end = t.indexOf('}', i);
        final v = _value(t.substring(i + 1, end));
        i = end + 1;
        if (v == null) {
          missing = true;
        } else {
          flushLit();
          out.add((v, true));
        }
      } else {
        lit.write(c);
        i++;
      }
    }
    flushLit();
    return (out, missing);
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
    .replaceAll(_illegalPathCharsRe, '')
    .replaceAllMapped(_fullWidthCharsRe, (m) => _fullWidth[m[0]]!)
    .replaceAll(_multiSpaceRe, ' ')
    .trim()
    .replaceAll(_trailingDotSpaceRe, '');
