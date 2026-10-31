import '../model/ids.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../tmdb/metadata_provider.dart';

/// Owner: Agent D. Turns a recognized scan + user decisions into ops, with conflict
/// detection (PLAN §4.3 rule 1). Subtitles follow their video, specials go to
/// Season 00, extras to Extras/, junk becomes unselected delete ops.
abstract interface class Planner {
  /// [existing] lists paths already present at the targets (for conflict checks);
  /// the caller fetches it from the backend.
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  });
}

class DefaultPlanner implements Planner {
  /// Used for season layouts, episode groups and episode titles (cached by the provider).
  final MetadataProvider metadata;

  DefaultPlanner(this.metadata);

  @override
  Future<RenamePlan> build(
    ScanResult scan,
    Map<GroupId, GroupDecision> decisions,
    PlanOptions options, {
    Set<String> existing = const {},
  }) => throw UnimplementedError('Agent D');
}
