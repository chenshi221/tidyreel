import Testing
import TidyreelModels
import TidyreelPlanner

@Suite("Strategy & Template Tests")
struct StrategyAndTemplateTests {
    private let dbz = [39, 35, 33, 30, 30, 34, 29, 31, 30]

    private func absRefs(_ ns: [Int]) -> [EpisodeRef] {
        ns.map { EpisodeRef(1, $0) }
    }

    // MARK: - Strategy

    @Test("asParsed identity and offset")
    func asParsedMode() {
        let input = [EpisodeRef(6, 5), EpisodeRef(1, 1)]
        #expect(applyStrategy(.asParsed, input, dbz) == input)
        #expect(applyStrategy(.asParsed, [EpisodeRef(2, 1)], dbz, episodeOffset: -1) == [EpisodeRef(2, 0)])
    }

    @Test("splitSequential boundaries, offset, overflow, and zero-episode seasons")
    func splitSequentialMode() {
        #expect(applyStrategy(.splitSequential, absRefs([1, 39, 40, 74, 75, 291]), dbz) == [
            EpisodeRef(1, 1),
            EpisodeRef(1, 39),
            EpisodeRef(2, 1),
            EpisodeRef(2, 35),
            EpisodeRef(3, 1),
            EpisodeRef(9, 30),
        ])

        let all291 = applyStrategy(.splitSequential, absRefs(Array(1...291)), dbz)
        #expect(Set(all291).count == 291)
        for r in all291 {
            #expect(r.episode >= 1 && r.episode <= dbz[r.season - 1])
        }

        // Ignores input season
        #expect(applyStrategy(.splitSequential, [EpisodeRef(5, 40)], dbz) == [EpisodeRef(2, 1)])

        // Offset applied before splitting
        #expect(applyStrategy(.splitSequential, absRefs([1]), dbz, episodeOffset: 39) == [EpisodeRef(2, 1)])
        #expect(applyStrategy(.splitSequential, absRefs([40]), dbz, episodeOffset: -39) == [EpisodeRef(1, 1)])

        // Overflow keeps counting in the last season
        #expect(applyStrategy(.splitSequential, absRefs([291, 292, 295]), dbz) == [
            EpisodeRef(9, 30),
            EpisodeRef(9, 31),
            EpisodeRef(9, 34),
        ])

        // Empty counts: identity
        #expect(applyStrategy(.splitSequential, absRefs([5, 500]), []) == absRefs([5, 500]))

        // Zero-episode seasons skipped
        #expect(applyStrategy(.splitSequential, absRefs([3, 4]), [3, 0, 5]) == [
            EpisodeRef(1, 3),
            EpisodeRef(3, 1),
        ])
    }

    @Test("splitKeepEpisode keeps episode number while changing season")
    func splitKeepEpisodeMode() {
        let op = [61, 52, 54, 50]
        #expect(applyStrategy(.splitKeepEpisode, absRefs([1, 61, 62, 113, 114, 217]), op) == [
            EpisodeRef(1, 1),
            EpisodeRef(1, 61),
            EpisodeRef(2, 62),
            EpisodeRef(2, 113),
            EpisodeRef(3, 114),
            EpisodeRef(4, 217),
        ])
        #expect(applyStrategy(.splitKeepEpisode, absRefs([1]), op, episodeOffset: 61) == [EpisodeRef(2, 62)])
        #expect(applyStrategy(.splitKeepEpisode, absRefs([218, 300]), op) == [
            EpisodeRef(4, 218),
            EpisodeRef(4, 300),
        ])
    }

    @Test("mergeIntoOne accumulates seasons, preserves specials, and avoids overflow collisions")
    func mergeIntoOneMode() {
        let conan = [10, 12, 8]
        #expect(applyStrategy(.mergeIntoOne, [
            EpisodeRef(1, 1), EpisodeRef(1, 10),
            EpisodeRef(2, 1), EpisodeRef(2, 12),
            EpisodeRef(3, 1), EpisodeRef(3, 8),
        ], conan) == [1, 10, 11, 22, 23, 30].map { EpisodeRef(1, $0) })

        // Season 0 specials stay put
        #expect(applyStrategy(.mergeIntoOne, [EpisodeRef(0, 3)], conan) == [EpisodeRef(0, 3)])

        // Season beyond layout
        #expect(applyStrategy(.mergeIntoOne, [EpisodeRef(5, 2)], conan) == [EpisodeRef(1, 32)])

        // Multiple overflow seasons do not collide
        #expect(applyStrategy(.mergeIntoOne, [
            EpisodeRef(3, 1), EpisodeRef(3, 2),
            EpisodeRef(4, 1), EpisodeRef(4, 2),
        ], [10, 12]) == [
            EpisodeRef(1, 23), EpisodeRef(1, 24),
            EpisodeRef(1, 25), EpisodeRef(1, 26),
        ])

        #expect(applyStrategy(.mergeIntoOne, [EpisodeRef(2, 1)], conan, episodeOffset: 1) == [EpisodeRef(1, 12)])
        #expect(applyStrategy(.mergeIntoOne, [EpisodeRef(2, 3)], []) == [EpisodeRef(2, 3)])

        for s in SeasonStrategy.allCases {
            #expect(applyStrategy(s, [], dbz).isEmpty)
        }
    }

    @Test("suggestSeasonStrategy recommends splitSequential for continuous unseasoned episodes")
    func suggestStrategyCheck() {
        let files = [
            makeVideo("/dl/01.mkv", absolute: 1),
            makeVideo("/dl/15.mkv", absolute: 15),
            makeVideo("/dl/23.mkv", absolute: 23),
        ]
        let (st, reason) = suggestSeasonStrategy(files: files, show: TestDemo.dorohedoroShow)
        #expect(st == .splitSequential)
        #expect(reason?.contains("23") == true)
        #expect(reason?.contains("12") == true)

        let seasoned = [
            makeVideo("/dl/S01E01.mkv", season: 1, episode: 1),
            makeVideo("/dl/S02E01.mkv", season: 2, episode: 1),
        ]
        let none = suggestSeasonStrategy(files: seasoned, show: TestDemo.dorohedoroShow)
        #expect(none.strategy == nil)
        #expect(none.reason == nil)
    }

    // MARK: - Template

    private let friendsVars: [String: String] = [
        "title": "老友记",
        "en_title": "Friends",
        "year": "1994",
        "season": "2",
        "episode": "3",
        "episode_title": "The One With the Lesbian Wedding",
        "extra_info": "2160p.DV",
        "group": "GRP",
        "tmdb_tag": "{tmdb-1668}",
    ]

    private let inceptionVars: [String: String] = [
        "title": "盗梦空间",
        "en_title": "Inception",
        "year": "2010",
        "tmdb_tag": "{tmdb-27205}",
    ]

    private func renderTv(_ o: NamingOptions, vars: [String: String]? = nil) -> String {
        renderTemplate(compileTemplate(o, isMovie: false), vars: vars ?? friendsVars)
    }

    private func renderMovie(_ o: NamingOptions, vars: [String: String]? = nil) -> String {
        renderTemplate(compileTemplate(o, isMovie: true), vars: vars ?? inceptionVars)
    }

    @Test("renderTemplate variables, zero padding, optionals, separators, and escapes")
    func renderTemplateBasics() {
        #expect(renderTemplate("{title} S{season:02}E{episode:02}", vars: friendsVars) == "老友记 S02E03")
        #expect(renderTemplate("{season:03}", vars: ["season": "12"]) == "012")
        #expect(renderTemplate("{title:02}", vars: ["title": "ab"]) == "ab")

        #expect(renderTemplate("{title}[ - {episode_title}]", vars: ["title": "A"]) == "A")
        #expect(renderTemplate("{title}[ - {episode_title}]", vars: ["title": "A", "episode_title": ""]) == "A")
        #expect(renderTemplate("{title}[ - {episode_title}]", vars: ["title": "A", "episode_title": "B"]) == "A - B")

        #expect(renderTemplate("S{season:02}", vars: ["season": "0"]) == "S00")
        #expect(renderTemplate("{a}[.{b}[.{c}]]", vars: ["a": "A", "b": "B"]) == "A.B")
        #expect(renderTemplate("{a}[.{b}[.{c}]]", vars: ["a": "A", "c": "C"]) == "A")

        #expect(renderTemplate(".{a}..{b}.", vars: ["a": "A", "b": "B"]) == "A.B")
        #expect(renderTemplate("{a}  {b}", vars: ["a": "A", "b": "B"]) == "A B")
        #expect(renderTemplate("-{a}__", vars: ["a": "A"]) == "A")

        #expect(renderTemplate("{title} ({year})", vars: ["title": "A"]) == "A")
        #expect(renderTemplate("{title} ({year})", vars: ["title": "A", "year": "2000"]) == "A (2000)")
        #expect(renderTemplate("{nope}x", vars: [:]) == "x")
        #expect(renderTemplate(#"a\[b\]"#, vars: [:]) == "a[b]")

        // Preserves ellipsis and double hyphens inside substituted titles
        #expect(
            renderTemplate("{title}.{year}", vars: ["title": "Once Upon a Time... in Hollywood", "year": "2019"])
                == "Once Upon a Time... in Hollywood.2019"
        )
        #expect(
            renderTemplate("{title} - {episode_title}", vars: ["title": "A -- B", "episode_title": "To Be Continued..."])
                == "A -- B - To Be Continued..."
        )
    }

    @Test("compileTemplate options, episode styles, separators, and order")
    func compileTemplateOptions() {
        #expect(renderMovie(NamingOptions()) == "盗梦空间.Inception.2010")
        #expect(renderTv(NamingOptions()) == "老友记.Friends.1994.S02E03")
        #expect(renderTemplate(NamingOptions().folderTemplate, vars: inceptionVars) == "盗梦空间 (2010)")
        #expect(renderTemplate(NamingOptions().seasonFolderTemplate, vars: ["season": "2"]) == "Season 02")

        #expect(renderTv(NamingOptions(titleLanguage: .englishFirst)) == "Friends.老友记.1994.S02E03")
        #expect(renderMovie(NamingOptions(bilingual: false)) == "盗梦空间.2010")
        #expect(renderMovie(NamingOptions(titleLanguage: .englishFirst, bilingual: false)) == "Inception.2010")

        #expect(renderMovie(NamingOptions(), vars: ["title": "盗梦空间", "year": "2010"]) == "盗梦空间.2010")
        #expect(
            renderMovie(NamingOptions(titleLanguage: .englishFirst), vars: ["title": "盗梦空间", "year": "2010"])
                == "盗梦空间.2010"
        )

        #expect(renderMovie(NamingOptions(includeYear: false)) == "盗梦空间.Inception")
        #expect(renderMovie(NamingOptions(yearInParens: true)) == "盗梦空间.Inception.(2010)")

        #expect(renderTv(NamingOptions(episodeStyle: .upperPadded)) == "老友记.Friends.1994.S02E03")
        #expect(renderTv(NamingOptions(episodeStyle: .lowerPadded)) == "老友记.Friends.1994.s02e03")
        #expect(renderTv(NamingOptions(episodeStyle: .lowerShort)) == "老友记.Friends.1994.s2e3")
        #expect(renderTv(NamingOptions(episodeStyle: .cross)) == "老友记.Friends.1994.2x03")
        #expect(renderTv(NamingOptions(episodeStyle: .lowerDotted)) == "老友记.Friends.1994.s02.e03")

        for sep in [".", "_", " ", "-"] {
            let out = renderTv(NamingOptions(episodeStyle: .lowerDotted, separator: sep))
            #expect(out.contains("s02.e03"))
        }

        #expect(
            renderTv(NamingOptions(
                episodeTitle: true,
                extraInfo: true,
                releaseGroup: true,
                tmdbIdTag: true
            )) == "老友记.Friends.1994.S02E03.The One With the Lesbian Wedding.2160p.DV.{tmdb-1668}-GRP"
        )

        #expect(
            renderTv(NamingOptions(order: [.year, .title, .episode]))
                == "1994.老友记.Friends.S02E03"
        )
        #expect(
            renderTv(
                NamingOptions(titleLanguage: .englishFirst, bilingual: true, order: [.year, .title, .episode]),
                vars: ["title": "老友记", "year": "1994", "season": "2", "episode": "3"]
            ) == "1994.老友记.S02E03"
        )

        let custom = NamingOptions(customTemplate: "{en_title} - S{season:02}E{episode:02}")
        #expect(renderTv(custom) == "Friends - S02E03")
        #expect(compileTemplate(custom, isMovie: true) == "{en_title} - S{season:02}E{episode:02}")
    }

    @Test("sanitizeName, applyRewrites, and previewNamingExample")
    func sanitizeAndRewriteAndPreview() {
        #expect(sanitizeName(#"a\b/c"#) == "abc")
        #expect(sanitizeName(#"a:b?c*d"e<f>g|h"#) == "a：b？c＊d＂e＜f＞g｜h")
        #expect(sanitizeName("  Dr.  Strange   Movie. . ") == "Dr. Strange Movie")
        #expect(sanitizeName("a\t\n b") == "a b")
        #expect(sanitizeName("a\u{007f}b") == "ab")
        #expect(sanitizeName("CON") == "CON_")
        #expect(sanitizeName("prn") == "prn_")
        #expect(sanitizeName("AUX.") == "AUX_")
        #expect(sanitizeName("nul") == "nul_")
        #expect(sanitizeName("COM1") == "COM1_")
        #expect(sanitizeName("lpt9.txt") == "lpt9_.txt")
        #expect(sanitizeName("CONAN") == "CONAN")
        #expect(sanitizeName("COM0") == "COM0")
        #expect(sanitizeName("COM10") == "COM10")

        #expect(
            applyRewrites("Season 01", rewrites: [
                NameRewrite(#"Season (\d+)"#, #"S$1"#),
                NameRewrite("S0", "S"),
            ]) == "S1"
        )
        #expect(
            applyRewrites("老友记", rewrites: [
                NameRewrite("(", "x"),
                NameRewrite(".*", ""),
            ]) == "老友记"
        )

        let moviePreview = previewNamingExample(profile: .vidhub, isMovie: true)
        #expect(moviePreview == "电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv")

        let tvPreview = previewNamingExample(profile: .vidhub, isMovie: false)
        #expect(tvPreview == "剧集/老友记 (1994)/Season 02/老友记.Friends.1994.S02E03.mp4")

        let plexTv = previewNamingExample(profile: .forPlayer(.plex), isMovie: false)
        #expect(plexTv.hasPrefix("TV Shows/老友记 (1994)/Season 02/"))
        #expect(plexTv.contains("{tmdb-1668}"))

        // Bounded regex cache handles repeated valid, invalid, and >128 distinct patterns cleanly
        for i in 0..<150 {
            let rewrites = [
                NameRewrite("tok_\(i)_(\\d+)", "ep_$1"),
                NameRewrite("[unclosed_\(i)", "ignored"),
            ]
            #expect(applyRewrites("tok_\(i)_07", rewrites: rewrites) == "ep_07")
            #expect(applyRewrites("tok_\(i)_07", rewrites: rewrites) == "ep_07")
        }
    }
}
