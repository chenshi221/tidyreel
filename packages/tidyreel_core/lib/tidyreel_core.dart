/// Tidyreel core engine. See PLAN.md §4.
library;

export 'src/model/connection.dart';
export 'src/model/history.dart';
export 'src/model/ids.dart';
export 'src/model/media.dart';
export 'src/model/metadata.dart';
export 'src/model/naming.dart';
export 'src/model/plan.dart';
export 'src/model/scan.dart';
export 'src/model/task.dart';
export 'src/model/title_rules.dart';

export 'src/parser/parser.dart';
export 'src/tmdb/metadata_provider.dart';
export 'src/tmdb/anilist.dart';
export 'src/storage/storage_backend.dart';
export 'src/storage/cached_backend.dart';
export 'src/storage/walk.dart';
export 'src/storage/direct_lan.dart' show isPrivateHost;
export 'src/plan/recognizer.dart';
export 'src/plan/strategy.dart';
export 'src/plan/template.dart';
export 'src/plan/text.dart' show relaxedQueries;
export 'src/plan/planner.dart';
export 'src/exec/executor.dart';
export 'src/task/task_manager.dart';
