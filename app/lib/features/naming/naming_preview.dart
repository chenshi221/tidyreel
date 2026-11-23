import 'dart:convert';

import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/settings_codec.dart';
import '../../l10n/l10n.dart';

/// Sample inputs for the live preview (PLAN §3.2).
class NamingSample {
  final String original;
  final String ext;
  final Map<String, Object?> vars;
  final String? partLabel;

  const NamingSample(this.original, this.ext, this.vars, {this.partLabel});

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

  static const movieUhdDv = NamingSample(
    'Dune.Part.Two.2024.2160p.UHD.BluRay.DV.HDR10+.TrueHD.Atmos-WiKi.mkv',
    'mkv',
    {
      'title': '沙丘2',
      'original_title': 'Dune: Part Two',
      'en_title': 'Dune Part Two',
      'year': 2024,
      'tmdbid': 693134,
      'tmdb_tag': '{tmdb-693134}',
      'resolution': '2160p',
      'extra_info': '2160p.DV.HDR10+.Atmos',
      'version': '2160p.DV.HDR10+.Atmos',
      'group': 'WiKi',
      'lang': '',
      'ext': 'mkv',
    },
  );

  static const movieEditionPart = NamingSample(
    "Inception.2010.Director's.Cut.CD1.1080p.BluRay.x264-CHD.mkv",
    'mkv',
    {
      'title': '盗梦空间',
      'original_title': 'Inception',
      'en_title': 'Inception',
      'year': 2010,
      'tmdbid': 27205,
      'tmdb_tag': '{tmdb-27205}',
      'resolution': '1080p',
      'extra_info': "1080p.Director's.Cut",
      'version': "Director's Cut",
      'group': 'CHD',
      'lang': '',
      'ext': 'mkv',
    },
    partLabel: 'cd1',
  );

  static NamingSample tvAnimeFor(NamingOptions options) => NamingSample(
    '[VCB-Studio] Sousou no Frieren [01][Ma10p_1080p][x265_flac].mkv',
    'mkv',
    {
      'title': '葬送的芙莉莲',
      'original_title': '葬送のフリーレン',
      'en_title': 'Frieren',
      'year': options.showYear == ShowYearSource.seasonAir ? 2024 : 2023,
      'season': 1,
      'episode': 1,
      'episode_title': '冒险的终点',
      'tmdbid': 209867,
      'tmdb_tag': '{tmdb-209867}',
      'resolution': '1080p',
      'extra_info': '1080p',
      'version': '',
      'group': 'VCB-Studio',
      'lang': '',
      'ext': 'mkv',
    },
  );

  static NamingSample tvDonghuaVarietyFor(NamingOptions options) =>
      NamingSample(
        '凡人修仙传.S03E12.2020.2160p.HDR.WEB-DL.H265-QHstudIo.mp4',
        'mp4',
        {
          'title': '凡人修仙传',
          'original_title': '凡人修仙传',
          'en_title': 'A Record of a Mortals Journey to Immortality',
          'year': options.showYear == ShowYearSource.seasonAir ? 2023 : 2020,
          'season': 3,
          'episode': 12,
          'episode_title': '初入虚天殿',
          'tmdbid': 106449,
          'tmdb_tag': '{tmdb-106449}',
          'resolution': '2160p',
          'extra_info': '2160p.HDR',
          'version': '',
          'group': 'QHstudIo',
          'lang': '',
          'ext': 'mp4',
        },
      );
}

/// A selectable preset scenario for the live preview.
class NamingScenario {
  final String id;
  final String label;
  final String englishLabel;
  final NamingSample Function(NamingOptions options) buildSample;

  const NamingScenario({
    required this.id,
    required this.label,
    required this.englishLabel,
    required this.buildSample,
  });

  String localizedLabel(AppL10n l10n) => l10n.isEn ? englishLabel : label;
}

final List<NamingScenario> movieNamingScenarios = [
  NamingScenario(
    id: 'standard',
    label: '常规电影',
    englishLabel: 'Standard Movie',
    buildSample: (_) => NamingSample.movie,
  ),
  NamingScenario(
    id: 'uhd-dv',
    label: '4K 杜比视界',
    englishLabel: '4K Dolby Vision',
    buildSample: (_) => NamingSample.movieUhdDv,
  ),
  NamingScenario(
    id: 'edition-part',
    label: '导演剪辑版 / 分盘',
    englishLabel: "Director's Cut / Multi-disc",
    buildSample: (_) => NamingSample.movieEditionPart,
  ),
];

final List<NamingScenario> tvNamingScenarios = [
  NamingScenario(
    id: 'standard',
    label: '常规剧集',
    englishLabel: 'Standard TV',
    buildSample: NamingSample.tvFor,
  ),
  NamingScenario(
    id: 'anime',
    label: '日漫长篇',
    englishLabel: 'Anime',
    buildSample: NamingSample.tvAnimeFor,
  ),
  NamingScenario(
    id: 'donghua-variety',
    label: '国漫 / 综艺',
    englishLabel: 'Donghua / Variety',
    buildSample: NamingSample.tvDonghuaVarietyFor,
  ),
];

/// Outcome of one preview render. [text] null means an invalid template ([error]).
class PreviewResult {
  final String? text;
  final String? error;

  const PreviewResult.ok(String this.text) : error = null;
  const PreviewResult.error(String this.error) : text = null;

  /// What to show in the example card.
  String get display => text ?? '模板有误：$error';

  String localizedDisplay(AppL10n l10n) =>
      text ?? l10n.tr('模板有误：$error', 'Invalid template: $error');
}

/// compileTemplate + renderTemplate.
PreviewResult renderNaming(
  NamingOptions options,
  MediaKind kind,
  NamingSample sample,
) {
  try {
    final tpl = compileTemplate(options, kind);
    var base = applyRewrites(
      renderTemplate(tpl, sample.vars),
      options.rewrites,
    );
    final part = sample.partLabel?.trim();
    if (part != null && part.isNotEmpty) {
      base = '$base-${sanitizeName(part)}';
    }
    return PreviewResult.ok('$base.${sample.ext}');
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

/// Live parse + render outcome for the custom filename tester.
class CustomFilenamePreview {
  final ParsedName parsed;
  final bool isTv;
  final PreviewResult renderedName;
  final PreviewResult renderedFolder;
  final PreviewResult? renderedSeason;
  final String rootDir;

  const CustomFilenamePreview({
    required this.parsed,
    required this.isTv,
    required this.renderedName,
    required this.renderedFolder,
    required this.renderedSeason,
    required this.rootDir,
  });
}

String _extOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1);
}

String _stemOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return fileName;
  return fileName.substring(0, dot);
}

/// Parses an arbitrary user-pasted filename (or relative path) with
/// [RuleBasedParser] and renders its target filename under [profile].
CustomFilenamePreview previewCustomFilename(
  String rawInput,
  NamingProfile profile, {
  required bool fallbackIsTv,
}) {
  final normalized = rawInput.trim().replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  final fileName = segments.isEmpty ? normalized : segments.last;
  final parentDirs = segments.length > 1
      ? segments.sublist(0, segments.length - 1).reversed.toList()
      : const <String>[];

  final parsed = const RuleBasedParser().parse(
    fileName,
    parentDirs: parentDirs,
  );
  final bool isTv = switch (parsed.kind) {
    MediaKind.episode || MediaKind.special => true,
    MediaKind.movie => false,
    MediaKind.extra || MediaKind.unknown => fallbackIsTv,
  };
  final kind = isTv ? MediaKind.episode : MediaKind.movie;
  final options = isTv ? profile.tv : profile.movie;

  final ext = _extOf(fileName).isEmpty ? 'mkv' : _extOf(fileName);
  final rawTitle = (parsed.title != null && parsed.title!.trim().isNotEmpty)
      ? parsed.title!.trim()
      : _stemOf(fileName);
  final String? titleVar;
  final String? enTitleVar;
  if (options.bilingual) {
    if (options.titleLanguage == TitleLanguage.englishFirst) {
      enTitleVar = rawTitle;
      titleVar = null;
    } else {
      titleVar = rawTitle;
      enTitleVar = null;
    }
  } else {
    titleVar = rawTitle;
    enTitleVar = rawTitle;
  }

  final extraRaw = parsed.extraInfo ?? parsed.resolution;
  final extraFormatted = extraRaw?.replaceAll(
    RegExp(r'[._ ]+'),
    options.separator,
  );
  final episode = parsed.episodes.firstOrNull ?? parsed.absolute;
  final episodeEnd =
      parsed.episodes.length > 1 && parsed.episodes.last > parsed.episodes.first
      ? parsed.episodes.last
      : null;
  final season =
      parsed.season ??
      (isTv ? (parsed.kind == MediaKind.special ? 0 : 1) : null);
  final tmdbId = parsed.externalId?.source == 'tmdb'
      ? parsed.externalId!.id
      : null;

  final sample = NamingSample(fileName, ext, {
    'title': titleVar,
    'original_title': rawTitle,
    'en_title': enTitleVar,
    'year': parsed.year ?? parsed.airDate?.year,
    'season': season,
    'episode': episode,
    'episode_end': episodeEnd,
    'episode_title': null,
    'tmdbid': tmdbId,
    'tmdb_tag': tmdbId == null ? null : '{tmdb-$tmdbId}',
    'resolution': parsed.resolution,
    'extra_info': extraFormatted,
    'version': parsed.edition ?? extraFormatted,
    'group': parsed.group,
    'lang': parsed.lang,
    'ext': ext,
  }, partLabel: parsed.partLabel);

  final rendered = renderNaming(options, kind, sample);
  final sanitizedName = rendered.text == null
      ? rendered
      : PreviewResult.ok(sanitizeName(rendered.text!));
  final folder = _renderFolderVars(options.folderTemplate, {
    ...sample.vars,
    'title': rawTitle,
    'en_title': rawTitle,
  }, options.rewrites);
  final seasonFolder = isTv && season != null
      ? _renderFolderVars(options.seasonFolderTemplate, {
          'season': season,
        }, options.rewrites)
      : null;

  return CustomFilenamePreview(
    parsed: parsed,
    isTv: isTv,
    renderedName: sanitizedName,
    renderedFolder: folder,
    renderedSeason: seasonFolder,
    rootDir: isTv ? profile.tvDir : profile.movieDir,
  );
}

/// Convenience helper for [renderFolder] taking raw vars map.
PreviewResult _renderFolderVars(
  String template,
  Map<String, Object?> vars,
  List<NameRewrite> rewrites,
) {
  try {
    return PreviewResult.ok(
      sanitizeName(applyRewrites(renderTemplate(template, vars), rewrites)),
    );
  } catch (e) {
    return PreviewResult.error('$e');
  }
}

/// Exported/imported bundle of naming profile + title rules (`version: 1`).
class NamingBundle {
  final NamingProfile? naming;
  final TitleRules? titleRules;

  const NamingBundle({this.naming, this.titleRules});
}

/// Serializes [profile] and [rules] into the v1 JSON bundle format.
String encodeNamingBundle(NamingProfile profile, TitleRules rules) =>
    const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'naming': namingProfileToJson(profile),
      'titleRules': titleRulesToJson(rules),
    });

/// Parses and validates a JSON naming/title-rules bundle.
({NamingBundle? bundle, String? error}) decodeNamingBundle(
  String raw, {
  AppL10n l10n = AppL10n.zh,
}) {
  final text = raw.trim();
  if (text.isEmpty) {
    return (
      bundle: null,
      error: l10n.tr(
        '请先粘贴或选择 JSON 配置',
        'Paste or load a JSON configuration first',
      ),
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return (
      bundle: null,
      error: l10n.tr(
        'JSON 语法有误：${e.message}',
        'Invalid JSON syntax: ${e.message}',
      ),
    );
  }
  if (decoded is! Map) {
    return (
      bundle: null,
      error: l10n.tr(
        'JSON 顶层必须是对象（{ ... }）',
        'Top-level JSON value must be an object ({ ... })',
      ),
    );
  }
  final map = decoded.cast<String, Object?>();
  if (map.containsKey('version')) {
    final v = map['version'];
    if (v is! int || v != 1) {
      return (
        bundle: null,
        error: l10n.tr(
          '不支持的配置版本：$v（仅支持 version: 1）',
          'Unsupported config version: $v (only version: 1 is supported)',
        ),
      );
    }
  }
  final hasNaming = map.containsKey('naming') && map['naming'] != null;
  final hasTitleRules =
      map.containsKey('titleRules') && map['titleRules'] != null;
  if (!hasNaming && !hasTitleRules) {
    return (
      bundle: null,
      error: l10n.tr(
        '缺少 "naming" 或 "titleRules" 配置字段',
        'Missing "naming" or "titleRules" field',
      ),
    );
  }
  NamingProfile? naming;
  if (hasNaming) {
    final rawNaming = map['naming'];
    if (rawNaming is! Map) {
      return (
        bundle: null,
        error: l10n.tr(
          '字段 "naming" 格式无效，应为对象',
          'Field "naming" must be a JSON object',
        ),
      );
    }
    try {
      naming = namingProfileFromJson(rawNaming.cast<String, Object?>());
    } on Object catch (e) {
      return (
        bundle: null,
        error: l10n.tr('命名规则字段解析失败：$e', 'Failed to parse naming rules: $e'),
      );
    }
  }
  TitleRules? titleRules;
  if (hasTitleRules) {
    final rawRules = map['titleRules'];
    if (rawRules is! Map) {
      return (
        bundle: null,
        error: l10n.tr(
          '字段 "titleRules" 格式无效，应为对象',
          'Field "titleRules" must be a JSON object',
        ),
      );
    }
    try {
      titleRules = titleRulesFromJson(rawRules.cast<String, Object?>());
    } on Object catch (e) {
      return (
        bundle: null,
        error: l10n.tr('片名规则字段解析失败：$e', 'Failed to parse title rules: $e'),
      );
    }
  }
  return (
    bundle: NamingBundle(naming: naming, titleRules: titleRules),
    error: null,
  );
}
