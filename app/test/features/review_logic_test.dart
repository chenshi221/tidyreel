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

  test('effectiveGroup follows the match, not the first guess', () {
    final movie = MediaGroup(
      id: const GroupId('m'),
      kind: MediaKind.movie,
      anchorTitle: '翠鸟',
      rootDir: '/s',
      files: files,
      match: Demo.inception,
    );
    expect(identical(effectiveGroup(movie, null), movie), isTrue);
    final show = effectiveGroup(
      movie,
      const GroupDecision(match: Demo.friends),
    );
    expect(show.kind, MediaKind.episode);
    expect(show.files, files);
  });

  test(
    'shiftFrom preserves missing-episode gaps and rolls gaps across seasons',
    () {
      const gapped = [10, 11, 13];
      final gapFiles = [
        for (final n in gapped)
          ScanFile(
            path: '/s/$n.mkv',
            name: '$n.mkv',
            size: 1,
            role: FileRole.video,
            parsed: parser.parse('$n.mkv', parentDirs: const ['老友记']),
          ),
      ];
      final gapRows = [
        for (final f in gapFiles) ReviewRow(f, null, null, 1, false),
      ];
      final set = shiftFrom(
        g,
        null,
        gapRows,
        gapRows[0],
        const EpisodeRef(1, 10),
      );
      expect(
        {
          for (final e in set.entries)
            e.key: EpisodeRef(e.value.season!, e.value.episode!),
        },
        {
          '/s/10.mkv': const EpisodeRef(1, 10),
          '/s/11.mkv': const EpisodeRef(1, 11),
          '/s/13.mkv': const EpisodeRef(2, 2),
        },
      );
    },
  );

  test('shiftFrom keeps duplicate representations together and skips parsed specials', () {
    final dupFiles = [
      ScanFile(
        path: '/s/12.mkv',
        name: '12.mkv',
        size: 1,
        role: FileRole.video,
        parsed: parser.parse('12.mkv', parentDirs: const ['老友记']),
      ),
      const ScanFile(
        path: '/s/14.v1.mkv',
        name: '14.v1.mkv',
        size: 1,
        role: FileRole.video,
        parsed: ParsedName(season: 1, episodes: [14], confidence: 0.9),
      ),
      const ScanFile(
        path: '/s/14.v2.mkv',
        name: '14.v2.mkv',
        size: 1,
        role: FileRole.video,
        parsed: ParsedName(season: 1, episodes: [14], confidence: 0.9),
      ),
      const ScanFile(
        path: '/s/SP13.mkv',
        name: 'SP13.mkv',
        size: 1,
        role: FileRole.video,
        parsed: ParsedName(
          kind: MediaKind.special,
          season: 0,
          episodes: [13],
          confidence: 0.9,
        ),
      ),
    ];
    final dupRows = [
      for (final f in dupFiles)
        ReviewRow(f, null, null, f.parsed?.season ?? 1, false),
    ];
    final set = shiftFrom(g, null, dupRows, dupRows[0], const EpisodeRef(2, 1));
    expect(
      {
        for (final e in set.entries)
          e.key: EpisodeRef(e.value.season!, e.value.episode!),
      },
      {
        '/s/12.mkv': const EpisodeRef(2, 1),
        '/s/14.v1.mkv': const EpisodeRef(2, 3),
        '/s/14.v2.mkv': const EpisodeRef(2, 3),
      },
    );
  });

  test('shiftFollowingCount counts later main videos in same local season', () {
    expect(shiftFollowingCount(rows, rows[0]), 3);
    expect(shiftFollowingCount(rows, rows[2]), 1);
    expect(shiftFollowingCount(rows, rows[3]), 0);
  });

  test('conflictGroups and firstConflictLocation locate conflicting group and season', () {
    final op1 = RenameOp(
      id: const OpId('o1'),
      kind: OpKind.relocate,
      phase: ExecPhase.files,
      src: '/s/10.mkv',
      dst: '/s/Season 01/老友记.S01E10.mkv',
      group: const GroupId('g'),
    );
    final review = TaskReview(
      id: const TaskId('t'),
      scan: ScanResult(
        connection: const ConnectionId('c'),
        roots: const ['/s'],
        groups: [g],
      ),
      decisions: const {},
      preview: RenamePlan(
        ops: [op1],
        conflicts: const [
          PlanConflict(
            ops: [OpId('o1')],
            path: '/s/Season 01/老友记.S01E10.mkv',
            reason: '目标位置已存在同名文件或文件夹',
          ),
        ],
      ),
    );
    expect(conflictGroups(review), {const GroupId('g')});
    final loc = firstConflictLocation(review);
    expect(loc?.group, const GroupId('g'));
    expect(loc?.season, 1);
    final builtRows = rowsOf(g, null, review);
    expect(builtRows.first.conflict, isTrue);
    expect(builtRows.first.conflictReason, '目标位置已存在同名文件或文件夹');
  });
}
