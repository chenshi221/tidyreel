import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _FnAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) fn;
  _FnAdapter(this.fn);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => fn(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  group('popularity and voteCount tie-breaker', () {
    test('popular homonym beats obscure homonym on equal title', () {
      const popular = Candidate(
        tmdbId: 1,
        kind: MediaKind.movie,
        title: 'Frozen',
        year: 2013,
        voteCount: 16000,
        popularity: 120.0,
      );
      const obscure = Candidate(
        tmdbId: 2,
        kind: MediaKind.movie,
        title: 'Frozen',
        year: 2013,
        voteCount: 3,
        popularity: 0.5,
      );

      final popScore = scoreCandidate(popular, query: 'Frozen', year: 2013);
      final obsScore = scoreCandidate(obscure, query: 'Frozen', year: 2013);
      expect(popScore, greaterThan(obsScore));
      expect(popScore - obsScore, lessThanOrEqualTo(0.03));
    });

    test('popular unrelated title gets no bonus and loses to exact title', () {
      const exactObscure = Candidate(
        tmdbId: 1,
        kind: MediaKind.movie,
        title: 'Her',
        voteCount: 0,
        popularity: 0.0,
      );
      const popularWrong = Candidate(
        tmdbId: 2,
        kind: MediaKind.movie,
        title: 'Avengers: Endgame',
        voteCount: 25000,
        popularity: 500.0,
      );
      const popularWrongNoPop = Candidate(
        tmdbId: 3,
        kind: MediaKind.movie,
        title: 'Avengers: Endgame',
      );
      const popularPartial = Candidate(
        tmdbId: 4,
        kind: MediaKind.movie,
        title: 'Hereditary',
        voteCount: 25000,
        popularity: 500.0,
      );

      expect(
        scoreCandidate(popularWrong, query: 'Her'),
        equals(scoreCandidate(popularWrongNoPop, query: 'Her')),
      );
      expect(
        scoreCandidate(exactObscure, query: 'Her'),
        greaterThan(scoreCandidate(popularWrong, query: 'Her')),
      );
      expect(
        scoreCandidate(exactObscure, query: 'Her'),
        greaterThan(scoreCandidate(popularPartial, query: 'Her')),
      );
    });

    test(
      'null voteCount and popularity add zero bonus and score clamps to 1.0',
      () {
        const bare = Candidate(
          tmdbId: 1,
          kind: MediaKind.movie,
          title: 'Inception',
          year: 2010,
        );
        const massive = Candidate(
          tmdbId: 2,
          kind: MediaKind.movie,
          title: 'Inception',
          year: 2010,
          voteCount: 1000000,
          popularity: 100000.0,
        );

        expect(scoreCandidate(bare, query: 'Inception'), closeTo(0.7, 1e-9));
        expect(
          scoreCandidate(massive, query: 'Inception'),
          closeTo(0.73, 1e-9),
        );
        expect(
          scoreCandidate(
            massive,
            query: 'Inception',
            year: 2010,
            kind: MediaKind.movie,
          ),
          lessThanOrEqualTo(1.0),
        );
      },
    );

    test(
      'TmdbProvider.search breaks 1.0 score ties in favor of popular homonym',
      () async {
        final dio = Dio()
          ..httpClientAdapter = _FnAdapter((opts) async {
            final body = {
              'page': 1,
              'results': [
                {
                  'id': 999,
                  'title': 'Frozen',
                  'original_title': 'Frozen',
                  'release_date': '2013-01-01',
                  'vote_count': 2,
                  'popularity': 0.4,
                },
                {
                  'id': 109445,
                  'title': 'Frozen',
                  'original_title': 'Frozen',
                  'release_date': '2013-11-20',
                  'vote_count': 16000,
                  'popularity': 115.0,
                },
              ],
            };
            return ResponseBody.fromString(
              jsonEncode(body),
              200,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          });

        final provider = TmdbProvider(
          const TmdbConfig(apiKey: 'k', language: 'en-US'),
          dio: dio,
        );
        final hits = await provider.search(
          'Frozen',
          kind: MediaKind.movie,
          year: 2013,
        );
        expect(hits.first.tmdbId, 109445);
      },
    );
  });

  group('scoreEpisodeFit', () {
    ShowDetail makeShow(List<(int, int)> seasons) => ShowDetail(
      info: const Candidate(tmdbId: 1, kind: MediaKind.episode, title: 'Show'),
      seasons: [
        for (final (n, count) in seasons)
          SeasonInfo(number: n, episodeCount: count),
      ],
    );

    test('rewards exact and partial single-season fits', () {
      final exact = scoreEpisodeFit(
        localMaxEp: 12,
        localSeasonCount: 1,
        show: makeShow([(0, 4), (1, 12)]),
      );
      final partial = scoreEpisodeFit(
        localMaxEp: 6,
        localSeasonCount: 1,
        show: makeShow([(1, 24)]),
      );
      expect(exact, greaterThan(0.05));
      expect(exact, lessThanOrEqualTo(0.10));
      expect(exact, greaterThan(partial));
      expect(partial, greaterThan(0.0));
    });

    test(
      'rewards absolute-numbered episodes fitting total regular seasons',
      () {
        final fit = scoreEpisodeFit(
          localMaxEp: 48,
          localSeasonCount: 1,
          show: makeShow([(0, 10), (1, 24), (2, 24)]),
        );
        expect(fit, greaterThan(0.05));
        expect(fit, lessThanOrEqualTo(0.10));
      },
    );

    test('penalizes severe episode count mismatch against miniseries', () {
      final miniseries = makeShow([(1, 2)]);
      final fullSeries = makeShow([(1, 26), (2, 24)]);

      final miniScore = scoreEpisodeFit(
        localMaxEp: 50,
        localSeasonCount: 1,
        show: miniseries,
      );
      final fullScore = scoreEpisodeFit(
        localMaxEp: 50,
        localSeasonCount: 1,
        show: fullSeries,
      );
      expect(miniScore, closeTo(-0.12, 1e-9));
      expect(fullScore, greaterThan(0.05));
    });

    test(
      'penalizes severe season count mismatch and ignores specials-only shows',
      () {
        final oneSeason = makeShow([(1, 12)]);
        final fiveSeasons = makeShow([
          (1, 12),
          (2, 12),
          (3, 12),
          (4, 12),
          (5, 12),
        ]);

        final mismatch = scoreEpisodeFit(
          localMaxEp: 10,
          localSeasonCount: 5,
          show: oneSeason,
        );
        final match = scoreEpisodeFit(
          localMaxEp: 10,
          localSeasonCount: 5,
          show: fiveSeasons,
        );
        expect(mismatch, lessThan(0.0));
        expect(match, greaterThan(0.05));

        // Specials-only or unknown local episode counts stay neutral.
        expect(
          scoreEpisodeFit(
            localMaxEp: 12,
            localSeasonCount: 1,
            show: makeShow([(0, 5)]),
          ),
          0.0,
        );
        expect(
          scoreEpisodeFit(
            localMaxEp: 0,
            localSeasonCount: 1,
            show: fiveSeasons,
          ),
          0.0,
        );
      },
    );

    test('mild ongoing overflow stays gentle and all results stay bounded', () {
      final ongoing = scoreEpisodeFit(
        localMaxEp: 13,
        localSeasonCount: 1,
        show: makeShow([(1, 12)]),
      );
      expect(ongoing, greaterThanOrEqualTo(-0.03));
      expect(ongoing, lessThan(0.0));
    });
  });
}
