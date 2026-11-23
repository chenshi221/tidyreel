import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'database.dart';

/// Cached directory snapshot stored per `(connectionId, dirPath)`.
class CachedDirListing {
  final String dirPath;
  final List<RemoteEntry> entries;
  final bool complete;
  final DateTime scannedAt;

  const CachedDirListing({
    required this.dirPath,
    required this.entries,
    required this.complete,
    required this.scannedAt,
  });
}

/// Persistent Drift store for directory listings so Map and Health reopen
/// instantly across app restarts without re-walking NAS / Alist trees.
class FolderStatsStore {
  final AppDatabase db;

  FolderStatsStore(this.db);

  Future<List<CachedDirListing>> loadFor(ConnectionId connection) async {
    final rows = await (db.select(
      db.folderStatsCache,
    )..where((t) => t.connectionId.equals(connection.value))).get();
    final out = <CachedDirListing>[];
    for (final r in rows) {
      try {
        final raw = (jsonDecode(r.entriesJson) as List).cast<Map>();
        final entries = [
          for (final m in raw)
            RemoteEntry(
              path: m['p'] as String,
              name: m['n'] as String,
              isDir: m['d'] as bool? ?? false,
              size: (m['s'] as num?)?.toInt() ?? 0,
              modified: m['m'] == null
                  ? null
                  : DateTime.tryParse(m['m'] as String),
            ),
        ];
        out.add(
          CachedDirListing(
            dirPath: r.dirPath,
            entries: entries,
            complete: r.complete,
            scannedAt: r.scannedAt,
          ),
        );
      } on Object {
        // Ignore corrupt single-row payload.
      }
    }
    return out;
  }

  Future<void> saveDir(
    ConnectionId connection,
    String dirPath,
    List<RemoteEntry> entries, {
    bool complete = false,
  }) => db
      .into(db.folderStatsCache)
      .insertOnConflictUpdate(
        FolderStatsCacheCompanion.insert(
          connectionId: connection.value,
          dirPath: dirPath,
          entriesJson: jsonEncode([
            for (final e in entries)
              {
                'p': e.path,
                'n': e.name,
                'd': e.isDir,
                's': e.size,
                if (e.modified != null)
                  'm': e.modified!.toUtc().toIso8601String(),
              },
          ]),
          complete: Value(complete),
          scannedAt: DateTime.now().toUtc(),
        ),
      );

  Future<void> markComplete(ConnectionId connection, String dirPath) =>
      (db.update(db.folderStatsCache)..where(
            (t) =>
                t.connectionId.equals(connection.value) &
                t.dirPath.equals(dirPath),
          ))
          .write(
            FolderStatsCacheCompanion(
              complete: const Value(true),
              scannedAt: Value(DateTime.now().toUtc()),
            ),
          );

  /// Deletes cached rows at or below [root], and marks ancestors incomplete.
  Future<void> deleteBelow(ConnectionId connection, String root) async {
    final norm = normalizeDir(root);
    final rows = await (db.select(
      db.folderStatsCache,
    )..where((t) => t.connectionId.equals(connection.value))).get();
    final toDelete = <String>[];
    final toInvalidate = <String>[];
    for (final r in rows) {
      final p = r.dirPath;
      if (norm == '/' || p == norm || p.startsWith('$norm/')) {
        toDelete.add(p);
      } else if (p == '/' || norm.startsWith('$p/')) {
        toInvalidate.add(p);
      }
    }
    await db.transaction(() async {
      if (toDelete.isNotEmpty) {
        await (db.delete(db.folderStatsCache)..where(
              (t) =>
                  t.connectionId.equals(connection.value) &
                  t.dirPath.isIn(toDelete),
            ))
            .go();
      }
      if (toInvalidate.isNotEmpty) {
        await (db.update(db.folderStatsCache)..where(
              (t) =>
                  t.connectionId.equals(connection.value) &
                  t.dirPath.isIn(toInvalidate),
            ))
            .write(const FolderStatsCacheCompanion(complete: Value(false)));
      }
    });
  }

  Future<void> clearFor(ConnectionId connection) => (db.delete(
    db.folderStatsCache,
  )..where((t) => t.connectionId.equals(connection.value))).go();
}
