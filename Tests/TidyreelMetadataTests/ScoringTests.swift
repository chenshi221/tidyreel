import Foundation
import Testing
@testable import TidyreelMetadata
import TidyreelModels

@Suite("ScoringTests")
struct ScoringTests {
    // MARK: - Popularity & VoteCount Tie-Breaker

    @Test("Popular homonym beats obscure homonym on equal title")
    func popularHomonymBeatsObscure() {
        let popular = Candidate(
            tmdbId: 1,
            kind: .movie,
            title: "Frozen",
            year: 2013,
            voteCount: 16_000,
            popularity: 120.0
        )
        let obscure = Candidate(
            tmdbId: 2,
            kind: .movie,
            title: "Frozen",
            year: 2013,
            voteCount: 3,
            popularity: 0.5
        )

        let popScore = scoreCandidate(popular, query: "Frozen", year: 2013)
        let obsScore = scoreCandidate(obscure, query: "Frozen", year: 2013)
        #expect(popScore > obsScore)
        #expect(popScore - obsScore <= 0.03)
    }

    @Test("Popular unrelated title gets no bonus and loses to exact title")
    func popularUnrelatedGetsNoBonus() {
        let exactObscure = Candidate(
            tmdbId: 1,
            kind: .movie,
            title: "Her",
            voteCount: 0,
            popularity: 0.0
        )
        let popularWrong = Candidate(
            tmdbId: 2,
            kind: .movie,
            title: "Avengers: Endgame",
            voteCount: 25_000,
            popularity: 500.0
        )
        let popularWrongNoPop = Candidate(
            tmdbId: 3,
            kind: .movie,
            title: "Avengers: Endgame"
        )
        let popularPartial = Candidate(
            tmdbId: 4,
            kind: .movie,
            title: "Hereditary",
            voteCount: 25_000,
            popularity: 500.0
        )

        #expect(scoreCandidate(popularWrong, query: "Her") == scoreCandidate(popularWrongNoPop, query: "Her"))
        #expect(scoreCandidate(exactObscure, query: "Her") > scoreCandidate(popularWrong, query: "Her"))
        #expect(scoreCandidate(exactObscure, query: "Her") > scoreCandidate(popularPartial, query: "Her"))
    }

    @Test("Null voteCount and popularity add zero bonus and score clamps to 1.0")
    func nullVoteCountAndClamp() {
        let bare = Candidate(
            tmdbId: 1,
            kind: .movie,
            title: "Inception",
            year: 2010
        )
        let massive = Candidate(
            tmdbId: 2,
            kind: .movie,
            title: "Inception",
            year: 2010,
            voteCount: 1_000_000,
            popularity: 100_000.0
        )

        #expect(abs(scoreCandidate(bare, query: "Inception") - 0.7) < 1e-9)
        #expect(abs(scoreCandidate(massive, query: "Inception") - 0.73) < 1e-9)
        #expect(scoreCandidate(massive, query: "Inception", year: 2010, kind: .movie) <= 1.0)
    }

    @Test("TmdbProvider.search breaks 1.0 score ties in favor of popular homonym")
    func searchBreaksTieByPopularity() async throws {
        let transport = MockHTTPTransport { req in
            let body: [String: Any] = [
                "page": 1,
                "results": [
                    [
                        "id": 999,
                        "title": "Frozen",
                        "original_title": "Frozen",
                        "release_date": "2013-01-01",
                        "vote_count": 2,
                        "popularity": 0.4,
                    ],
                    [
                        "id": 109445,
                        "title": "Frozen",
                        "original_title": "Frozen",
                        "release_date": "2013-11-20",
                        "vote_count": 16_000,
                        "popularity": 115.0,
                    ],
                ],
            ]
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: body)
        }

        let provider = TmdbProvider(
            config: TmdbConfig(apiKey: "k", language: "en-US"),
            transport: transport,
            minIntervalMs: 0
        )
        let hits = try await provider.search("Frozen", kind: .movie, year: 2013)
        #expect(hits.first?.tmdbId == 109445)
        await provider.close()
    }

    // MARK: - scoreCandidate Basics

    @Test("scoreCandidate matches zh, original, en titles and traditional Chinese")
    func scoreCandidateMatchesAllTitles() {
        let inception = Candidate(
            tmdbId: 1,
            kind: .movie,
            title: "盗梦空间",
            englishTitle: "Inception",
            originalTitle: "Inception",
            year: 2010
        )

        for q in ["inception", "INCEPTION!", "盗梦空间", "Inception.1080p"] {
            #expect(scoreCandidate(inception, query: q) > 0.69)
        }
        #expect(abs(scoreCandidate(inception, query: "盜夢空間") - 0.7) < 1e-9)

        let base = scoreCandidate(inception, query: "Inception")
        #expect(abs(scoreCandidate(inception, query: "Inception", year: 2010) - (base + 0.2)) < 1e-9)
        #expect(abs(scoreCandidate(inception, query: "Inception", year: 2011) - (base + 0.1)) < 1e-9)
        #expect(scoreCandidate(inception, query: "Inception", year: 2015) == base)
        #expect(abs(scoreCandidate(inception, query: "Inception", kind: .movie) - (base + 0.1)) < 1e-9)
        #expect(scoreCandidate(inception, query: "Inception", kind: .episode) == base)
    }

    // MARK: - scoreEpisodeFit

    private func makeShow(_ seasons: [(Int, Int)]) -> ShowDetail {
        ShowDetail(
            info: Candidate(tmdbId: 1, kind: .episode, title: "Show"),
            seasons: seasons.map { SeasonInfo(number: $0.0, episodeCount: $0.1) }
        )
    }

    @Test("scoreEpisodeFit rewards exact and partial single-season fits")
    func episodeFitSingleSeason() {
        let show1 = makeShow([(0, 4), (1, 12)])
        let show2 = makeShow([(1, 24)])

        let exact = scoreEpisodeFit(localSeasons: [1: 12], tmdbSeasons: show1.seasons)
        let partial = scoreEpisodeFit(localSeasons: [1: 6], tmdbSeasons: show2.seasons)
        #expect(exact > 0.05)
        #expect(exact <= 0.10)
        #expect(exact > partial)
        #expect(partial > 0.0)

        // Verify parity with ShowDetail overload
        #expect(exact == scoreEpisodeFit(localMaxEp: 12, localSeasonCount: 1, show: show1))
        #expect(partial == scoreEpisodeFit(localMaxEp: 6, localSeasonCount: 1, show: show2))
    }

    @Test("scoreEpisodeFit rewards absolute-numbered episodes fitting total regular seasons")
    func episodeFitAbsolute() {
        let show = makeShow([(0, 10), (1, 24), (2, 24)])
        let fit = scoreEpisodeFit(localSeasons: [:], tmdbSeasons: show.seasons, maxAbsolute: 48)
        #expect(fit > 0.05)
        #expect(fit <= 0.10)
    }

    @Test("scoreEpisodeFit penalizes severe episode count mismatch against miniseries")
    func episodeFitMiniseriesMismatch() {
        let miniseries = makeShow([(1, 2)])
        let fullSeries = makeShow([(1, 26), (2, 24)])

        let miniScore = scoreEpisodeFit(localSeasons: [1: 50], tmdbSeasons: miniseries.seasons)
        let fullScore = scoreEpisodeFit(localSeasons: [1: 50], tmdbSeasons: fullSeries.seasons)
        #expect(abs(miniScore - (-0.12)) < 1e-9)
        #expect(fullScore > 0.05)
    }

    @Test("scoreEpisodeFit penalizes severe season count mismatch and ignores specials-only shows")
    func episodeFitSeasonMismatchAndSpecials() {
        let oneSeason = makeShow([(1, 12)])
        let fiveSeasons = makeShow([(1, 12), (2, 12), (3, 12), (4, 12), (5, 12)])
        let localFive = [1: 10, 2: 10, 3: 10, 4: 10, 5: 10]

        let mismatch = scoreEpisodeFit(localSeasons: localFive, tmdbSeasons: oneSeason.seasons)
        let match = scoreEpisodeFit(localSeasons: localFive, tmdbSeasons: fiveSeasons.seasons)
        #expect(mismatch < 0.0)
        #expect(match > 0.05)

        let specialsOnly = makeShow([(0, 5)])
        #expect(scoreEpisodeFit(localSeasons: [1: 12], tmdbSeasons: specialsOnly.seasons) == 0.0)
        #expect(scoreEpisodeFit(localSeasons: [:], tmdbSeasons: fiveSeasons.seasons) == 0.0)
    }

    @Test("scoreEpisodeFit mild ongoing overflow stays gentle and bounded")
    func episodeFitMildOverflow() {
        let show = makeShow([(1, 12)])
        let ongoing = scoreEpisodeFit(localSeasons: [1: 13], tmdbSeasons: show.seasons)
        #expect(ongoing >= -0.03)
        #expect(ongoing < 0.0)
    }

    // MARK: - normalizeQuery, sameTitle, sharesToken

    @Test("normalizeQuery preserves leading years, future years, CJK-glued years, and extractYear=false")
    func normalizeQueryBehavior() {
        #expect(normalizeQuery("2012") == "2012")
        #expect(normalizeQuery("2012", extractYear: true) == NormalizedQuery(text: "2012", year: nil))
        #expect(normalizeQuery("Movie.Name.2019.2160p.UHD") == "Movie Name")
        #expect(normalizeQuery("Movie.Name.2019.2160p.UHD", extractYear: true) == NormalizedQuery(text: "Movie Name", year: 2019))

        #expect(normalizeQuery("Blade Runner 2049") == "Blade Runner 2049")
        #expect(normalizeQuery("Blade Runner 2049", extractYear: true) == NormalizedQuery(text: "Blade Runner 2049", year: nil))
        #expect(normalizeQuery("Blade Runner 2049 2017", extractYear: true) == NormalizedQuery(text: "Blade Runner 2049", year: 2017))
        #expect(normalizeQuery("2001: A Space Odyssey", extractYear: true) == NormalizedQuery(text: "2001 A Space Odyssey", year: nil))
        #expect(normalizeQuery("2001: A Space Odyssey 1968", extractYear: true) == NormalizedQuery(text: "2001 A Space Odyssey", year: 1968))
        #expect(normalizeQuery("Wonder Woman 1984", extractYear: false) == NormalizedQuery(text: "Wonder Woman 1984", year: nil))

        #expect(normalizeQuery("请回答1988", extractYear: true) == NormalizedQuery(text: "请回答1988", year: nil))
        #expect(normalizeQuery("请回答1988 2015", extractYear: true) == NormalizedQuery(text: "请回答1988", year: 2015))

        let ww84 = Candidate(tmdbId: 464052, kind: .movie, title: "Wonder Woman 1984", year: 2020)
        #expect(abs(scoreCandidate(ww84, query: "Wonder Woman 1984", year: 2020) - 0.9) < 1e-9)
    }

    @Test("sameTitle and sharesToken handle CJK and Unicode punctuation")
    func sameTitleAndSharesToken() {
        #expect(sameTitle("君の名は。", "君の名は"))
        #expect(sameTitle("SPY×FAMILY", "SPY FAMILY"))
        #expect(sameTitle("ちいかわ、", "ちいかわ"))
        #expect(sameTitle("Re:ゼロ…", "Re:ゼロ"))
        #expect(sameTitle("Spider―Man", "Spider-Man"))
        #expect(sameTitle("A+B", "A B"))
        #expect(sameTitle("Schindler's List", "Schindlers List"))
        #expect(sameTitle("『进击的巨人』", "进击的巨人"))
        #expect(sameTitle("Mr & Mrs Smith", "Mr Mrs Smith"))
        #expect(sameTitle("Spider—Man", "Spider-Man"))

        #expect(sharesToken("流人", "潮流合伙人"))
        #expect(!sharesToken("流人", "好人"))
        #expect(!sharesToken("进击的巨人", "哈利波特的魔法石"))
        #expect(!sharesToken("流人", "Slow Horses"))
        #expect(sharesToken("slow man", "Slow Horses"))
        #expect(!sharesToken("horse", "Cat"))
    }

    @Test("Packed UInt64 bigram scoring and fast ASCII date/year parsing preserve exact semantics")
    func packedBigramsAndFastDateParsing() {
        // Bigram Dice with repeated bigrams ("banana" vs "bandana"):
        // "banana" bigrams: ba(1), an(2), na(2) => 5
        // "bandana" bigrams: ba(1), an(2), nd(1), da(1), na(1) => 6
        // common: ba(1) + an(2) + na(1) = 4, total = 11 => sim = 0.7 * 8 / 11 => score = 0.7 * sim
        let c = Candidate(tmdbId: 1, kind: .movie, title: "Bandana")
        let expected = 0.7 * (0.7 * 2.0 * 4.0 / 11.0)
        #expect(abs(scoreCandidate(c, query: "Banana") - expected) < 1e-9)

        // Single-char non-matching title yields 0 similarity
        let single = Candidate(tmdbId: 2, kind: .movie, title: "X")
        #expect(scoreCandidate(single, query: "Y") == 0.0)
        #expect(scoreCandidate(single, query: "ABC") == 0.0)

        // PreparedQueryTokens matches sharesToken identically
        let prepared = PreparedQueryTokens("流人 slow")
        #expect(prepared.matches("潮流合伙人") == sharesToken("流人 slow", "潮流合伙人"))
        #expect(prepared.matches("Slow Horses") == sharesToken("流人 slow", "Slow Horses"))
        #expect(prepared.matches("好人") == sharesToken("流人 slow", "好人"))

        // Fast ASCII YYYY-MM-DD parseDate and parseYear parity with TidyreelCodecs.parseISO
        for dateStr in ["1970-01-01", "1993-01-01", "2000-02-29", "2010-07-15", "2024-02-29"] {
            let parsed = TmdbProvider.parseDate(.string(dateStr))
            #expect(parsed == TidyreelCodecs.parseISO(dateStr))
            #expect(TmdbProvider.parseYear(.string(dateStr)) == Int(dateStr.prefix(4)))
        }
        // Invalid calendar dates return nil
        #expect(TmdbProvider.parseDate(.string("1900-02-29")) == nil)
        #expect(TmdbProvider.parseYear(.string("1900-02-29")) == nil)
        #expect(TmdbProvider.parseYear(.string("2023-02-30")) == nil)
        #expect(TmdbProvider.parseYear(.string("")) == nil)
        // Full ISO timestamp fallback still works
        #expect(TmdbProvider.parseYear(.string("2024-05-03T12:00:00Z")) == 2024)
    }
}
