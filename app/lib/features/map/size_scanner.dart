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

  SizeScanner({
    required this.backend,
    required this.organizedOf,
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
  var _disposed = false;

  /// Root of the count in progress, if any.
  String? get running => _running;
  int get dirsListed => _dirsListed;
  Object? get error => _error;

  /// Whether [dir] and everything below it has been counted.
  bool isComplete(String dir) =>
      _complete.any((r) => r == dir || r == '/' || dir.startsWith('$r/'));

  /// Whether at least [dir] itself has been listed.
  bool isListed(String dir) => _listings.containsKey(dir);

  List<RemoteEntry> entriesOf(String dir) => _listings[dir] ?? const [];

  /// Counts everything below [root]. A second call for a counted folder
  /// returns at once; a call while another count runs stops that one first.
  Future<void> scan(String root) async {
    if (isComplete(root)) return;
    if (_running != null) {
      _stop = true;
      while (_running != null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    _running = root;
    _stop = false;
    _error = null;
    _dirsListed = 0;
    // Callers start a count from initState / didUpdateWidget, mid-build.
    scheduleMicrotask(_notify);
    try {
      await walkDirs(
        [root],
        (dir) async {
          final cached = _listings[dir];
          final list = cached ?? await backend.list(dir);
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

  /// Stops the count in progress; what was counted so far stays.
  void cancel() {
    if (_running != null) _stop = true;
  }

  /// Totals for [path] (a folder or a file) from what has been listed so far.
  FolderStats statsOf(RemoteEntry e) =>
      e.isDir ? _dir(e.path, _inherited(e.path)) : _file(e, _inherited(e.path));

  /// Totals for the folder [dir] itself.
  FolderStats statsOfDir(String dir) => _dir(dir, _inherited(dir));

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
    return organized || _organized.contains(e.path)
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
