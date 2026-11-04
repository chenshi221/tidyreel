import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

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

final _episodeTag = RegExp(
  r'(^|[^a-z0-9])(s\d{1,2}[ ._-]?e\d{1,3}|\d{1,2}x\d{2})($|[^a-z0-9])',
  caseSensitive: false,
);

/// A media folder: 「名称 (2011)」 or 「Name.2011」, maybe with a {tmdb-1} tag.
final _mediaFolder = RegExp(
  r'^.*\S(?:[ .]+[(（]?|[(（])((?:19|20)\d{2})[)）]?\s*([\[{].*[\]}])?$',
);

/// Whether a path already reads as organized, whoever did it. Loose on purpose
/// (not the current naming rules): other tools name things differently, and a
/// wrong guess only changes a colour. Folders go by their name alone, since
/// their contents may not be listed yet.
bool looksOrganized(RemoteEntry e) {
  final segs = e.path.split('/').where((s) => s.isNotEmpty).toList();
  if (e.isDir) return _mediaFolder.hasMatch(segs.last);
  if (segs.length < 2) return false;
  final parent = _mediaFolder.firstMatch(segs[segs.length - 2]);
  final grand = segs.length >= 3
      ? _mediaFolder.firstMatch(segs[segs.length - 3])
      : null;
  if (_episodeTag.hasMatch(e.name)) return parent != null || grand != null;
  // A movie: its folder's year shows up in the file name too.
  return parent != null && e.name.contains(parent[1]!);
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

  SizeScanner({
    required this.backend,
    required this.organizedOf,
    this.marks = _noMarks,
    this.parser = const RuleBasedParser(),
    this.parallel = 4,
  });

  final _listings = <String, List<RemoteEntry>>{};
  final _organized = <String>{};
  final _complete = <String>{};
  final _memo = <String, FolderStats>{};

  String? _running;
  var _stop = false;
  var _dirsListed = 0;
  Object? _error;
  final _skipped = <String, String>{};
  var _disposed = false;

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
    if (!fresh && isComplete(root)) return;
    // No await when idle: the count must be running as soon as this returns.
    if (_running != null) await _stopRunning();
    if (fresh) _drop(root);
    _running = root;
    _stop = false;
    _error = null;
    _dirsListed = 0;
    _skipped.clear();
    // Callers start a count from initState / didUpdateWidget, mid-build.
    scheduleMicrotask(_notify);
    try {
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
            final ask = [
              for (final e in list)
                if (e.isDir || parser.classify(e.name) == FileRole.video)
                  e.path,
            ];
            if (ask.isNotEmpty) _organized.addAll(await organizedOf(ask));
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
        stop: () => _stop,
      );
      if (!_stop) _complete.add(root);
    } catch (e) {
      _error = e;
    } finally {
      _running = null;
      _notify();
    }
  }

  /// Forgets what's known below [root]; the next count lists it again.
  Future<void> forget(String root) async {
    await _stopRunning();
    _drop(root);
    _notify();
  }

  /// The hand marks changed: same listings, new totals.
  void marksChanged() {
    _memo.clear();
    _notify();
  }

  Future<void> _stopRunning() async {
    if (_running == null) return;
    _stop = true;
    while (_running != null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void _drop(String root) {
    bool below(String p) => p == root || p.startsWith('$root/') || root == '/';
    _listings.removeWhere((k, _) => below(k));
    _organized.removeWhere(below);
    // Parents aren't complete any more either; recounting them reuses the
    // listings kept for their other children.
    _complete.removeWhere(
      (r) => below(r) || r == '/' || root.startsWith('$r/'),
    );
    _memo.clear();
  }

  /// Stops the count in progress; what was counted so far stays.
  void cancel() {
    if (_running != null) _stop = true;
  }

  /// Totals for [path] (a folder or a file) from what has been listed so far.
  FolderStats statsOf(RemoteEntry e) =>
      e.isDir ? _dir(e.path, _inherited(e.path)) : _file(e, _inherited(e.path));

  /// Totals for the folder [dir] itself.
  FolderStats statsOfDir(String dir) => _dir(dir, _inherited(dir));

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

  FolderStats _file(RemoteEntry e, bool organized) {
    final video = parser.classify(e.name) == FileRole.video;
    if (!video) return FolderStats(other: e.size, files: 1);
    return markFor(marks(), e.path) ??
            (organized || _organized.contains(e.path) || looksOrganized(e))
        ? FolderStats(organized: e.size, files: 1)
        : FolderStats(unorganized: e.size, files: 1);
  }

  FolderStats _dir(String dir, bool organized) {
    final key = '$organized$dir';
    final hit = _memo[key];
    if (hit != null) return hit;
    var s = FolderStats.zero;
    for (final e in _listings[dir] ?? const <RemoteEntry>[]) {
      final o = organized || _organized.contains(e.path);
      s += e.isDir ? _dir(e.path, o) : _file(e, o);
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
