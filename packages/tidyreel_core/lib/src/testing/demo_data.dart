import '../model/ids.dart';
import '../model/media.dart';
import '../model/metadata.dart';
import '../model/plan.dart';
import '../model/scan.dart';
import '../model/task.dart';

/// Canned TMDB data shared by the fakes.
abstract final class Demo {
  static const dorohedoro = Candidate(
    tmdbId: 94954,
    kind: MediaKind.episode,
    title: '异兽魔都',
    englishTitle: 'Dorohedoro',
    originalTitle: 'ドロヘドロ',
    year: 2020,
    originCountry: 'JP',
    voteAverage: 8.1,
  );
  static const dorohedoroShow = ShowDetail(
    info: dorohedoro,
    seasons: [
      SeasonInfo(number: 1, episodeCount: 12, name: '第 1 季'),
      SeasonInfo(number: 2, episodeCount: 11, name: '第 2 季'),
    ],
  );
  static const inception = Candidate(
    tmdbId: 27205,
    kind: MediaKind.movie,
    title: '盗梦空间',
    englishTitle: 'Inception',
    originalTitle: 'Inception',
    year: 2010,
    originCountry: 'US',
    voteAverage: 8.4,
  );
  static const friends = Candidate(
    tmdbId: 1668,
    kind: MediaKind.episode,
    title: '老友记',
    englishTitle: 'Friends',
    originalTitle: 'Friends',
    year: 1994,
    originCountry: 'US',
    voteAverage: 8.4,
  );
  static const onePiece = Candidate(
    tmdbId: 37854,
    kind: MediaKind.episode,
    title: '海贼王',
    englishTitle: 'One Piece',
    originalTitle: 'ワンピース',
    year: 1999,
    originCountry: 'JP',
    voteAverage: 8.7,
  );

  static const candidates = [dorohedoro, inception, friends, onePiece];

  /// A review with one TV show, one movie, one unmatched group and one junk file.
  static TaskReview review(TaskId id, ConnectionId connection, String root) {
    final showDir = '$root/异兽魔都 2020 1080p';
    final tvFiles = <ScanFile>[
      for (final (s, count) in [(1, 12), (2, 11)])
        for (var e = 1; e <= count; e++) ...[
          ScanFile(
            path:
                '$showDir/[Sub] Dorohedoro S${_pad(s)}E${_pad(e)} [1080p].mkv',
            name: '[Sub] Dorohedoro S${_pad(s)}E${_pad(e)} [1080p].mkv',
            size: 1 << 30,
            role: FileRole.video,
            parsed: ParsedName(
              title: 'Dorohedoro',
              season: s,
              episodes: [e],
              kind: MediaKind.episode,
              resolution: '1080p',
              group: 'Sub',
              confidence: 0.95,
            ),
          ),
          if (e <= 2)
            ScanFile(
              path: '$showDir/[Sub] Dorohedoro S${_pad(s)}E${_pad(e)}.chs.ass',
              name: '[Sub] Dorohedoro S${_pad(s)}E${_pad(e)}.chs.ass',
              size: 40000,
              role: FileRole.subtitle,
              parsed: ParsedName(
                title: 'Dorohedoro',
                season: s,
                episodes: [e],
                kind: MediaKind.episode,
                lang: 'chs',
                confidence: 0.95,
              ),
            ),
        ],
    ];
    const movieName = 'Inception.2010.2160p.BluRay.x265.mkv';
    final groups = [
      MediaGroup(
        id: const GroupId('g1'),
        kind: MediaKind.episode,
        anchorTitle: '异兽魔都',
        anchorYear: 2020,
        rootDir: showDir,
        files: tvFiles,
        match: dorohedoro,
        matchScore: 0.95,
        show: dorohedoroShow,
      ),
      MediaGroup(
        id: const GroupId('g2'),
        kind: MediaKind.movie,
        anchorTitle: 'Inception',
        anchorYear: 2010,
        rootDir: root,
        files: [
          ScanFile(
            path: '$root/$movieName',
            name: movieName,
            size: 20 << 30,
            role: FileRole.video,
            parsed: const ParsedName(
              title: 'Inception',
              year: 2010,
              kind: MediaKind.movie,
              resolution: '2160p',
              confidence: 0.9,
            ),
          ),
        ],
        match: inception,
        matchScore: 0.9,
      ),
      MediaGroup(
        id: const GroupId('g3'),
        kind: MediaKind.unknown,
        anchorTitle: '未知视频',
        rootDir: root,
        files: [
          ScanFile(
            path: '$root/未知视频 01.mp4',
            name: '未知视频 01.mp4',
            size: 1 << 28,
            role: FileRole.video,
            parsed: const ParsedName(
              title: '未知视频',
              episodes: [1],
              confidence: 0.2,
            ),
          ),
        ],
      ),
    ];
    final junk = ScanFile(
      path: '$root/更多资源请访问 www.example.com.txt',
      name: '更多资源请访问 www.example.com.txt',
      size: 120,
      role: FileRole.junk,
    );
    final scan = ScanResult(
      connection: connection,
      roots: [root],
      groups: groups,
      unassigned: [junk],
    );

    var n = 0;
    OpId next() => OpId('op${++n}');
    final ops = <RenameOp>[
      for (final f in tvFiles)
        RenameOp(
          id: next(),
          kind: OpKind.relocate,
          phase: ExecPhase.files,
          group: const GroupId('g1'),
          src: f.path,
          dst:
              '$showDir/Season ${_pad(f.parsed!.season!)}/'
              '异兽魔都.Dorohedoro.2020.S${_pad(f.parsed!.season!)}E${_pad(f.parsed!.episodes.first)}'
              '${f.role == FileRole.subtitle ? '.zh-Hans.ass' : '.mkv'}',
        ),
      RenameOp(
        id: next(),
        kind: OpKind.relocate,
        phase: ExecPhase.folders,
        group: const GroupId('g1'),
        src: showDir,
        dst: '$root/异兽魔都 (2020)',
      ),
      RenameOp(
        id: next(),
        kind: OpKind.mkdir,
        phase: ExecPhase.files,
        group: const GroupId('g2'),
        src: '',
        dst: '$root/盗梦空间 (2010)',
      ),
      RenameOp(
        id: next(),
        kind: OpKind.relocate,
        phase: ExecPhase.files,
        group: const GroupId('g2'),
        src: '$root/$movieName',
        dst: '$root/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv',
      ),
      RenameOp(
        id: next(),
        kind: OpKind.delete,
        phase: ExecPhase.cleanup,
        src: junk.path,
        dst: '',
        selected: false,
      ),
    ];

    return TaskReview(
      id: id,
      scan: scan,
      decisions: {
        const GroupId('g1'): const GroupDecision(),
        const GroupId('g2'): const GroupDecision(),
        const GroupId('g3'): const GroupDecision(selected: false),
      },
      preview: RenamePlan(ops: ops),
    );
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
