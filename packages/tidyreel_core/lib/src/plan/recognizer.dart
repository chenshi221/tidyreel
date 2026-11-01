import 'dart:math';

import '../model/ids.dart';
import '../model/media.dart';
import '../model/metadata.dart';
import '../model/scan.dart';
import '../parser/parser.dart';
import '../tmdb/anilist.dart';
import '../tmdb/metadata_provider.dart';
import 'follow.dart';
import 'text.dart';

/// Owner: Agent D. Classify + parse + anchor grouping + TMDB match (PLAN §1 step 4).
abstract interface class Recognizer {
  /// [files] is the recursive listing of [roots] (files only).
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files,
  );
}

/// Below this, a TMDB hit is not accepted and the group is left for manual matching.
const matchAcceptScore = 0.6;

/// Folders that never name a title: seasons, specials, extras, subtitle
/// folders, and quality / version folders ("嫁金钗/4K/01.mkv").
final _structural = RegExp(
  r'^(season|series)[\s._\-]*\d+.*$|^s\d{1,2}$|^第\s*[0-9一二三四五六七八九十百]+\s*[季部].*$|'
  r'^(specials?|sp|ova|oad|extras?|featurettes?|behind the scenes|bonus|'
  r'特别篇|特典|花絮|番外|subs?|subtitles?|字幕)$|'
  r'^(\d{3,4}[pi]|[248]k|uhd|fhd|hdr(10)?\+?|dv|dolby[\s._-]?vision|杜比视界|'
  r'blu-?ray|web-?dl|remux|高清|超清|蓝光|原盘|国语|粤语|国配|中字|普通话)$',
  caseSensitive: false,
);

/// What the user says a scan holds (设置 › 识别 › 内容类型). [mixed] decides
/// per folder from the file names.
enum MediaHint { mixed, anime, tv, movie }

final _cjkRe = RegExp(r'[぀-ヿ㐀-鿿가-힯]');

class AnchorRecognizer implements Recognizer {
  final FilenameParser parser;
  final MetadataProvider metadata;

  /// Asked when TMDB finds nothing for a Latin-script title (romaji).
  final AltTitleSource? altTitles;

  /// Read once per scan, so a settings change applies to the next one.
  final MediaHint Function() hint;

  AnchorRecognizer(
    this.parser,
    this.metadata, {
    this.altTitles,
    MediaHint Function()? hint,
  }) : hint = hint ?? (() => MediaHint.mixed);

  @override
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files,
  ) async {
    final rootDirs = [for (final r in roots) _trimSlash(r)];
    final entries = files.where((e) => !e.isDir).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final videos = <_Entry>[];
    final followers = <_Entry>[];
    final unassigned = <ScanFile>[];
    for (final e in entries) {
      final role = parser.classify(e.name);
      final chain = _chain(e.path, rootDirs);
      final wantsParse =
          role == FileRole.video ||
          role == FileRole.subtitle ||
          role == FileRole.sidecar;
      final file = ScanFile(
        path: e.path,
        name: e.name,
        size: e.size,
        role: role,
        parsed: wantsParse
            ? parser.parse(
                e.name,
                parentDirs: [for (final d in chain) baseOf(d)],
              )
            : null,
      );
      switch (role) {
        case FileRole.video:
          videos.add(_Entry(file, chain));
        case FileRole.subtitle || FileRole.sidecar:
          followers.add(_Entry(file, chain));
        case FileRole.junk || FileRole.other:
          unassigned.add(file);
      }
    }

    final drafts = _promoteToRoots(_draftGroups(videos, rootDirs), rootDirs);
    for (final f in followers) {
      final d = _homeOf(f, drafts);
      if (d == null) {
        unassigned.add(f.file);
      } else {
        d.followers.add(f.file);
      }
    }

    final cache = <String, Future<List<Candidate>>>{};
    final h = hint();
    // A few folders at a time: each costs several TMDB round trips.
    final looked = <_Lookup>[];
    for (var i = 0; i < drafts.length; i += 4) {
      looked.addAll(
        await Future.wait(
          drafts.skip(i).take(4).map((d) => _lookup(d, cache, h)),
        ),
      );
    }
    final usedIds = <String>{};
    final groups = [for (final l in looked) _toGroup(l, usedIds)];
    groups.sort(
      (a, b) => a.rootDir.compareTo(b.rootDir) != 0
          ? a.rootDir.compareTo(b.rootDir)
          : a.anchorTitle.compareTo(b.anchorTitle),
    );
    return ScanResult(
      connection: connection,
      roots: roots,
      groups: groups,
      unassigned: unassigned..sort((a, b) => a.path.compareTo(b.path)),
    );
  }

  // ---- grouping -----------------------------------------------------------

  List<_Draft> _draftGroups(List<_Entry> videos, List<String> rootDirs) {
    final buckets = <String, List<_Entry>>{};
    final titled = <String, bool>{};
    for (final v in videos) {
      final titleDir = v.chain.where((d) => !_structural.hasMatch(baseOf(d)));
      final dir = titleDir.isNotEmpty ? titleDir.first : v.chain.first;
      buckets.putIfAbsent(dir, () => []).add(v);
      titled[dir] = titleDir.isNotEmpty;
    }

    final drafts = <_Draft>[];
    for (final MapEntry(key: dir, value: vs) in buckets.entries) {
      final folderTitle = titled[dir]!
          ? parser
                .parse(
                  baseOf(dir),
                  parentDirs: [
                    for (var d = dirOf(dir); d != '/'; d = dirOf(d)) baseOf(d),
                  ],
                )
                .title
          : null;
      final isRoot = rootDirs.contains(dir);
      final byKey = <String, List<_Entry>>{};
      for (final v in vs) {
        byKey
            .putIfAbsent(normTitle(v.file.parsed?.title ?? ''), () => [])
            .add(v);
      }
      final keys = byKey.keys.where((k) => k.isNotEmpty).toList();
      keys.sort((a, b) => byKey[b]!.length.compareTo(byKey[a]!.length));

      var split = false;
      if (keys.length >= 2) {
        final explained =
            folderTitle != null &&
            keys.any((k) => similarity(folderTitle, k) >= 0.6);
        final dominant = byKey[keys.first]!.length / vs.length > 0.6;
        split = folderTitle == null || !(explained || dominant);
      }
      if (!split) {
        drafts.add(_Draft(dir, vs, folderTitle, isRoot));
      } else {
        final untitled = byKey[''] ?? const [];
        for (var i = 0; i < keys.length; i++) {
          drafts.add(
            _Draft(
              dir,
              [...byKey[keys[i]]!, if (i == 0) ...untitled],
              null,
              isRoot,
            ),
          );
        }
      }
    }
    return drafts;
  }

  /// A selected folder named after the only work inside it, one level down
  /// ("Show/[Group] Show [01-12]/01.mkv"), becomes that work's folder: it is
  /// the one renamed, and the inner folder turns into the season folder. With
  /// several works inside, each keeps its own folder.
  List<_Draft> _promoteToRoots(List<_Draft> drafts, List<String> rootDirs) {
    final out = [...drafts];
    for (final root in rootDirs) {
      if (root == '/' || _structural.hasMatch(baseOf(root))) continue;
      final inside = out
          .where((d) => d.dir == root || d.dir.startsWith('$root/'))
          .toList();
      if (inside.length != 1) continue;
      final d = inside.single;
      if (d.dir == root || dirOf(d.dir) != root) continue;
      final title = parser
          .parse(
            baseOf(root),
            parentDirs: [
              for (var p = dirOf(root); p != '/'; p = dirOf(p)) baseOf(p),
            ],
          )
          .title;
      // Only when the folder is named after the work: "下载" holding one show
      // is a container, not the show's folder.
      final names = [
        ?d.folderTitle,
        for (final v in d.videos.take(5)) ?v.file.parsed?.title,
      ];
      if (title == null ||
          normTitle(title).isEmpty ||
          !names.any((n) => similarity(title, n) >= 0.8)) {
        continue;
      }
      out[out.indexOf(d)] = _Draft(root, d.videos, title, true);
    }
    return out;
  }

  _Draft? _homeOf(_Entry f, List<_Draft> drafts) {
    _Draft? best;
    var sameDir = false;
    for (final d in drafts) {
      final m = matchVideo(f.file, [for (final v in d.videos) v.file]);
      if (m == null) continue;
      final same = dirOf(m.video.path) == dirOf(f.file.path);
      if (best == null || (same && !sameDir)) {
        best = d;
        sameDir = same;
      }
    }
    if (best != null) return best;
    // Fall back to the group whose folder contains the file (must be unambiguous).
    final dir = dirOf(f.file.path);
    final inside = drafts
        .where((d) => dir == d.dir || dir.startsWith('${d.dir}/'))
        .toList();
    if (inside.isEmpty) return null;
    inside.sort((a, b) => b.dir.length.compareTo(a.dir.length));
    final deepest = inside
        .where((d) => d.dir.length == inside.first.dir.length)
        .toList();
    return deepest.length == 1 ? deepest.first : null;
  }

  // ---- matching -----------------------------------------------------------

  Future<_Lookup> _lookup(
    _Draft d,
    Map<String, Future<List<Candidate>>> cache,
    MediaHint hint,
  ) async {
    final vids = [for (final v in d.videos) v.file];
    final main = vids.where((v) => v.parsed?.kind != MediaKind.extra).toList();
    final tvVotes = main.where((v) => _looksTv(v.parsed)).length;
    final looksTv = main.isNotEmpty && tvVotes * 2 > main.length;
    final kind = switch (hint) {
      MediaHint.movie => MediaKind.movie,
      MediaHint.tv => main.isEmpty ? MediaKind.movie : MediaKind.episode,
      // A folder of several files is a series; one file may be a 剧场版.
      MediaHint.anime =>
        looksTv || main.length > 1 ? MediaKind.episode : MediaKind.movie,
      MediaHint.mixed => looksTv ? MediaKind.episode : MediaKind.movie,
    };

    final fileTitle = _mostCommon([
      for (final v in vids)
        if (v.parsed?.title != null && v.parsed!.title!.trim().isNotEmpty)
          v.parsed!.title!.trim(),
    ]);
    final year =
        _mostCommonInt([
          for (final v in vids)
            if (v.parsed?.year != null) v.parsed!.year!,
        ]) ??
        (d.folderTitle == null ? null : parser.parse(baseOf(d.dir)).year);

    final queries = <String>[
      if (d.isRoot) ...[
        ?fileTitle,
        ?d.folderTitle,
      ] else ...[
        ?d.folderTitle,
        ?fileTitle,
      ],
    ].where((q) => normTitle(q).isNotEmpty).toSet().toList();

    Candidate? match;
    var score = 0.0;
    var anchor = queries.isNotEmpty ? queries.first : null;

    /// Best acceptable candidate for [q]; [scoreAs] are the names compared
    /// with TMDB's titles (all AniList aliases, best one counts).
    Future<bool> tryQuery(String q, {List<String>? scoreAs}) async {
      for (final y in [year, if (year != null) null]) {
        final results = await (cache['${kind.name}|$q|$y'] ??= metadata.search(
          q,
          kind: kind == MediaKind.movie ? MediaKind.movie : MediaKind.episode,
          year: y,
        ));
        Candidate? best;
        var bestScore = 0.0;
        for (final c in results.take(5)) {
          // Anime mode leans towards Japanese productions on near ties.
          final s =
              (scoreAs ?? [q]).map((t) => _score(t, year, c)).fold(0.0, max) +
              (hint == MediaHint.anime && c.originCountry == 'JP' ? 0.05 : 0);
          if (s > bestScore) (best, bestScore) = (c, s);
        }
        score = max(score, min(bestScore, 1.0));
        if (best != null && bestScore >= matchAcceptScore) {
          match = best;
          score = min(bestScore, 1.0);
          return true;
        }
      }
      return false;
    }

    for (final q in queries) {
      if (await tryQuery(q)) {
        anchor = q;
        break;
      }
    }
    final askAlt =
        match == null &&
        altTitles != null &&
        (hint == MediaHint.mixed || hint == MediaHint.anime);
    if (askAlt) {
      alt:
      for (final q in queries.where((q) => !_cjkRe.hasMatch(q))) {
        final alts = await altTitles!.altTitles(q);
        for (final a in alts.take(4)) {
          if (await tryQuery(a, scoreAs: [q, ...alts])) {
            anchor = q;
            break alt;
          }
        }
      }
    }
    anchor ??= vids.isNotEmpty ? stem(vids.first.name) : baseOf(d.dir);

    final show = match != null && kind == MediaKind.episode
        ? await metadata.show(match!.tmdbId)
        : null;
    return _Lookup(d, vids, kind, anchor, year, match, score, show);
  }

  MediaGroup _toGroup(_Lookup l, Set<String> usedIds) {
    final key = '${l.draft.dir}|${l.kind.name}|${normTitle(l.anchor)}';
    var id = 'g-${stableHash(key)}';
    for (var n = 2; !usedIds.add(id); n++) {
      id = 'g-${stableHash('$key|$n')}';
    }
    final all = [...l.vids, ...l.draft.followers]
      ..sort((a, b) => a.path.compareTo(b.path));
    return MediaGroup(
      id: GroupId(id),
      kind: l.kind,
      anchorTitle: l.anchor,
      anchorYear: l.year,
      rootDir: l.draft.dir,
      files: all,
      match: l.match,
      matchScore: l.score,
      show: l.show,
    );
  }

  /// 75% title similarity (best of the three TMDB titles) + 25% year agreement
  /// (unknown = 0.5, exact = 1, off by one = 0.7, else 0).
  double _score(String query, int? year, Candidate c) {
    final titleSim = [
      c.title,
      c.englishTitle,
      c.originalTitle,
    ].whereType<String>().map((t) => similarity(query, t)).fold(0.0, max);
    final yearScore = (year == null || c.year == null)
        ? 0.5
        : switch ((year - c.year!).abs()) {
            0 => 1.0,
            1 => 0.7,
            _ => 0.0,
          };
    return 0.75 * titleSim + 0.25 * yearScore;
  }

  bool _looksTv(ParsedName? p) =>
      p != null &&
      (p.kind == MediaKind.episode ||
          p.kind == MediaKind.special ||
          p.season != null ||
          p.episodes.isNotEmpty ||
          p.absolute != null);
}

class _Lookup {
  final _Draft draft;
  final List<ScanFile> vids;
  final MediaKind kind;
  final String anchor;
  final int? year;
  final Candidate? match;
  final double score;
  final ShowDetail? show;

  _Lookup(
    this.draft,
    this.vids,
    this.kind,
    this.anchor,
    this.year,
    this.match,
    this.score,
    this.show,
  );
}

class _Entry {
  final ScanFile file;

  /// Folders from the file's own directory up to its root, nearest first.
  final List<String> chain;

  _Entry(this.file, this.chain);
}

class _Draft {
  final String dir;
  final List<_Entry> videos;
  final String? folderTitle;
  final bool isRoot;
  final List<ScanFile> followers = [];

  _Draft(this.dir, this.videos, this.folderTitle, this.isRoot);
}

String _trimSlash(String p) =>
    p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

List<String> _chain(String path, List<String> roots) {
  final dir = dirOf(path);
  String? root;
  for (final r in roots) {
    if ((dir == r || dir.startsWith(r == '/' ? '/' : '$r/')) &&
        (root == null || r.length > root.length)) {
      root = r;
    }
  }
  final chain = <String>[];
  for (var d = dir; ; d = dirOf(d)) {
    chain.add(d);
    if (root == null || d == root || d == '/') break;
  }
  return chain;
}

String? _mostCommon(List<String> xs) {
  final counts = <String, int>{};
  final first = <String, String>{};
  for (final x in xs) {
    final k = normTitle(x);
    counts.update(k, (v) => v + 1, ifAbsent: () => 1);
    first.putIfAbsent(k, () => x);
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
  return first[best.key];
}

int? _mostCommonInt(List<int> xs) {
  final counts = <int, int>{};
  for (final x in xs) {
    counts.update(x, (v) => v + 1, ifAbsent: () => 1);
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}
