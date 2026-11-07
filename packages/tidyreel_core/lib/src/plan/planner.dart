import '../model/ids.dart';
import '../model/media.dart';
import '../model/metadata.dart';
import '../model/naming.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../tmdb/metadata_provider.dart';
import 'follow.dart';
import 'strategy.dart';
import 'template.dart';
import 'scrape.dart';
import 'text.dart';

final _punct = RegExp(r'[^\p{L}\p{N}]', unicode: true);
const _overflowWarning = '超出 TMDB 总集数';

/// Owner: Agent D. Turns a recognized scan + user decisions into ops, with conflict
/// detection (PLAN §4.3 rule 1). Subtitles follow their video, specials go to
/// Season 00, extras to Extras/, junk becomes unselected delete ops.
final _han = RegExp(r'[\u4e00-\u9fff]');

abstract interface class Planner {
  /// [existing] lists paths already present at the targets (for conflict checks);
  /// the caller fetches it from the backend.
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  });
}

class DefaultPlanner implements Planner {
  /// Used for season layouts, episode groups and episode titles (cached by the provider).
  final MetadataProvider metadata;

  DefaultPlanner(this.metadata);

  /// Paths in the plan are the physical paths at the time each phase runs: files are
  /// moved inside their old folder first, then the group folder is renamed (inPlace).
  @override
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  }) => _PlanBuilder(metadata, scan, decisions, options, existing).run();
}

/// One video (or extra) of a group with its resolved target.
class _Item {
  final ScanFile file;
  bool extra = false;
  EpisodeRef? ref;
  final warnings = <String>[];
  bool selected = true;
  bool manual = false;

  late String dstDir;
  late String newBase;

  /// File name the video gets (newBase plus extension).
  late String outName;

  _Item(this.file);
}

class _PlanBuilder {
  final MetadataProvider metadata;
  final ScanResult scan;
  final Map<GroupId, GroupDecision> decisions;
  final PlanOptions opts;
  final Set<String> existing;

  final mkdirs = <String, GroupId?>{};
  final selectedMkdirs = <String>{};
  final fileOps = <RenameOp>[];
  final folderOps = <RenameOp>[];

  /// Season folders made by renaming a subfolder; they run before the
  /// group-folder renames since their paths are inside the old folder.
  final seasonOps = <RenameOp>[];
  final renamedSeasons = <String, String>{};
  final deleteOps = <RenameOp>[];
  final renamedRoots = <String, String>{};

  /// Show folder (final path) → the first group filling it and where that
  /// group's files go during the run (its old root, before the rename).
  final showFolders = <String, ({GroupId group, String base})>{};
  final merges = <PlanMerge>[];
  final knownDirs = <String>{};

  _PlanBuilder(
    this.metadata,
    this.scan,
    this.decisions,
    this.opts,
    this.existing,
  );

  Future<RenamePlan> run() async {
    knownDirs
      ..addAll(existing)
      ..addAll(scan.roots);
    for (final f in [
      ...scan.groups.expand((g) => g.files),
      ...scan.unassigned,
    ]) {
      for (var d = dirOf(f.path); d != '/' && knownDirs.add(d); d = dirOf(d)) {}
    }

    final processed = <MediaGroup>[];
    final skipped = <MediaGroup>[];
    for (final g in scan.groups) {
      final d = decisions[g.id] ?? const GroupDecision();
      final match = d.match ?? g.match;
      if (!d.selected || match == null) {
        skipped.add(g);
        continue;
      }
      await _group(g, d, match);
      processed.add(g);
    }
    _junk(processed, skipped);

    final mkdirOps =
        [
          for (final e in mkdirs.entries)
            RenameOp(
              id: OpId('m-${stableHash(e.key)}'),
              kind: OpKind.mkdir,
              phase: ExecPhase.files,
              src: '',
              dst: e.key,
              group: e.value,
              selected: selectedMkdirs.contains(e.key),
            ),
        ]..sort((a, b) {
          final da = '/'.allMatches(a.dst).length;
          final db = '/'.allMatches(b.dst).length;
          return da != db ? da.compareTo(db) : a.dst.compareTo(b.dst);
        });
    final ops = [
      ...mkdirOps,
      ...fileOps,
      ...seasonOps,
      ...folderOps,
      ...deleteOps,
    ];
    return RenamePlan(ops: ops, conflicts: _conflicts(ops), merges: merges);
  }

  // ---- one group ----------------------------------------------------------

  /// Air date -> episode across the show's regular seasons; the first episode
  /// wins when two air the same day.
  Future<Map<DateTime, EpisodeRef>> _episodesByDate(
    int tmdbId,
    ShowDetail show,
  ) async {
    final out = <DateTime, EpisodeRef>{};
    for (final s in show.seasons.where((s) => s.number > 0)) {
      for (final e in await metadata.season(tmdbId, s.number)) {
        final d = e.airDate;
        if (d == null) continue;
        out.putIfAbsent(
          DateTime.utc(d.year, d.month, d.day),
          () => EpisodeRef(s.number, e.number),
        );
      }
    }
    return out;
  }

  Future<void> _group(MediaGroup g, GroupDecision d, Candidate match) async {
    // What it was matched to decides, not the first guess from file names:
    // picking a show for a folder recognized as a movie makes it a show.
    final isTv = match.kind == MediaKind.episode;
    final naming = isTv ? opts.naming.tv : opts.naming.movie;
    final template = compileTemplate(
      naming,
      isTv ? MediaKind.episode : MediaKind.movie,
    );
    final lowMatch = d.match == null && g.matchScore < opts.confidenceThreshold;
    final videos = [
      for (final f in g.files)
        if (f.role == FileRole.video && !(d.overrides[f.path]?.ignore ?? false))
          f,
    ];

    // --- season layout (TV)
    ShowDetail? show;
    EpisodeGroup? epGroup;
    var tmdbCounts = <int>[];
    if (isTv) {
      show = (g.show != null && g.match?.tmdbId == match.tmdbId)
          ? g.show
          : await metadata.show(match.tmdbId);
      if (d.episodeGroupId != null) {
        final groups = await metadata.episodeGroups(match.tmdbId);
        epGroup = groups.where((x) => x.id == d.episodeGroupId).firstOrNull;
      }
      tmdbCounts = epGroup != null
          ? _denseCounts({
              for (final s in epGroup.seasons) s.order: s.episodes.length,
            })
          : _denseCounts({
              for (final s in show!.seasons) s.number: s.episodeCount,
            });
    }

    // Air-dated files (variety shows): TMDB episode by date.
    final byDate = isTv && videos.any((v) => v.parsed?.airDate != null)
        ? await _episodesByDate(match.tmdbId, show!)
        : const <DateTime, EpisodeRef>{};

    // "01.mkv … 12.mkv" in a matched show folder: each bare number alone is a
    // guess, but a run of distinct numbers is the usual layout (Jellyfin and
    // Sonarr read these as episodes too), so it is not flagged.
    final bare = [
      for (final v in videos)
        if (v.parsed case final p?
            when p.episodes.isEmpty && p.absolute != null)
          p.absolute!,
    ];
    final bareRun =
        isTv && bare.length >= 2 && bare.toSet().length == bare.length;

    // --- resolve every video
    final items = <_Item>[];
    final pending = <_Item>[];
    final inputs = <EpisodeRef>[];
    final split =
        d.strategy == SeasonStrategy.splitSequential ||
        d.strategy == SeasonStrategy.splitKeepEpisode;
    for (final v in videos) {
      final ov = d.overrides[v.path];
      final p = v.parsed;
      final kind = ov?.kind ?? p?.kind ?? MediaKind.unknown;
      final it = _Item(v);
      final lowParse =
          (p == null || p.confidence < opts.confidenceThreshold) &&
          !(bareRun && p != null && p.episodes.isEmpty && p.absolute != null);
      if (kind == MediaKind.extra) {
        it.extra = true;
        items.add(it);
        continue;
      }
      if (!isTv) {
        items.add(it);
        if (lowParse) it.warnings.add('识别置信度较低');
        continue;
      }
      final n = p?.episodes.firstOrNull ?? p?.absolute;
      final isSpecial = kind == MediaKind.special || p?.season == 0;
      if (ov?.season != null || ov?.episode != null) {
        final ep = ov!.episode ?? n;
        if (ep == null) continue;
        it.ref = EpisodeRef(ov.season ?? (isSpecial ? 0 : p?.season ?? 1), ep);
        it.manual = true;
      } else if (n == null && byDate.containsKey(p?.airDate)) {
        it.ref = byDate[p!.airDate];
      } else if (n == null) {
        continue; // no episode number to name it by: leave the file alone
      } else if (isSpecial) {
        it.ref = EpisodeRef(0, n);
      } else {
        inputs.add(split ? EpisodeRef(1, n) : EpisodeRef(p?.season ?? 1, n));
        pending.add(it);
      }
      if (lowParse && !it.manual) it.warnings.add('识别置信度较低');
      items.add(it);
    }

    if (isTv) {
      var counts = tmdbCounts;
      if (counts.isEmpty && d.strategy == SeasonStrategy.mergeIntoOne) {
        final localMax = <int, int>{};
        for (var i = 0; i < pending.length; i++) {
          localMax.update(
            inputs[i].season,
            (m) => m > inputs[i].episode ? m : inputs[i].episode,
            ifAbsent: () => inputs[i].episode,
          );
        }
        counts = _denseCounts(localMax);
      }
      final refs = applyStrategy(
        d.strategy,
        inputs,
        counts,
        episodeOffset: d.episodeOffset,
      );
      final inverse = <EpisodeRef, EpisodeRef>{
        if (epGroup != null && d.strategy == SeasonStrategy.asParsed)
          for (final s in epGroup.seasons)
            for (var i = 0; i < s.episodes.length; i++)
              s.episodes[i]: EpisodeRef(s.order, i + 1),
      };
      for (var i = 0; i < pending.length; i++) {
        final r = inverse[refs[i]] ?? refs[i];
        pending[i].ref = r;
        if (r.episode < 1) {
          pending[i].warnings.add('集号无效');
        } else if (_overflow(d.strategy, r, tmdbCounts)) {
          pending[i].warnings.add(_overflowWarning);
        }
      }
    }
    for (final it in items) {
      // A download with more episodes than TMDB lists is still named (and
      // selected); the warning stays visible.
      it.selected =
          !lowMatch && it.warnings.every((w) => w == _overflowWarning);
      if (lowMatch) it.warnings.add('片名匹配置信度较低');
    }

    // --- episode titles
    final wantTitles =
        isTv &&
        (naming.episodeTitle ||
            (naming.customTemplate?.contains('episode_title') ?? false));
    final titles = wantTitles
        ? await _episodeTitles(match.tmdbId, epGroup, d.strategy, items)
        : const <EpisodeRef, String>{};

    // --- folders
    final groupSelected = items.any((it) => it.selected);
    // A movie without a zh-CN title: movie() may find a Chinese one.
    Candidate? movieInfo;
    if (!isTv && !_han.hasMatch(match.title)) {
      try {
        movieInfo = (await metadata.movie(match.tmdbId)).info;
      } on Object {
        // Keep the search title.
      }
    }
    final titleVars = _titleVars(
      chineseNamed(match, show?.info ?? movieInfo),
      naming,
      g.anchorTitle,
    );
    final folderVars = {
      ...titleVars,
      if (naming.titleLanguage == TitleLanguage.englishFirst &&
          titleVars['en_title'] != null)
        'title': titleVars['en_title'],
      'year': match.year,
    };
    final folderName = sanitizeName(
      applyRewrites(
        renderTemplate(naming.folderTemplate, folderVars),
        naming.rewrites,
      ),
    );
    String curBase;
    // Where the show folder ends up, and whether another group / the disk
    // already has it: then this group merges in unless told 分开保留.
    String? mergeInto;
    if (opts.mode == OrganizeMode.inPlace) {
      if (_owns(g, match)) {
        curBase = g.rootDir;
        final there = _onDiskShow(dirOf(g.rootDir), folderName, match);
        final finalBase = there != null && there != g.rootDir
            ? there
            : joinPath(dirOf(g.rootDir), folderName);
        final claimed = showFolders[finalBase];
        final onDisk = finalBase != g.rootDir && existing.contains(finalBase);
        if ((claimed != null || onDisk) && !d.separate) {
          // Files go under the other group's old root (renamed later) or
          // straight into the existing folder; this root keeps its name.
          curBase = claimed?.base ?? finalBase;
          mergeInto = finalBase;
          _noteMerge(g, finalBase, claimed?.group, onDisk, items);
        } else if (claimed != null || onDisk) {
          // 分开保留: keep this folder's own name, rename files inside.
        } else {
          showFolders[finalBase] = (group: g.id, base: g.rootDir);
          if (finalBase != g.rootDir) {
            renamedRoots[g.rootDir] = finalBase;
            folderOps.add(
              RenameOp(
                id: OpId('f-${stableHash(g.rootDir)}'),
                kind: OpKind.relocate,
                phase: ExecPhase.folders,
                src: g.rootDir,
                dst: finalBase,
                group: g.id,
                selected: groupSelected,
              ),
            );
          }
        }
      } else {
        curBase = joinPath(g.rootDir, folderName);
        _mkdir(curBase, g.id, selected: groupSelected);
      }
    } else {
      final lib = opts.libraryRoot;
      if (lib == null) {
        throw ArgumentError('moveToLibrary needs PlanOptions.libraryRoot');
      }
      final typeDir = isTv ? opts.naming.tvDir : opts.naming.movieDir;
      var base = lib == '/' ? '' : lib.replaceFirst(RegExp(r'/+$'), '');
      if (typeDir.isNotEmpty) {
        base = '$base/${sanitizeName(typeDir)}';
        _mkdir(base, g.id, selected: groupSelected);
      }
      curBase =
          _onDiskShow(base.isEmpty ? '/' : base, folderName, match) ??
          '$base/$folderName';
      final claimed = showFolders[curBase];
      final onDisk = existing.contains(curBase);
      if ((claimed != null || onDisk) && d.separate) {
        // 分开保留 in the library: the next free "名称 (2)".
        var n = 2;
        while (showFolders.containsKey('$base/$folderName ($n)') ||
            existing.contains('$base/$folderName ($n)')) {
          n++;
        }
        curBase = '$base/$folderName ($n)';
      } else if (claimed != null || onDisk) {
        mergeInto = curBase;
        _noteMerge(g, curBase, claimed?.group, onDisk, items);
      }
      showFolders.putIfAbsent(curBase, () => (group: g.id, base: curBase));
      _mkdir(curBase, g.id, selected: groupSelected);
    }
    if (mergeInto != null && curBase != mergeInto) {
      // Merging into a folder that is renamed later in this run.
      _mkdir(curBase, g.id, selected: groupSelected);
    }

    // --- name every video
    // Single-season shows may skip the Season folder; multi-season never do.
    final flat =
        isTv &&
        !naming.singleSeasonFolder &&
        tmdbCounts.where((c) => c > 0).length <= 1 &&
        items.every((it) => it.extra || it.ref!.season == 1);
    for (final it in items) {
      final v = it.file;
      final ext = extOf(v.name);
      if (it.extra) {
        it.dstDir = joinPath(curBase, 'Extras');
        it.newBase = stem(v.name);
        continue;
      }
      final p = v.parsed;
      final extraInfo = p?.extraInfo?.replaceAll(
        RegExp(r'[._ ]+'),
        naming.separator,
      );
      final vars = <String, Object?>{
        ...titleVars,
        'year': match.year,
        'resolution': p?.resolution,
        'group': p?.group,
        'extra_info': extraInfo,
        'version': extraInfo,
        'lang': _parsedLang(v),
        'ext': ext,
      };
      if (isTv) {
        final r = it.ref!;
        final span =
            !it.manual &&
                p != null &&
                p.episodes.length > 1 &&
                p.episodes.last > p.episodes.first
            ? p.episodes.last - p.episodes.first
            : 0;
        vars['season'] = r.season;
        vars['episode'] = r.episode;
        vars['episode_end'] = span > 0 ? r.episode + span : null;
        vars['episode_title'] = titles[r];
        if (naming.showYear == ShowYearSource.seasonAir) {
          vars['year'] =
              show!.seasons
                  .where((s) => s.number == r.season)
                  .firstOrNull
                  ?.airDate
                  ?.year ??
              match.year;
        }
        it.dstDir = flat
            ? curBase
            : joinPath(
                curBase,
                sanitizeName(
                  applyRewrites(
                    renderTemplate(naming.seasonFolderTemplate, {
                      'season': r.season,
                    }),
                    naming.rewrites,
                  ),
                ),
              );
      } else {
        it.dstDir = curBase;
      }
      it.newBase = sanitizeName(
        applyRewrites(renderTemplate(template, vars), naming.rewrites),
      );
    }
    if (isTv && opts.mode == OrganizeMode.inPlace) {
      _reuseSeasonFolders(g, items, curBase);
    }
    for (final it in items) {
      _mkdir(it.dstDir, g.id, selected: it.selected);
      final ext = extOf(it.file.name);
      final hasExt =
          ext.isNotEmpty &&
          it.newBase.toLowerCase().endsWith('.${ext.toLowerCase()}');
      it.outName = it.extra
          ? it.file.name
          : (ext.isEmpty || hasExt)
          ? it.newBase
          : '${it.newBase}.$ext';
      _emit(it, it.outName, g.id);
    }

    // --- subtitles and sidecars follow their video
    final byPath = {for (final it in items) it.file.path: it};
    final subTargets = <String, int>{};
    for (final f in g.files) {
      if (f.role != FileRole.subtitle && f.role != FileRole.sidecar) continue;
      var m = matchVideo(f, [for (final it in items) it.file]);
      if (m == null && items.length == 1 && f.role == FileRole.subtitle) {
        m = FollowMatch(items.first.file, '');
      }
      final it = m == null ? null : byPath[m.video.path];
      if (m == null || it == null) continue;
      final ext = extOf(f.name);
      String name;
      if (it.extra) {
        name = f.name;
      } else if (f.role == FileRole.subtitle) {
        final lang = langFromRemainder(m.remainder) ?? _parsedLang(f);
        final prefix = '${it.newBase}${lang == null ? '' : '.$lang'}';
        final key = '${it.dstDir}/$prefix.$ext'.toLowerCase();
        final n = (subTargets[key] ?? 0) + 1;
        subTargets[key] = n;
        name = n == 1 ? '$prefix.$ext' : '$prefix.$n.$ext';
      } else {
        name = '${it.newBase}${m.remainder}.$ext';
      }
      _emit(it, name, g.id, source: f);
    }

    if (opts.scrape) {
      // Paths as they are after the run: season folders and the show folder
      // renamed, or merged into another one.
      final showDir = mergeInto ?? renamedRoots[g.rootDir] ?? curBase;
      String finalDir(String dir) {
        final d = renamedSeasons[dir] ?? dir;
        if (d == curBase) return showDir;
        return d.startsWith('$curBase/')
            ? '$showDir${d.substring(curBase.length)}'
            : d;
      }

      await _scrape(g, match, show, epGroup, items, showDir, finalDir);
    }
  }

  /// Paths [_scrape] already wrote this plan (two groups merging into one
  /// show folder share its tvshow.nfo).
  final scraped = <String>{};

  void _writeOp(
    String dst,
    String source,
    GroupId gid, {
    required bool selected,
  }) {
    if (!scraped.add(dst)) return;
    final there = existing.contains(dst);
    deleteOps.add(
      RenameOp(
        id: OpId('w-${stableHash(dst)}'),
        kind: OpKind.write,
        phase: ExecPhase.cleanup,
        src: source,
        dst: dst,
        group: gid,
        // Never overwrite: an existing nfo / poster is the user's.
        selected: selected && !there,
        warning: there ? '已存在，保留原文件' : null,
      ),
    );
  }

  /// 刮削模式: .nfo files and TMDB artwork for one group.
  Future<void> _scrape(
    MediaGroup g,
    Candidate match,
    ShowDetail? show,
    EpisodeGroup? epGroup,
    List<_Item> items,
    String showDir,
    String Function(String dir) finalDir,
  ) async {
    final on = items.any((it) => it.selected);
    String img(String path, String size) =>
        'https://image.tmdb.org/t/p/$size$path';
    void art(String dir, Candidate c) {
      if (c.posterPath != null) {
        _writeOp(
          '$dir/poster.jpg',
          img(c.posterPath!, 'w780'),
          g.id,
          selected: on,
        );
      }
      if (c.backdropPath != null) {
        _writeOp(
          '$dir/fanart.jpg',
          img(c.backdropPath!, 'w1280'),
          g.id,
          selected: on,
        );
      }
    }

    if (match.kind == MediaKind.movie) {
      Candidate info = match;
      try {
        info = (await metadata.movie(match.tmdbId)).info;
      } on Object {
        // Search data is enough for an nfo.
      }
      final main = items.where((it) => !it.extra).toList();
      if (main.isEmpty) return;
      final dir = finalDir(main.first.dstDir);
      for (final it in main) {
        _writeOp(
          '${finalDir(it.dstDir)}/${stem(it.outName)}.nfo',
          '$writeTextPrefix${movieNfo(info)}',
          g.id,
          selected: it.selected,
        );
      }
      art(dir, info);
      return;
    }

    final s = show ?? await metadata.show(match.tmdbId);
    _writeOp(
      '$showDir/tvshow.nfo',
      '$writeTextPrefix${tvShowNfo(s)}',
      g.id,
      selected: on,
    );
    art(showDir, s.info);
    final episodes = <int, Map<int, Episode>>{};
    Future<Episode?> episode(int season, int n) async {
      // Episode-group numbering isn't TMDB's: no per-episode details then.
      if (epGroup != null) return null;
      if (!episodes.containsKey(season)) {
        try {
          episodes[season] = {
            for (final e in await metadata.season(match.tmdbId, season))
              e.number: e,
          };
        } on Object {
          episodes[season] = const {};
        }
      }
      return episodes[season]![n];
    }

    final seasons = <int>{};
    for (final it in items) {
      final r = it.ref;
      if (it.extra || r == null) continue;
      seasons.add(r.season);
      final dir = finalDir(it.dstDir);
      final e = await episode(r.season, r.episode);
      final base = stem(it.outName);
      _writeOp(
        '$dir/$base.nfo',
        '$writeTextPrefix${episodeNfo(show: s.info, season: r.season, episode: r.episode, info: e)}',
        g.id,
        selected: it.selected,
      );
      if (e?.stillPath != null) {
        _writeOp(
          '$dir/$base-thumb.jpg',
          img(e!.stillPath!, 'w780'),
          g.id,
          selected: it.selected,
        );
      }
    }
    for (final n in seasons) {
      final poster = s.seasons
          .where((x) => x.number == n)
          .firstOrNull
          ?.posterPath;
      if (poster == null) continue;
      final name = n == 0
          ? 'season-specials-poster.jpg'
          : 'season${n.toString().padLeft(2, '0')}-poster.jpg';
      _writeOp('$showDir/$name', img(poster, 'w780'), g.id, selected: on);
    }
  }

  /// The show folder already in [dir] for [match]: our exact [folderName],
  /// or one another tool / an older template made, found by its TMDB id tag
  /// or by 「标题 (年份)」 (a raw download like 「标题 (年份) [BDRip]」 doesn't
  /// count). Lets a later season or the rest of a season join it.
  String? _onDiskShow(String dir, String folderName, Candidate match) {
    final exact = joinPath(dir, folderName);
    if (existing.contains(exact)) return exact;
    final tag = RegExp(
      'tmdb(?:id)?[-=]${match.tmdbId}(?![0-9])',
      caseSensitive: false,
    );
    final names = {
      normTitle(_untagged(folderName)),
      if (match.year case final y?)
        for (final t in [match.title, match.englishTitle, match.originalTitle])
          if (t != null && t.isNotEmpty) normTitle('$t ($y)'),
    };
    for (final p in existing) {
      if (dirOf(p) != dir || p == exact) continue;
      final name = baseOf(p);
      if (_fileLike.hasMatch(name)) continue;
      if (tag.hasMatch(name)) return p;
      if (_titleYear.hasMatch(_untagged(name)) &&
          names.contains(normTitle(_untagged(name)))) {
        return p;
      }
    }
    return null;
  }

  void _noteMerge(
    MediaGroup g,
    String into,
    GroupId? withGroup,
    bool exists,
    List<_Item> items,
  ) => merges.add(
    PlanMerge(
      group: g.id,
      into: into,
      exists: exists,
      withGroup: withGroup,
      seasons: {
        for (final it in items)
          if (!it.extra && it.ref != null) it.ref!.season,
      }.toList()..sort(),
    ),
  );

  String? _parsedLang(ScanFile f) {
    final raw = f.parsed?.lang;
    if (raw == null || raw.isEmpty) return null;
    return normalizeLang(raw) ?? raw;
  }

  /// A season's files that all sit in one subfolder with no folders inside
  /// (e.g. "4K/01.mkv …") are renamed in place and that folder becomes the
  /// season folder, instead of creating it and moving every file.
  void _reuseSeasonFolders(MediaGroup g, List<_Item> items, String curBase) {
    final bySeason = <String, List<_Item>>{};
    for (final it in items) {
      if (!it.extra && it.dstDir != curBase) {
        (bySeason[it.dstDir] ??= []).add(it);
      }
    }
    final taken = <String>{};
    for (final MapEntry(key: season, value: its) in bySeason.entries) {
      final dirs = {for (final it in its) dirOf(it.file.path)};
      if (dirs.length != 1) continue;
      final src = dirs.single;
      final inside = '$src/';
      final ok =
          dirOf(src) == curBase &&
          src.startsWith('${g.rootDir}/') &&
          src != season &&
          !taken.contains(src) &&
          !knownDirs.contains(season) &&
          !mkdirs.containsKey(season) &&
          !knownDirs.any((d) => d.startsWith(inside)) &&
          // every video there goes to this season (nothing else stays behind)
          g.files.every(
            (f) =>
                f.role != FileRole.video ||
                dirOf(f.path) != src ||
                its.any((it) => it.file.path == f.path),
          ) &&
          !scan.unassigned.any(
            (f) => f.role != FileRole.junk && f.path.startsWith(inside),
          ) &&
          !scan.groups.any(
            (o) =>
                !identical(o, g) &&
                o.files.any((f) => f.path.startsWith(inside)),
          );
      if (!ok) continue;
      taken.add(src);
      for (final it in its) {
        it.dstDir = src;
      }
      renamedSeasons[src] = season;
      seasonOps.add(
        RenameOp(
          id: OpId('s-${stableHash(src)}'),
          kind: OpKind.relocate,
          phase: ExecPhase.folders,
          src: src,
          dst: season,
          group: g.id,
          selected: its.any((it) => it.selected),
        ),
      );
    }
  }

  /// Adds a relocate op for [src] (default: the item's video) to `item.dstDir/name`.
  void _emit(_Item it, String name, GroupId gid, {ScanFile? source}) {
    final src = source ?? it.file;
    // Same name still gets an op: running it records the file as organized
    // (the executor treats src == dst as done, and undo as a no-op).
    final dst = joinPath(it.dstDir, name);
    fileOps.add(
      RenameOp(
        id: OpId('r-${stableHash(src.path)}'),
        kind: OpKind.relocate,
        phase: ExecPhase.files,
        src: src.path,
        dst: dst,
        group: gid,
        selected: it.selected,
        warning: source == null && it.warnings.isNotEmpty
            ? it.warnings.join('；')
            : null,
      ),
    );
  }

  void _mkdir(String dir, GroupId gid, {bool selected = true}) {
    if (!knownDirs.contains(dir)) {
      mkdirs.putIfAbsent(dir, () => gid);
      if (selected) selectedMkdirs.add(dir);
    }
  }

  /// A group "owns" its folder when nothing else lives in it and it is what the user
  /// imported (or below it), or the folder is named after the title; only then is the
  /// folder itself renamed. A top-level folder may be a storage mount: name match only.
  bool _owns(MediaGroup g, Candidate match) {
    final prefix = g.rootDir == '/' ? '/' : '${g.rootDir}/';
    final shared = scan.groups.any(
      (o) =>
          !identical(o, g) &&
          (o.rootDir == g.rootDir ||
              o.files.any((f) => f.path.startsWith(prefix))),
    );
    if (shared) return false;
    final imported =
        g.rootDir.lastIndexOf('/') > 0 &&
        scan.roots.any(
          (r) => r == '/' || r == g.rootDir || g.rootDir.startsWith('$r/'),
        );
    if (imported) return true;
    final folder = normTitle(baseOf(g.rootDir));
    return [g.anchorTitle, match.title, match.englishTitle, match.originalTitle]
        .whereType<String>()
        .map(normTitle)
        .any((t) => t.isNotEmpty && folder.contains(t));
  }

  // ---- junk ---------------------------------------------------------------

  void _junk(List<MediaGroup> processed, List<MediaGroup> skipped) {
    bool under(String path, Iterable<MediaGroup> gs) =>
        gs.any((g) => path.startsWith('${g.rootDir}/'));
    for (final f in scan.unassigned) {
      if (f.role != FileRole.junk) continue;
      if (under(f.path, skipped) && !under(f.path, processed)) continue;
      var path = f.path;
      for (final e in renamedSeasons.entries) {
        if (path.startsWith('${e.key}/')) {
          path = '${e.value}${path.substring(e.key.length)}';
          break;
        }
      }
      for (final e in renamedRoots.entries) {
        if (path.startsWith('${e.key}/')) {
          path = '${e.value}${path.substring(e.key.length)}';
          break;
        }
      }
      deleteOps.add(
        RenameOp(
          id: OpId('d-${stableHash(f.path)}'),
          kind: OpKind.delete,
          phase: ExecPhase.cleanup,
          src: path,
          dst: '',
          selected: opts.deleteJunk,
        ),
      );
    }
  }

  // ---- helpers ------------------------------------------------------------

  /// [local] is the title already on disk: when TMDB's differs only in
  /// punctuation ("全金属狂潮" vs "全金属狂潮！"), keep it rather than rename
  /// every file for one character.
  Map<String, Object?> _titleVars(
    Candidate c,
    NamingOptions o, [
    String? local,
  ]) {
    var en = c.englishTitle;
    if (en != null && en.trim().isEmpty) en = null;
    final englishOnly =
        o.titleLanguage == TitleLanguage.englishFirst && !o.bilingual;
    if (englishOnly) {
      en ??= c.title;
    } else if (o.customTemplate == null &&
        en != null &&
        normTitle(en) == normTitle(c.title)) {
      en = null;
    }
    String bare(String s) => s.replaceAll(_punct, '');
    final keepLocal =
        local != null && local != c.title && bare(local) == bare(c.title);
    return {
      'title': keepLocal ? local : c.title,
      'en_title': en,
      'original_title': c.originalTitle,
      'tmdbid': c.tmdbId,
      'tmdb_tag': '{tmdb-${c.tmdbId}}',
    };
  }

  /// Index 0 = season 1; seasons without episodes are 0. Season 0 is ignored.
  List<int> _denseCounts(Map<int, int> bySeason) {
    final max = bySeason.keys.fold(0, (m, s) => s > m ? s : m);
    return [for (var s = 1; s <= max; s++) bySeason[s] ?? 0];
  }

  bool _overflow(SeasonStrategy st, EpisodeRef r, List<int> counts) {
    if (counts.isEmpty || r.season < 1) return false;
    final total = counts.fold(0, (a, b) => a + b);
    return switch (st) {
      SeasonStrategy.mergeIntoOne ||
      SeasonStrategy.splitKeepEpisode => r.episode > total,
      _ => r.season > counts.length || r.episode > counts[r.season - 1],
    };
  }

  /// Titles by (output season, episode); failures just mean no title.
  Future<Map<EpisodeRef, String>> _episodeTitles(
    int id,
    EpisodeGroup? epGroup,
    SeasonStrategy strategy,
    List<_Item> items,
  ) async {
    final seasonCache = <int, Map<int, String?>>{};
    Future<String?> titleOf(int season, int ep) async {
      if (!seasonCache.containsKey(season)) {
        try {
          seasonCache[season] = {
            for (final e in await metadata.season(id, season))
              e.number: e.title,
          };
        } catch (_) {
          seasonCache[season] = {};
        }
      }
      return seasonCache[season]![ep];
    }

    final out = <EpisodeRef, String>{};
    for (final r in {for (final it in items) ?it.ref}) {
      var orig = r;
      if (epGroup != null) {
        final s = epGroup.seasons.where((s) => s.order == r.season).firstOrNull;
        if (s == null) continue;
        var idx = r.episode - 1;
        if (strategy == SeasonStrategy.splitKeepEpisode) {
          for (final prev in epGroup.seasons) {
            if (prev.order >= r.season) break;
            idx -= prev.episodes.length;
          }
        }
        if (idx < 0 || idx >= s.episodes.length) continue;
        orig = s.episodes[idx];
      }
      final t = await titleOf(orig.season, orig.episode);
      if (t != null && t.isNotEmpty) out[r] = t;
    }
    return out;
  }

  List<PlanConflict> _conflicts(List<RenameOp> ops) {
    final moves = [
      for (final o in ops)
        if (o.kind == OpKind.relocate && o.selected) o,
    ];
    final sources = {for (final o in moves) o.src};
    final byDst = <String, List<RenameOp>>{};
    for (final o in moves) {
      byDst.putIfAbsent(o.dst, () => []).add(o);
    }
    return [
      for (final MapEntry(key: dst, value: list) in byDst.entries)
        if (list.length > 1)
          PlanConflict(
            ops: [for (final o in list) o.id],
            path: dst,
            reason: '有 ${list.length} 个文件会被命名为同一个路径',
          )
        else if (existing.contains(dst) && !sources.contains(dst))
          PlanConflict(
            ops: [list.single.id],
            path: dst,
            reason: '目标位置已存在同名文件或文件夹',
          ),
    ];
  }
}

/// A trailing id tag: 「{tmdb-1}」, 「[tmdbid=1]」.
final _idTag = RegExp(
  r'\s*(?:\{[^}]*\}|\[tmdb[^\]]*\])\s*$',
  caseSensitive: false,
);
String _untagged(String name) => name.replaceAll(_idTag, '');

/// 「标题 (2020)」 and nothing after the year.
final _titleYear = RegExp(r'\S \((?:19|20)\d{2}\)$');

/// Looks like a file name (has an extension), not a folder.
final _fileLike = RegExp(r'\.[A-Za-z][A-Za-z0-9]{1,3}$');
