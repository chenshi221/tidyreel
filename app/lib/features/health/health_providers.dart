import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/settings.dart';
import 'health_models.dart';
import 'health_scanner.dart';

/// Injectable scanner factory so widget tests can seed a custom scanner while
/// production uses the live backend, FolderStatsStore and settings.
typedef HealthScannerFactory = HealthScanner Function(
  ConnectionId connectionId,
);

final healthScannerFactoryProvider = Provider<HealthScannerFactory>(
  (ref) =>
      (connectionId) => HealthScanner(
        backend: ref.read(connectionBackendProvider(connectionId)),
        connectionId: connectionId,
        folderStatsStore: ref.read(folderStatsStoreProvider),
        probeMedia: ref.read(settingsProvider).probeMedia,
      ),
);

/// UI state for the lightweight Library Health page.
@immutable
class HealthState {
  final ConnectionId? selectedConnection;
  final String targetPath;
  final bool scanning;
  final HealthScanProgress? progress;
  final HealthReport? report;
  final String? error;
  final HealthCategory category;
  final Set<String> selectedMissingFolders;
  final Set<String> selectedCleanupPaths;
  final bool busyAction;

  const HealthState({
    this.selectedConnection,
    this.targetPath = '/',
    this.scanning = false,
    this.progress,
    this.report,
    this.error,
    this.category = HealthCategory.duplicates,
    this.selectedMissingFolders = const {},
    this.selectedCleanupPaths = const {},
    this.busyAction = false,
  });

  HealthState copyWith({
    ConnectionId? Function()? selectedConnection,
    String? targetPath,
    bool? scanning,
    HealthScanProgress? Function()? progress,
    HealthReport? Function()? report,
    String? Function()? error,
    HealthCategory? category,
    Set<String>? selectedMissingFolders,
    Set<String>? selectedCleanupPaths,
    bool? busyAction,
  }) => HealthState(
    selectedConnection: selectedConnection != null
        ? selectedConnection()
        : this.selectedConnection,
    targetPath: targetPath ?? this.targetPath,
    scanning: scanning ?? this.scanning,
    progress: progress != null ? progress() : this.progress,
    report: report != null ? report() : this.report,
    error: error != null ? error() : this.error,
    category: category ?? this.category,
    selectedMissingFolders:
        selectedMissingFolders ?? this.selectedMissingFolders,
    selectedCleanupPaths: selectedCleanupPaths ?? this.selectedCleanupPaths,
    busyAction: busyAction ?? this.busyAction,
  );
}

/// Default audit directory for a connection: `libraryRoot ?? startDir`.
String defaultHealthRootFor(ConnectionConfig c) {
  final root = c.libraryRoot?.trim();
  if (root != null && root.isNotEmpty) return normalizeDir(root);
  return normalizeDir(c.startDir);
}

class HealthController extends Notifier<HealthState> {
  int _scanGen = 0;
  bool _cancelRequested = false;

  @override
  HealthState build() {
    final conns = ref.read(connectionsProvider);
    ref.listen<List<ConnectionConfig>>(connectionsProvider, (_, next) {
      final cur = state.selectedConnection;
      if (cur == null && next.isNotEmpty) {
        final first = next.first;
        state = state.copyWith(
          selectedConnection: () => first.id,
          targetPath: defaultHealthRootFor(first),
        );
      } else if (cur != null && !next.any((c) => c.id == cur)) {
        _scanGen++;
        _cancelRequested = true;
        final fallback = next.firstOrNull;
        state = HealthState(
          selectedConnection: fallback?.id,
          targetPath: fallback == null ? '/' : defaultHealthRootFor(fallback),
        );
      }
    });
    final initial = conns.firstOrNull;
    return HealthState(
      selectedConnection: initial?.id,
      targetPath: initial == null ? '/' : defaultHealthRootFor(initial),
    );
  }

  void selectConnection(ConnectionId id) {
    if (state.selectedConnection == id) return;
    final conn = ref
        .read(connectionsProvider)
        .where((c) => c.id == id)
        .firstOrNull;
    if (conn == null) return;
    _scanGen++;
    _cancelRequested = true;
    state = HealthState(
      selectedConnection: conn.id,
      targetPath: defaultHealthRootFor(conn),
    );
  }

  void setTargetPath(String path) {
    final norm = normalizeDir(path);
    if (state.targetPath == norm) return;
    state = state.copyWith(targetPath: norm, error: () => null);
  }

  void setCategory(HealthCategory category) {
    if (state.category == category) return;
    state = state.copyWith(category: category);
  }

  Future<void> startScan({bool fresh = false}) async {
    final connId = state.selectedConnection;
    if (connId == null) return;

    final gen = ++_scanGen;
    _cancelRequested = false;
    state = state.copyWith(
      scanning: true,
      error: () => null,
      progress: () => const HealthScanProgress(
        phase: HealthScanPhase.walking,
        message: '正在准备扫描…',
        fraction: 0.05,
      ),
    );

    try {
      final scanner = ref.read(healthScannerFactoryProvider)(connId);
      final report = await scanner.scan(
        state.targetPath,
        fresh: fresh,
        onProgress: (p) {
          if (gen != _scanGen) return;
          state = state.copyWith(progress: () => p);
        },
        isCancelled: () => _cancelRequested || gen != _scanGen,
      );
      if (gen != _scanGen) return;

      final defaultScrapeFolders = {
        for (final m in report.missingAssets) m.folderPath,
      };
      final defaultCleanup = {for (final c in report.cleanupItems) c.path};
      state = state.copyWith(
        scanning: false,
        progress: () => null,
        report: () => report,
        error: () => null,
        category: report.firstNonEmptyCategory ?? HealthCategory.duplicates,
        selectedMissingFolders: defaultScrapeFolders,
        selectedCleanupPaths: defaultCleanup,
      );
    } on HealthScanCancelled {
      if (gen == _scanGen) {
        state = state.copyWith(scanning: false, progress: () => null);
      }
    } on Object catch (e) {
      if (gen == _scanGen) {
        state = state.copyWith(
          scanning: false,
          progress: () => null,
          error: () => _friendlyError(e),
        );
      }
    }
  }

  void cancelScan() {
    if (!state.scanning) return;
    _cancelRequested = true;
    _scanGen++;
    state = state.copyWith(scanning: false, progress: () => null);
  }

  void toggleMissingFolder(String folderPath) {
    final next = {...state.selectedMissingFolders};
    if (!next.add(folderPath)) next.remove(folderPath);
    state = state.copyWith(selectedMissingFolders: next);
  }

  void selectAllMissingFolders() {
    final report = state.report;
    if (report == null) return;
    state = state.copyWith(
      selectedMissingFolders: {
        for (final m in report.missingAssets) m.folderPath,
      },
    );
  }

  void clearMissingFolders() =>
      state = state.copyWith(selectedMissingFolders: const {});

  void toggleCleanupPath(String path) {
    final next = {...state.selectedCleanupPaths};
    if (!next.add(path)) next.remove(path);
    state = state.copyWith(selectedCleanupPaths: next);
  }

  void selectAllCleanup() {
    final report = state.report;
    if (report == null) return;
    state = state.copyWith(
      selectedCleanupPaths: {for (final c in report.cleanupItems) c.path},
    );
  }

  void clearCleanupSelection() =>
      state = state.copyWith(selectedCleanupPaths: const {});

  /// Removes user-confirmed duplicate file paths on the backend.
  Future<int> deleteDuplicatePaths(List<String> paths) async {
    final report = state.report;
    if (report == null || paths.isEmpty || state.busyAction) return 0;

    state = state.copyWith(busyAction: true);
    final backend = ref.read(connectionBackendProvider(report.connection));
    final stats = ref.read(folderStatsStoreProvider);
    final deleted = <String>{};
    try {
      final byDir = <String, List<String>>{};
      for (final raw in paths) {
        final dir = normalizeDir(p.posix.dirname(raw));
        final name = p.posix.basename(raw);
        if (name.isEmpty) continue;
        (byDir[dir] ??= []).add(name);
      }
      for (final entry in byDir.entries) {
        await backend.remove(entry.key, entry.value);
        for (final name in entry.value) {
          deleted.add(p.posix.join(entry.key, name));
        }
        await stats.deleteBelow(report.connection, entry.key);
      }
      final updated = report.withoutDeletedPaths(deletedFiles: deleted);
      state = state.copyWith(report: () => updated, busyAction: false);
      return deleted.length;
    } on Object {
      if (deleted.isNotEmpty) {
        final updated = report.withoutDeletedPaths(deletedFiles: deleted);
        state = state.copyWith(report: () => updated, busyAction: false);
      } else {
        state = state.copyWith(busyAction: false);
      }
      rethrow;
    }
  }

  /// Removes user-confirmed junk files and empty directories (deepest-first).
  Future<({int filesRemoved, int dirsRemoved})> cleanupSelected() async {
    final report = state.report;
    if (report == null ||
        state.selectedCleanupPaths.isEmpty ||
        state.busyAction) {
      return (filesRemoved: 0, dirsRemoved: 0);
    }

    state = state.copyWith(busyAction: true);
    final backend = ref.read(connectionBackendProvider(report.connection));
    final stats = ref.read(folderStatsStoreProvider);
    final selected = state.selectedCleanupPaths;
    final files = [
      for (final c in report.cleanupItems)
        if (c.kind == CleanupKind.junkFile && selected.contains(c.path)) c,
    ];
    final dirs =
        [
          for (final c in report.cleanupItems)
            if (c.kind == CleanupKind.emptyDir && selected.contains(c.path)) c,
        ]..sort(
          (a, b) => '/'
              .allMatches(b.path)
              .length
              .compareTo('/'.allMatches(a.path).length),
        );

    final deletedFiles = <String>{};
    final deletedDirs = <String>{};
    try {
      // 1. Delete junk files grouped by parent directory.
      final byDir = <String, List<String>>{};
      for (final f in files) {
        final dir = normalizeDir(p.posix.dirname(f.path));
        (byDir[dir] ??= []).add(f.name);
      }
      for (final entry in byDir.entries) {
        await backend.remove(entry.key, entry.value);
        for (final name in entry.value) {
          deletedFiles.add(p.posix.join(entry.key, name));
        }
      }

      // 2. Delete empty directories deepest-first, re-checking each live so a
      // newly created file is never accidentally deleted.
      final protected = {'/', report.rootDir};
      for (final d in dirs) {
        final normDir = normalizeDir(d.path);
        if (protected.contains(normDir)) continue;
        try {
          final entries = await backend.list(normDir, refresh: true);
          final hasReal = entries.any(
            (e) =>
                e.isDir ||
                !ignorableEmptyDirFiles.contains(e.name.toLowerCase()),
          );
          if (hasReal) continue;
          if (entries.isNotEmpty) {
            await backend.remove(normDir, [for (final e in entries) e.name]);
          }
          await backend.remove(normalizeDir(p.posix.dirname(normDir)), [
            p.posix.basename(normDir),
          ]);
          deletedDirs.add(normDir);
        } on StorageException catch (e) {
          if (e.code == StorageErrorCode.notFound) {
            deletedDirs.add(normDir);
            continue;
          }
          rethrow;
        }
      }

      if (deletedFiles.isNotEmpty || deletedDirs.isNotEmpty) {
        await stats.deleteBelow(report.connection, report.rootDir);
      }
      final updated = report.withoutDeletedPaths(
        deletedFiles: deletedFiles,
        deletedDirs: deletedDirs,
      );
      final nextSelected = {
        for (final pth in state.selectedCleanupPaths)
          if (!deletedFiles.contains(pth) && !deletedDirs.contains(pth)) pth,
      };
      state = state.copyWith(
        report: () => updated,
        selectedCleanupPaths: nextSelected,
        busyAction: false,
      );
      return (
        filesRemoved: deletedFiles.length,
        dirsRemoved: deletedDirs.length,
      );
    } on Object {
      final updated = report.withoutDeletedPaths(
        deletedFiles: deletedFiles,
        deletedDirs: deletedDirs,
      );
      state = state.copyWith(report: () => updated, busyAction: false);
      rethrow;
    }
  }

  /// Submits a scrape-only task (`scrape: true, scrapeOnly: true`) for selected
  /// works missing NFO/poster without renaming or moving any media file.
  Future<TaskId?> scrapeSelectedMissing() async {
    final report = state.report;
    if (report == null ||
        state.selectedMissingFolders.isEmpty ||
        state.busyAction) {
      return null;
    }

    final orderedPaths = <String>[];
    final seen = <String>{};
    for (final m in report.missingAssets) {
      if (state.selectedMissingFolders.contains(m.folderPath) &&
          seen.add(m.folderPath)) {
        orderedPaths.add(m.folderPath);
      }
    }
    if (orderedPaths.isEmpty) return null;

    state = state.copyWith(busyAction: true);
    try {
      final tm = ref.read(taskManagerProvider);
      final id = await tm.submit(
        report.connection,
        orderedPaths,
        OrganizeMode.inPlace,
        scrape: true,
        scrapeOnly: true,
      );
      state = state.copyWith(busyAction: false);
      return id;
    } on Object {
      state = state.copyWith(busyAction: false);
      rethrow;
    }
  }

  static String _friendlyError(Object e) {
    if (e is StorageException) return e.message;
    if (e is StateError) return e.message;
    return '$e';
  }
}

final healthControllerProvider =
    NotifierProvider<HealthController, HealthState>(HealthController.new);
