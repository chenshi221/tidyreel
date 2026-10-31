import '../model/ids.dart';
import '../model/plan.dart';
import '../model/task.dart';

export 'default_task_manager.dart';
export 'task_store.dart';

/// Owner: Agent E. Orchestrates list -> recognize -> review -> plan -> execute
/// for several concurrent tasks (PLAN §1). The UI talks only to this.
abstract interface class TaskManager {
  Future<TaskId> submit(
    ConnectionId connection,
    List<String> paths,
    OrganizeMode mode,
  );

  /// All tasks, newest first; emits on every change.
  Stream<List<TaskSummary>> watchAll();

  /// Available from [TaskStage.awaitingReview] on.
  Future<TaskReview> review(TaskId id);

  /// Re-plans and returns the updated review.
  Future<TaskReview> updateDecision(
    TaskId id,
    GroupId group,
    GroupDecision decision,
  );

  Future<TaskReview> setMode(TaskId id, OrganizeMode mode);

  /// [onlyConfident]: 立即执行 — run only high-confidence, conflict-free ops.
  Future<void> run(TaskId id, {bool onlyConfident = false});

  Future<void> cancel(TaskId id);

  Future<void> undo(TaskId id, {Set<OpId>? only});
}
