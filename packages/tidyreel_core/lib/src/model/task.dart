import 'ids.dart';
import 'plan.dart';
import 'scan.dart';

/// PLAN §1 task state machine.
enum TaskStage {
  importing,
  recognizing,
  awaitingReview,
  renamingFiles,
  renamingFolders,
  done,
  partiallyFailed,
  cancelled,
  undone;

  bool get isActive => index <= renamingFolders.index;
}

/// Whether [TaskManager.retry] accepts [t]: nothing of it is on disk.
bool canRetry(TaskSummary t) =>
    t.stage == TaskStage.undone ||
    (t.stage == TaskStage.cancelled && t.batch == null);

/// A card in the 任务中心.
class TaskSummary {
  final TaskId id;
  final ConnectionId connection;
  final List<String> paths;
  final OrganizeMode mode;

  /// 刮削: also write .nfo files and TMDB artwork (PlanOptions.scrape).
  final bool scrape;
  final TaskStage stage;

  /// Human-readable status line, e.g. "锚点识别完成，正在进行后续处理".
  final String message;

  /// Live count while importing.
  final int importedCount;
  final int videoCount;
  final int folderCount;
  final int subtitleCount;

  /// Progress within the current stage, 0..1. Null = indeterminate.
  final double? progress;

  /// Set once executed; used for undo.
  final BatchId? batch;
  final DateTime createdAt;

  const TaskSummary({
    required this.id,
    required this.connection,
    required this.paths,
    required this.mode,
    this.scrape = false,
    required this.stage,
    this.message = '',
    this.importedCount = 0,
    this.videoCount = 0,
    this.folderCount = 0,
    this.subtitleCount = 0,
    this.progress,
    this.batch,
    required this.createdAt,
  });
}

/// Everything the review page needs for one task.
class TaskReview {
  final TaskId id;
  final ScanResult scan;
  final Map<GroupId, GroupDecision> decisions;

  /// Plan rendered from [scan] + [decisions] + current options.
  final RenamePlan preview;

  const TaskReview({
    required this.id,
    required this.scan,
    required this.decisions,
    required this.preview,
  });
}
