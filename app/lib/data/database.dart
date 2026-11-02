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

@DriftDatabase(tables: [Batches, HistoryRecords, Tasks])
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
  int get schemaVersion => 1;
}
