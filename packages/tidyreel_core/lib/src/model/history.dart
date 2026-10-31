import 'ids.dart';
import 'plan.dart';

enum OpStatus { pending, done, failed, skipped, undone }

class ExecProgress {
  final ExecPhase phase;
  final int done;
  final int total;
  final OpId? current;
  final String? error;

  const ExecProgress({
    required this.phase,
    required this.done,
    required this.total,
    this.current,
    this.error,
  });
}

/// One executed op as stored in history.
class HistoryRecord {
  final BatchId batch;
  final RenameOp op;
  final OpStatus status;
  final String? error;
  final DateTime updatedAt;

  const HistoryRecord({
    required this.batch,
    required this.op,
    required this.status,
    this.error,
    required this.updatedAt,
  });
}

class BatchSummary {
  final BatchId id;
  final TaskId task;
  final ConnectionId connection;
  final DateTime createdAt;
  final int total;
  final int done;
  final int failed;
  final bool undone;

  const BatchSummary({
    required this.id,
    required this.task,
    required this.connection,
    required this.createdAt,
    required this.total,
    required this.done,
    required this.failed,
    this.undone = false,
  });
}
