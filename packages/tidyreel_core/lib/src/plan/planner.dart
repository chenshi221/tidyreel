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

const _overflowWarning = '超出 TMDB 总集数';

/// Owner: Agent D. Turns a recognized scan + user decisions into ops, with conflict
/// detection (PLAN §4.3 rule 1). Subtitles follow their video, specials go to
/// Season 00, extras to Extras/, junk becomes unselected delete ops.

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

/// A subtitle or sidecar planned alongside [_Item] or independently via override.
class _Companion {
  final ScanFile file;
  final FileOverride? override;
  final _Item? followed;
  final String remainder;
  final ScanFile? fallbackVideo;
  bool extra = false;
  EpisodeRef? ref;
  final warnings = <String>[];
  bool selected = false;

  _Companion(
    this.file,
    this.override,
    this.followed,
    this.remainder, {
    this.fallbackVideo,
  });
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
  final _scanFilePaths = <String>{};
  final _movedSrcs = <String>{};
  final _plannedFinalDsts = <String>{};
  final _seasonCache = <(int, int), Future<List<Episode>>>{};
  final _movieCache = <int, Future<MovieDetail?>>{};

  _PlanBuilder(
    this.metadata,
    this.scan,
    this.decisions,
    this.opts,
    this.existing,
  );

  Future<List<Episode>> _fetchSeason(int tmdbId, int season) =>
      _seasonCache.putIfAbsent((tmdbId, season), () async {
        try {
          return await metadata.season(tmdbId, season);
        } on Object {
          return const <Episode>[];
        }
      });

  Future<Map<int, List<Episode>>> _fetchSeasons(
    int tmdbId,
    Iterable<int> seasons,
  ) async {
    final unique = seasons.toSet().toList();
    if (unique.isEmpty) return const {};
    final results = await Future.wait([
      for (final s in unique) _fetchSeason(tmdbId, s),
    ]);
    return {for (var i = 0; i < unique.length; i++) unique[i]: results[i]};
  }

  Future<MovieDetail?> _fetchMovie(int tmdbId) =>
      _movieCache.putIfAbsent(tmdbId, () async {
        try {
          return await metadata.movie(tmdbId);
        } on Object {
          return null;
        }
      });

  Future<RenamePlan> run() async {
    knownDirs
      ..addAll(existing.where((p) => !_fileLike.hasMatch(baseOf(p))))
      ..addAll(scan.roots);
    for (final f in [
      ...scan.groups.expand((g) => g.files),
      ...scan.unassigned,
    ]) {
      _scanFilePaths.add(f.path);
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
    if (!opts.scrapeOnly) {
      _junk(processed, skipped);
    }

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
    final regular = [
      for (final s in show.seasons)
        if (s.number > 0) s.number,
    ];
    final bySeason = await _fetchSeasons(tmdbId, regular);
    final out = <DateTime, EpisodeRef>{};
    for (final s in regular) {
      for (final e in bySeason[s] ?? const <Episode>[]) {
        final d = e.airDate;
        if (d == null) continue;
        out.putIfAbsent(
          DateTime.utc(d.year, d.month, d.day),
          () => EpisodeRef(s, e.number),
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
    final allVideos = [
      for (final f in g.files)
        if (f.role == FileRole.video) f,
    ];
    final videos = [
      for (final f in allVideos)
        if (!(d.overrides[f.path]?.ignore ?? false)) f,
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
          d.match == null &&
          (p == null || p.confidence < opts.confidenceThreshold) &&
          !(bareRun && p != null && p.episodes.isEmpty && p.absolute != null);
      if (kind == MediaKind.extra) {
        it.extra = true;
        items.add(it);
        continue;
      }
      if (!isTv || v.isDiscDir) {
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
        pending[i].ref = inverse[refs[i]] ?? refs[i];
      }
      // Validate all resolved TV refs, including manual overrides and specials.
      for (final it in items) {
        final r = it.ref;
        if (it.extra || r == null) continue;
        if (r.season < 0) it.warnings.add('季号无效');
        if (r.episode < 1) {
          it.warnings.add('集号无效');
        } else if (r.season >= 0 && _overflow(d.strategy, r, tmdbCounts)) {
          it.warnings.add(_overflowWarning);
        }
      }
    }
    for (final it in items) {
      // A per-file decision confirms confidence warnings, not invalid episodes.
      final confirmed = d.overrides.containsKey(it.file.path);
      it.selected =
          (!lowMatch || confirmed) &&
          it.warnings.every(
            (w) => w == _overflowWarning || (confirmed && w == '识别置信度较低'),
          );
      if (lowMatch) it.warnings.add('片名匹配置信度较低');
    }

    // --- resolve subtitles and sidecars (either following a video or explicit)
    final byPath = {for (final it in items) it.file.path: it};
    final itemFiles = [for (final it in items) it.file];
    final companions = <_Companion>[];
    for (final f in g.files) {
      if (f.role != FileRole.subtitle && f.role != FileRole.sidecar) continue;
      final ov = d.overrides[f.path];
      if (ov?.ignore ?? false) continue;
      final hasExplicit =
          ov != null &&
          (ov.season != null ||
              ov.episode != null ||
              ov.kind == MediaKind.extra ||
              ov.kind == MediaKind.special);
      var mItem = matchVideo(f, itemFiles);
      if (mItem == null &&
          itemFiles.length == 1 &&
          f.role == FileRole.subtitle) {
        mItem = FollowMatch(itemFiles.first, '');
      }
      var mAll = mItem ?? matchVideo(f, allVideos);
      if (mAll == null &&
          allVideos.length == 1 &&
          f.role == FileRole.subtitle) {
        mAll = FollowMatch(allVideos.first, '');
      }
      final it = mItem == null ? null : byPath[mItem.video.path];
      if (!hasExplicit && it != null) {
        final c = _Companion(f, ov, it, mItem!.remainder);
        c.selected =
            it.selected ||
            (ov != null &&
                it.warnings.every(
                  (w) =>
                      w == _overflowWarning ||
                      w == '识别置信度较低' ||
                      w == '片名匹配置信度较低',
                ));
        companions.add(c);
        continue;
      }
      if (!hasExplicit && ov == null) continue;
      final c = _Companion(
        f,
        ov,
        null,
        mAll?.remainder ?? '',
        fallbackVideo: mAll?.video,
      );
      final kind =
          ov.kind ??
          (mAll?.video.parsed?.kind == MediaKind.extra
              ? MediaKind.extra
              : MediaKind.unknown);
      if (kind == MediaKind.extra) {
        c.extra = true;
        c.selected = true;
        companions.add(c);
        continue;
      }
      if (!isTv) {
        c.selected = true;
        if (lowMatch) c.warnings.add('片名匹配置信度较低');
        companions.add(c);
        continue;
      }
      final pf = f.parsed;
      final pv = mAll?.video.parsed;
      final n =
          pf?.episodes.firstOrNull ??
          pf?.absolute ??
          pv?.episodes.firstOrNull ??
          pv?.absolute;
      final ep = ov.episode ?? n;
      if (ep == null) continue;
      final isSpecial =
          kind == MediaKind.special ||
          ov.season == 0 ||
          (ov.season == null && pf?.season == 0);
      final season =
          ov.season ?? (isSpecial ? 0 : pf?.season ?? pv?.season ?? 1);
      final r = EpisodeRef(season, ep);
      c.ref = r;
      if (r.season < 0) c.warnings.add('季号无效');
      if (r.episode < 1) {
        c.warnings.add('集号无效');
      } else if (r.season >= 0 && _overflow(d.strategy, r, tmdbCounts)) {
        c.warnings.add(_overflowWarning);
      }
      c.selected = c.warnings.every(
        (w) => w == _overflowWarning || w == '识别置信度较低',
      );
      if (lowMatch) c.warnings.add('片名匹配置信度较低');
      companions.add(c);
    }

    // --- episode titles
    final wantScrape = opts.scrape || opts.scrapeOnly;
    final wantTitles =
        isTv &&
        (naming.episodeTitle ||
            (naming.customTemplate?.contains('episode_title') ?? false) ||
            (wantScrape && epGroup != null));
    final titles = wantTitles
        ? await _episodeTitles(match.tmdbId, epGroup, d.strategy, tmdbCounts, [
            for (final it in items) ?it.ref,
            for (final c in companions) ?c.ref,
          ])
        : const <EpisodeRef, String>{};

    // --- 仅刮削补全: write .nfo and artwork beside existing files; zero moves/mkdirs/deletes.
    if (opts.scrapeOnly) {
      for (final it in items) {
        if (it.file.isDiscDir) {
          it.dstDir = it.file.path;
          it.outName = 'movie';
        } else {
          it.dstDir = dirOf(it.file.path);
          it.outName = it.file.name;
        }
      }
      await _scrape(
        g,
        match,
        show,
        epGroup,
        d.strategy,
        tmdbCounts,
        titles,
        items,
        g.rootDir,
        (dir) => dir,
      );
      return;
    }

    // --- folders
    final groupSelected =
        items.any((it) => it.selected) || companions.any((c) => c.selected);
    final plannedRefs = <EpisodeRef>[
      for (final it in items)
        if (!it.extra && it.ref != null) it.ref!,
      for (final c in companions)
        if (c.followed == null && !c.extra && c.ref != null) c.ref!,
    ];
    // A movie without a zh-CN title: movie() may find a Chinese one.
    Candidate? movieInfo;
    if (!isTv && !hasHan(match.title)) {
      movieInfo = (await _fetchMovie(match.tmdbId))?.info;
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

    // --- BDMV / VIDEO_TS disc units: relocate the folder as an atomic unit,
    // never touching inner stream files and never adding a video extension.
    final discItems = [
      for (final it in items)
        if (it.file.isDiscDir) it,
    ];
    if (discItems.isNotEmpty && discItems.length == items.length) {
      String? libTypeBase;
      if (opts.mode == OrganizeMode.moveToLibrary) {
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
        libTypeBase = base.isEmpty ? '/' : base;
      }
      for (final it in discItems) {
        it.dstDir = opts.mode == OrganizeMode.inPlace
            ? dirOf(it.file.path)
            : libTypeBase!;
        it.newBase = folderName;
      }
      _disambiguateVersions(discItems, isDisc: true);
      for (final it in discItems) {
        final part = it.file.parsed?.partLabel?.trim();
        if (part != null && part.isNotEmpty) {
          it.newBase = '${it.newBase}-${sanitizeName(part)}';
        }
        final discDst = joinPath(it.dstDir, it.newBase);
        if (it.file.path != discDst) {
          renamedRoots[it.file.path] = discDst;
        }
        if (it.selected && it.file.path != discDst) {
          _movedSrcs.add(it.file.path);
        }
        folderOps.add(
          RenameOp(
            id: OpId('f-${stableHash(it.file.path)}'),
            kind: OpKind.relocate,
            phase: ExecPhase.folders,
            src: it.file.path,
            dst: discDst,
            group: g.id,
            selected: it.selected,
            warning: it.warnings.isNotEmpty ? it.warnings.join('；') : null,
          ),
        );
        it.dstDir = discDst;
        it.outName = 'movie';
      }
      if (wantScrape) {
        await _scrape(
          g,
          match,
          show,
          epGroup,
          d.strategy,
          tmdbCounts,
          titles,
          discItems,
          discItems.first.dstDir,
          (dir) => dir,
        );
      }
      return;
    }
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
        final onDisk =
            finalBase != g.rootDir &&
            existing.contains(finalBase) &&
            !_fileLike.hasMatch(baseOf(finalBase));
        if ((claimed != null || onDisk) && !d.separate) {
          // Files go under the other group's old root (renamed later) or
          // straight into the existing folder; this root keeps its name.
          curBase = claimed?.base ?? finalBase;
          mergeInto = finalBase;
          _noteMerge(g, finalBase, claimed?.group, onDisk, plannedRefs);
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
      final onDisk =
          existing.contains(curBase) && !_fileLike.hasMatch(baseOf(curBase));
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
        _noteMerge(g, curBase, claimed?.group, onDisk, plannedRefs);
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
        plannedRefs.every((r) => r.season == 1);

    ({String dstDir, String newBase}) renderName({
      required ScanFile file,
      required EpisodeRef? ref,
      required bool manual,
      ScanFile? metaSource,
    }) {
      final srcFile = metaSource ?? file;
      final p = srcFile.parsed;
      final ext = extOf(file.name);
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
        'lang': _parsedLang(srcFile),
        'ext': ext,
      };
      late final String dstDir;
      if (isTv) {
        final r = ref!;
        final span =
            !manual &&
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
        dstDir = flat
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
        dstDir = curBase;
      }
      final newBase = sanitizeName(
        applyRewrites(renderTemplate(template, vars), naming.rewrites),
      );
      return (dstDir: dstDir, newBase: newBase);
    }

    for (final it in items) {
      final v = it.file;
      if (it.extra) {
        it.dstDir = joinPath(curBase, 'Extras');
        it.newBase = stem(v.name);
        continue;
      }
      final rendered = renderName(file: v, ref: it.ref, manual: it.manual);
      it.dstDir = rendered.dstDir;
      it.newBase = rendered.newBase;
    }
    _disambiguateVersions(items);
    for (final it in items) {
      if (it.extra || it.file.isDiscDir) continue;
      final part = it.file.parsed?.partLabel?.trim();
      if (part != null && part.isNotEmpty) {
        final ext = extOf(it.file.name);
        it.newBase =
            '${_stripTrailingExt(it.newBase, ext)}-${sanitizeName(part)}';
      }
    }
    if (isTv && opts.mode == OrganizeMode.inPlace) {
      _reuseSeasonFolders(g, items, curBase);
    }
    final groupFileOpsStart = fileOps.length;
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

    // --- emit subtitles and sidecars
    final seasonByDst = {
      for (final e in renamedSeasons.entries) e.value: e.key,
    };
    final renderedCompanion = <_Companion, ({String dstDir, String newBase})>{};
    final subBaseCounts = <String, int>{};
    for (final c in companions) {
      final f = c.file;
      final followed = c.followed;
      String dstDir;
      String base;
      if (followed != null) {
        dstDir = followed.dstDir;
        base = followed.newBase;
      } else if (c.extra) {
        dstDir = joinPath(curBase, 'Extras');
        base = stem(f.name);
      } else {
        final rendered = renderName(
          file: f,
          ref: c.ref,
          manual: true,
          metaSource: c.fallbackVideo,
        );
        dstDir = seasonByDst[rendered.dstDir] ?? rendered.dstDir;
        base = rendered.newBase;
        renderedCompanion[c] = (dstDir: dstDir, newBase: base);
      }
      if (f.role == FileRole.subtitle && !(followed?.extra ?? c.extra)) {
        final ext = extOf(f.name);
        final lang = langFromRemainder(c.remainder) ?? _parsedLang(f);
        final flags = _mergedSubFlags(f, c.remainder);
        final std = _canonicalSubFlags(flags);
        final cleanBase = _stripTrailingExt(
          base,
          extOf(followed?.file.name ?? ''),
        );
        final baseKey =
            '$dstDir/$cleanBase${lang == null ? '' : '.$lang'}${std.isEmpty ? '' : '.${std.join('.')}'}.$ext'
                .toLowerCase();
        subBaseCounts[baseKey] = (subBaseCounts[baseKey] ?? 0) + 1;
      }
    }

    final subTargets = <String, int>{};
    String formatSubName({
      required ScanFile f,
      required String remainder,
      required String dstDir,
      required String base,
      required String ext,
    }) {
      final lang = langFromRemainder(remainder) ?? _parsedLang(f);
      final flags = _mergedSubFlags(f, remainder);
      final std = _canonicalSubFlags(flags);
      final baseKey =
          '$dstDir/$base${lang == null ? '' : '.$lang'}${std.isEmpty ? '' : '.${std.join('.')}'}.$ext'
              .toLowerCase();
      final addBilingual =
          flags.contains('bilingual') && (subBaseCounts[baseKey] ?? 0) > 1;
      final suffixParts = <String>[
        ?lang,
        if (addBilingual) 'bilingual',
        ...std,
      ];
      final prefix = suffixParts.isEmpty
          ? base
          : '$base.${suffixParts.join('.')}';
      final key = '$dstDir/$prefix.$ext'.toLowerCase();
      final n = (subTargets[key] ?? 0) + 1;
      subTargets[key] = n;
      return n == 1 ? '$prefix.$ext' : '$prefix.$n.$ext';
    }

    for (final c in companions) {
      final f = c.file;
      final ext = extOf(f.name);
      final followed = c.followed;
      if (followed != null) {
        final followedBase = _stripTrailingExt(
          followed.newBase,
          extOf(followed.file.name),
        );
        String name;
        if (followed.extra) {
          name = f.name;
        } else if (f.role == FileRole.subtitle) {
          name = formatSubName(
            f: f,
            remainder: c.remainder,
            dstDir: followed.dstDir,
            base: followedBase,
            ext: ext,
          );
        } else {
          name = '$followedBase${c.remainder}.$ext';
        }
        _mkdir(followed.dstDir, g.id, selected: c.selected);
        _emit(followed, name, g.id, source: f, selected: c.selected);
        continue;
      }

      late final String dstDir;
      late final String name;
      if (c.extra) {
        dstDir = joinPath(curBase, 'Extras');
        name = f.name;
      } else {
        final r = renderedCompanion[c]!;
        dstDir = r.dstDir;
        if (f.role == FileRole.subtitle) {
          name = formatSubName(
            f: f,
            remainder: c.remainder,
            dstDir: dstDir,
            base: r.newBase,
            ext: ext,
          );
        } else {
          name = '${r.newBase}${c.remainder}.$ext';
        }
      }
      _mkdir(dstDir, g.id, selected: c.selected);
      final dst = joinPath(dstDir, name);
      if (c.selected && f.path != dst) _movedSrcs.add(f.path);
      fileOps.add(
        RenameOp(
          id: OpId('r-${stableHash(f.path)}'),
          kind: OpKind.relocate,
          phase: ExecPhase.files,
          src: f.path,
          dst: dst,
          group: g.id,
          selected: c.selected,
          warning: c.warnings.isNotEmpty ? c.warnings.join('；') : null,
        ),
      );
    }

    if (wantScrape) {
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

      for (var i = groupFileOpsStart; i < fileOps.length; i++) {
        final o = fileOps[i];
        if (o.selected) {
          _plannedFinalDsts.add(
            joinPath(finalDir(dirOf(o.dst)), baseOf(o.dst)),
          );
        }
      }
      await _scrape(
        g,
        match,
        show,
        epGroup,
        d.strategy,
        tmdbCounts,
        titles,
        items,
        showDir,
        finalDir,
      );
    }
  }

  /// Paths [_scrape] already wrote this plan (two groups merging into one
  /// show folder share its tvshow.nfo).
  final scraped = <String>{};

  String? _preRenamePath(String dst) {
    String? cur;
    for (final e in renamedRoots.entries) {
      if (dst == e.value) {
        cur = e.key;
        break;
      } else if (dst.startsWith('${e.value}/')) {
        cur = '${e.key}${dst.substring(e.value.length)}';
        break;
      }
    }
    final base = cur ?? dst;
    for (final e in renamedSeasons.entries) {
      if (base == e.value) {
        return e.key;
      } else if (base.startsWith('${e.value}/')) {
        return '${e.key}${base.substring(e.value.length)}';
      }
    }
    return cur;
  }

  bool _alreadyThere(String dst) {
    bool has(String path) =>
        existing.contains(path) ||
        (_scanFilePaths.contains(path) && !_movedSrcs.contains(path));
    if (has(dst) || _plannedFinalDsts.contains(dst)) return true;
    final pre = _preRenamePath(dst);
    return pre != null && has(pre);
  }

  void _writeOp(
    String dst,
    String source,
    GroupId gid, {
    required bool selected,
  }) {
    if (!scraped.add(dst)) return;
    final there = _alreadyThere(dst);
    final isNfo = dst.toLowerCase().endsWith('.nfo');
    final canOverwrite = there && isNfo && opts.overwriteNfo;
    deleteOps.add(
      RenameOp(
        id: OpId('w-${stableHash(dst)}'),
        kind: OpKind.write,
        phase: ExecPhase.cleanup,
        src: source,
        dst: dst,
        group: gid,
        // Never overwrite unless overwriteNfo is explicitly enabled for .nfo files.
        selected: selected && (!there || canOverwrite),
        warning: there && !canOverwrite ? '已存在，保留原文件' : null,
        overwrite: isNfo && opts.overwriteNfo,
      ),
    );
  }

  /// 刮削模式: .nfo files and TMDB artwork for one group.
  Future<void> _scrape(
    MediaGroup g,
    Candidate match,
    ShowDetail? show,
    EpisodeGroup? epGroup,
    SeasonStrategy strategy,
    List<int> tmdbCounts,
    Map<EpisodeRef, String> titles,
    List<_Item> items,
    String showDir,
    String Function(String dir) finalDir,
  ) async {
    final on = items.any((it) => it.selected);
    String img(String path, String size) =>
        'https://image.tmdb.org/t/p/$size$path';
    void art(String dir, Candidate c, Candidate fallback) {
      final same = fallback.tmdbId == c.tmdbId;
      final poster = c.posterPath ?? (same ? fallback.posterPath : null);
      final backdrop = c.backdropPath ?? (same ? fallback.backdropPath : null);
      final clearLogo =
          c.clearLogoPath ?? (same ? fallback.clearLogoPath : null);
      final landscape =
          c.landscapePath ?? (same ? fallback.landscapePath : null);
      if (poster != null) {
        _writeOp('$dir/poster.jpg', img(poster, 'w780'), g.id, selected: on);
      }
      if (backdrop != null) {
        _writeOp('$dir/fanart.jpg', img(backdrop, 'w1280'), g.id, selected: on);
      }
      if (clearLogo != null) {
        _writeOp(
          '$dir/clearlogo.png',
          img(clearLogo, 'original'),
          g.id,
          selected: on,
        );
      }
      if (landscape != null) {
        _writeOp(
          '$dir/landscape.jpg',
          img(landscape, 'w1280'),
          g.id,
          selected: on,
        );
      }
    }

    if (match.kind == MediaKind.movie) {
      final info = (await _fetchMovie(match.tmdbId))?.info ?? match;
      final main = items.where((it) => !it.extra).toList();
      if (main.isEmpty) return;
      final dir = finalDir(main.first.dstDir);
      for (final it in main) {
        final nfoPath = it.file.isDiscDir
            ? '${finalDir(it.dstDir)}/movie.nfo'
            : '${finalDir(it.dstDir)}/${stem(it.outName)}.nfo';
        _writeOp(
          nfoPath,
          '$writeTextPrefix${movieNfo(info)}',
          g.id,
          selected: it.selected,
        );
      }
      art(dir, info, match);
      return;
    }

    final s = show ?? await metadata.show(match.tmdbId);
    _writeOp(
      '$showDir/tvshow.nfo',
      '$writeTextPrefix${tvShowNfo(s)}',
      g.id,
      selected: on,
    );
    art(showDir, s.info, match);

    final episodeItems = [
      for (final it in items)
        if (!it.extra && it.ref != null) it,
    ];
    final tmdbRefs = <EpisodeRef, EpisodeRef>{};
    if (epGroup == null) {
      for (final it in episodeItems) {
        final orig = _resolveTmdbRef(it.ref!, strategy, tmdbCounts, null);
        if (orig != null) tmdbRefs[it.ref!] = orig;
      }
    }
    final fetchedSeasons = epGroup == null
        ? await _fetchSeasons(
            match.tmdbId,
            tmdbRefs.values.map((r) => r.season),
          )
        : const <int, List<Episode>>{};
    final episodesBySeason = <int, Map<int, Episode>>{
      for (final e in fetchedSeasons.entries)
        e.key: {for (final ep in e.value) ep.number: ep},
    };

    final seasons = <int>{};
    for (final it in episodeItems) {
      final r = it.ref!;
      seasons.add(r.season);
      final dir = finalDir(it.dstDir);
      final orig = tmdbRefs[r];
      final e = orig == null
          ? null
          : episodesBySeason[orig.season]?[orig.episode];
      final base = stem(it.outName);
      _writeOp(
        '$dir/$base.nfo',
        '$writeTextPrefix${episodeNfo(show: s.info, season: r.season, episode: r.episode, info: e, title: titles[r])}',
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
    if (existing.contains(exact) && !_fileLike.hasMatch(folderName)) {
      return exact;
    }
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
    List<EpisodeRef> refs,
  ) => merges.add(
    PlanMerge(
      group: g.id,
      into: into,
      exists: exists,
      withGroup: withGroup,
      seasons: {for (final r in refs) r.season}.toList()..sort(),
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
      final itPaths = {for (final it in its) it.file.path};
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
                itPaths.contains(f.path),
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
  void _emit(
    _Item it,
    String name,
    GroupId gid, {
    ScanFile? source,
    bool? selected,
  }) {
    final src = source ?? it.file;
    // Same name still gets an op: running it records the file as organized
    // (the executor treats src == dst as done, and undo as a no-op).
    final dst = joinPath(it.dstDir, name);
    final sel = selected ?? it.selected;
    if (sel && src.path != dst) _movedSrcs.add(src.path);
    fileOps.add(
      RenameOp(
        id: OpId('r-${stableHash(src.path)}'),
        kind: OpKind.relocate,
        phase: ExecPhase.files,
        src: src.path,
        dst: dst,
        group: gid,
        selected: sel,
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

  // ---- multi-version & subtitle helpers -----------------------------------

  static const _orderedSubFlags = ['forced', 'default', 'sdh'];

  static String _stripTrailingExt(String base, String ext) {
    if (ext.isNotEmpty &&
        base.toLowerCase().endsWith('.${ext.toLowerCase()}')) {
      return base.substring(0, base.length - ext.length - 1);
    }
    return base;
  }

  static Set<String> _mergedSubFlags(ScanFile f, String remainder) {
    final out = <String>{};
    for (final flag in f.parsed?.subFlags ?? const <String>[]) {
      final norm = flag.trim().toLowerCase();
      if (norm.isNotEmpty) out.add(norm);
    }
    for (final flag in subFlagsFromRemainder(remainder)) {
      final norm = flag.trim().toLowerCase();
      if (norm.isNotEmpty) out.add(norm);
    }
    return out;
  }

  static List<String> _canonicalSubFlags(Set<String> flags) => [
    for (final flag in _orderedSubFlags)
      if (flags.contains(flag)) flag,
  ];

  static String? _editionTag(ParsedName? p) {
    final raw = p?.edition?.trim();
    return raw == null || raw.isEmpty ? null : raw;
  }

  static String? _techTag(ParsedName? p) {
    if (p == null) return null;
    for (final candidate in [
      p.extraInfo,
      p.probe?.extraInfoSummary,
      p.resolution,
      p.probe?.resolution,
    ]) {
      final s = candidate?.trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// Appends VidHub / Emby / Plex multi-version ` - <tag>` suffixes when two or
  /// more videos in the same group render to the exact same target name but
  /// differ by edition, extraInfo/probe tech tags, or resolution. True
  /// duplicates (identical tags) are left untouched so [_conflicts] catches them.
  void _disambiguateVersions(List<_Item> items, {bool isDisc = false}) {
    final buckets = <String, List<_Item>>{};
    for (final it in items) {
      if (it.extra) continue;
      if (!isDisc && it.file.isDiscDir) continue;
      final ext = isDisc ? '' : extOf(it.file.name);
      final cleanBase = isDisc
          ? it.newBase
          : _stripTrailingExt(it.newBase, ext);
      final part = it.file.parsed?.partLabel?.trim();
      final partSuffix = part == null || part.isEmpty
          ? ''
          : '-${sanitizeName(part)}';
      final key = isDisc
          ? '${it.dstDir}/$cleanBase$partSuffix'.toLowerCase()
          : '${it.dstDir}/$cleanBase$partSuffix.$ext'.toLowerCase();
      (buckets[key] ??= []).add(it);
    }

    bool allDistinct(List<String?> tags) {
      if (!tags.any((t) => t != null && t.isNotEmpty)) return false;
      final seen = <String>{};
      for (final t in tags) {
        if (!seen.add((t ?? '').toLowerCase())) return false;
      }
      return true;
    }

    for (final bucket in buckets.values) {
      if (bucket.length < 2) continue;
      final editions = [for (final it in bucket) _editionTag(it.file.parsed)];
      final techs = [for (final it in bucket) _techTag(it.file.parsed)];
      final combined = [
        for (var i = 0; i < bucket.length; i++)
          () {
            final parts = <String>[?editions[i], ?techs[i]];
            return parts.isEmpty ? null : parts.join(' ');
          }(),
      ];

      List<String?>? chosen;
      if (allDistinct(editions)) {
        chosen = editions;
      } else if (allDistinct(techs)) {
        chosen = techs;
      } else if (allDistinct(combined)) {
        chosen = combined;
      } else {
        final sigs = {for (final t in combined) (t ?? '').toLowerCase()};
        if (sigs.length >= 2) chosen = combined;
      }
      if (chosen == null) continue;

      for (var i = 0; i < bucket.length; i++) {
        final tag = chosen[i];
        if (tag == null || tag.isEmpty) continue;
        final it = bucket[i];
        final ext = isDisc ? '' : extOf(it.file.name);
        final cleanBase = isDisc
            ? it.newBase
            : _stripTrailingExt(it.newBase, ext);
        it.newBase = '$cleanBase - ${sanitizeName(tag)}';
      }
    }
  }

  // ---- junk ---------------------------------------------------------------

  void _junk(List<MediaGroup> processed, List<MediaGroup> skipped) {
    bool under(String path, Iterable<MediaGroup> gs) =>
        gs.any((g) => path.startsWith('${g.rootDir}/'));
    for (final f in scan.unassigned) {
      final override = opts.unassignedDeletes[f.path];
      if (override == null) {
        if (f.role != FileRole.junk) continue;
        if (under(f.path, skipped) && !under(f.path, processed)) continue;
      } else if (!override) {
        if (f.role != FileRole.junk) continue;
        if (under(f.path, skipped) && !under(f.path, processed)) continue;
      }
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
          selected: override ?? opts.deleteJunk,
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
    final keepLocal =
        local != null &&
        local != c.title &&
        stripPunct(local) == stripPunct(c.title);
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

  /// Maps an output [EpisodeRef] back to its TMDB `(season, episode)`.
  EpisodeRef? _resolveTmdbRef(
    EpisodeRef r,
    SeasonStrategy strategy,
    List<int> tmdbCounts,
    EpisodeGroup? epGroup,
  ) {
    if (epGroup != null) {
      if (strategy == SeasonStrategy.mergeIntoOne && r.season == 1) {
        final regular = [
          for (final s in epGroup.seasons)
            if (s.order > 0) s,
        ]..sort((a, b) => a.order.compareTo(b.order));
        var rem = r.episode;
        for (final s in regular) {
          if (rem <= s.episodes.length) {
            return rem >= 1 ? s.episodes[rem - 1] : null;
          }
          rem -= s.episodes.length;
        }
        return null;
      }
      final s = epGroup.seasons.where((s) => s.order == r.season).firstOrNull;
      if (s == null) return null;
      var idx = r.episode - 1;
      if (strategy == SeasonStrategy.splitKeepEpisode && r.season > 0) {
        for (final prev in epGroup.seasons) {
          if (prev.order <= 0 || prev.order >= r.season) continue;
          idx -= prev.episodes.length;
        }
      }
      if (idx < 0 || idx >= s.episodes.length) return null;
      return s.episodes[idx];
    }
    if (strategy == SeasonStrategy.mergeIntoOne &&
        r.season == 1 &&
        tmdbCounts.isNotEmpty) {
      var rem = r.episode;
      if (rem < 1) return null;
      for (var s = 1; s <= tmdbCounts.length; s++) {
        final c = tmdbCounts[s - 1];
        if (rem <= c) return EpisodeRef(s, rem);
        rem -= c;
      }
      return null;
    }
    return r;
  }

  /// Titles by (output season, episode); failures just mean no title.
  Future<Map<EpisodeRef, String>> _episodeTitles(
    int id,
    EpisodeGroup? epGroup,
    SeasonStrategy strategy,
    List<int> tmdbCounts,
    List<EpisodeRef> targetRefs,
  ) async {
    final mapped = <EpisodeRef, EpisodeRef>{};
    for (final r in targetRefs.toSet()) {
      final orig = _resolveTmdbRef(r, strategy, tmdbCounts, epGroup);
      if (orig != null) mapped[r] = orig;
    }
    final fetched = await _fetchSeasons(
      id,
      mapped.values.map((orig) => orig.season),
    );
    final bySeason = <int, Map<int, String?>>{
      for (final e in fetched.entries)
        e.key: {for (final ep in e.value) ep.number: ep.title},
    };
    final out = <EpisodeRef, String>{};
    for (final MapEntry(key: r, value: orig) in mapped.entries) {
      final t = bySeason[orig.season]?[orig.episode];
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
