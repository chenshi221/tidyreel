import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

const s1 = '/d/异兽魔都 S01';
const s2 = '/d/异兽魔都 S02';
const out = '/d/异兽魔都 (2020)';

final scan = scanOf([
  tvGroup([video('$s1/E01.mkv', season: 1, episode: 1)], rootDir: s1),
  tvGroup([video('$s2/E01.mkv', season: 2, episode: 1)], rootDir: s2, id: 'g2'),
]);

Future<(RenamePlan, MemoryStorageBackend)> run(
  Map<GroupId, GroupDecision> decisions, {
  Map<String, int> extra = const {},
}) async {
  final be = MemoryStorageBackend({
    '$s1/E01.mkv': 1,
    '$s2/E01.mkv': 1,
    ...extra,
  });
  final p = await DefaultPlanner(FakeMetadataProvider()).build(
    scan,
    decisions,
    const PlanOptions(),
    // What the task manager's probe finds: files and every folder above them.
    existing: {
      ...be.files,
      for (final f in be.files)
        for (var d = dirOf(f); d.length > 1; d = dirOf(d)) d,
    },
  );
  expect(p.canExecute, isTrue, reason: '${p.conflicts.map((c) => c.reason)}');
  await applyPlan(p, be);
  return (p, be);
}

String dirOf(String f) {
  final i = f.lastIndexOf('/');
  return i <= 0 ? '/' : f.substring(0, i);
}

void main() {
  test('two downloads of one show merge into one folder', () async {
    final (p, be) = await run(const {});
    expect(p.merges.single.group, const GroupId('g2'));
    expect(p.merges.single.into, out);
    expect(p.merges.single.withGroup, const GroupId('g1'));
    expect(p.merges.single.exists, isFalse);
    expect(p.merges.single.seasons, [2]);
    expect(be.files.where((f) => f.startsWith('$out/')), hasLength(2));
    expect(be.files.where((f) => f.contains('Season 02')), hasLength(1));
  });

  test('分开保留 keeps the second folder', () async {
    final (p, be) = await run({
      const GroupId('g2'): const GroupDecision(separate: true),
    });
    expect(p.merges, isEmpty);
    expect(be.files.where((f) => f.startsWith('$out/')), hasLength(1));
    expect(be.files.where((f) => f.startsWith('$s2/')), hasLength(1));
  });

  test('a show folder already on disk is merged into', () async {
    final (p, be) = await run(const {}, extra: {'$out/Season 01/old.mkv': 1});
    final m = p.merges.firstWhere((m) => m.group == const GroupId('g1'));
    expect(m.exists, isTrue);
    expect(m.into, out);
    expect(be.files.where((f) => f.startsWith('$out/')), hasLength(3));
  });
}
