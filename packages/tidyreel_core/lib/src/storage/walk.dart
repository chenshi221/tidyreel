import 'dart:async';

/// Visits folders [parallel] at a time, starting from [roots]. [visit] lists one
/// folder and returns the subfolders to descend into. Remote listings take
/// seconds each, so walking them one by one is what made scans slow. An error
/// from [visit] stops the walk and is rethrown.
Future<void> walkDirs(
  Iterable<String> roots,
  Future<Iterable<String>> Function(String dir) visit, {
  int parallel = 6,
  bool Function()? stop,
}) {
  final queue = [...roots];
  final done = Completer<void>();
  var active = 0;

  void pump() {
    if (done.isCompleted) return;
    if (stop?.call() ?? false) queue.clear();
    while (active < parallel && queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      active++;
      visit(dir).then(
        (subs) {
          active--;
          queue.addAll(subs);
          pump();
        },
        onError: (Object e, StackTrace s) {
          active--;
          if (!done.isCompleted) done.completeError(e, s);
        },
      );
    }
    if (active == 0 && queue.isEmpty) done.complete();
  }

  pump();
  return done.future;
}
