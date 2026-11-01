import '../model/ids.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../model/task.dart';

/// What survives a restart for one task (PLAN §1: "任务和状态都保存在数据库里").
/// The plan is not stored: it is cheap to rebuild from [scan] + [decisions].
class StoredTask {
  final TaskSummary summary;

  /// Null until recognition has finished.
  final ScanResult? scan;
  final Map<GroupId, GroupDecision> decisions;

  const StoredTask(this.summary, {this.scan, this.decisions = const {}});
}

/// Owner: Agent E. The app implements it with drift; [MemoryTaskStore] is for tests.
abstract interface class TaskStore {
  /// Insert or update the summary row for `summary.id`.
  Future<void> saveSummary(TaskSummary summary);

  /// Stores the recognition result and the user's decisions for [id].
  Future<void> saveReview(
    TaskId id,
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
  );

  /// All stored tasks, any order.
  Future<List<StoredTask>> loadAll();

  /// Forgets [id] (summary and review). No-op if it isn't stored.
  Future<void> delete(TaskId id);
}

class MemoryTaskStore implements TaskStore {
  final _summaries = <TaskId, TaskSummary>{};
  final _reviews = <TaskId, (ScanResult, Map<GroupId, GroupDecision>)>{};

  @override
  Future<void> saveSummary(TaskSummary summary) async =>
      _summaries[summary.id] = summary;

  @override
  Future<void> saveReview(
    TaskId id,
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
  ) async => _reviews[id] = (scan, Map.of(decisions));

  @override
  Future<void> delete(TaskId id) async {
    _summaries.remove(id);
    _reviews.remove(id);
  }

  @override
  Future<List<StoredTask>> loadAll() async => [
    for (final s in _summaries.values)
      StoredTask(
        s,
        scan: _reviews[s.id]?.$1,
        decisions: _reviews[s.id]?.$2 ?? const {},
      ),
  ];
}
