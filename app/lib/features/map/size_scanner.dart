import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/folder_stats_store.dart';

/// What a folder (or file) holds, by bytes.
@immutable
class FolderStats {
  /// Video bytes a done op produced (or that sit in a folder one produced).
  final int organized;

  /// Video bytes nothing has organized yet.
  final int unorganized;

  /// Subtitles, sidecars, junk and everything else.
  final int other;
  final int files;

  const FolderStats({
    this.organized = 0,
    this.unorganized = 0,
    this.other = 0,
    this.files = 0,
  });

  static const zero = FolderStats();

  int get total => organized + unorganized + other;
  int get video => organized + unorganized;

  FolderStats operator +(FolderStats o) => FolderStats(
    organized: organized + o.organized,
    unorganized: unorganized + o.unorganized,
    other: other + o.other,
    files: files + o.files,
  );
}

/// How the map shades a block (PLAN: colour = organize state).
enum BlockState {
  /// ≥ 80 % of the video bytes are organized.
  organized,

  /// Some organized, some not.
  mixed,

  /// ≥ 80 % of the video bytes still need organizing: drawn as contours.
  unorganized,

  /// No video at all (subtitles, extras, junk…).
  other,
}

BlockState blockStateOf(FolderStats s) {
  if (s.video == 0) return BlockState.other;
  final ratio = s.organized / s.video;
  if (ratio >= 0.8) return BlockState.organized;
  if (ratio <= 0.2) return BlockState.unorganized;
  return BlockState.mixed;
}

Map<String, bool> _noMarks() => const {};

/// Our show / movie folder: 「名称 (2011)」, maybe with a {tmdb-1} tag.
final _movieFolder = RegExp(
  r'^(.*\S) \(((?:19|20)\d{2})\)(?: [\[{][^\]}]*[\]}])?$',
);

/// Our season folder: 「Season 01」 (or 「Specials」 for season 0).
final _seasonFolder = RegExp(r'^(?:Season (\d{1,2})|Specials)$');

final _episodeTag = RegExp(
  r'(?:^|[^a-z0-9])s(\d{2})e\d{2,3}(?:$|[^0-9])',
  caseSensitive: false,
);
final _episodeLowerShort = RegExp(
  r'(?:^|[^a-z0-9])s(\d{1,2})e\d{1,4}(?:$|[^0-9])',
  caseSensitive: false,
);
final _episodeCross = RegExp(
  r'(?:^|[^a-z0-9])(\d{1,2})x\d{2,3}(?:$|[^0-9])',
  caseSensitive: false,
);
final _episodeLowerDotted = RegExp(
  r'(?:^|[^a-z0-9])s(\d{1,2})\.e\d{1,4}(?:$|[^0-9])',
  caseSensitive: false,
);

final _seasonPlaceholderRe = RegExp(r'\{season(?::\d+)?\}');
final _folderTokenRe = RegExp(r'\{([a-z_]+)(?::\d+)?\}');
final _nonAsciiRe = RegExp(r'[^\x00-\x7F]');
final _trailingTagRe = RegExp(r'\s*[\[{][^\]}]*[\]}]\s*$');
final _genericContainerDir = RegExp(
  r'^(?:tv|tv ?shows?|shows?|series|movies?|films?|anime|animations?|downloads?|'
  r'videos?|media|unsorted|incoming|temp|tmp|extras?|specials?|bdmv|video_ts|'
  r'电视剧|电影|动漫|动画|番剧|综艺|纪录片|剧集|影视|影视库|新番|国产剧|美剧|日剧|'
  r'韩剧|欧美剧|港剧|电视|下载|视频|待分类|待整理|字幕|字幕包|原声音乐|音乐)$',
  caseSensitive: false,
);
final _rawReleaseNoise = RegExp(
  r'^\s*[\[【]|'
  r'(?:^|[^a-z0-9])(?:480|576|720|1080|2160)[pi](?:$|[^a-z0-9])|'
  r'(?:^|[^a-z0-9])(?:web[-. ]?dl|webrip|bluray|bdrip|remux|hdtv|dvdrip|x26[45]|h\.?26[45]|hevc|avc|10bit|atvp|amzn|dsnp|hmax|uhd)(?:$|[^a-z0-9])|'
  r'(?:^|[^a-z0-9])s\d{1,2}(?:e\d{1,3})?(?:$|[^a-z0-9])|'
  r'(?:^|[^a-z0-9])\d{1,2}-\d{1,2}(?:$|[^a-z0-9])|'
  r'全\d+集',
  caseSensitive: false,
);
final _dotYearRelease = RegExp(r'\.(?:19|20)\d{2}(?:$|\.)');

typedef _FolderMatch = ({String title, String? year});

NamingProfile? _lastProfile;
_ProfileMatcher? _lastMatcher;

_ProfileMatcher _matcherFor(NamingProfile profile) {
  if (_lastProfile == profile && _lastMatcher != null) return _lastMatcher!;
  _lastProfile = profile;
  return _lastMatcher = _ProfileMatcher(profile);
}

class _ProfileMatcher {
  final NamingProfile profile;
  final List<RegExp> seasonRegexes;
  final List<RegExp> extraEpisodeRegexes;
  final List<RegExp> movieFolderRegexes;
  final List<RegExp> tvFolderRegexes;
  final bool movieAllowsNoYear;
  final bool tvAllowsNoYear;
  final Set<String> genericLower;

  _ProfileMatcher(this.profile)
    : seasonRegexes = _buildSeasonRegexes(profile.tv),
      extraEpisodeRegexes = _buildEpisodeRegexes(profile.tv),
      movieFolderRegexes = _buildFolderRegexes(profile.movie),
      tvFolderRegexes = _buildFolderRegexes(profile.tv),
      movieAllowsNoYear =
          !profile.movie.includeYear ||
          !profile.movie.folderTemplate.contains('{year}'),
      tvAllowsNoYear =
          !profile.tv.includeYear ||
          !profile.tv.folderTemplate.contains('{year}'),
      genericLower = {
        profile.movieDir.trim().toLowerCase(),
        profile.tvDir.trim().toLowerCase(),
      }..remove('');

  static List<RegExp> _buildSeasonRegexes(NamingOptions tv) {
    final out = <RegExp>[];
    final direct = _compileSeasonTemplate(tv.seasonFolderTemplate);
    if (direct != null) out.add(direct);
    if (tv.rewrites.isNotEmpty) {
      final rendered = renderTemplate(tv.seasonFolderTemplate, {'season': 77});
      final rewritten = applyRewrites(rendered, tv.rewrites);
      if (rewritten != rendered && rewritten.contains('77')) {
        final re = _compileSeasonTemplate(
          rewritten.replaceAll('77', '{season}'),
        );
        if (re != null) out.add(re);
      }
    }
    return out;
  }

  static RegExp? _compileSeasonTemplate(String template) {
    final t = template.trim();
    if (t.isEmpty || !_seasonPlaceholderRe.hasMatch(t)) return null;
    final flexibleSpace = _nonAsciiRe.hasMatch(t);
    final buf = StringBuffer('^');
    var pos = 0;
    for (final m in _seasonPlaceholderRe.allMatches(t)) {
      if (m.start > pos) {
        buf.write(_escapeLiteral(t.substring(pos, m.start), flexibleSpace));
      }
      buf.write(r'(\d{1,2})');
      pos = m.end;
    }
    if (pos < t.length) {
      buf.write(_escapeLiteral(t.substring(pos), flexibleSpace));
    }
    buf.write(r'$');
    try {
      return RegExp(buf.toString());
    } on FormatException {
      return null;
    }
  }

  static String _escapeLiteral(String literal, bool flexibleSpace) =>
      RegExp.escape(literal)
          .replaceAll(RegExp(r'\s+'), flexibleSpace ? r'\s*' : r'\s+');

  static List<RegExp> _buildEpisodeRegexes(NamingOptions tv) {
    final out = <RegExp>[];
    void add(RegExp re) {
      if (!out.contains(re)) out.add(re);
    }

    switch (tv.episodeStyle) {
      case EpisodeStyle.upperPadded:
      case EpisodeStyle.lowerPadded:
        break; // Already matched by _episodeTag.
      case EpisodeStyle.lowerShort:
        add(_episodeLowerShort);
      case EpisodeStyle.cross:
        add(_episodeCross);
      case EpisodeStyle.lowerDotted:
        add(_episodeLowerDotted);
    }
    final custom = tv.customTemplate;
    if (custom != null && custom.isNotEmpty) {
      final lower = custom.toLowerCase();
      if (lower.contains('x{episode')) add(_episodeCross);
      if (lower.contains('.e{episode')) add(_episodeLowerDotted);
      if (lower.contains('s{season}e{episode')) add(_episodeLowerShort);
    }
    return out;
  }

  static List<RegExp> _buildFolderRegexes(NamingOptions opts) {
    final re = _compileFolderTemplate(opts.folderTemplate);
    return re == null ? const [] : [re];
  }

  static RegExp? _compileFolderTemplate(String template) {
    final t = template.trim();
    if (t.isEmpty || t == '{title} ({year})') return null;
    final hasAnchor =
        t.contains('{year}') ||
        t.contains('{tmdb_tag}') ||
        t.contains('{tmdbid}');
    final hasTitle =
        t.contains('{title}') ||
        t.contains('{en_title}') ||
        t.contains('{original_title}');
    if (!hasAnchor || !hasTitle) return null;

    // Only treat `[` / `]` as optional groups when balanced.
    var depth = 0;
    var balanced = true;
    for (var i = 0; i < t.length; i++) {
      if (t[i] == r'\' && i + 1 < t.length) {
        i++;
        continue;
      }
      if (t[i] == '[') depth++;
      if (t[i] == ']') {
        depth--;
        if (depth < 0) balanced = false;
      }
    }
    if (depth != 0) balanced = false;

    final buf = StringBuffer('^');
    var hasNamedTitle = false;
    var hasNamedYear = false;
    var i = 0;
    while (i < t.length) {
      final c = t[i];
      if (c == r'\' && i + 1 < t.length) {
        buf.write(RegExp.escape(t[i + 1]));
        i += 2;
      } else if (balanced && c == '[') {
        buf.write('(?:');
        i++;
      } else if (balanced && c == ']') {
        buf.write(')?');
        i++;
      } else if (c == '{') {
        final m = _folderTokenRe.matchAsPrefix(t, i);
        if (m != null) {
          switch (m[1]) {
            case 'title':
            case 'en_title':
            case 'original_title':
              if (!hasNamedTitle) {
                buf.write(r'(?<title>.+?)');
                hasNamedTitle = true;
              } else {
                buf.write('.+?');
              }
            case 'year':
              if (!hasNamedYear) {
                buf.write(r'(?<year>(?:19|20)\d{2})');
                hasNamedYear = true;
              } else {
                buf.write(r'(?:19|20)\d{2}');
              }
            case 'tmdb_tag':
              buf.write(r'[\[{](?:tmdb|tmdbid)[-=:]\d+[\]}]');
            case 'tmdbid':
              buf.write(r'\d+');
            default:
              buf.write('.+?');
          }
          i = m.end;
        } else {
          buf.write(RegExp.escape(c));
          i++;
        }
      } else if (c == ' ') {
        buf.write(r'\s+');
        i++;
      } else {
        buf.write(RegExp.escape(c));
        i++;
      }
    }
    buf.write(r'(?:\s*[\[{][^\]}]*[\]}])?$');
    try {
      return RegExp(buf.toString());
    } on FormatException {
      return null;
    }
  }

  int? matchSeason(String name) {
    if (name.toLowerCase() == 'specials') return 0;
    for (final re in seasonRegexes) {
      final m = re.firstMatch(name);
      if (m != null) return int.parse(m[1]!);
    }
    return null;
  }

  int? matchEpisodeSeason(String fileName) {
    for (final re in extraEpisodeRegexes) {
      final m = re.firstMatch(fileName);
      if (m != null) return int.parse(m[1]!);
    }
    return null;
  }

  bool _isCleanNoYearFolder(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (genericLower.contains(trimmed.toLowerCase())) return false;
    if (_genericContainerDir.hasMatch(trimmed)) return false;
    if (_seasonFolder.hasMatch(trimmed) || matchSeason(trimmed) != null) {
      return false;
    }
    if (_rawReleaseNoise.hasMatch(trimmed)) return false;
    if (_dotYearRelease.hasMatch(trimmed)) return false;
    return true;
  }

  _FolderMatch? matchFolder(
    String name, {
    required bool allowMovie,
    required bool allowTv,
  }) {
    final regexes = [
      if (allowMovie) ...movieFolderRegexes,
      if (allowTv) ...tvFolderRegexes,
    ];
    for (final re in regexes) {
      final m = re.firstMatch(name);
      if (m == null) continue;
      final title =
          (m.groupNames.contains('title') ? m.namedGroup('title') : '')
              ?.trim() ??
          '';
      if (title.isEmpty ||
          _rawReleaseNoise.hasMatch(title) ||
          _genericContainerDir.hasMatch(title)) {
        continue;
      }
      final year = m.groupNames.contains('year') ? m.namedGroup('year') : null;
      return (title: title, year: year);
    }
    final allowsNoYear =
        (allowMovie && movieAllowsNoYear) || (allowTv && tvAllowsNoYear);
    if (allowsNoYear && _isCleanNoYearFolder(name)) {
      final title = name.replaceAll(_trailingTagRe, '').trim();
      if (title.isNotEmpty) return (title: title, year: null);
    }
    return null;
  }
}

int? _matchSeasonNumber(String name, _ProfileMatcher? matcher) {
  final def = _seasonFolder.firstMatch(name);
  if (def != null) return int.parse(def[1] ?? '0');
  return matcher?.matchSeason(name);
}

int? _matchEpisodeSeason(String fileName, _ProfileMatcher? matcher) {
  final def = _episodeTag.firstMatch(fileName);
  if (def != null) return int.parse(def[1]!);
  return matcher?.matchEpisodeSeason(fileName);
}

_FolderMatch? _matchMediaFolder(
  String name,
  _ProfileMatcher? matcher, {
  required bool allowMovie,
  required bool allowTv,
}) {
  final def = _movieFolder.firstMatch(name);
  if (def != null) return (title: def[1]!, year: def[2]!);
  return matcher?.matchFolder(name, allowMovie: allowMovie, allowTv: allowTv);
}

bool _isDiscEntry(List<String> segs, bool isDir, _ProfileMatcher? matcher) {
  final maxIdx = isDir ? segs.length - 1 : segs.length - 2;
  for (var i = 1; i <= maxIdx; i++) {
    final upper = segs[i].toUpperCase();
    if (upper == 'BDMV' || upper == 'VIDEO_TS') {
      return _matchMediaFolder(
            segs[i - 1],
            matcher,
            allowMovie: true,
            allowTv: false,
          ) !=
          null;
    }
  }
  return false;
}

/// Whether a path already reads as organized: our layout (PLAN §3), the user's
/// active [profile] (when provided), or one close to it, like Filmix's.
/// Episodes sit in 「名称 (年份)/Season 1/」 (or the configured season folder)
/// with a matching episode tag, or straight in 「名称 (年份)/」 (single-season
/// shows need no season folder); movies are named after their folder's title
/// and year (or sit inside a `BDMV`/`VIDEO_TS` disc folder under an organized
/// movie folder). A raw release name, a season mismatch or an unconfigured
/// folder without 「(年份)」 still needs organizing. Folders go by their name
/// alone, since their contents may not be listed yet.
bool looksOrganized(RemoteEntry e, {NamingProfile? profile}) {
  final segs = e.path.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return false;
  final matcher = profile == null ? null : _matcherFor(profile);
  if (_isDiscEntry(segs, e.isDir, matcher)) return true;
  if (e.isDir) {
    return _matchMediaFolder(
              segs.last,
              matcher,
              allowMovie: true,
              allowTv: true,
            ) !=
            null ||
        (segs.length >= 2 &&
            _matchSeasonNumber(segs.last, matcher) != null &&
            _matchMediaFolder(
                  segs[segs.length - 2],
                  matcher,
                  allowMovie: false,
                  allowTv: true,
                ) !=
                null);
  }
  if (segs.length < 2) return false;
  final parent = segs[segs.length - 2];
  final epSeason = _matchEpisodeSeason(e.name, matcher);
  if (epSeason != null) {
    if (_matchMediaFolder(parent, matcher, allowMovie: false, allowTv: true) !=
        null) {
      return true;
    }
    final season = _matchSeasonNumber(parent, matcher);
    if (season == null || segs.length < 3) return false;
    if (_matchMediaFolder(
          segs[segs.length - 3],
          matcher,
          allowMovie: false,
          allowTv: true,
        ) ==
        null) {
      return false;
    }
    return epSeason == season;
  }
  // A movie: named after its folder, 「盗梦空间.Inception.2010.mkv」 in
  // 「盗梦空间 (2010)」.
  final movie = _matchMediaFolder(
    parent,
    matcher,
    allowMovie: true,
    allowTv: false,
  );
  if (movie == null || !e.name.startsWith(movie.title)) return false;
  final requireYear =
      movie.year != null && (profile == null || profile.movie.includeYear);
  return !requireYear || e.name.contains(movie.year!);
}

/// The hand mark on [path] or its nearest marked ancestor.
bool? markFor(Map<String, bool> marks, String path) {
  if (marks.isEmpty) return null;
  var p = path;
  while (true) {
    final m = marks[p];
    if (m != null) return m;
    final i = p.lastIndexOf('/');
    if (i <= 0) return null;
    p = p.substring(0, i);
  }
}

/// Read-only recursive size count for one connection, for the repository map.
///
/// Remote folder listings carry no folder sizes (WebDAV reports 0, most Alist
/// storages too), so sizes come from listing everything below a folder and
/// adding file sizes up. Listings are kept, so drilling into a folder that was
/// already counted is instant. Never writes to the backend.
class SizeScanner extends ChangeNotifier {
  final StorageBackend backend;

  /// Which of [paths] a done op produced (HistoryStore.areOrganized).
  final Future<Set<String>> Function(Iterable<String> paths) organizedOf;
  final FilenameParser parser;
  final int parallel;

  /// Hand marks (path → organized), read on every count.
  final Map<String, bool> Function() marks;

  /// Active naming profile, read when classifying entries by layout.
  final NamingProfile Function()? namingProfile;

  /// Optional Drift cache store for persisting directory listings across runs.
  final FolderStatsStore? cacheStore;

  /// Connection id associated with [cacheStore].
  final ConnectionId? connectionId;

  SizeScanner({
    required this.backend,
    required this.organizedOf,
    this.marks = _noMarks,
    this.namingProfile,
    this.cacheStore,
    this.connectionId,
    this.parser = const RuleBasedParser(),
    this.parallel = 4,
  });

  final _listings = <String, List<RemoteEntry>>{};
  final _organized = <String>{};
  final _checkedOrganized = <String>{};
  final _complete = <String>{};
  final _memo = <String, FolderStats>{};

  static const _organizedBatchSize = 200;

  String? _running;
  var _stop = false;
  var _gen = 0;
  Future<void>? _activeRun;
  var _dirsListed = 0;
  Object? _error;
  final _skipped = <String, String>{};
  var _disposed = false;
  var _hydrated = false;
  Future<void>? _hydrating;
  Future<void> _cacheChain = Future.value();

  Future<void> _enqueueCache(Future<void> Function() op) {
    final next = _cacheChain.then((_) async {
      try {
        await op();
      } on Object {
        // Cache persistence is best-effort; never fail a live scan or teardown.
      }
    });
    _cacheChain = next;
    return next;
  }

  /// Loads cached directory listings from [cacheStore] into memory once.
  Future<void> hydrate() {
    if (_hydrated || _disposed) return Future.value();
    final store = cacheStore;
    final connId = connectionId;
    if (store == null || connId == null) {
      _hydrated = true;
      return Future.value();
    }
    return _hydrating ??= _doHydrate(store, connId);
  }

  Future<void> _doHydrate(FolderStatsStore store, ConnectionId connId) async {
    try {
      await _cacheChain;
      if (_disposed) return;
      final rows = await store.loadFor(connId);
      if (_disposed) return;
      final toCheck = <String>[];
      var changed = false;
      for (final row in rows) {
        if (!_listings.containsKey(row.dirPath)) {
          _listings[row.dirPath] = row.entries;
          changed = true;
          for (final e in row.entries) {
            if ((e.isDir || parser.classify(e.name) == FileRole.video) &&
                !_checkedOrganized.contains(e.path)) {
              toCheck.add(e.path);
            }
          }
        }
        if (row.complete && !_complete.contains(row.dirPath)) {
          _complete.add(row.dirPath);
          changed = true;
        }
      }
      for (var i = 0; i < toCheck.length; i += _organizedBatchSize) {
        if (_disposed) return;
        final end = i + _organizedBatchSize < toCheck.length
            ? i + _organizedBatchSize
            : toCheck.length;
        final batch = toCheck.sublist(i, end);
        _checkedOrganized.addAll(batch);
        final found = await organizedOf(batch);
        if (_disposed) return;
        if (found.isNotEmpty) {
          _organized.addAll(found);
          changed = true;
        }
      }
      if (changed) {
        _memo.clear();
        _notify();
      }
    } on Object {
      // Best-effort hydration: fall back to live scanning on cache errors.
    } finally {
      _hydrated = true;
      _hydrating = null;
    }
  }

  /// Root of the count in progress, if any.
  String? get running => _running;
  int get dirsListed => _dirsListed;
  Object? get error => _error;

  /// Folders the last count could not read, with the reason; not in the totals.
  Map<String, String> get skipped => _skipped;

  /// Whether [dir] and everything below it has been counted.
  bool isComplete(String dir) =>
      _complete.any((r) => r == dir || r == '/' || dir.startsWith('$r/'));

  /// Whether at least [dir] itself has been listed.
  bool isListed(String dir) => _listings.containsKey(dir);

  List<RemoteEntry> entriesOf(String dir) => _listings[dir] ?? const [];

  /// Counts everything below [root]. A second call for a counted folder
  /// returns at once unless [fresh], which recounts from the server; a call
  /// while another count runs stops that one first.
  Future<void> scan(String root, {bool fresh = false}) async {
    if (_disposed) return;
    if (!fresh && isComplete(root)) return;
    final myGen = ++_gen;
    // No await when idle: the count must be running as soon as this returns.
    if (_activeRun != null) {
      await _stopRunning();
      if (_disposed || myGen != _gen) return;
    }
    if (fresh) _drop(root);
    final done = Completer<void>();
    _activeRun = done.future;
    _running = root;
    _stop = false;
    _error = null;
    _dirsListed = 0;
    _skipped.clear();
    // Callers start a count from initState / didUpdateWidget, mid-build.
    scheduleMicrotask(_notify);

    final pendingAsk = <String>[];
    Future<void> flushOrganized() async {
      if (pendingAsk.isEmpty || _disposed) return;
      final batch = List<String>.of(pendingAsk);
      pendingAsk.clear();
      _checkedOrganized.addAll(batch);
      final found = await organizedOf(batch);
      if (found.isNotEmpty) {
        _organized.addAll(found);
        _memo.clear();
      }
    }

    try {
      if (!fresh && !_hydrated && cacheStore != null && connectionId != null) {
        await hydrate();
        if (_stop || _disposed || myGen != _gen) return;
        if (isComplete(root)) return;
      }
      await walkDirs(
        [root],
        (dir) async {
          final cached = _listings[dir];
          final List<RemoteEntry> list;
          try {
            list = cached ?? await backend.list(dir, refresh: fresh);
          } on StorageException catch (e) {
            // One unreadable folder ("G:\\System Volume Information") must not
            // end the count; a dead connection or the root itself still does.
            if (dir == root ||
                e.code == StorageErrorCode.unauthorized ||
                e.code == StorageErrorCode.network ||
                e.code == StorageErrorCode.rateLimited) {
              rethrow;
            }
            _skipped[dir] = e.message;
            return const <String>[];
          }
          if (cached == null) {
            _listings[dir] = list;
            final store = cacheStore;
            final connId = connectionId;
            if (store != null && connId != null) {
              unawaited(_enqueueCache(() => store.saveDir(connId, dir, list)));
            }
            for (final e in list) {
              if ((e.isDir || parser.classify(e.name) == FileRole.video) &&
                  !_checkedOrganized.contains(e.path)) {
                pendingAsk.add(e.path);
              }
            }
            if (pendingAsk.length >= _organizedBatchSize) {
              await flushOrganized();
            }
            _memo.clear();
          }
          _dirsListed++;
          _notify();
          return [
            for (final e in list)
              if (e.isDir) e.path,
          ];
        },
        parallel: parallel,
        stop: () => _stop || _disposed || myGen != _gen,
      );
      await flushOrganized();
      if (!_stop && !_disposed && myGen == _gen) {
        _complete.add(root);
        final store = cacheStore;
        final connId = connectionId;
        if (store != null && connId != null) {
          unawaited(_enqueueCache(() => store.markComplete(connId, root)));
        }
      }
    } catch (e) {
      if (!_disposed && myGen == _gen) _error = e;
    } finally {
      if (pendingAsk.isNotEmpty && !_disposed && myGen == _gen) {
        try {
          await flushOrganized();
        } on Object {
          // Best-effort flush on error/cancel.
        }
      }
      if (!_disposed && cacheStore != null && connectionId != null) {
        await _cacheChain;
      }
      if (myGen == _gen) _running = null;
      if (identical(_activeRun, done.future)) _activeRun = null;
      done.complete();
      _notify();
    }
  }

  /// Forgets what's known below [root]; the next count lists it again.
  Future<void> forget(String root) async {
    if (_disposed) return;
    final myGen = ++_gen;
    await _stopRunning();
    if (_disposed || myGen != _gen) return;
    _drop(root);
    _notify();
    if (!_disposed && cacheStore != null && connectionId != null) {
      await _cacheChain;
    }
  }

  /// The hand marks or naming profile changed: same listings, new totals.
  void marksChanged() {
    _memo.clear();
    _notify();
  }

  Future<void> _stopRunning() async {
    final run = _activeRun;
    if (run == null) return;
    _stop = true;
    await run;
  }

  void _drop(String root) {
    bool below(String p) => p == root || p.startsWith('$root/') || root == '/';
    _listings.removeWhere((k, _) => below(k));
    _organized.removeWhere(below);
    _checkedOrganized.removeWhere(below);
    // Parents aren't complete any more either; recounting them reuses the
    // listings kept for their other children.
    _complete.removeWhere(
      (r) => below(r) || r == '/' || root.startsWith('$r/'),
    );
    _memo.clear();
    final store = cacheStore;
    final connId = connectionId;
    if (store != null && connId != null) {
      unawaited(_enqueueCache(() => store.deleteBelow(connId, root)));
    }
  }

  /// Stops the count in progress; what was counted so far stays.
  void cancel() {
    if (_running != null) _stop = true;
  }

  /// Totals for [path] (a folder or a file) from what has been listed so far.
  FolderStats statsOf(RemoteEntry e) {
    final currentMarks = marks();
    final profile = namingProfile?.call();
    return e.isDir
        ? _dir(e.path, _inherited(e.path), currentMarks, profile)
        : _file(e, _inherited(e.path), currentMarks, profile);
  }

  /// Totals for the folder [dir] itself.
  FolderStats statsOfDir(String dir) =>
      _dir(dir, _inherited(dir), marks(), namingProfile?.call());

  /// Whether a done op produced [path] or a folder above it.
  bool _inherited(String path) {
    var p = path;
    while (true) {
      if (_organized.contains(p)) return true;
      final i = p.lastIndexOf('/');
      if (i <= 0) return false;
      p = p.substring(0, i);
    }
  }

  FolderStats _file(
    RemoteEntry e,
    bool organized,
    Map<String, bool> currentMarks,
    NamingProfile? profile,
  ) {
    final video = parser.classify(e.name) == FileRole.video;
    if (!video) return FolderStats(other: e.size, files: 1);
    return markFor(currentMarks, e.path) ??
            (organized ||
                _organized.contains(e.path) ||
                looksOrganized(e, profile: profile))
        ? FolderStats(organized: e.size, files: 1)
        : FolderStats(unorganized: e.size, files: 1);
  }

  FolderStats _dir(
    String dir,
    bool organized,
    Map<String, bool> currentMarks,
    NamingProfile? profile,
  ) {
    final key = '$organized$dir';
    final hit = _memo[key];
    if (hit != null) return hit;
    var s = FolderStats.zero;
    for (final e in _listings[dir] ?? const <RemoteEntry>[]) {
      final o = organized || _organized.contains(e.path);
      s += e.isDir
          ? _dir(e.path, o, currentMarks, profile)
          : _file(e, o, currentMarks, profile);
    }
    return _memo[key] = s;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop = true;
    super.dispose();
  }
}
