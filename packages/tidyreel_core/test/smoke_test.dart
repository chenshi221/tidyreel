import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  test('fake task runs the whole stage sequence', () async {
    final tm = FakeTaskManager(step: Duration.zero);
    const conn = ConnectionId('c1');
    final seen = <TaskStage>{};
    final sub = tm.watchAll().listen(
      (ts) => seen.addAll(ts.map((t) => t.stage)),
    );

    final id = await tm.submit(conn, ['/下载'], OrganizeMode.inPlace);
    await tm.watchAll().firstWhere(
      (ts) => ts.single.stage == TaskStage.awaitingReview,
    );

    final review = await tm.review(id);
    expect(review.scan.groups.map((g) => g.match?.title), [
      '异兽魔都',
      '盗梦空间',
      null,
    ]);
    expect(review.preview.canExecute, isTrue);

    await tm.run(id);
    await Future<void>.delayed(Duration.zero);
    expect(
      seen,
      containsAll(
        TaskStage.values.where((s) => s.index <= TaskStage.done.index),
      ),
    );
    await sub.cancel();
    tm.dispose();
  });

  test('memory backend: rename, move, conflicts, remove', () async {
    final be = MemoryStorageBackend({'/dl/a.mkv': 10, '/dl/sub/b.ass': 1});
    await be.rename('/dl/a.mkv', 'A.mkv');
    await be.mkdirs('/lib/电影');
    await be.move('/dl', '/lib/电影', ['A.mkv', 'sub']);
    expect(be.files, ['/lib/电影/A.mkv', '/lib/电影/sub/b.ass']);
    expect(
      () => be.rename('/lib/电影/A.mkv', 'sub'),
      throwsA(
        isA<StorageException>().having(
          (e) => e.code,
          'code',
          StorageErrorCode.alreadyExists,
        ),
      ),
    );
    await be.remove('/lib/电影', ['sub']);
    expect(be.files, ['/lib/电影/A.mkv']);
    expect((await be.list('/lib')).single.isDir, isTrue);
  });

  test('memory history: batch lifecycle and isOrganized', () async {
    final h = MemoryHistoryStore();
    const conn = ConnectionId('c1');
    const op = RenameOp(
      id: OpId('o1'),
      kind: OpKind.relocate,
      phase: ExecPhase.files,
      src: '/a.mkv',
      dst: '/A.mkv',
    );
    final b = await h.beginBatch(const TaskId('t1'), conn, [op]);
    expect(await h.isOrganized(conn, '/A.mkv'), isFalse);
    await h.mark(b, op.id, OpStatus.done);
    expect(await h.isOrganized(conn, '/A.mkv'), isTrue);
    expect((await h.batches()).single.done, 1);
  });

  test('fake metadata search matches any title language', () async {
    final m = FakeMetadataProvider();
    expect((await m.search('dorohedoro')).single.title, '异兽魔都');
    expect((await m.search('盗梦', kind: MediaKind.episode)), isEmpty);
    expect((await m.show(Demo.dorohedoro.tmdbId)).seasons.length, 2);
  });
}
