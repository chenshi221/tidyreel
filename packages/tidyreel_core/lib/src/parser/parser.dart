import '../model/media.dart';

/// Owner: Agent A. PLAN §4.5.
abstract interface class FilenameParser {
  /// [parentDirs] are folder names from nearest to farthest, e.g. ["Season 6", "权力的游戏"].
  ParsedName parse(String fileName, {List<String> parentDirs = const []});

  /// By extension and name only (video / subtitle / sidecar / junk / other).
  FileRole classify(String fileName);
}

class RuleBasedParser implements FilenameParser {
  const RuleBasedParser();

  @override
  ParsedName parse(String fileName, {List<String> parentDirs = const []}) =>
      throw UnimplementedError('Agent A');

  @override
  FileRole classify(String fileName) => throw UnimplementedError('Agent A');
}
