import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/review/review_logic.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  // "10.mkv … 13.mkv" planned as S01E10…S01E13, but season 1 has 11 episodes.
  const parser = RuleBasedParser();
  final files = [
    for (final n in [10, 11, 12, 13])
      ScanFile(
        path: '/s/$n.mkv',
        name: '$n.mkv',
        size: 1,
        role: FileRole.video,
        parsed: parser.parse('$n.mkv', parentDirs: const ['老友记']),
      ),
  ];
  final g = MediaGroup(
    id: const GroupId('g'),
    kind: MediaKind.episode,
    anchorTitle: '老友记',
    rootDir: '/s',
    files: files,
    match: Demo.friends,
    show: const ShowDetail(
      info: Demo.friends,
      seasons: [
        SeasonInfo(number: 1, episodeCount: 11),
        SeasonInfo(number: 2, episodeCount: 10),
      ],
    ),
  );
  final rows = [
    for (final f in files)
      ReviewRow(
        f,
        RenameOp(
          id: OpId(f.name),
          kind: OpKind.relocate,
          phase: ExecPhase.files,
          src: f.path,
          dst: '/s/Season 01/老友记.S01E${f.name.substring(0, 2)}.mkv',
        ),
        null,
        1,
        false,
      ),
  ];

  test('seasonOverflow finds the first file past the end of season 1', () {
    final o = seasonOverflow(g, null, rows)!;
    expect(o.row.file.name, '12.mkv');
    expect(o.target, const EpisodeRef(1, 12));
    expect(o.size, 11);
  });

  test('shiftFrom renumbers later files and rolls into the next season', () {
    final set = shiftFrom(g, null, rows, rows[1], const EpisodeRef(1, 10));
    expect(
      {
        for (final e in set.entries)
          e.key: EpisodeRef(e.value.season!, e.value.episode!),
      },
      {
        '/s/11.mkv': const EpisodeRef(1, 10),
        '/s/12.mkv': const EpisodeRef(1, 11),
        '/s/13.mkv': const EpisodeRef(2, 1),
      },
    );
  });
}
