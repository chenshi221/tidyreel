import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

List<EpisodeRef> abs(Iterable<int> ns) => [
  for (final n in ns) EpisodeRef(1, n),
];

void main() {
  // 龙珠Z: 9 seasons, 291 episodes.
  const dbz = [39, 35, 33, 30, 30, 34, 29, 31, 30];

  group('asParsed', () {
    test('is the identity', () {
      final input = [const EpisodeRef(6, 5), const EpisodeRef(1, 1)];
      expect(applyStrategy(SeasonStrategy.asParsed, input, dbz), input);
    });
    test('offset only shifts the episode', () {
      expect(
        applyStrategy(
          SeasonStrategy.asParsed,
          [const EpisodeRef(2, 1)],
          dbz,
          episodeOffset: -1,
        ),
        [const EpisodeRef(2, 0)],
      );
    });
  });

  group('splitSequential', () {
    List<EpisodeRef> run(
      List<int> ns, {
      int offset = 0,
      List<int> counts = dbz,
    }) => applyStrategy(
      SeasonStrategy.splitSequential,
      abs(ns),
      counts,
      episodeOffset: offset,
    );

    test('龙珠Z season boundaries', () {
      expect(run([1, 39, 40, 74, 75, 291]), const [
        EpisodeRef(1, 1),
        EpisodeRef(1, 39),
        EpisodeRef(2, 1),
        EpisodeRef(2, 35),
        EpisodeRef(3, 1),
        EpisodeRef(9, 30),
      ]);
    });
    test('every absolute number maps to a unique, in-range pair', () {
      final out = run([for (var i = 1; i <= 291; i++) i]);
      expect(out.toSet().length, 291);
      for (final r in out) {
        expect(r.episode, inInclusiveRange(1, dbz[r.season - 1]));
      }
    });
    test('ignores the input season', () {
      expect(
        applyStrategy(SeasonStrategy.splitSequential, [
          const EpisodeRef(5, 40),
        ], dbz),
        [const EpisodeRef(2, 1)],
      );
    });
    test('offset is applied before splitting', () {
      expect(run([1], offset: 39), [const EpisodeRef(2, 1)]);
      expect(run([40], offset: -39), [const EpisodeRef(1, 1)]);
    });
    test('overflow keeps counting in the last season', () {
      expect(run([291, 292, 295]), const [
        EpisodeRef(9, 30),
        EpisodeRef(9, 31),
        EpisodeRef(9, 34),
      ]);
    });
    test('empty counts: identity', () {
      expect(run([5, 500], counts: const []), abs([5, 500]));
    });
    test('single season', () {
      expect(run([1, 24, 25], counts: const [24]), const [
        EpisodeRef(1, 1),
        EpisodeRef(1, 24),
        EpisodeRef(1, 25),
      ]);
    });
    test('zero-episode seasons are skipped', () {
      expect(run([3, 4], counts: const [3, 0, 5]), const [
        EpisodeRef(1, 3),
        EpisodeRef(3, 1),
      ]);
    });
  });

  group('splitKeepEpisode', () {
    // 海贼王-style: episode number stays absolute, only the season changes.
    const op = [61, 52, 54, 50];
    List<EpisodeRef> run(List<int> ns, {int offset = 0}) => applyStrategy(
      SeasonStrategy.splitKeepEpisode,
      abs(ns),
      op,
      episodeOffset: offset,
    );

    test('season changes, episode stays', () {
      expect(run([1, 61, 62, 113, 114, 217]), const [
        EpisodeRef(1, 1),
        EpisodeRef(1, 61),
        EpisodeRef(2, 62),
        EpisodeRef(2, 113),
        EpisodeRef(3, 114),
        EpisodeRef(4, 217),
      ]);
    });
    test('offset first', () {
      expect(run([1], offset: 61), const [EpisodeRef(2, 62)]);
    });
    test('overflow goes to the last season', () {
      expect(run([218, 300]), const [EpisodeRef(4, 218), EpisodeRef(4, 300)]);
    });
  });

  group('mergeIntoOne', () {
    // 名侦探柯南-style: per-season input, one long season out.
    const conan = [10, 12, 8];
    List<EpisodeRef> run(
      List<EpisodeRef> xs, {
      int offset = 0,
      List<int> c = conan,
    }) => applyStrategy(
      SeasonStrategy.mergeIntoOne,
      xs,
      c,
      episodeOffset: offset,
    );

    test('accumulates previous seasons', () {
      expect(
        run(const [
          EpisodeRef(1, 1),
          EpisodeRef(1, 10),
          EpisodeRef(2, 1),
          EpisodeRef(2, 12),
          EpisodeRef(3, 1),
          EpisodeRef(3, 8),
        ]),
        [
          for (final n in [1, 10, 11, 22, 23, 30]) EpisodeRef(1, n),
        ],
      );
    });
    test('season 0 specials stay put', () {
      expect(run(const [EpisodeRef(0, 3)]), const [EpisodeRef(0, 3)]);
    });
    test('season beyond the layout adds everything known', () {
      expect(run(const [EpisodeRef(5, 2)]), const [EpisodeRef(1, 32)]);
    });
    test('offset first', () {
      expect(run(const [EpisodeRef(2, 1)], offset: 1), const [
        EpisodeRef(1, 12),
      ]);
    });
    test('empty counts: identity', () {
      expect(run(const [EpisodeRef(2, 3)], c: const []), const [
        EpisodeRef(2, 3),
      ]);
    });
  });

  test('empty input', () {
    for (final s in SeasonStrategy.values) {
      expect(applyStrategy(s, const [], dbz), isEmpty);
    }
  });
}
