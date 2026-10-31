import 'ids.dart';
import 'media.dart';
import 'metadata.dart';
import 'naming.dart';

/// PLAN §2.
enum SeasonStrategy {
  /// 默认：识别到的季集.
  asParsed,

  /// 顺序拆多季 (龙珠Z): episodes restart at 1 in each season.
  splitSequential,

  /// 跳序拆多季 (海贼王): season changes, absolute episode number kept.
  splitKeepEpisode,

  /// 多季合并一季 (名侦探柯南): everything in S01, episodes accumulate.
  mergeIntoOne,
}

enum OrganizeMode { inPlace, moveToLibrary }

/// Manual correction of a single file in the review page.
class FileOverride {
  final int? season;
  final int? episode;
  final MediaKind? kind;
  final bool ignore;

  const FileOverride({
    this.season,
    this.episode,
    this.kind,
    this.ignore = false,
  });
}

/// Everything the user decided about one [MediaGroup].
class GroupDecision {
  /// Overrides the auto match (纠错). Null keeps [MediaGroup.match].
  final Candidate? match;
  final SeasonStrategy strategy;

  /// Applied before the strategy.
  final int episodeOffset;

  /// TMDB episode group used as the season layout instead of the default seasons.
  final String? episodeGroupId;

  /// Keyed by [ScanFile.path].
  final Map<String, FileOverride> overrides;
  final bool selected;

  const GroupDecision({
    this.match,
    this.strategy = SeasonStrategy.asParsed,
    this.episodeOffset = 0,
    this.episodeGroupId,
    this.overrides = const {},
    this.selected = true,
  });

  GroupDecision copyWith({
    Candidate? match,
    SeasonStrategy? strategy,
    int? episodeOffset,
    String? Function()? episodeGroupId,
    Map<String, FileOverride>? overrides,
    bool? selected,
  }) => GroupDecision(
    match: match ?? this.match,
    strategy: strategy ?? this.strategy,
    episodeOffset: episodeOffset ?? this.episodeOffset,
    episodeGroupId: episodeGroupId != null
        ? episodeGroupId()
        : this.episodeGroupId,
    overrides: overrides ?? this.overrides,
    selected: selected ?? this.selected,
  );
}

class PlanOptions {
  final OrganizeMode mode;

  /// Required for [OrganizeMode.moveToLibrary].
  final String? libraryRoot;
  final NamingProfile naming;

  /// Junk deletion ops are generated but unselected unless this is true.
  final bool deleteJunk;

  /// Rows below this parse/match confidence start unselected.
  final double confidenceThreshold;

  const PlanOptions({
    this.mode = OrganizeMode.inPlace,
    this.libraryRoot,
    this.naming = NamingProfile.vidhub,
    this.deleteJunk = false,
    this.confidenceThreshold = 0.7,
  });
}

/// Execution order: all [files] ops, then [folders], then [cleanup].
enum ExecPhase { files, folders, cleanup }

enum OpKind {
  mkdir,

  /// Move and/or rename src -> dst. The executor picks rename vs move calls.
  relocate,
  delete,
}

class RenameOp {
  final OpId id;
  final OpKind kind;
  final ExecPhase phase;

  /// Empty for mkdir.
  final String src;

  /// Empty for delete.
  final String dst;
  final GroupId? group;
  final bool selected;

  /// Shown in yellow, e.g. "超出 TMDB 总集数".
  final String? warning;

  const RenameOp({
    required this.id,
    required this.kind,
    required this.phase,
    required this.src,
    required this.dst,
    this.group,
    this.selected = true,
    this.warning,
  });
}

class PlanConflict {
  /// Ops that target the same path, or a target that already exists.
  final List<OpId> ops;
  final String path;
  final String reason;

  const PlanConflict({
    required this.ops,
    required this.path,
    required this.reason,
  });
}

class RenamePlan {
  final List<RenameOp> ops;

  /// Non-empty means the plan must not run (PLAN §4.3 rule 1).
  final List<PlanConflict> conflicts;

  const RenamePlan({required this.ops, this.conflicts = const []});

  bool get canExecute => conflicts.isEmpty;
}
