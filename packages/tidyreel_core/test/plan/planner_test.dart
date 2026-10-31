import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';
import 'test_parser.dart';

const conn = ConnectionId('c');
const root = '/d/异兽魔都 2020';
const season1Dir = '$root/Season 01';
const name = '异兽魔都.Dorohedoro.2020';

DefaultPlanner planner([MetadataProvider? m]) =>
    DefaultPlanner(m ?? FakeMetadataProvider());

Future<RenamePlan> plan(
  ScanResult scan, {
  Map<GroupId, GroupDecision> decisions = const {},
  PlanOptions options = const PlanOptions(),
  Set<String> existing = const {},
  MetadataProvider? metadata,
}) => planner(metadata).build(scan, decisions, options, existing: existing);

RenameOp opFor(RenamePlan p, String src) =>
    p.ops.firstWhere((o) => o.src == src);

void main() {
  group('end to end (recognizer + planner + memory backend)', () {
    test('异兽魔都 two seasons with subtitles, in place', () async {
      const show = '/下载/异兽魔都 2020 1080p';
      const e1 = '[Sub] Dorohedoro S01E01 [1080p]';
      final paths = [
        '$show/Season 1/$e1.mkv',
        '$show/Season 1/$e1.chs.ass',
        '$show/Season 1/$e1.eng.srt',
        '$show/Season 1/[Sub] Dorohedoro S01E02 [1080p].mkv',
        '$show/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv',
        '$show/Season 2/[Sub] Dorohedoro S02E01 [1080p].cht.ass',
        '$show/Extras/花絮 PV.mkv',
        '$show/RARBG.txt',
        '/下载/其他/readme.pdf',
      ];
      final meta = FakeMetadataProvider();
      final scan = await AnchorRecognizer(
        const TestParser(),
        meta,
      ).recognize(conn, ['/下载'], entriesOf(paths));
      final backend = MemoryStorageBackend({for (final p in paths) p: 1});

      final p = await planner(meta).build(
        scan,
        const {},
        const PlanOptions(),
        existing: {for (final f in backend.files) f},
      );
      expect(
        p.canExecute,
        isTrue,
        reason: '${p.conflicts.map((c) => c.reason)}',
      );
      await applyPlan(p, backend);

      const out = '/下载/异兽魔都 (2020)';
      expect(
        backend.files,
        [
          '/下载/其他/readme.pdf',
          '$out/Extras/花絮 PV.mkv',
          '$out/RARBG.txt', // junk stays unless deleteJunk
          '$out/Season 01/$name.S01E01.en.srt',
          '$out/Season 01/$name.S01E01.mkv',
          '$out/Season 01/$name.S01E01.zh-Hans.ass',
          '$out/Season 01/$name.S01E02.mkv',
          '$out/Season 02/$name.S02E01.mkv',
          '$out/Season 02/$name.S02E01.zh-Hant.ass',
        ]..sort(),
      );
      // Group folder is renamed in the folders phase, after all file ops.
      final folderOps = p.ops.where((o) => o.phase == ExecPhase.folders);
      expect(folderOps.single.src, show);
      expect(folderOps.single.dst, out);
      final lastFile = p.ops.lastIndexWhere((o) => o.phase == ExecPhase.files);
      expect(p.ops.indexOf(folderOps.single), greaterThan(lastFile));
    });

    test(
      'junk is deleted after the folder rename when deleteJunk is on',
      () async {
        const show = '/下载/异兽魔都 2020 1080p';
        final paths = [
          '$show/[Sub] Dorohedoro S01E01 [1080p].mkv',
          '$show/RARBG.txt',
        ];
        final meta = FakeMetadataProvider();
        final scan = await AnchorRecognizer(
          const TestParser(),
          meta,
        ).recognize(conn, ['/下载'], entriesOf(paths));
        final backend = MemoryStorageBackend({for (final p in paths) p: 1});
        final p = await planner(meta)
            .build(scan, const {}, const PlanOptions(deleteJunk: true));
        final del = p.ops.singleWhere((o) => o.kind == OpKind.delete);
        expect(del.phase, ExecPhase.cleanup);
        expect(del.src, '/下载/异兽魔都 (2020)/RARBG.txt');
        expect(del.selected, isTrue);
        await applyPlan(p, backend);
        expect(backend.files, ['/下载/异兽魔都 (2020)/Season 01/$name.S01E01.mkv']);
      },
    );

    test('盗梦空间 movie moved into the library', () async {
      const src = '/下载/Inception.2010.1080p.BluRay';
      final paths = [
        '$src/Inception.2010.1080p.BluRay.mkv',
        '$src/Inception.2010.1080p.BluRay.chs.srt',
        '$src/Inception.2010.1080p.BluRay.nfo',
        '$src/Extras/花絮.mkv',
        '$src/www.site.url',
      ];
      final meta = FakeMetadataProvider();
      final scan = await AnchorRecognizer(
        const TestParser(),
        meta,
      ).recognize(conn, ['/下载'], entriesOf(paths));
      final backend = MemoryStorageBackend({for (final p in paths) p: 1});
      final p = await planner(meta).build(
        scan,
        const {},
        const PlanOptions(
          mode: OrganizeMode.moveToLibrary,
          libraryRoot: '/影视库',
        ),
      );
      expect(p.canExecute, isTrue);
      expect(p.ops.where((o) => o.kind == OpKind.mkdir).map((o) => o.dst), [
        '/影视库/电影',
        '/影视库/电影/盗梦空间 (2010)',
        '/影视库/电影/盗梦空间 (2010)/Extras',
      ]);
      expect(
        p.ops
            .where((o) => o.kind == OpKind.mkdir)
            .every((o) => o.phase == ExecPhase.files),
        isTrue,
      );
      // mkdirs come before any relocate.
      final firstMove = p.ops.indexWhere((o) => o.kind == OpKind.relocate);
      expect(
        p.ops.indexWhere((o) => o.kind == OpKind.mkdir),
        lessThan(firstMove),
      );
      expect(p.ops.where((o) => o.phase == ExecPhase.folders), isEmpty);
      await applyPlan(p, backend);
      const lib = '/影视库/电影/盗梦空间 (2010)';
      expect(
        backend.files,
        [
          '$lib/Extras/花絮.mkv',
          '$lib/盗梦空间.Inception.2010.mkv',
          '$lib/盗梦空间.Inception.2010.nfo',
          '$lib/盗梦空间.Inception.2010.zh-Hans.srt',
          '$src/www.site.url',
        ]..sort(),
      );
    });

    test('conflicts block the plan', () async {
      final meta = FakeMetadataProvider();
      final paths = [
        '/dl/Inception.2010.1080p.mkv',
        '/dl/Inception.2010.2160p.mkv',
      ];
      final scan = await AnchorRecognizer(
        const TestParser(),
        meta,
      ).recognize(conn, ['/dl'], entriesOf(paths));
      const options = PlanOptions(
        mode: OrganizeMode.moveToLibrary,
        libraryRoot: '/lib',
      );

      // Two files, one target name.
      var p = await planner(meta).build(scan, const {}, options);
      expect(p.canExecute, isFalse);
      expect(
        p.conflicts.single.path,
        '/lib/电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv',
      );
      expect(p.conflicts.single.ops.length, 2);
      expect(p.conflicts.single.reason, contains('同一个路径'));

      // Keep only one; it now collides with a file that is already there.
      final only = ScanResult(
        connection: conn,
        roots: scan.roots,
        groups: [
          MediaGroup(
            id: scan.groups.single.id,
            kind: MediaKind.movie,
            anchorTitle: 'Inception',
            rootDir: '/dl',
            files: [scan.groups.single.files.first],
            match: Demo.inception,
            matchScore: 1,
          ),
        ],
      );
      p = await planner(meta).build(
        only,
        const {},
        options,
        existing: {'/lib/电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv'},
      );
      expect(p.canExecute, isFalse);
      expect(p.conflicts.single.reason, contains('已存在'));
      expect(p.conflicts.single.ops.single, p.ops.last.id);

      // Nothing in the way: fine.
      p = await planner(meta).build(only, const {}, options);
      expect(p.canExecute, isTrue);
    });
  });

  group('conflict rules', () {
    final files = [
      video('$season1Dir/$name.S01E01.mkv', season: 1, episode: 1),
      video('$season1Dir/$name.S01E02.mkv', season: 1, episode: 2),
    ];

    test('renames that shift into each other are not conflicts', () async {
      final p = await plan(
        scanOf([tvGroup(files)]),
        decisions: {const GroupId('g1'): const GroupDecision(episodeOffset: 1)},
        existing: {for (final f in files) f.path, root},
      );
      expect(moves(p), {
        files[0].path: '$season1Dir/$name.S01E02.mkv',
        files[1].path: '$season1Dir/$name.S01E03.mkv',
      });
      expect(p.canExecute, isTrue);
    });

    test('a target that exists and is not moving away is a conflict', () async {
      final p = await plan(
        scanOf([tvGroup(files)]),
        decisions: {const GroupId('g1'): const GroupDecision(episodeOffset: 1)},
        existing: {'$season1Dir/$name.S01E03.mkv'},
      );
      expect(p.conflicts.single.path, '$season1Dir/$name.S01E03.mkv');
    });

    test(
      'an in-place folder rename onto an existing folder conflicts',
      () async {
        final f = video('/d/Dorohedoro 2020/e.mkv', season: 1, episode: 1);
        final p = await plan(
          scanOf([
            tvGroup([f], rootDir: '/d/Dorohedoro 2020'),
          ]),
          existing: {'/d/异兽魔都 (2020)'},
        );
        expect(p.conflicts.single.path, '/d/异兽魔都 (2020)');
      },
    );

    test('already organized files produce no ops', () async {
      final p = await plan(
        scanOf([
          tvGroup([
            video(
              '/d/异兽魔都 (2020)/Season 01/$name.S01E01.mkv',
              season: 1,
              episode: 1,
            ),
          ], rootDir: '/d/异兽魔都 (2020)'),
        ]),
      );
      expect(p.ops, isEmpty);
      expect(p.canExecute, isTrue);
    });
  });

  group('season strategies through the planner', () {
    // Dorohedoro has 12 + 11 episodes.
    final abs = [
      video('$root/a.mkv', absolute: 1),
      video('$root/b.mkv', absolute: 12),
      video('$root/c.mkv', absolute: 13),
      video('$root/d.mkv', absolute: 23),
    ];
    Future<Map<String, String>> run(
      GroupDecision d, [
      List<ScanFile>? fs,
    ]) async => moves(
      await plan(
        scanOf([tvGroup(fs ?? abs)]),
        decisions: {const GroupId('g1'): d},
      ),
    );

    String t(int s, int e) =>
        '$root/Season ${s.toString().padLeft(2, '0')}/$name.S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}.mkv';

    test('asParsed with only absolute numbers uses season 1', () async {
      expect((await run(const GroupDecision())).values, [
        t(1, 1), t(1, 12), t(1, 13), t(1, 23), //
      ]);
    });
    test('splitSequential', () async {
      expect(
        (await run(
          const GroupDecision(strategy: SeasonStrategy.splitSequential),
        )).values,
        [
          t(1, 1), t(1, 12), t(2, 1), t(2, 11), //
        ],
      );
    });
    test('splitKeepEpisode', () async {
      expect(
        (await run(
          const GroupDecision(strategy: SeasonStrategy.splitKeepEpisode),
        )).values,
        [
          t(1, 1), t(1, 12), t(2, 13), t(2, 23), //
        ],
      );
    });
    test('mergeIntoOne uses the TMDB season sizes', () async {
      final fs = [
        video('$root/a.mkv', season: 1, episode: 1),
        video('$root/b.mkv', season: 2, episode: 1),
        video('$root/c.mkv', season: 2, episode: 11),
      ];
      expect(
        (await run(
          const GroupDecision(strategy: SeasonStrategy.mergeIntoOne),
          fs,
        )).values,
        [
          t(1, 1), t(1, 13), t(1, 23), //
        ],
      );
    });
    test(
      'mergeIntoOne falls back to local season maxima without TMDB data',
      () async {
        final fs = [
          video('$root/a.mkv', season: 1, episode: 1),
          video('$root/b.mkv', season: 1, episode: 5),
          video('$root/c.mkv', season: 2, episode: 1),
        ];
        final p = await plan(
          scanOf([
            tvGroup(
              fs,
              show: const ShowDetail(info: Demo.dorohedoro, seasons: []),
            ),
          ]),
          decisions: {
            const GroupId('g1'): const GroupDecision(
              strategy: SeasonStrategy.mergeIntoOne,
            ),
          },
          // The planner trusts group.show; an empty show forces the local fallback.
        );
        expect(moves(p).values, [t(1, 1), t(1, 5), t(1, 6)]);
      },
    );
    test('offset', () async {
      expect(
        (await run(
          const GroupDecision(
            strategy: SeasonStrategy.splitSequential,
            episodeOffset: 1,
          ),
        )).values,
        [t(1, 2), t(2, 1), t(2, 2), t(2, 12)],
      );
    });
    test(
      'overflow goes to the last season, unselected with a warning',
      () async {
        final fs = [
          video('$root/a.mkv', absolute: 23),
          video('$root/b.mkv', absolute: 25),
        ];
        final p = await plan(
          scanOf([tvGroup(fs)]),
          decisions: {
            const GroupId('g1'): const GroupDecision(
              strategy: SeasonStrategy.splitSequential,
            ),
          },
        );
        expect(opFor(p, '$root/a.mkv').dst, t(2, 11));
        expect(opFor(p, '$root/a.mkv').selected, isTrue);
        final over = opFor(p, '$root/b.mkv');
        expect(over.dst, t(2, 13));
        expect(over.selected, isFalse);
        expect(over.warning, contains('超出 TMDB 总集数'));
      },
    );
    test('episode numbers below 1 are flagged', () async {
      final p = await plan(
        scanOf([
          tvGroup([video('$root/a.mkv', season: 1, episode: 1)]),
        ]),
        decisions: {
          const GroupId('g1'): const GroupDecision(episodeOffset: -1),
        },
      );
      expect(fileOps(p).single.selected, isFalse);
      expect(fileOps(p).single.warning, contains('集号无效'));
    });
    test('TMDB episode group supplies the season sizes', () async {
      final meta = GroupedMetadata([
        EpisodeGroup(
          id: 'abs',
          name: '绝对顺序',
          type: 2,
          seasons: [
            EpisodeGroupSeason(
              order: 1,
              name: 'All',
              episodes: [
                for (var e = 1; e <= 12; e++) EpisodeRef(1, e),
                for (var e = 1; e <= 11; e++) EpisodeRef(2, e),
              ],
            ),
          ],
        ),
      ]);
      GroupDecision d(SeasonStrategy s) =>
          GroupDecision(strategy: s, episodeGroupId: 'abs');
      // Sequential split over a single 23-episode season keeps everything in S01.
      var p = await plan(
        scanOf([tvGroup(abs)]),
        decisions: {const GroupId('g1'): d(SeasonStrategy.splitSequential)},
        metadata: meta,
      );
      expect(moves(p).values, [t(1, 1), t(1, 12), t(1, 13), t(1, 23)]);
      // As parsed: original S02E01 is remapped to its position in the group (S01E13).
      p = await plan(
        scanOf([
          tvGroup([
            video('$root/x.mkv', season: 2, episode: 1),
            video('$root/y.mkv', season: 1, episode: 3),
          ]),
        ]),
        decisions: {const GroupId('g1'): d(SeasonStrategy.asParsed)},
        metadata: meta,
      );
      expect(moves(p).values, [t(1, 13), t(1, 3)]);
    });
  });

  group('per-file handling', () {
    test('file overrides win over the parse and the strategy', () async {
      final fs = [
        video('$root/a.mkv', absolute: 13),
        video('$root/b.mkv', season: 1, episode: 1),
        video('$root/c.mkv', season: 1, episode: 2),
        video('$root/d.mkv', season: 1, episode: 3),
      ];
      final p = await plan(
        scanOf([tvGroup(fs)]),
        decisions: {
          const GroupId('g1'): const GroupDecision(
            strategy: SeasonStrategy.splitSequential,
            episodeOffset: 5,
            overrides: {
              '$root/a.mkv': FileOverride(season: 1, episode: 7),
              '$root/b.mkv': FileOverride(ignore: true),
              '$root/c.mkv': FileOverride(kind: MediaKind.extra),
              '$root/d.mkv': FileOverride(kind: MediaKind.special),
            },
          ),
        },
      );
      expect(moves(p), {
        '$root/a.mkv': '$root/Season 01/$name.S01E07.mkv',
        '$root/c.mkv': '$root/Extras/c.mkv',
        '$root/d.mkv': '$root/Season 00/$name.S00E03.mkv',
      });
      // An override is not "low confidence", whatever the parse said.
      final low = await plan(
        scanOf([
          tvGroup([video('$root/e.mkv', confidence: 0.1)]),
        ]),
        decisions: {
          const GroupId('g1'): const GroupDecision(
            overrides: {'$root/e.mkv': FileOverride(season: 1, episode: 4)},
          ),
        },
      );
      expect(fileOps(low).single.selected, isTrue);
    });

    test('low-confidence parses start unselected with a warning', () async {
      final p = await plan(
        scanOf([
          tvGroup([
            video('$root/a.mkv', season: 1, episode: 1, confidence: 0.3),
            video('$root/b.mkv', season: 1, episode: 2),
          ]),
        ]),
      );
      expect(opFor(p, '$root/a.mkv').selected, isFalse);
      expect(opFor(p, '$root/a.mkv').warning, contains('置信度'));
      expect(opFor(p, '$root/b.mkv').selected, isTrue);
      expect(opFor(p, '$root/b.mkv').warning, isNull);

      final strict = await plan(
        scanOf([
          tvGroup([video('$root/b.mkv', season: 1, episode: 2)]),
        ]),
        options: const PlanOptions(confidenceThreshold: 0.95),
      );
      expect(fileOps(strict).single.selected, isFalse);
    });

    test(
      'a weak group match makes its rows unselected unless the user picked it',
      () async {
        final scan = scanOf([
          tvGroup([video('$root/b.mkv', season: 1, episode: 2)], score: 0.62),
        ]);
        expect(fileOps(await plan(scan)).single.selected, isFalse);
        final picked = await plan(
          scan,
          decisions: {
            const GroupId('g1'): const GroupDecision(match: Demo.dorohedoro),
          },
        );
        expect(fileOps(picked).single.selected, isTrue);
      },
    );

    test('specials go to Season 00', () async {
      final p = await plan(
        scanOf([
          tvGroup([
            video(
              '$root/sp.mkv',
              season: 0,
              episode: 1,
              kind: MediaKind.special,
            ),
            video('$root/ova.mkv', episode: 2, kind: MediaKind.special),
          ]),
        ]),
      );
      expect(moves(p).values, [
        '$root/Season 00/$name.S00E01.mkv',
        '$root/Season 00/$name.S00E02.mkv',
      ]);
    });

    test('extras keep their name under Extras', () async {
      final p = await plan(
        scanOf([
          tvGroup([
            video('$root/Behind The Scenes.mkv', kind: MediaKind.extra),
          ]),
        ]),
      );
      expect(fileOps(p).last.dst, '$root/Extras/Behind The Scenes.mkv');
      expect(
        p.ops.where((o) => o.kind == OpKind.mkdir).single.dst,
        '$root/Extras',
      );
    });

    test('episode titles are fetched only when the option is on', () async {
      final fs = [video('$root/a.mkv', season: 1, episode: 2)];
      final off = await plan(scanOf([tvGroup(fs)]));
      expect(fileOps(off).single.dst, endsWith('$name.S01E02.mkv'));
      final on = await plan(
        scanOf([tvGroup(fs)]),
        options: PlanOptions(
          naming: NamingProfile(tv: const NamingOptions(episodeTitle: true)),
        ),
      );
      expect(fileOps(on).single.dst, endsWith('$name.S01E02.第 2 集.mkv'));
    });

    test('multi-language naming profile and tmdb tag', () async {
      final p = await plan(
        scanOf([
          tvGroup([video('$root/a.mkv', season: 1, episode: 2)]),
        ]),
        options: PlanOptions(
          naming: NamingProfile(
            tv: const NamingOptions(
              tmdbIdTag: true,
              episodeStyle: EpisodeStyle.cross,
              separator: ' ',
              folderTemplate: '{title} ({year}) {tmdb_tag}',
            ),
          ),
        ),
      );
      // Files move inside the old folder first; the folder is renamed afterwards.
      expect(
        fileOps(p).single.dst,
        '$root/Season 01/异兽魔都 Dorohedoro 2020 1x02 {tmdb-94954}.mkv',
      );
      expect(p.ops.last.dst, '/d/异兽魔都 (2020) {tmdb-94954}');
    });

    test('sidecars follow the video; unrelated sidecars stay', () async {
      final p = await plan(
        scanOf([
          tvGroup([
            video('$root/a.mkv', season: 1, episode: 1),
            video('$root/b.mkv', season: 1, episode: 2),
            other('$root/a.nfo', FileRole.sidecar),
            other('$root/a-poster.jpg', FileRole.sidecar),
            other('$root/a.zh-TW.srt', FileRole.subtitle),
            other('$root/a.sc.ass', FileRole.subtitle),
            other('$root/unrelated.jpg', FileRole.sidecar),
          ]),
        ]),
      );
      const base = '$root/Season 01/$name.S01E01';
      expect(moves(p), {
        '$root/a.mkv': '$base.mkv',
        '$root/b.mkv': '$root/Season 01/$name.S01E02.mkv',
        '$root/a.nfo': '$base.nfo',
        '$root/a-poster.jpg': '$base-poster.jpg',
        '$root/a.zh-TW.srt': '$base.zh-Hant.srt',
        '$root/a.sc.ass': '$base.zh-Hans.ass',
      });
    });

    test('a subtitle falls back to the parser language tag', () async {
      final sub = ScanFile(
        path: '$root/Subs/Dorohedoro.S01E01.ass',
        name: 'Dorohedoro.S01E01.ass',
        size: 1,
        role: FileRole.subtitle,
        parsed: const ParsedName(
          season: 1,
          episodes: [1],
          lang: '简体',
          confidence: 0.9,
        ),
      );
      final p = await plan(
        scanOf([
          tvGroup([video('$root/a.mkv', season: 1, episode: 1), sub]),
        ]),
      );
      expect(moves(p)[sub.path], '$root/Season 01/$name.S01E01.zh-Hans.ass');
    });
  });

  group('groups, folders and junk', () {
    test(
      'unmatched or deselected groups are skipped; a decision match rescues',
      () async {
        final fs = [video('$root/a.mkv', season: 1, episode: 1)];
        final unmatched = scanOf([
          tvGroup(fs, match: null, show: null, score: 0.3),
        ]);
        expect((await plan(unmatched)).ops, isEmpty);
        final rescued = await plan(
          unmatched,
          decisions: {
            const GroupId('g1'): const GroupDecision(match: Demo.dorohedoro),
          },
        );
        expect(rescued.ops, isNotEmpty);
        final off = await plan(
          scanOf([tvGroup(fs)]),
          decisions: {
            const GroupId('g1'): const GroupDecision(selected: false),
          },
        );
        expect(off.ops, isEmpty);
      },
    );

    test('correcting the match uses the new title and its seasons', () async {
      final p = await plan(
        scanOf([
          tvGroup([video('$root/a.mkv', absolute: 25)]),
        ]),
        decisions: {
          const GroupId('g1'): const GroupDecision(
            match: Demo.friends,
            strategy: SeasonStrategy.splitSequential,
          ),
        },
      );
      // Fake "friends" has one 24-episode season, so 25 overflows within S01.
      final file = opFor(p, '$root/a.mkv');
      expect(file.dst, '$root/Season 01/老友记.Friends.1994.S01E25.mkv');
      expect(file.selected, isFalse);
      // The folder still looks like the anchor title, so it is renamed to the new match.
      expect(p.ops.last.dst, '/d/老友记 (1994)');
    });

    test('loose files are not renamed into their shared folder', () async {
      final loose = [video('/d/a.mkv', season: 1, episode: 1)];
      final p = await plan(scanOf([tvGroup(loose, rootDir: '/d')]));
      expect(p.ops.where((o) => o.phase == ExecPhase.folders), isEmpty);
      expect(p.ops.where((o) => o.kind == OpKind.mkdir).map((o) => o.dst), [
        '/d/异兽魔都 (2020)',
        '/d/异兽魔都 (2020)/Season 01',
      ]);
      expect(fileOps(p).last.dst, '/d/异兽魔都 (2020)/Season 01/$name.S01E01.mkv');
    });

    test('two groups sharing a folder do not rename it', () async {
      final a = tvGroup(
        [video('/d/x/a.mkv', season: 1, episode: 1)],
        rootDir: '/d/x',
        id: 'a',
      );
      final b = tvGroup(
        [video('/d/x/b.mkv', season: 1, episode: 1)],
        rootDir: '/d/x',
        id: 'b',
      );
      final p = await plan(scanOf([a, b]));
      expect(p.ops.where((o) => o.phase == ExecPhase.folders), isEmpty);
    });

    test('mkdir skips folders that already exist', () async {
      final p = await plan(
        scanOf([
          tvGroup([video('$root/Season 1/a.mkv', season: 1, episode: 1)]),
        ]),
        existing: {'$root/Season 01'},
      );
      expect(p.ops.where((o) => o.kind == OpKind.mkdir), isEmpty);
    });

    test('moveToLibrary needs a library root', () {
      expect(
        plan(
          scanOf([
            tvGroup([video('$root/a.mkv', season: 1, episode: 1)]),
          ]),
          options: const PlanOptions(mode: OrganizeMode.moveToLibrary),
        ),
        throwsArgumentError,
      );
    });

    test('moveToLibrary puts TV under the TV dir', () async {
      final p = await plan(
        scanOf([
          tvGroup([video('$root/a.mkv', season: 2, episode: 3)]),
        ]),
        options: const PlanOptions(
          mode: OrganizeMode.moveToLibrary,
          libraryRoot: '/影视库/',
        ),
      );
      expect(
        fileOps(p).last.dst,
        '/影视库/剧集/异兽魔都 (2020)/Season 02/$name.S02E03.mkv',
      );
      expect(p.ops.where((o) => o.phase == ExecPhase.folders), isEmpty);
    });

    test('junk: delete ops in cleanup, unselected by default, skipped for untouched groups', () async {
      final scan = scanOf(
        [
          tvGroup([video('$root/a.mkv', season: 1, episode: 1)]),
          tvGroup(
            [video('/d/other/b.mkv', season: 1, episode: 1)],
            rootDir: '/d/other',
            match: null,
            show: null,
            id: 'g2',
          ),
        ],
        unassigned: [
          other('$root/ad.txt', FileRole.junk),
          other('/d/other/ad.txt', FileRole.junk),
          other('/d/loose.url', FileRole.junk),
          other('/d/notes.pdf', FileRole.other),
        ],
      );
      final p = await plan(scan);
      final dels = p.ops.where((o) => o.kind == OpKind.delete).toList();
      expect(dels.map((o) => o.src), ['/d/异兽魔都 (2020)/ad.txt', '/d/loose.url']);
      expect(
        dels.every(
          (o) => !o.selected && o.phase == ExecPhase.cleanup && o.dst.isEmpty,
        ),
        isTrue,
      );
      final on = await plan(scan, options: const PlanOptions(deleteJunk: true));
      expect(
        on.ops.where((o) => o.kind == OpKind.delete).every((o) => o.selected),
        isTrue,
      );
    });

    test('op ids are deterministic and unique', () async {
      final scan = scanOf(
        [
          tvGroup([
            video('$root/a.mkv', season: 1, episode: 1),
            video('$root/b.mkv', season: 2, episode: 1),
            other('$root/b.chs.ass', FileRole.subtitle),
          ]),
        ],
        unassigned: [other('$root/ad.txt', FileRole.junk)],
      );
      final a = await plan(scan);
      final b = await plan(scan);
      expect(a.ops.map((o) => o.id), b.ops.map((o) => o.id));
      expect(a.ops.map((o) => o.id).toSet().length, a.ops.length);
    });

    test('titles with illegal characters are sanitized', () async {
      const odd = Candidate(
        tmdbId: 1,
        kind: MediaKind.episode,
        title: '谁是谁: 第二季?',
        englishTitle: 'AC/DC',
        year: 2001,
      );
      final p = await plan(
        scanOf([
          tvGroup(
            [video('$root/a.mkv', season: 1, episode: 1)],
            match: odd,
            show: const ShowDetail(
              info: odd,
              seasons: [SeasonInfo(number: 1, episodeCount: 5)],
            ),
          ),
        ]),
      );
      expect(
        opFor(p, '$root/a.mkv').dst,
        '$root/Season 01/谁是谁： 第二季？.ACDC.2001.S01E01.mkv',
      );
      expect(p.ops.last.dst, '/d/谁是谁： 第二季？ (2001)');
    });
  });
}
