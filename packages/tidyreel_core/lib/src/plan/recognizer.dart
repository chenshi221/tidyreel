import '../model/ids.dart';
import '../model/scan.dart';
import '../parser/parser.dart';
import '../tmdb/metadata_provider.dart';

/// Owner: Agent D. Classify + parse + anchor grouping + TMDB match (PLAN §1 step 4).
abstract interface class Recognizer {
  /// [files] is the recursive listing of [roots] (files only).
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files,
  );
}

class AnchorRecognizer implements Recognizer {
  final FilenameParser parser;
  final MetadataProvider metadata;

  AnchorRecognizer(this.parser, this.metadata);

  @override
  Future<ScanResult> recognize(
    ConnectionId connection,
    List<String> roots,
    List<RemoteEntry> files,
  ) => throw UnimplementedError('Agent D');
}
