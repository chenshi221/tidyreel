import 'dart:async';

import 'package:drift/drift.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'codec.dart' show enumByName;
import 'database.dart';

/// Immutable configuration for one lightweight watch-mode folder rule.
class WatchRule {
  final String id;
  final ConnectionId connection;
  final String path;
  final bool enabled;

  /// Polling interval in minutes for remote connections (Alist/WebDAV/SMB),
  /// and safety rescan interval for local folders.
  final int intervalMinutes;
  final OrganizeMode mode;
  final bool scrape;

  /// False (default): recognize and wait in 「待确认」.
  /// True: automatically execute high-confidence conflict-free ops only.
  final bool autoRunHighConfidence;
  final DateTime? lastScanAt;
  final String lastStatus;

  const WatchRule({
    required this.id,
    required this.connection,
    required this.path,
    this.enabled = true,
    this.intervalMinutes = 10,
    this.mode = OrganizeMode.inPlace,
    this.scrape = false,
    this.autoRunHighConfidence = false,
    this.lastScanAt,
    this.lastStatus = '',
  });

  WatchRule copyWith({
    ConnectionId? connection,
    String? path,
    bool? enabled,
    int? intervalMinutes,
    OrganizeMode? mode,
    bool? scrape,
    bool? autoRunHighConfidence,
    DateTime? Function()? lastScanAt,
    String? lastStatus,
  }) => WatchRule(
    id: id,
    connection: connection ?? this.connection,
    path: path ?? this.path,
    enabled: enabled ?? this.enabled,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    mode: mode ?? this.mode,
    scrape: scrape ?? this.scrape,
    autoRunHighConfidence: autoRunHighConfidence ?? this.autoRunHighConfidence,
    lastScanAt: lastScanAt != null ? lastScanAt() : this.lastScanAt,
    lastStatus: lastStatus ?? this.lastStatus,
  );
}

/// Drift-backed store for [WatchRule] rows.
/// Uses an explicit broadcast stream rather than Drift's StreamQueryStore so
/// widget disposal never leaves pending zero-duration cleanup timers.
class WatchRulesStore {
  final AppDatabase db;
  final _changes = StreamController<List<WatchRule>>.broadcast();

  WatchRulesStore(this.db);

  static WatchRule _fromRow(WatchRuleRow r) => WatchRule(
    id: r.id,
    connection: ConnectionId(r.connectionId),
    path: r.path,
    enabled: r.enabled,
    intervalMinutes: r.intervalMinutes.clamp(1, 1440),
    mode: enumByName(OrganizeMode.values, r.mode, OrganizeMode.inPlace),
    scrape: r.scrape,
    autoRunHighConfidence: r.autoRunHighConfidence,
    lastScanAt: r.lastScanAt,
    lastStatus: r.lastStatus,
  );

  Future<void> _emit() async {
    if (_changes.isClosed) return;
    try {
      final list = await loadAll();
      if (!_changes.isClosed) _changes.add(list);
    } on Object {
      // Ignore emits racing with database close during shutdown.
    }
  }

  Stream<List<WatchRule>> watchAll() async* {
    yield await loadAll();
    yield* _changes.stream;
  }

  Future<List<WatchRule>> loadAll() async {
    final rows = await (db.select(
      db.watchRules,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    return [for (final r in rows) _fromRow(r)];
  }

  Future<void> upsert(WatchRule rule) async {
    await db
        .into(db.watchRules)
        .insertOnConflictUpdate(
          WatchRulesCompanion.insert(
            id: rule.id,
            connectionId: rule.connection.value,
            path: normalizeDir(rule.path),
            enabled: Value(rule.enabled),
            intervalMinutes: Value(rule.intervalMinutes.clamp(1, 1440)),
            mode: Value(rule.mode.name),
            scrape: Value(rule.scrape),
            autoRunHighConfidence: Value(rule.autoRunHighConfidence),
            lastScanAt: Value(rule.lastScanAt),
            lastStatus: Value(rule.lastStatus),
          ),
        );
    await _emit();
  }

  Future<void> updateRunStatus(
    String id,
    DateTime scannedAt,
    String status,
  ) async {
    await (db.update(db.watchRules)..where((t) => t.id.equals(id))).write(
      WatchRulesCompanion(
        lastScanAt: Value(scannedAt.toUtc()),
        lastStatus: Value(status),
      ),
    );
    await _emit();
  }

  Future<void> delete(String id) async {
    await (db.delete(db.watchRules)..where((t) => t.id.equals(id))).go();
    await _emit();
  }

  Future<void> deleteForConnection(ConnectionId connection) async {
    await (db.delete(
      db.watchRules,
    )..where((t) => t.connectionId.equals(connection.value))).go();
    await _emit();
  }

  void dispose() {
    unawaited(_changes.close());
  }
}
