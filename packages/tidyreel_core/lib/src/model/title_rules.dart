import 'metadata.dart';
import 'naming.dart' show NameRewrite;

/// A title that always means one work (命名规则 › 片名规则 › 指定匹配), for
/// names TMDB never finds on its own.
class TitlePin {
  /// Found in the folder name or parsed title (case-insensitive) → [match].
  final String keyword;
  final Candidate match;

  const TitlePin(this.keyword, this.match);
}

/// User rules for turning folder / file names into TMDB searches.
class TitleRules {
  /// Find/replace (regex) on each title before it is searched, in order;
  /// e.g. `^【.*?】` → '' drops a "【日剧】" prefix.
  final List<NameRewrite> cleanups;
  final List<TitlePin> pins;

  const TitleRules({this.cleanups = const [], this.pins = const []});
}
