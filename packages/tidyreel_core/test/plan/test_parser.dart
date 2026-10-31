import 'package:tidyreel_core/tidyreel_core.dart';

/// Tiny parser for planner / recognizer tests: SxxEyy, 第N集, bare absolute numbers, years.
class TestParser implements FilenameParser {
  const TestParser();

  static const _video = {'mkv', 'mp4', 'avi', 'ts', 'rmvb', 'mov'};
  static const _sub = {'ass', 'srt', 'ssa', 'vtt', 'sub'};
  static const _side = {'nfo', 'jpg', 'png'};
  static const _junk = {'txt', 'url', 'html', 'torrent'};

  @override
  FileRole classify(String fileName) {
    final i = fileName.lastIndexOf('.');
    final ext = i < 0 ? '' : fileName.substring(i + 1).toLowerCase();
    if (_video.contains(ext)) return FileRole.video;
    if (_sub.contains(ext)) return FileRole.subtitle;
    if (_side.contains(ext)) return FileRole.sidecar;
    if (_junk.contains(ext)) return FileRole.junk;
    return FileRole.other;
  }

  @override
  ParsedName parse(String fileName, {List<String> parentDirs = const []}) {
    var s = fileName;
    final dot = s.lastIndexOf('.');
    if (dot > 0 && s.length - dot <= 5) s = s.substring(0, dot);
    final isExtra =
        RegExp(r'花絮|featurette|behind', caseSensitive: false).hasMatch(s) ||
        parentDirs.any(
          (d) => RegExp(r'^(extras?|花絮)$', caseSensitive: false).hasMatch(d),
        );

    String? lang;
    final langM = RegExp(r'[. ](chs|cht|sc|tc|eng|zh-CN|zh-TW|简体|繁体)(?=[. ]|$)')
        .firstMatch(s);
    if (langM != null) lang = langM[1];

    int? season, absolute;
    final episodes = <int>[];
    var cut = s.length;
    final se = RegExp(r'[Ss](\d{1,2})[Ee](\d{1,3})').firstMatch(s);
    if (se != null) {
      season = int.parse(se[1]!);
      episodes.add(int.parse(se[2]!));
      cut = se.start;
    } else {
      final cn = RegExp(r'第\s*(\d{1,4})\s*[集话]').firstMatch(s);
      final bare = RegExp(r'(?:^|[\s\]\-_.])(\d{1,4})(?=[\s\[.\-_]|$)')
          .allMatches(s)
          .where((m) => !RegExp(r'^(19|20)\d\d$').hasMatch(m[1]!))
          .where((m) => !RegExp(r'^\d{3,4}p$').hasMatch(m[0]!))
          .lastOrNull;
      if (cn != null) {
        absolute = int.parse(cn[1]!);
        cut = cn.start;
      } else if (bare != null &&
          RegExp(r'[\-\s]\s*\d{1,4}\s*(\[|$)').hasMatch(s)) {
        absolute = int.parse(bare[1]!);
        cut = bare.start;
      }
    }
    final year = RegExp(r'(?:^|[\s.(\[])((?:19|20)\d\d)(?=[\s.)\]]|$)')
        .firstMatch(s);
    final res = RegExp(r'(\d{3,4}p)').firstMatch(s)?[1];
    if (year != null && year.start < cut) cut = year.start;
    if (res != null) {
      final r = s.indexOf(res);
      if (r < cut) cut = r;
    }
    var title = s
        .substring(0, cut)
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'[._]'), ' ')
        .replaceAll(RegExp(r'\s+-\s*$'), ' ')
        .trim();
    final group = RegExp(r'^\[([^\]]+)\]').firstMatch(s)?[1];

    final hasNum = episodes.isNotEmpty || absolute != null;
    if (season == null && hasNum) {
      for (final d in parentDirs) {
        final m = RegExp(
          r'^(?:Season|S)\s*(\d+)$',
          caseSensitive: false,
        ).firstMatch(d);
        if (m != null) season = int.parse(m[1]!);
      }
    }
    final kind = isExtra
        ? MediaKind.extra
        : season == 0
        ? MediaKind.special
        : hasNum
        ? MediaKind.episode
        : year != null
        ? MediaKind.movie
        : MediaKind.unknown;
    return ParsedName(
      title: title.isEmpty ? null : title,
      year: year == null ? null : int.parse(year[1]!),
      season: season,
      episodes: episodes,
      absolute: absolute,
      kind: kind,
      resolution: res,
      group: group,
      lang: lang,
      confidence: title.isEmpty ? 0.3 : (hasNum || year != null ? 0.9 : 0.5),
    );
  }
}
