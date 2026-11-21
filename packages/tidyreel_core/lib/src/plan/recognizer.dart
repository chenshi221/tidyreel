import 'dart:convert';
import 'dart:math';

import '../model/ids.dart';
import '../model/media.dart';
import '../model/metadata.dart';
import '../model/scan.dart';
import '../model/title_rules.dart';
import '../parser/parser.dart';
import '../tmdb/anilist.dart';
import '../tmdb/metadata_provider.dart';
import 'follow.dart';
import 'template.dart' show applyRewrites;
import 'text.dart';

/// Owner: Agent D. Classify + parse + anchor grouping + TMDB match (PLAN §1 step 4).
abstract interface class Recognizer {
  /// [files] is the recursive listing of [roots] (files only). [read]
  /// fetches a file's content (already-scraped .nfo); without it nothing is
  /// read.
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files, {
    Future<List<int>> Function(String path)? read,
  });
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

class AnchorRecognizer implements Recognizer {
  final FilenameParser parser;
  final MetadataProvider metadata;

  /// Asked when TMDB finds nothing for a Latin-script title (romaji).
  final AltTitleSource? altTitles;

  /// Read once per scan, so a settings change applies to the next one.
  final MediaHint Function() hint;

  /// 片名规则, read once per scan like [hint].
  final TitleRules Function() titleRules;

  AnchorRecognizer(
    this.parser,
    this.metadata, {
    this.altTitles,
    MediaHint Function()? hint,
    TitleRules Function()? titleRules,
  }) : hint = hint ?? (() => MediaHint.mixed),
       titleRules = titleRules ?? (() => const TitleRules());

  @override
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files, {
    Future<List<int>> Function(String path)? read,
  }) async {
    final rootDirs = [for (final r in roots) _trimSlash(r)];
    final nfos = {
      for (final e in files)
        if (!e.isDir && e.name.toLowerCase().endsWith('.nfo')) e.path,
    };
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
    final draftsByDir = <String, List<_Draft>>{};
    final draftsByVideoDir = <String, List<_Draft>>{};
    for (final d in drafts) {
      (draftsByDir[d.dir] ??= []).add(d);
      final seenDirs = <String>{};
      for (final v in d.videoFiles) {
        final vd = dirOf(v.path);
        if (seenDirs.add(vd)) (draftsByVideoDir[vd] ??= []).add(d);
      }
    }
    for (final f in followers) {
      final d = _homeOf(f, drafts, draftsByDir, draftsByVideoDir);
      if (d == null) {
        unassigned.add(f.file);
      } else {
        d.followers.add(f.file);
      }
    }

    final cache = <String, Future<List<Candidate>>>{};
    final h = hint();
    final rules = titleRules();
    // A few folders at a time: each costs several TMDB round trips.
    final looked = List<_Lookup?>.filled(drafts.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < drafts.length) {
        final idx = next++;
        looked[idx] = await _lookup(drafts[idx], cache, h, rules, nfos, read);
      }
    }

    await Future.wait([
      for (var i = 0; i < min(4, drafts.length); i++) worker(),
    ]);
    final usedIds = <String>{};
    final groups = [for (final l in looked) _toGroup(l!, usedIds)];
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

  /// A selected folder holding a single work one level down ("Show/[Group] Show
  /// [01-12]/01.mkv") becomes that work's folder: it is the one renamed, and the
  /// inner folder turns into the season folder. With several works inside, each
  /// keeps its own folder. A top-level folder may be a storage mount: left alone.
  List<_Draft> _promoteToRoots(List<_Draft> drafts, List<String> rootDirs) {
    final out = [...drafts];
    for (final root in rootDirs) {
      if (root.lastIndexOf('/') <= 0 || _structural.hasMatch(baseOf(root))) {
        continue;
      }
      final inside = out
          .where((d) => d.dir == root || d.dir.startsWith('$root/'))
          .toList();
      if (inside.length != 1) continue;
      final d = inside.single;
      if (d.dir == root || dirOf(d.dir) != root) continue;
      out[out.indexOf(d)] = _Draft(
        root,
        d.videos,
        d.folderTitle,
        true,
        originalDir: d.dir,
      );
    }
    return out;
  }

  _Draft? _homeOf(
    _Entry f,
    List<_Draft> drafts,
    Map<String, List<_Draft>> draftsByDir,
    Map<String, List<_Draft>> draftsByVideoDir,
  ) {
    final fdir = dirOf(f.file.path);
    final checked = <_Draft>{};
    _Draft? best;

    // 1. Check drafts that already have a video in the follower's exact directory.
    for (final d in draftsByVideoDir[fdir] ?? const <_Draft>[]) {
      checked.add(d);
      final m = matchVideo(f.file, d.videoFiles);
      if (m == null) continue;
      if (dirOf(m.video.path) == fdir) return d;
      best ??= d;
    }

    // 2. Check enclosing drafts along the follower's directory chain.
    List<_Draft>? deepestEnclosing;
    for (final anc in f.chain) {
      final list = draftsByDir[anc];
      if (list == null) continue;
      deepestEnclosing ??= list;
      for (final d in list) {
        if (!checked.add(d)) continue;
        final m = matchVideo(f.file, d.videoFiles);
        if (m == null) continue;
        if (dirOf(m.video.path) == fdir) return d;
        best ??= d;
      }
    }
    if (best != null) return best;

    // 3. Fall back to the unambiguous enclosing group folder (fast path).
    if (deepestEnclosing != null) {
      return deepestEnclosing.length == 1 ? deepestEnclosing.single : null;
    }

    // 4. Follower sits outside all group folders (e.g. a sibling Subs/ dir).
    for (final d in drafts) {
      if (!checked.add(d)) continue;
      if (matchVideo(f.file, d.videoFiles) != null) return d;
    }
    return null;
  }

  // ---- matching -----------------------------------------------------------

  Future<_Lookup> _lookup(
    _Draft d,
    Map<String, Future<List<Candidate>>> cache,
    MediaHint hint,
    TitleRules rules,
    Set<String> nfos,
    Future<List<int>> Function(String path)? read,
  ) async {
    final vids = [for (final v in d.videos) v.file];
    final main = vids.where((v) => v.parsed?.kind != MediaKind.extra).toList();
    final tvVotes = main.where((v) => _looksTv(v.parsed)).length;
    final looksTv = main.isNotEmpty && tvVotes * 2 > main.length;
    var kind = switch (hint) {
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

    final queries =
        <String>[
              if (d.isRoot) ...[
                ?fileTitle,
                ?d.folderTitle,
              ] else ...[
                ?d.folderTitle,
                ?fileTitle,
              ],
            ]
            .map((q) => applyRewrites(q, rules.cleanups).trim())
            .where((q) => normTitle(q).isNotEmpty)
            .toSet()
            .toList();

    Candidate? match;
    var score = 0.0;
    var anchor = queries.isNotEmpty ? queries.first : null;

    /// Best acceptable candidate for [q]; [scoreAs] are the names compared
    /// with TMDB's titles (all AniList aliases, best one counts).
    Future<bool> tryQuery(String q, {List<String>? scoreAs}) async {
      for (final y in [year, if (year != null) null]) {
        final key = '${kind.name}|$q|$y';
        final future = cache.putIfAbsent(key, () {
          final f = metadata.search(
            q,
            kind: kind == MediaKind.movie ? MediaKind.movie : MediaKind.episode,
            year: y,
          );
          f.then<void>(
            (_) {},
            onError: (Object _) {
              if (identical(cache[key], f)) cache.remove(key);
            },
          );
          return f;
        });
        final results = await future;
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

    // 指定匹配 wins over any search.
    final names = [
      baseOf(d.dir),
      ?d.folderTitle,
      ?fileTitle,
    ].map((n) => n.toLowerCase());
    final pin = rules.pins
        .where(
          (p) =>
              p.keyword.trim().isNotEmpty &&
              names.any((n) => n.contains(p.keyword.trim().toLowerCase())),
        )
        .firstOrNull;
    final scraped = pin == null && read != null
        ? await _fromNfo(d, vids, nfos, read)
        : null;
    if (pin != null || scraped != null) {
      // 指定匹配, or the TMDB id an earlier scrape left in tvshow/movie.nfo.
      match = pin?.match ?? scraped!.match;
      score = 1;
      kind = match!.kind == MediaKind.movie
          ? MediaKind.movie
          : MediaKind.episode;
    } else {
      for (final q in queries) {
        if (await tryQuery(q)) {
          anchor = q;
          break;
        }
      }
    }
    final askAlt =
        match == null &&
        altTitles != null &&
        (hint == MediaHint.mixed || hint == MediaHint.anime);
    if (askAlt) {
      alt:
      for (final q in queries.where((q) => !hasCjk(q))) {
        final List<String> alts;
        try {
          alts = await altTitles!.altTitles(q);
        } on Object {
          continue;
        }
        for (final a in alts.take(4)) {
          if (await tryQuery(a, scoreAs: [q, ...alts])) {
            anchor = q;
            break alt;
          }
        }
      }
    }
    // Still nothing: loosen the names (sort letter, brackets, one language).
    if (match == null) {
      final tried = {for (final q in queries) normTitle(q)};
      relaxed:
      for (final q in queries) {
        for (final r in relaxedQueries(q, baseOf(d.dir))) {
          if (!tried.add(normTitle(r))) continue;
          if (await tryQuery(r)) {
            anchor = r;
            break relaxed;
          }
        }
      }
    }
    anchor ??= vids.isNotEmpty ? stem(vids.first.name) : baseOf(d.dir);

    final show =
        scraped?.show ??
        (match != null && kind == MediaKind.episode
            ? await metadata.show(match!.tmdbId)
            : null);
    // No zh-CN title: show() / movie() may have found a Chinese one.
    if (match case final m? when !hasHan(m.title)) {
      Candidate? detail = show?.info ?? scraped?.movie?.info;
      if (detail == null && m.kind == MediaKind.movie) {
        try {
          detail = (await metadata.movie(m.tmdbId)).info;
        } on Object {
          // Keep the search title.
        }
      }
      match = chineseNamed(m, detail);
    }
    return _Lookup(d, vids, kind, anchor, year, match, score, show);
  }

  static final _nfoRootRe = RegExp(r'<(tvshow|movie)\b', caseSensitive: false);
  static final _nfoTmdbRe = RegExp(
    r'<uniqueid\b[^>]*type="tmdb"[^>]*>\s*(\d+)\s*<|<tmdbid>\s*(\d+)\s*<',
    caseSensitive: false,
  );

  /// The work named by an already-scraped folder: `tvshow.nfo` / `movie.nfo`
  /// in it, or `<video>.nfo` next to a lone video. Episode nfos are skipped
  /// (their id is the episode's). Unreadable or id-less nfos give null.
  Future<({Candidate match, ShowDetail? show, MovieDetail? movie})?> _fromNfo(
    _Draft d,
    List<ScanFile> vids,
    Set<String> nfos,
    Future<List<int>> Function(String path) read,
  ) async {
    final dirs = [
      d.dir,
      if (d.originalDir != null && d.originalDir != d.dir) d.originalDir!,
    ];
    final paths = <String>{
      for (final dir in dirs) ...[
        joinPath(dir, 'tvshow.nfo'),
        joinPath(dir, 'movie.nfo'),
      ],
      if (vids.length == 1)
        joinPath(dirOf(vids.single.path), '${stem(vids.single.name)}.nfo'),
    };
    for (final path in paths.where(nfos.contains)) {
      try {
        final text = utf8.decode(await read(path), allowMalformed: true);
        final root = _nfoRootRe.firstMatch(text)?[1]?.toLowerCase();
        final m = _nfoTmdbRe.firstMatch(text);
        final id = int.tryParse(m?[1] ?? m?[2] ?? '');
        if (root == null || id == null) continue;
        if (root == 'movie') {
          final detail = await metadata.movie(id);
          return (match: detail.info, show: null, movie: detail);
        }
        final detail = await metadata.show(id);
        return (match: detail.info, show: detail, movie: null);
      } on Object {
        // A broken nfo or a TMDB hiccup: fall back to searching.
        continue;
      }
    }
    return null;
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

  /// 75% title similarity (best of the TMDB titles) + 25% year agreement
  /// (unknown = 0.5, exact = 1, off by one = 0.7, else 0).
  double _score(String query, int? year, Candidate c) {
    final titleSim = [
      c.title,
      c.englishTitle,
      c.originalTitle,
      ...c.aliases,
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
  final String? originalDir;
  final List<_Entry> videos;
  final List<ScanFile> videoFiles;
  final String? folderTitle;
  final bool isRoot;
  final List<ScanFile> followers = [];

  _Draft(
    this.dir,
    this.videos,
    this.folderTitle,
    this.isRoot, {
    this.originalDir,
  }) : videoFiles = [for (final v in videos) v.file];
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
