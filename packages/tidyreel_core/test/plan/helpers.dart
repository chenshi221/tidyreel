import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

/// Wraps [FakeMetadataProvider] with episode groups for the layout tests.
class GroupedMetadata extends FakeMetadataProvider {
  final List<EpisodeGroup> groups;
  GroupedMetadata(this.groups);

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async => groups;
}

List<RemoteEntry> entriesOf(Iterable<String> paths) => [
  for (final path in paths)
    RemoteEntry(
      path: path,
      name: p.posix.basename(path),
      isDir: false,
      size: 1,
    ),
];

/// Applies the selected ops in plan order, the way the executor will (without history).
Future<void> applyPlan(RenamePlan plan, MemoryStorageBackend be) async {
  for (final op in plan.ops.where((o) => o.selected)) {
    switch (op.kind) {
      case OpKind.mkdir:
        await be.mkdirs(op.dst);
      case OpKind.relocate:
        if (op.src == op.dst) continue;
        final srcDir = p.posix.dirname(op.src);
        final dstDir = p.posix.dirname(op.dst);
        if (srcDir == dstDir) {
          await be.rename(op.src, p.posix.basename(op.dst));
        } else {
          final name = p.posix.basename(op.dst);
          var cur = op.src;
          if (p.posix.basename(op.src) != name) {
            await be.rename(op.src, name);
            cur = p.posix.join(srcDir, name);
          }
          await be.mkdirs(dstDir);
          await be.move(p.posix.dirname(cur), dstDir, [name]);
        }
      case OpKind.delete:
        await be.remove(p.posix.dirname(op.src), [p.posix.basename(op.src)]);
      case OpKind.write:
        await be.write(
          op.dst,
          op.src.startsWith(writeTextPrefix)
              ? utf8.encode(op.src.substring(writeTextPrefix.length))
              : [0],
        );
    }
  }
}

ScanFile video(
  String path, {
  int? season,
  int? episode,
  int? absolute,
  MediaKind kind = MediaKind.episode,
  double confidence = 0.9,
  String? title = 'Dorohedoro',
}) => ScanFile(
  path: path,
  name: p.posix.basename(path),
  size: 1,
  role: FileRole.video,
  parsed: ParsedName(
    title: title,
    season: season,
    episodes: episode == null ? const [] : [episode],
    absolute: absolute,
    kind: kind,
    resolution: '1080p',
    confidence: confidence,
  ),
);

ScanFile other(String path, FileRole role, {String? lang}) => ScanFile(
  path: path,
  name: p.posix.basename(path),
  size: 1,
  role: role,
  parsed: role == FileRole.junk
      ? null
      : ParsedName(lang: lang, confidence: 0.9),
);

MediaGroup tvGroup(
  List<ScanFile> files, {
  String rootDir = '/d/异兽魔都 2020',
  Candidate? match = Demo.dorohedoro,
  ShowDetail? show = Demo.dorohedoroShow,
  double score = 0.95,
  String id = 'g1',
}) => MediaGroup(
  id: GroupId(id),
  kind: MediaKind.episode,
  anchorTitle: '异兽魔都',
  anchorYear: 2020,
  rootDir: rootDir,
  files: files,
  match: match,
  matchScore: score,
  show: show,
);

ScanResult scanOf(
  List<MediaGroup> groups, {
  List<ScanFile> unassigned = const [],
  List<String> roots = const ['/d'],
}) => ScanResult(
  connection: const ConnectionId('c'),
  roots: roots,
  groups: groups,
  unassigned: unassigned,
);

/// File-phase relocate ops (the group folder rename is checked separately).
List<RenameOp> fileOps(RenamePlan plan) => [
  for (final o in plan.ops)
    if (o.kind == OpKind.relocate && o.phase == ExecPhase.files) o,
];

Map<String, String> moves(RenamePlan plan) => {
  for (final o in fileOps(plan)) o.src: o.dst,
};
