import 'dart:async';

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

/// 标记为已整理 / 未整理 by hand: path → organized, for one connection. Kept in
/// prefs and never touches the files or the op history.
class OrganizedMarks extends Notifier<Map<String, bool>> {
  OrganizedMarks(this.connection);

  final ConnectionId connection;
  static const _key = 'organizedMarks';

  Map<String, Object?> get _all =>
      (ref.read(bootstrapProvider).prefs.read(_key) as Map?)
          ?.cast<String, Object?>() ??
      const {};

  @override
  Map<String, bool> build() =>
      (_all[connection.value] as Map?)?.cast<String, bool>() ?? const {};

  void mark(String path, bool organized) {
    state = {...state, path: organized};
    ref.read(bootstrapProvider).prefs.write(_key, {
      ..._all,
      connection.value: state,
    });
  }
}

final organizedMarksProvider =
    NotifierProvider.family<OrganizedMarks, Map<String, bool>, ConnectionId>(
      OrganizedMarks.new,
    );

/// One size counter per connection; it keeps its listings for the session so
/// going back up or into a counted folder needs no new requests.
/// Watches [connectionBackendProvider] so toggling favorites or editing other
/// connections never disposes this scanner, and refreshes automatically when a
/// task for this connection finishes or is undone.
final sizeScannerProvider = Provider.family<SizeScanner, ConnectionId>((
  ref,
  id,
) {
  final scanner = SizeScanner(
    backend: ref.watch(connectionBackendProvider(id)),
    organizedOf: ref.watch(mapOrganizedOfProvider(id)),
    marks: () => ref.read(organizedMarksProvider(id)),
  );
  ref.listen(organizedMarksProvider(id), (_, _) => scanner.marksChanged());
  ref.listen(tasksProvider, (prev, next) {
    final before = {
      for (final t in prev?.value ?? const <TaskSummary>[]) t.id: t.stage,
    };
    for (final t in next.value ?? const <TaskSummary>[]) {
      if (t.connection != id) continue;
      final was = before[t.id];
      if (was == null || was == t.stage) continue;
      if (t.stage == TaskStage.done ||
          t.stage == TaskStage.partiallyFailed ||
          t.stage == TaskStage.undone) {
        unawaited(scanner.forget('/'));
        break;
      }
    }
  });
  ref.onDispose(scanner.dispose);
  return scanner;
});
