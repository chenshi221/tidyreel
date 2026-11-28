import Foundation
import Testing
@testable import TidyreelMetadata
import TidyreelModels

@Suite("AniListTests")
struct AniListTests {
    private func extractSearchVariable(_ req: URLRequest) -> String? {
        guard let body = req.httpBody,
              let obj = JSONValue.parseObject(from: body),
              let vars = obj["variables"]?.objectValue else {
            return nil
        }
        return vars["s"]?.stringValue
    }

    @Test("parseAniList keeps native, english, romaji, synonyms once each and ignores malformed items")
    func parseAniListDeduplicationAndMalformed() {
        let titles = parseAniList([
            [
                "title": [
                    "native": "不束者な悪女ですが",
                    "english": NSNull(),
                    "romaji": "Futsutsuka na Akujo dewa Gozaimasu ga",
                ],
                "synonyms": ["恶女不才", "Futsutsuka na Akujo dewa Gozaimasu ga"],
            ],
        ])
        #expect(titles == [
            "不束者な悪女ですが",
            "Futsutsuka na Akujo dewa Gozaimasu ga",
            "恶女不才",
        ])

        let mixed: [Any] = [
            NSNull(),
            "not a map",
            123,
            [
                "title": ["native": "葬送のフリーレン", "romaji": "Sousou no Frieren"],
                "synonyms": ["葬送的芙莉莲", 42],
            ],
        ]
        #expect(parseAniList(mixed) == ["葬送のフリーレン", "Sousou no Frieren", "葬送的芙莉莲"])
    }

    @Test("Subtitles are stripped into meaningful prefixes appended after full titles, and plausibility handles edge cases")
    func subtitleStrippingAndPlausibility() {
        let m: [String: Any] = [
            "title": [
                "native": "ふつつかな悪女ではございますが ~雛宮蝶鼠とりかえ伝~",
                "romaji": "Futsutsuka na Akujo de wa Gozaimasu ga: Suuguu Chouso Torikae Den",
            ],
        ]
        #expect(parseAniList([m]).contains("ふつつかな悪女ではございますが"))
        #expect(plausibleAniList("Futsutsuka na Akujo dewa Gozaimasu ga", m))
        #expect(!plausibleAniList("Futsutsuka na Shounen", m))

        #expect(!plausibleAniList("Frieren", ["title": "not-a-map", "synonyms": "not-a-list"]))
        let reZero: [String: Any] = [
            "title": [
                "romaji": "Re:Zero kara Hajimeru Isekai Seikatsu",
                "english": "Re:ZERO -Starting Life in Another World-",
            ],
            "synonyms": ["ReZero"],
        ]
        #expect(!plausibleAniList("Re", reZero))
        #expect(!plausibleAniList("a", reZero))
        #expect(plausibleAniList("ReZero", reZero))
        #expect(plausibleAniList("K", ["title": ["romaji": "K", "english": "K"], "synonyms": [String]()]))

        let ordered = parseAniList([
            [
                "title": [
                    "native": "Re:ゼロから始める異世界生活",
                    "english": "Re:ZERO - Starting Life in Another World",
                    "romaji": "Frieren: Beyond Journey's End",
                ],
                "synonyms": ["葬送のフリーレン ~魔法~"],
            ],
        ])
        #expect(!ordered.contains("Re"))
        let fullIdx = ordered.firstIndex(of: "葬送のフリーレン ~魔法~") ?? -1
        let strippedEnIdx = ordered.firstIndex(of: "Frieren") ?? -1
        let strippedJpIdx = ordered.firstIndex(of: "葬送のフリーレン") ?? -1
        #expect(strippedEnIdx > fullIdx)
        #expect(strippedJpIdx > fullIdx)
    }

    @Test("Queries single-word anime titles and normalizes cache whitespace")
    func singleWordAndCacheNormalization() async {
        let transport = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": [
                    "Page": [
                        "media": [
                            [
                                "title": [
                                    "native": "葬送のフリーレン",
                                    "english": "Frieren: Beyond Journey's End",
                                    "romaji": "Sousou no Frieren",
                                ],
                                "synonyms": ["Frieren"],
                            ],
                        ],
                    ],
                ],
            ])
        }
        let anilist = AniListTitles(transport: transport, minIntervalMs: 0)
        let res1 = await anilist.altTitles("Frieren")
        #expect(res1.contains("葬送のフリーレン"))
        let queries1 = await transport.requests().compactMap(extractSearchVariable)
        #expect(queries1 == ["Frieren"])

        let res2 = await anilist.altTitles("  frieren  ")
        #expect(res2 == res1)
        let queries2 = await transport.requests().compactMap(extractSearchVariable)
        #expect(queries2 == ["Frieren"])
        await anilist.close()
    }

    @Test("Retries once on HTTP 429 and evicts cache on GraphQL errors or missing Page")
    func retry429AndEvictGraphQLErrors() async {
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
            func value() -> Int { count }
        }

        // 429 retry
        let c1 = CallCounter()
        let t1 = MockHTTPTransport { req in
            let n = await c1.next()
            if n == 1 {
                return MockHTTPTransport.makeJSONResponse(
                    for: req,
                    status: 429,
                    headers: ["Retry-After": "1"],
                    jsonObject: ["errors": [["message": "Too Many Requests"]]]
                )
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": [
                    "Page": [
                        "media": [[
                            "title": ["native": "銀魂", "english": "Gintama", "romaji": "Gintama"],
                            "synonyms": [String](),
                        ]],
                    ],
                ],
            ])
        }
        let sleeper = RecordingSleeper()
        let a1 = AniListTitles(transport: t1, minIntervalMs: 0, sleeper: sleeper.sleep)
        let r1 = await a1.altTitles("Gintama")
        #expect(r1.contains("銀魂"))
        #expect(await c1.value() == 2)
        #expect(await sleeper.recorded() == [1.0])

        // GraphQL error & missing Page eviction
        let c2 = CallCounter()
        let t2 = MockHTTPTransport { req in
            let n = await c2.next()
            if n == 1 {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "errors": [["message": "Internal error"]],
                    "data": NSNull(),
                ])
            }
            if n == 2 {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "data": [String: Any](),
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": [
                    "Page": [
                        "media": [[
                            "title": ["native": "銀魂", "english": "Gintama", "romaji": "Gintama"],
                            "synonyms": [String](),
                        ]],
                    ],
                ],
            ])
        }
        let a2 = AniListTitles(transport: t2, minIntervalMs: 0, sleeper: sleeper.sleep)
        #expect(await a2.altTitles("Gintama").isEmpty)
        #expect(await a2.altTitles("Gintama").isEmpty)
        #expect(await a2.altTitles("Gintama").contains("銀魂"))
        #expect(await c2.value() == 3)
    }

    @Test("AniListTitles persistent cache uses anilist: prefix, honors TTL, and supports clearCache")
    func persistentCacheTTLAndClearCache() async {
        let cache = MapTmdbCache()
        let t1 = MockHTTPTransport { req in
            let q = self.extractSearchVariable(req)
            if q == "Gintama" {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "data": [
                        "Page": [
                            "media": [[
                                "title": ["native": "銀魂", "english": "Gintama", "romaji": "Gintama"],
                                "synonyms": [String](),
                            ]],
                        ],
                    ],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": ["Page": ["media": [Any]()]],
            ])
        }
        let a1 = AniListTitles(transport: t1, cache: cache, minIntervalMs: 0)
        #expect(await a1.altTitles("Gintama").contains("銀魂"))
        #expect(await a1.altTitles("Nonexistent").isEmpty)
        #expect(await t1.requests().count == 2)

        let keys = Set(await cache.keys())
        #expect(keys.contains("anilist:gintama"))
        #expect(keys.contains("anilist:nonexistent"))

        // Second instance sharing L2 serves positive and negative hits without HTTP requests
        let t2 = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": ["Page": ["media": [Any]()]],
            ])
        }
        let a2 = AniListTitles(transport: t2, cache: cache, minIntervalMs: 0)
        #expect(await a2.altTitles("  GINTAMA ").contains("銀魂"))
        #expect(await a2.altTitles("nonexistent").isEmpty)
        #expect(await t2.requests().isEmpty)

        // Expired positive (> 14d) and expired negative (> 24h) entries trigger fresh HTTP calls
        let expiredCache = MapTmdbCache()
        let oldPosTs = Int64(Date().timeIntervalSince1970 - AltTitleCacheCodec.positiveTTL - 120)
        let oldNegTs = Int64(Date().timeIntervalSince1970 - AltTitleCacheCodec.negativeTTL - 120)
        await expiredCache.put("anilist:gintama", json: #"{"titles":["Stale"],"ts":\#(oldPosTs)}"#)
        await expiredCache.put("anilist:frieren", json: #"{"titles":[],"ts":\#(oldNegTs)}"#)

        let t3 = MockHTTPTransport { req in
            let q = self.extractSearchVariable(req)
            if q == "Gintama" {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "data": [
                        "Page": [
                            "media": [[
                                "title": ["native": "銀魂", "english": "Gintama", "romaji": "Gintama"],
                                "synonyms": [String](),
                            ]],
                        ],
                    ],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": [
                    "Page": [
                        "media": [[
                            "title": ["native": "葬送のフリーレン", "english": "Frieren", "romaji": "Sousou no Frieren"],
                            "synonyms": [String](),
                        ]],
                    ],
                ],
            ])
        }
        let a3 = AniListTitles(transport: t3, cache: expiredCache, minIntervalMs: 0)
        #expect(await a3.altTitles("Gintama").contains("銀魂"))
        #expect(await a3.altTitles("Frieren").contains("葬送のフリーレン"))
        #expect(await t3.requests().count == 2)

        // clearCache wipes L1
        let t4 = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "data": [
                    "Page": [
                        "media": [[
                            "title": ["native": "銀魂", "english": "Gintama", "romaji": "Gintama"],
                            "synonyms": [String](),
                        ]],
                    ],
                ],
            ])
        }
        let a4 = AniListTitles(transport: t4, minIntervalMs: 0)
        _ = await a4.altTitles("Gintama")
        _ = await a4.altTitles("Gintama")
        #expect(await t4.requests().count == 1)
        await a4.clearCache()
        _ = await a4.altTitles("Gintama")
        #expect(await t4.requests().count == 2)
    }
}
