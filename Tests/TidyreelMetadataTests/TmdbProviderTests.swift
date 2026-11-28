import Foundation
import Testing
@testable import TidyreelMetadata
import TidyreelModels

@Suite("TmdbProviderTests")
struct TmdbProviderTests {
    private func makeProvider(
        key: String = "v3key",
        baseUrl: String? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 0,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) -> (TmdbProvider, MockHTTPTransport) {
        let transport = TmdbFixtures.makeTransport()
        let config = if let baseUrl {
            TmdbConfig(apiKey: key, baseUrl: baseUrl)
        } else {
            TmdbConfig(apiKey: key)
        }
        let provider = TmdbProvider(
            config: config,
            transport: transport,
            cache: cache,
            minIntervalMs: minIntervalMs,
            sleeper: sleeper
        )
        return (provider, transport)
    }

    // MARK: - Auth & Base URL

    @Test("v3 key goes in api_key query, no Authorization header")
    func v3Auth() async throws {
        let (p, a) = makeProvider(key: "abc123")
        _ = try await p.movie(27205)
        let req = try #require(await a.requests().first)
        #expect(req.queryMap["api_key"] == "abc123")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("v4 token (eyJ... or length > 40) goes in Bearer header, no api_key")
    func v4Auth() async throws {
        for token in [
            "eyJhbGciOiJIUzI1NiJ9.payload.sig",
            String(repeating: "x", count: 45),
        ] {
            let (p, a) = makeProvider(key: token)
            _ = try await p.movie(27205)
            let req = try #require(await a.requests().first)
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(req.queryMap["api_key"] == nil)
        }
    }

    @Test("Base URL override (proxy) is used")
    func baseUrlProxyOverride() async throws {
        let (p, a) = makeProvider(baseUrl: "https://proxy.example.com/tmdb/3/")
        _ = try await p.movie(27205)
        let req = try #require(await a.requests().first)
        #expect(req.url?.absoluteString.hasPrefix("https://proxy.example.com/tmdb/3/movie/27205?") == true)
    }

    @Test("HTTP errors become TmdbError with statusCode")
    func httpErrorMapsStatusCode() async {
        let (p, _) = makeProvider()
        await #expect(throws: TmdbError.self) {
            try await p.show(999)
        }
        do {
            _ = try await p.show(999)
            Issue.record("Expected TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 404)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Search

    @Test("Inception 2010 ranks 盗梦空间 first and fills all titles")
    func searchInception2010() async throws {
        let (p, a) = makeProvider()
        let r = try await p.search("Inception 2010")
        #expect(r.first?.tmdbId == 27205)
        #expect(r.first?.title == "盗梦空间")
        #expect(r.first?.originalTitle == "Inception")
        #expect(r.first?.englishTitle == "Inception")
        #expect(r.first?.year == 2010)
        #expect(r.first?.kind == .movie)
        #expect(r.first?.voteCount == 36_000)
        #expect(abs((r.first?.popularity ?? 0) - 83.9) < 1e-6)
        #expect(r.map(\.tmdbId) == [27205, 64956, 700001])

        let movieReq = try #require(await a.requests().first { $0.url?.path == "/3/search/movie" })
        #expect(movieReq.queryMap["year"] == "2010")
        #expect(movieReq.queryMap["query"] == "Inception")
    }

    @Test("老友记 beats similarly named titles even when listed later")
    func searchFriendsZh() async throws {
        let (p, _) = makeProvider()
        let r = try await p.search("老友记", kind: .episode)
        #expect(r.map(\.tmdbId) == [1668, 800002, 800001])
        #expect(r.first?.englishTitle == "Friends")
        #expect(r.first?.originCountry == "US")
    }

    @Test("Empty zh results fall back to en-US")
    func searchFallbackEn() async throws {
        let (p, a) = makeProvider()
        let r = try await p.search("Dorohedoro", kind: .episode)
        #expect(r.count == 1)
        #expect(r[0].tmdbId == 85937)
        #expect(r[0].title == "Dorohedoro")
        #expect(r[0].originalTitle == "ドロヘドロ")
        let langs = Set(await a.requests().compactMap { $0.queryMap["language"] })
        #expect(langs == ["zh-CN", "en-US"])
    }

    @Test("Year filter is dropped when it yields nothing, and low-score year hits fall back to yearless search")
    func searchYearFallback() async throws {
        let (p1, a1) = makeProvider()
        let empty = try await p1.search("Nonexistent Title 2011", kind: .movie)
        #expect(empty.isEmpty)
        #expect(await a1.requests().contains { $0.queryMap["year"] != nil })

        let transport = MockHTTPTransport { req in
            let hasYear = req.queryMap["year"] != nil
            let body: [String: Any] = hasYear
                ? [
                    "page": 1,
                    "results": [
                        [
                            "id": 1,
                            "title": "Completely Unrelated Film",
                            "original_title": "Completely Unrelated Film",
                            "release_date": "2011-01-01",
                        ],
                    ],
                ]
                : [
                    "page": 1,
                    "results": [
                        [
                            "id": 27205,
                            "title": "盗梦空间",
                            "original_title": "Inception",
                            "release_date": "2010-07-15",
                        ],
                    ],
                ]
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: body)
        }
        let p2 = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: transport, minIntervalMs: 0)
        let hits = try await p2.search("Inception", kind: .movie, year: 2011)
        #expect(hits.first?.tmdbId == 27205)
    }

    @Test("Second identical search hits memory cache")
    func searchMemoryCache() async throws {
        let (p, a) = makeProvider()
        _ = try await p.search("Inception", kind: .movie)
        let countAfterFirst = await a.requests().count
        _ = try await p.search("Inception", kind: .movie)
        #expect(await a.requests().count == countAfterFirst)
    }

    // MARK: - Alias Search & Chinese Alias Fallback

    @Test("Alias search ranks page 2 hit matched by alias first, and skips extra calls on exact page 1 hit")
    func aliasSearchPaginationAndExactShortCircuit() async throws {
        let routes: [String: Any] = [
            "/3/search/tv|1": [
                "total_pages": 2,
                "results": [
                    ["id": 1, "name": "潮流合伙人", "original_name": "潮流合伙人", "first_air_date": "2022-04-01"],
                    ["id": 2, "name": "名人流浪记", "original_name": "名人流浪记", "first_air_date": "2022-04-01"],
                ],
            ],
            "/3/search/tv|2": [
                "total_pages": 2,
                "results": [
                    ["id": 95480, "name": "Slow Horses", "original_name": "Slow Horses", "first_air_date": "2022-04-01"],
                ],
            ],
            "/3/tv/95480/alternative_titles|1": [
                "results": [
                    ["title": "流人"],
                    ["title": "驽马"],
                ],
            ],
        ]
        let transport = MockHTTPTransport { req in
            let key = "\(req.url?.path ?? "")|\(req.queryMap["page"] ?? "1")"
            if let body = routes[key] {
                return MockHTTPTransport.makeJSONResponse(for: req, status: 200, jsonObject: body)
            }
            return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
        }
        let p = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: transport, minIntervalMs: 0)
        let hits = try await p.search("流人", kind: .episode)
        #expect(hits.first?.tmdbId == 95480)
        #expect(hits.first?.aliases.contains("流人") == true)
        #expect(Set(hits.map(\.tmdbId)).isSuperset(of: [1, 2]))

        // Exact title on page 1 costs no extra page/alias requests
        let exactTransport = MockHTTPTransport { req in
            let key = "\(req.url?.path ?? "")|\(req.queryMap["page"] ?? "1")"
            if key == "/3/search/tv|1" {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "total_pages": 3,
                    "results": [
                        ["id": 1, "name": "流人", "original_name": "流人", "first_air_date": "2022-04-01"],
                        ["id": 2, "name": "Other", "original_name": "Other", "first_air_date": "2022-04-01"],
                    ],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
        }
        let pExact = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: exactTransport, minIntervalMs: 0)
        let exactHits = try await pExact.search("流人", kind: .episode)
        #expect(exactHits.first?.tmdbId == 1)
        let paths = Set(await exactTransport.requests().map { "\($0.url?.path ?? "")|\($0.queryMap["page"] ?? "1")" })
        #expect(paths == ["/3/search/tv|1"])
    }

    @Test("show() and movie() resolve Chinese aliases and embedded translations")
    func chineseAliasAndEmbeddedTranslations() async throws {
        // 1. CN alias when TMDB has no Chinese name
        let t1 = MockHTTPTransport { req in
            switch req.url?.path {
            case "/3/tv/95480":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["id": 95480, "name": "Slow Horses", "seasons": []])
            case "/3/tv/95480/alternative_titles":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "results": [
                        ["iso_3166_1": "RU", "title": "Хромые"],
                        ["iso_3166_1": "CN", "title": "流人"],
                        ["iso_3166_1": "CN", "title": "驽马"],
                    ],
                ])
            default:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
            }
        }
        let s1 = try await TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: t1, minIntervalMs: 0).show(95480)
        #expect(s1.info.title == "流人")
        #expect(s1.info.englishTitle == "Slow Horses")

        // 2. zh-TW translation fallback without CN alias
        let t2 = MockHTTPTransport { req in
            switch req.url?.path {
            case "/3/tv/120911":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["id": 120911, "name": "The Terminal List", "seasons": []])
            case "/3/tv/120911/translations":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "translations": [
                        ["iso_639_1": "en", "iso_3166_1": "US", "data": ["name": "X"]],
                        ["iso_639_1": "zh", "iso_3166_1": "CN", "data": ["name": ""]],
                        ["iso_639_1": "zh", "iso_3166_1": "TW", "data": ["name": "終極名單"]],
                    ],
                ])
            default:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
            }
        }
        let s2 = try await TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: t2, minIntervalMs: 0).show(120911)
        #expect(s2.info.title == "終極名單")

        // 3. movie() prefers zh-CN translation over TW alias
        let t3 = MockHTTPTransport { req in
            switch req.url?.path {
            case "/3/movie/9":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["id": 9, "title": "Dark Matter"])
            case "/3/movie/9/translations":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "translations": [
                        ["iso_639_1": "zh", "iso_3166_1": "CN", "data": ["title": "人生复本"]],
                    ],
                ])
            case "/3/movie/9/alternative_titles":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "titles": [
                        ["iso_3166_1": "TW", "title": "人生複本"],
                    ],
                ])
            default:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
            }
        }
        let m3 = try await TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: t3, minIntervalMs: 0).movie(9)
        #expect(m3.info.title == "人生复本")

        // 4. Embedded append_to_response avoids extra HTTP calls
        let t4 = MockHTTPTransport { req in
            if req.url?.path == "/3/tv/555" {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "id": 555,
                    "name": "Slow Horses",
                    "seasons": [],
                    "translations": ["translations": []],
                    "alternative_titles": [
                        "results": [["iso_3166_1": "CN", "title": "流人"]],
                    ],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_message": "not found"])
        }
        let s4 = try await TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: t4, minIntervalMs: 0).show(555)
        #expect(s4.info.title == "流人")
        let reqPaths = await t4.requests().compactMap { $0.url?.path }
        #expect(!reqPaths.contains { $0.contains("translations") || $0.contains("alternative_titles") })
    }

    // MARK: - Details (show, season, movie, episodeGroups)

    @Test("show(), season(), movie(), and episodeGroups() map recorded fixtures accurately")
    func coreDetailEndpoints() async throws {
        let (p, _) = makeProvider()

        let s = try await p.show(1668)
        #expect(s.info.title == "老友记")
        #expect(s.info.englishTitle == "Friends")
        #expect(s.info.kind == .episode)
        #expect(s.seasons.map { [$0.number, $0.episodeCount] } == [[0, 3], [1, 24], [2, 24]])
        #expect(s.seasons.first?.airDate == TidyreelCodecs.parseISO("1993-01-01"))

        let eps = try await p.season(1668, season: 1)
        #expect(eps.map(\.number) == [1, 2])
        #expect(eps.first?.title == "六人行")
        #expect(eps.last?.title == nil)
        #expect(eps.first?.season == 1)

        let m = try await p.movie(27205)
        #expect(m.info.title == "盗梦空间")
        #expect(m.info.englishTitle == "Inception")
        #expect(m.info.year == 2010)
        #expect(m.info.originCountry == "US")
        #expect(m.info.imdbId == nil)
        #expect(m.info.studios.isEmpty)

        let gs = try await p.episodeGroups(37854)
        #expect(gs.map(\.name) == ["按故事篇章", "绝对顺序"])
        #expect(gs.first?.type == 6)
        let arcs = try #require(gs.first?.seasons)
        #expect(arcs.map(\.name) == ["第一篇", "第二篇"])
        #expect(arcs[0].episodes == [EpisodeRef(1, 1), EpisodeRef(1, 2)])
        #expect(arcs[1].episodes == [EpisodeRef(2, 1), EpisodeRef(2, 2)])
        #expect(gs.last?.seasons.first?.episodes == [EpisodeRef(1, 1), EpisodeRef(1, 2), EpisodeRef(2, 1)])
    }

    @Test("movie() and show() parse full append_to_response detail payloads")
    func fullEnrichedDetailPayloads() async throws {
        // Movie enriched payload
        let movieTransport = MockHTTPTransport { req in
            let isEn = req.queryMap["language"] == "en-US"
            let cast: [[String: Any]] = stride(from: 14, through: 0, by: -1).map { i in
                ["name": "Actor \(i)", "character": "Role \(i)", "profile_path": "/a\(i).jpg", "order": i]
            }
            let body: [String: Any] = [
                "id": 27205,
                "title": isEn ? "Inception" : "盗梦空间",
                "original_title": "Inception",
                "release_date": "2010-07-15",
                "vote_average": 8.4,
                "vote_count": 36_000,
                "popularity": 83.9,
                "imdb_id": "tt1375666",
                "external_ids": ["imdb_id": "tt1375666"],
                "belongs_to_collection": ["id": 101, "name": "梦境系列"],
                "production_companies": [
                    ["name": "Legendary Pictures"],
                    ["name": "Syncopy"],
                    ["name": "Syncopy"],
                    ["name": "Warner Bros."],
                    ["name": "Studio 4"],
                    ["name": "Studio 5"],
                    ["name": "Studio 6"],
                ],
                "images": [
                    "logos": [
                        ["iso_639_1": "en", "file_path": "/logo_en.png", "vote_average": 9.0, "vote_count": 50],
                        ["iso_639_1": "zh", "file_path": "/logo_zh_low.png", "vote_average": 5.0, "vote_count": 2],
                        ["iso_639_1": "zh", "file_path": "/logo_zh_best.png", "vote_average": 5.0, "vote_count": 10],
                        ["iso_639_1": NSNull(), "file_path": "/logo_null.png", "vote_average": 8.0, "vote_count": 20],
                    ],
                    "backdrops": [
                        ["iso_639_1": NSNull(), "file_path": "/fanart_textless.jpg", "aspect_ratio": 1.778, "vote_average": 9.5, "vote_count": 100],
                        ["iso_639_1": "en", "file_path": "/landscape_en.jpg", "aspect_ratio": 1.778, "vote_average": 6.0, "vote_count": 20],
                        ["iso_639_1": "zh", "file_path": "/landscape_zh.jpg", "aspect_ratio": 1.778, "vote_average": 5.2, "vote_count": 5],
                    ],
                ],
                "release_dates": [
                    "results": [
                        ["iso_3166_1": "CN", "release_dates": [["certification": ""]]],
                        ["iso_3166_1": "US", "release_dates": [["certification": ""], ["certification": "PG-13"]]],
                        ["iso_3166_1": "HK", "release_dates": [["certification": "IIA"]]],
                    ],
                ],
                "credits": [
                    "cast": cast,
                    "crew": [
                        ["name": "Christopher Nolan", "job": "Director", "department": "Directing"],
                        ["name": "Christopher Nolan", "job": "Director", "department": "Directing"],
                        ["name": "Christopher Nolan", "job": "Writer", "department": "Writing"],
                        ["name": "Writer 2", "job": "Screenplay", "department": "Writing"],
                        ["name": "Writer 3", "job": "Story", "department": "Writing"],
                        ["name": "Writer 4", "job": "Novel", "department": "Writing"],
                        ["name": "Writer 5", "job": "Writer", "department": "Writing"],
                        ["name": "Writer 6", "job": "Writer", "department": "Writing"],
                        ["name": "Writer 7", "job": "Writer", "department": "Writing"],
                    ],
                ],
                "keywords": [
                    "keywords": (1...12).map { ["name": "kw\($0)"] },
                ],
            ]
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: body)
        }

        let mp = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: movieTransport, minIntervalMs: 0)
        let mc = try await mp.movie(27205).info
        let primaryMovieReq = try #require(await movieTransport.requests().first { $0.queryMap["language"] == "zh-CN" })
        #expect(primaryMovieReq.queryMap["append_to_response"] == "credits,external_ids,images,release_dates,keywords,translations,alternative_titles")
        #expect(primaryMovieReq.queryMap["include_image_language"] == "zh,en,null")
        #expect(mc.imdbId == "tt1375666")
        #expect(mc.collectionName == "梦境系列")
        #expect(mc.collectionId == 101)
        #expect(mc.clearLogoPath == "/logo_zh_best.png")
        #expect(mc.landscapePath == "/landscape_zh.jpg")
        #expect(mc.certification == "IIA")
        #expect(mc.studios == ["Legendary Pictures", "Syncopy", "Warner Bros.", "Studio 4", "Studio 5"])
        #expect(mc.actors.count == 12)
        #expect(mc.actors.first == PersonCredit(name: "Actor 0", role: "Role 0", profilePath: "/a0.jpg"))
        #expect(mc.actors.last?.name == "Actor 11")
        #expect(mc.directors == ["Christopher Nolan"])
        #expect(mc.writers.count == 6)
        #expect(mc.writers.first == "Christopher Nolan")
        #expect(mc.tags.count == 10)
        #expect(mc.tags.first == "kw1")

        // TV enriched payload
        let tvTransport = MockHTTPTransport { req in
            let isEn = req.queryMap["language"] == "en-US"
            let body: [String: Any] = [
                "id": 1668,
                "name": isEn ? "Friends" : "老友记",
                "original_name": "Friends",
                "first_air_date": "1994-09-22",
                "external_ids": ["imdb_id": "tt0108778", "tvdb_id": 79168],
                "networks": [["name": "NBC"]],
                "production_companies": [["name": "NBC"], ["name": "Bright/Kauffman/Crane Productions"]],
                "created_by": [["name": "David Crane"], ["name": "Marta Kauffman"]],
                "credits": [
                    "cast": [["name": "Jennifer Aniston", "character": "Rachel Green", "order": 0]],
                    "crew": [
                        ["name": "David Crane", "job": "Director", "department": "Directing"],
                        ["name": "Gary Halvorson", "job": "Director", "department": "Directing"],
                    ],
                ],
                "content_ratings": [
                    "results": [
                        ["iso_3166_1": "GB", "rating": "12"],
                        ["iso_3166_1": "US", "rating": "TV-14"],
                    ],
                ],
                "images": [
                    "logos": [["iso_639_1": NSNull(), "file_path": "/logo_textless.png", "vote_average": 5.0]],
                    "backdrops": [["iso_639_1": NSNull(), "file_path": "/fanart_only.jpg", "aspect_ratio": 1.778]],
                ],
                "keywords": [
                    "results": [["name": "new york city"], ["name": "sitcom"]],
                ],
                "seasons": [["season_number": 1, "episode_count": 24, "name": "Season 1"]],
            ]
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: body)
        }
        let tp = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: tvTransport, minIntervalMs: 0)
        let tc = try await tp.show(1668).info
        let primaryTvReq = try #require(await tvTransport.requests().first { $0.queryMap["language"] == "zh-CN" })
        #expect(primaryTvReq.queryMap["append_to_response"] == "credits,external_ids,images,content_ratings,keywords,translations,alternative_titles")
        #expect(tc.imdbId == "tt0108778")
        #expect(tc.tvdbId == 79168)
        #expect(tc.certification == "TV-14")
        #expect(tc.studios == ["NBC", "Bright/Kauffman/Crane Productions"])
        #expect(tc.directors == ["David Crane", "Marta Kauffman", "Gary Halvorson"])
        #expect(tc.clearLogoPath == "/logo_textless.png")
        #expect(tc.landscapePath == nil)
        #expect(tc.tags == ["new york city", "sitcom"])
        #expect(tc.actors == [PersonCredit(name: "Jennifer Aniston", role: "Rachel Green")])
    }

    // MARK: - findByExternalId

    @Test("findByExternalId supports tmdb, imdb, and tvdb with kind hints and enrichment")
    func externalIdLookup() async throws {
        let (p, _) = makeProvider()

        let movie = try await p.findByExternalId(source: "tmdb", id: "27205", kind: .movie)
        #expect(movie?.tmdbId == 27205)
        #expect(movie?.kind == .movie)
        #expect(movie?.title == "盗梦空间")

        let tv = try await p.findByExternalId(source: "tmdb", id: "1668", kind: .episode)
        #expect(tv?.tmdbId == 1668)
        #expect(tv?.kind == .episode)
        #expect(tv?.title == "老友记")

        let fallbackTv = try await p.findByExternalId(source: "tmdb", id: "1668", kind: nil)
        #expect(fallbackTv?.tmdbId == 1668)
        #expect(fallbackTv?.kind == .episode)

        #expect(try await p.findByExternalId(source: "tmdb", id: "999999") == nil)
        #expect(try await p.findByExternalId(source: "tmdb", id: "not-a-num") == nil)
        #expect(try await p.findByExternalId(source: "tmdb", id: "0") == nil)
        #expect(try await p.findByExternalId(source: "unknown", id: "27205") == nil)

        // IMDb & TVDB /find
        let findTransport = MockHTTPTransport { req in
            let path = req.url?.path ?? ""
            let q = req.queryMap
            switch path {
            case "/3/find/tt1375666":
                #expect(q["external_source"] == "imdb_id")
                #expect(q["language"] == "zh-CN")
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "movie_results": [["id": 27205, "title": "盗梦空间", "release_date": "2010-07-15"]],
                    "tv_results": [["id": 1668, "name": "老友记", "first_air_date": "1994-09-22"]],
                ])
            case "/3/find/79168":
                #expect(q["external_source"] == "tvdb_id")
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "movie_results": [],
                    "tv_results": [["id": 1668, "name": "老友记", "first_air_date": "1994-09-22"]],
                ])
            case "/3/find/tt0000001":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "movie_results": [[
                        "id": 55555,
                        "title": "回退电影",
                        "original_title": "Fallback Film",
                        "release_date": "2023-05-01",
                        "vote_count": 42,
                    ]],
                    "tv_results": [],
                ])
            case "/3/find/tt9999999":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["movie_results": [], "tv_results": []])
            case "/3/movie/27205":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "id": 27205,
                    "title": q["language"] == "en-US" ? "Inception" : "盗梦空间",
                    "original_title": "Inception",
                    "release_date": "2010-07-15",
                    "imdb_id": "tt1375666",
                ])
            case "/3/tv/1668":
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "id": 1668,
                    "name": q["language"] == "en-US" ? "Friends" : "老友记",
                    "original_name": "Friends",
                    "first_air_date": "1994-09-22",
                    "external_ids": ["imdb_id": "tt0108778", "tvdb_id": 79168],
                    "seasons": [],
                ])
            default:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["status_code": 34, "status_message": "not found"])
            }
        }
        let fp = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: findTransport, minIntervalMs: 0)
        let mHit = try await fp.findByExternalId(source: "imdb", id: "tt1375666", kind: .movie)
        #expect(mHit?.tmdbId == 27205)
        #expect(mHit?.englishTitle == "Inception")
        #expect(mHit?.imdbId == "tt1375666")

        let tvHit = try await fp.findByExternalId(source: "imdb", id: "tt1375666", kind: .episode)
        #expect(tvHit?.tmdbId == 1668)
        #expect(tvHit?.englishTitle == "Friends")
        #expect(tvHit?.tvdbId == 79168)

        let tvdbHit = try await fp.findByExternalId(source: "tvdb", id: "79168", kind: .episode)
        #expect(tvdbHit?.tmdbId == 1668)
        #expect(tvdbHit?.title == "老友记")

        let fallbackHit = try await fp.findByExternalId(source: "imdb", id: "tt0000001")
        #expect(fallbackHit?.tmdbId == 55555)
        #expect(fallbackHit?.title == "回退电影")
        #expect(fallbackHit?.voteCount == 42)

        #expect(try await fp.findByExternalId(source: "imdb", id: "tt9999999") == nil)
        #expect(try await fp.findByExternalId(source: "tvdb", id: "not-numeric") == nil)
    }

    // MARK: - Cache, Retry, Security & Fallback Language

    @Test("Persistent TmdbResponseCache serves a new provider without HTTP requests and omits apiKey")
    func persistentCacheAndMemoryCache() async throws {
        let cache = MapTmdbCache()
        let (p1, a1) = makeProvider(key: "v3key", cache: cache)
        _ = try await p1.show(1668)
        let firstCount = await a1.requests().count
        _ = try await p1.show(1668)
        #expect(await a1.requests().count == firstCount)

        let storedKeys = await cache.keys().joined(separator: "|")
        #expect(!storedKeys.contains("v3key"))

        let (p2, a2) = makeProvider(key: "v3key", cache: cache)
        let s = try await p2.show(1668)
        #expect(s.info.tmdbId == 1668)
        #expect(await a2.requests().isEmpty)
    }

    @Test("Disk cache isolates endpoint, credential and legacy entries, including cached 404s")
    func diskCacheScopes() async throws {
        let cache = MapTmdbCache()
        await cache.put("/movie/1?", json: #"{"origin":"legacy"}"#)
        let transport = MockHTTPTransport { request in
            let key = request.queryMap["api_key"]
            if key == "absent" {
                return MockHTTPTransport.makeResponse(for: request, status: 404, body: "{}")
            }
            return MockHTTPTransport.makeJSONResponse(for: request, jsonObject: ["origin": request.url?.host ?? ""])
        }
        func client(_ endpoint: String, _ key: String) -> TmdbClient {
            TmdbClient(apiKey: key, baseUrl: endpoint, transport: transport, cache: cache, minIntervalMs: 0)
        }
        let a = "https://a.example/3"
        let b = "https://b.example/3"
        #expect(try await client(a, "first").get("/movie/1")["origin"] == .string("a.example"))
        #expect(try await client(b, "first").get("/movie/1")["origin"] == .string("b.example"))
        await #expect(throws: TmdbError.self) { try await client(a, "absent").get("/movie/1") }
        await #expect(throws: TmdbError.self) { try await client(a, "absent").get("/movie/1") }
        #expect(try await client(a + "/", "first").get("/movie/1")["origin"] == .string("a.example"))
        #expect(await transport.requests().count == 3)
    }

    @Test("429 is retried honoring Retry-After and gives up after maxRetries")
    func retry429AndGiveUp() async throws {
        let sleeper1 = RecordingSleeper()
        let (p1, a1) = makeProvider(sleeper: sleeper1.sleep)
        await a1.addOverride(status: 429, headers: ["Retry-After": "0"])
        let m = try await p1.movie(27205)
        #expect(m.info.tmdbId == 27205)
        #expect(await a1.count(path: "/3/movie/27205") == 3)
        let sleeps1 = await sleeper1.recorded()
        #expect(sleeps1.contains(1.0))

        let sleeper2 = RecordingSleeper()
        let (p2, a2) = makeProvider(sleeper: sleeper2.sleep)
        for _ in 0..<4 {
            await a2.addOverride(status: 429, headers: ["Retry-After": "0"])
        }
        do {
            _ = try await p2.season(1668, season: 1)
            Issue.record("Expected 429 TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 429)
        }
        #expect(await a2.count(path: "/3/tv/1668/season/1") == 4)
        #expect(await sleeper2.recorded() == [1.0, 1.0, 1.0])
    }

    @Test("Does not retry cancelled or bad certificate errors, and parseRetryAfter clamps properly")
    func nonRetryableErrorsAndParseRetryAfter() async throws {
        for code in [URLError.Code.cancelled, URLError.Code.serverCertificateUntrusted] {
            let transport = MockHTTPTransport { _ in
                throw URLError(code)
            }
            let client = TmdbClient(apiKey: "k", transport: transport, minIntervalMs: 0, networkRetryBaseDelay: 0)
            await #expect(throws: TmdbError.self) {
                try await client.get("/movie/1")
            }
            #expect(await transport.requests().count == 1)
        }

        #expect(TmdbClient.parseRetryAfter("0", attempt: 0) == 1.0)
        #expect(TmdbClient.parseRetryAfter("120", attempt: 0) == 30.0)
        #expect(TmdbClient.parseRetryAfter("5", attempt: 0) == 5.0)

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let futureHeader = df.string(from: Date().addingTimeInterval(12))
        let parsed = TmdbClient.parseRetryAfter(futureHeader, attempt: 0)
        #expect((9.0...13.0).contains(parsed))
    }

    @Test("Rejects non-JSON HTTP 200 with Chinese message and redacts v3 api_key on network failure")
    func nonJson200AndSecretRedaction() async throws {
        let htmlTransport = MockHTTPTransport { req in
            MockHTTPTransport.makeResponse(
                for: req,
                status: 200,
                headers: ["Content-Type": "text/html"],
                body: "<html>blocked</html>"
            )
        }
        let htmlProvider = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: htmlTransport, minIntervalMs: 0)
        do {
            _ = try await htmlProvider.movie(27205)
            Issue.record("Expected non-JSON TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 200)
            #expect(err.message.contains("非 JSON"))
        }

        struct LeakingError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let secret = "super_secret_v3_key_987654"
        let errTransport = MockHTTPTransport { _ in
            throw LeakingError(
                message: "Failed https://api.themoviedb.org/3/movie/1?api_key=\(secret)&language=zh-CN (key=\(secret))"
            )
        }
        let client = TmdbClient(apiKey: secret, transport: errTransport, minIntervalMs: 0, networkRetryBaseDelay: 0)
        do {
            _ = try await client.get("/movie/1")
            Issue.record("Expected redacted TmdbError")
        } catch let err as TmdbError {
            #expect(!err.message.contains(secret))
            #expect(err.message.contains("[REDACTED]"))
        }
    }

    @Test("Fallback language, en-US deduplication, unknown/extra kinds, and 429 concurrent cooldown")
    func fallbackLangAndConcurrentCooldown() async throws {
        // en-US single-language deduplication
        let enTransport = TmdbFixtures.makeTransport()
        let enProvider = TmdbProvider(
            config: TmdbConfig(apiKey: "k", language: "en-US"),
            transport: enTransport,
            minIntervalMs: 0
        )
        _ = try await enProvider.movie(27205)
        let enReqs = await enTransport.requests()
        #expect(enReqs.count == 1)
        #expect(enReqs[0].queryMap["append_to_response"] == "credits,external_ids,images,release_dates,keywords")
        #expect(enReqs[0].queryMap["include_image_language"] == "en,null")

        // Custom fallbackLanguage ja-JP
        let jaTransport = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "id": 27205,
                "title": "インセプション",
                "original_title": "Inception",
                "release_date": "2010-07-15",
            ])
        }
        let jaProvider = TmdbProvider(
            config: TmdbConfig(apiKey: "k", language: "zh-CN", fallbackLanguage: "ja-JP"),
            transport: jaTransport,
            minIntervalMs: 0
        )
        _ = try await jaProvider.movie(27205)
        let jaReqs = await jaTransport.requests()
        let langs = Set(jaReqs.compactMap { $0.queryMap["language"] })
        #expect(langs == ["zh-CN", "ja-JP"])
        let imgLang = jaReqs.compactMap { $0.queryMap["include_image_language"] }.first
        #expect(imgLang == "zh,ja,null")

        // Unknown and extra kinds search both movie and tv
        for kind in [MediaKind.unknown, MediaKind.extra] {
            let kt = MockHTTPTransport { req in
                MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["page": 1, "results": []])
            }
            let kp = TmdbProvider(config: TmdbConfig(apiKey: "k"), transport: kt, minIntervalMs: 0)
            _ = try await kp.search("Some Title", kind: kind)
            let paths = Set(await kt.requests().compactMap { $0.url?.path })
            #expect(paths == ["/3/search/movie", "/3/search/tv"])
        }

        // 429 cooldown blocks concurrent queued requests without real wall-clock sleeping
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
            func total() -> Int { count }
        }
        actor CooldownCoordinator {
            private var durations: [TimeInterval] = []
            private var firstEntered = false
            private var waitForFirst: CheckedContinuation<Void, Never>?
            private var releaseFirst: CheckedContinuation<Void, Never>?

            func recordSleep(_ seconds: TimeInterval) async {
                durations.append(seconds)
                if durations.count == 1 {
                    firstEntered = true
                    waitForFirst?.resume()
                    waitForFirst = nil
                    await withCheckedContinuation { cont in
                        releaseFirst = cont
                    }
                } else if durations.count == 2 {
                    releaseFirst?.resume()
                    releaseFirst = nil
                }
            }

            func awaitFirstSleep() async {
                if firstEntered { return }
                await withCheckedContinuation { cont in
                    waitForFirst = cont
                }
            }

            func recorded() -> [TimeInterval] {
                durations
            }
        }

        let calls = CallCounter()
        let coordinator = CooldownCoordinator()
        let cooldownTransport = MockHTTPTransport { req in
            let n = await calls.next()
            if n == 1 {
                return MockHTTPTransport.makeResponse(
                    for: req,
                    status: 429,
                    headers: ["Retry-After": "5"],
                    body: #"{"status_message":"Too many requests"}"#
                )
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["id": 1])
        }
        let client = TmdbClient(
            apiKey: "k",
            transport: cooldownTransport,
            minIntervalMs: 0,
            sleeper: { seconds in
                await coordinator.recordSleep(seconds)
            }
        )
        let r1 = Task { try await client.get("/movie/1") }
        await coordinator.awaitFirstSleep()
        let r2 = Task { try await client.get("/movie/2") }
        _ = try await r1.value
        _ = try await r2.value

        #expect(await calls.total() == 3)
        let cooldownSleeps = await coordinator.recorded()
        #expect(cooldownSleeps.count == 2)
        #expect(cooldownSleeps[0] == 5.0)
        #expect(cooldownSleeps[1] >= 4.0 && cooldownSleeps[1] <= 5.05)
    }

    // MARK: - Transport, LRUCache, clearMemoryCache, Negative 404 & Cache Keys

    @Test("URLSessionHTTPTransport uses ephemeral uncached session by default")
    func urlSessionTransportDefaultsToEphemeralUncached() {
        let transport = URLSessionHTTPTransport()
        #expect(transport.session !== URLSession.shared)
        #expect(transport.session.configuration.urlCache == nil)
        #expect(transport.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        let external = URLSession(configuration: .ephemeral)
        defer { external.finishTasksAndInvalidate() }
        let borrowed = URLSessionHTTPTransport(session: external)
        #expect(borrowed.session === external)
    }

    @Test("O(1) LRUCache evicts LRU, promotes on get, keeps order on peek, and reuses slots")
    func lruCacheBehavior() {
        var cache = LRUCache<String, Int>(capacity: 3)
        #expect(cache.isEmpty)
        #expect(cache.count == 0)

        cache.put("a", 1)
        cache.put("b", 2)
        cache.put("c", 3)
        #expect(cache.count == 3)
        #expect(cache.values == [3, 2, 1])

        // peek must NOT promote "a"
        #expect(cache.peek("a") == 1)
        #expect(cache.values == [3, 2, 1])

        // get promotes "a" to MRU
        #expect(cache.get("a") == 1)
        #expect(cache.values == [1, 3, 2])

        // inserting "d" evicts LRU ("b")
        cache.put("d", 4)
        #expect(cache.peek("b") == nil)
        #expect(cache.values == [4, 1, 3])

        // overwriting existing key updates value & promotes without evicting
        cache.put("c", 30)
        #expect(cache.count == 3)
        #expect(cache.values == [30, 4, 1])

        // remove middle element
        #expect(cache.removeValue(forKey: "d") == 4)
        #expect(cache.count == 2)
        #expect(cache.values == [30, 1])

        // removeOldest pops tail in LRU order
        let oldest1 = cache.removeOldest()
        #expect(oldest1?.key == "a" && oldest1?.value == 1)
        let oldest2 = cache.removeOldest()
        #expect(oldest2?.key == "c" && oldest2?.value == 30)
        #expect(cache.removeOldest() == nil)
        #expect(cache.isEmpty)

        // capacity 1 edge case
        var tiny = LRUCache<Int, String>(capacity: 1)
        tiny.put(1, "one")
        tiny.put(1, "ONE")
        #expect(tiny.count == 1)
        #expect(tiny.get(1) == "ONE")
        tiny.put(2, "two")
        #expect(tiny.peek(1) == nil)
        #expect(tiny.get(2) == "two")
        tiny.removeAll()
        #expect(tiny.isEmpty)

        // scale / slot-reuse check
        var large = LRUCache<Int, Int>(capacity: 64)
        for i in 0..<5_000 {
            large.put(i, i * 10)
        }
        #expect(large.count == 64)
        #expect(large.peek(0) == nil)
        #expect(large.peek(4_935) == nil)
        #expect(large.peek(4_936) == 49_360)
        #expect(large.peek(4_999) == 49_990)
    }

    @Test("clearMemoryCache clears L1 while keeping L2 cache intact")
    func clearMemoryCacheBehavior() async throws {
        // Without L2: clearing memory cache forces a fresh HTTP request
        let (pMemOnly, tMemOnly) = makeProvider()
        _ = try await pMemOnly.movie(27205)
        let firstCount = await tMemOnly.requests().count
        _ = try await pMemOnly.movie(27205)
        #expect(await tMemOnly.requests().count == firstCount)
        #expect(await pMemOnly.client.memoryCacheEntryCount > 0)

        await pMemOnly.clearMemoryCache()
        #expect(await pMemOnly.client.memoryCacheEntryCount == 0)
        #expect(await pMemOnly.client.memoryCacheByteCount == 0)

        _ = try await pMemOnly.movie(27205)
        #expect(await tMemOnly.requests().count == firstCount * 2)

        // With L2: clearing memory cache falls back to L2 without HTTP traffic
        let l2 = MapTmdbCache()
        let (pBacked, tBacked) = makeProvider(cache: l2)
        _ = try await pBacked.movie(27205)
        let backedFirst = await tBacked.requests().count
        await pBacked.clearMemoryCache()
        #expect(await pBacked.client.memoryCacheEntryCount == 0)

        let cachedMovie = try await pBacked.movie(27205)
        #expect(cachedMovie.info.tmdbId == 27205)
        #expect(await tBacked.requests().count == backedFirst)
        #expect(await pBacked.client.memoryCacheEntryCount > 0)
    }

    @Test("HTTP 404 is negative-cached in L1 and L2 sentinel and expires after TTL")
    func negative404CachingAndExpiry() async throws {
        let l2 = MapTmdbCache()
        let (p1, t1) = makeProvider(cache: l2)

        // First 404 hits network and writes negative sentinel to L1 + L2
        do {
            _ = try await p1.season(999, season: 1)
            Issue.record("Expected 404 TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 404)
        }
        #expect(await t1.requests().count == 1)

        // Second call hits L1 negative cache with zero additional HTTP requests
        do {
            _ = try await p1.season(999, season: 1)
            Issue.record("Expected cached 404 TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 404)
        }
        #expect(await t1.requests().count == 1)

        // Verify sentinel format stored in L2
        let keys = await l2.keys()
        let sentinelValues = await withTaskGroup(of: String?.self) { group in
            for k in keys {
                group.addTask { await l2.rawValue(for: k) }
            }
            var out: [String] = []
            for await val in group {
                if let val { out.append(val) }
            }
            return out
        }
        #expect(sentinelValues.contains { $0.contains("\"__tidyreel_negative_404\":true") })

        // New provider with same L2 gets 404 from persistent sentinel without HTTP calls
        let (p2, t2) = makeProvider(cache: l2)
        do {
            _ = try await p2.season(999, season: 1)
            Issue.record("Expected L2 negative 404 TmdbError")
        } catch let err as TmdbError {
            #expect(err.statusCode == 404)
        }
        #expect(await t2.requests().isEmpty)

        // Expired L2 sentinel (> 6h old) falls through to network
        let expiredCache = MapTmdbCache()
        let staleTs = Int64(Date().timeIntervalSince1970 - TmdbClient.negative404TTL - 60)
        let (p3, t3) = makeProvider(cache: expiredCache)
        let key = p3.client.makeCacheKey(path: "/tv/1668/season/1", query: ["language": "zh-CN"])
        await expiredCache.put(key, json: #"{"__tidyreel_negative_404":true,"ts":\#(staleTs)}"#)

        let eps = try await p3.season(1668, season: 1)
        #expect(eps.count == 2)
        #expect(await t3.count(path: "/3/tv/1668/season/1") == 1)
    }

    @Test("TmdbClient percent-encodes cache keys and bounds L1 entries")
    func cacheKeyEncodingAndBoundedL1() async throws {
        let client = TmdbClient(apiKey: "k")
        let k1 = client.makeCacheKey(path: "/search/movie", query: ["a": "1&b=2"])
        let k2 = client.makeCacheKey(path: "/search/movie", query: ["a": "1", "b": "2"])
        #expect(k1 != k2)
        #expect(k1.contains("%26"))
        #expect(k1.contains("%3D"))

        let transport = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["ok": true])
        }
        let backed = TmdbClient(apiKey: "k", transport: transport, cache: MapTmdbCache(), minIntervalMs: 0)
        for i in 0..<150 {
            _ = try await backed.get("/movie/\(i)")
        }
        #expect(await backed.memoryCacheEntryCount == 128)

        let unbacked = TmdbClient(apiKey: "k", transport: transport, cache: nil, minIntervalMs: 0)
        for i in 0..<280 {
            _ = try await unbacked.get("/movie/\(i)")
        }
        #expect(await unbacked.memoryCacheEntryCount == 256)
    }
}
