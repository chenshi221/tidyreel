import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/review/review_panes.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  testWidgets('merge dialog says where, what is there, and can keep apart', (
    tester,
  ) async {
    const into = '/库/异兽魔都 (2020)';
    final be = MemoryStorageBackend({
      '$into/Season 01/a.mkv': 1,
      '$into/Season 02/b.mkv': 1,
    });
    const g = MediaGroup(
      id: GroupId('g5'),
      kind: MediaKind.episode,
      anchorTitle: '异兽魔都',
      rootDir: '/下载/异兽魔都 S05',
      files: [],
      match: Demo.dorohedoro,
    );
    final review = TaskReview(
      id: const TaskId('t'),
      scan: const ScanResult(
        connection: ConnectionId('c'),
        roots: ['/下载'],
        groups: [g],
        unassigned: [],
      ),
      decisions: const {},
      preview: const RenamePlan(ops: []),
    );
    Set<GroupId>? result = {};
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showMergeDialog(
              context,
              review: review,
              merges: const [
                PlanMerge(
                  group: GroupId('g5'),
                  into: into,
                  exists: true,
                  seasons: [5],
                ),
              ],
              backend: be,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('合并到 $into'), findsOneWidget);
    expect(find.text('已有：Season 01、Season 02'), findsOneWidget);
    expect(find.text('本次新增：Season 05'), findsOneWidget);

    await tester.tap(find.text('分开保留'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('merge-continue')));
    await tester.pumpAndSettle();
    expect(result, {const GroupId('g5')});
  });
}
