import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import 'size_scanner.dart';

/// 列表 | 地图 in the file browser.
final browserMapModeProvider = NotifierProvider<Val<bool>, bool>(
  () => Val(false),
);

/// "Which of these paths has a done op produced?" for one connection. Its own
/// provider so tests and demos can paint a believable library.
final mapOrganizedOfProvider =
    Provider.family<
      Future<Set<String>> Function(Iterable<String>),
      ConnectionId
    >((ref, id) {
      final history = ref.watch(historyProvider);
      return (paths) => history.areOrganized(id, paths);
    });

/// One size counter per connection; it keeps its listings for the session so
/// going back up or into a counted folder needs no new requests.
final sizeScannerProvider = Provider.family<SizeScanner, ConnectionId>((
  ref,
  id,
) {
  final scanner = SizeScanner(
    backend: ref.watch(backendForProvider)(id),
    organizedOf: ref.watch(mapOrganizedOfProvider(id)),
  );
  ref.onDispose(scanner.dispose);
  return scanner;
});

/// Which connection the 来源页 map shows; null = the first one.
final sourcesMapConnectionProvider =
    NotifierProvider<Val<ConnectionId?>, ConnectionId?>(() => Val(null));
