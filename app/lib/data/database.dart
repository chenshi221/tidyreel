// Tidyreel's drift database: batches + history records (undo log) and tasks.
//
// Construct (nothing here is wired into providers yet):
//
//   final db = await AppDatabase.openDefault();        // file in the app support dir
//   // tests: AppDatabase(NativeDatabase.memory())
//   final history = DriftHistoryStore(db);              // drift_history_store.dart
//   final tasks = DriftTaskStore(db);                   // drift_task_store.dart
//   final executor = DefaultExecutor(history);
//   final tm = DefaultTaskManager(..., history: history, store: tasks, ...);
//   await tm.resumeInterrupted();
//
// After editing tables run `dart run build_runner build` in app/.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// One executed plan (PLAN §4.3). Ops live in [HistoryRecords].
@DataClassName('BatchRow')
class Batches extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text()();
  TextColumn get connectionId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Write-ahead log: every op is inserted as `pending` before storage is touched.
@DataClassName('HistoryRow')
@TableIndex(name: 'history_records_dst_status', columns: {#dst, #status})
class HistoryRecords extends Table {
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get opId => text()();

  /// Position in the batch; undo walks it backwards.
  IntColumn get seq => integer()();
  TextColumn get kind => text()();
  TextColumn get phase => text()();
  TextColumn get src => text()();
  TextColumn get dst => text()();
  TextColumn get groupId => text().nullable()();
  BoolColumn get selected => boolean()();
  TextColumn get warning => text().nullable()();
  TextColumn get status => text()();
  TextColumn get error => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {batchId, opId};

  @override
  List<Set<Column>> get uniqueKeys => [
    {batchId, seq},
  ];
}

@DataClassName('TaskRow')
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get connectionId => text()();
  TextColumn get pathsJson => text()();
  TextColumn get mode => text()();
  BoolColumn get scrape => boolean().withDefault(const Constant(false))();
  BoolColumn get scrapeOnly => boolean().withDefault(const Constant(false))();
  TextColumn get stage => text()();
  TextColumn get message => text()();
  IntColumn get importedCount => integer()();
  IntColumn get videoCount => integer()();
  IntColumn get folderCount => integer()();
  IntColumn get subtitleCount => integer()();
  RealColumn get progress => real().nullable()();
  TextColumn get batchId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  /// TaskReview parts, as JSON (see codec.dart). Null until recognition finished.
  TextColumn get scanJson => text().nullable()();
  TextColumn get decisionsJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Persisted directory listing cache per connection for instant Map & Health reopen.
@DataClassName('FolderStatsCacheRow')
@TableIndex(name: 'folder_stats_cache_conn', columns: {#connectionId})
class FolderStatsCache extends Table {
  TextColumn get connectionId => text()();
  TextColumn get dirPath => text()();

  /// JSON array of serialized RemoteEntry objects: {p, n, d, s, m}.
  TextColumn get entriesJson => text()();
  BoolColumn get complete => boolean().withDefault(const Constant(false))();
  DateTimeColumn get scannedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {connectionId, dirPath};
}

/// Lightweight watch mode rules (local Directory.watch + remote polling; no webhook).
@DataClassName('WatchRuleRow')
@TableIndex(name: 'watch_rules_conn', columns: {#connectionId})
class WatchRules extends Table {
  TextColumn get id => text()();
  TextColumn get connectionId => text()();
  TextColumn get path => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get intervalMinutes => integer().withDefault(const Constant(10))();
  TextColumn get mode => text().withDefault(const Constant('inPlace'))();
  BoolColumn get scrape => boolean().withDefault(const Constant(false))();
  BoolColumn get autoRunHighConfidence =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastScanAt => dateTime().nullable()();
  TextColumn get lastStatus => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [Batches, HistoryRecords, Tasks, FolderStatsCache, WatchRules],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// `<application support dir>/tidyreel.sqlite`, opened on a background isolate.
  static Future<AppDatabase> openDefault() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return AppDatabase(
      NativeDatabase.createInBackground(
        File('${dir.path}${Platform.pathSeparator}tidyreel.sqlite'),
      ),
    );
  }

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_batches_conn ON batches(connection_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_history_batch_phase '
        'ON history_records(batch_id, phase, kind, status)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createIndex(historyRecordsDstStatus);
      }
      if (from < 3) {
        await m.addColumn(tasks, tasks.scrape);
      }
      if (from < 4) {
        await m.addColumn(tasks, tasks.scrapeOnly);
        await m.createTable(folderStatsCache);
        await m.createIndex(folderStatsCacheConn);
        await m.createTable(watchRules);
        await m.createIndex(watchRulesConn);
      }
    },
  );
}
