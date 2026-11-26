import Foundation
import Testing
@testable import TidyreelMetadata
import TidyreelModels

@Suite("BangumiTests")
struct BangumiTests {
    private struct FakeAltSource: AltTitleSource {
        let titles: [String]

        func altTitles(_ query: String) async -> [String] {
            titles
        }
    }

    @Test("Returns name_cn then name, unescapes HTML, deduplicates, and sends User-Agent and params")
    func basicLookupAndRequestShape() async {
        let transport = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "results": 2,
                "list": [
                    [
                        "id": 400_602,
                        "type": 2,
                        "name": "葬送のフリーレン",
                        "name_cn": "葬送的芙莉莲",
                    ],
                    [
                        "id": 450_000,
                        "type": 2,
                        "name": "葬送のフリーレン &amp; 魔法",
                        "name_cn": "葬送的芙莉莲",
                    ],
                ],
            ])
        }

        let bgm = BangumiTitles(
            transport: transport,
            minIntervalMs: 0,
            userAgent: "Tidyreel/1.0-test"
        )
        let titles = await bgm.altTitles("Sousou no Frieren")
        #expect(titles == ["葬送的芙莉莲", "葬送のフリーレン", "葬送のフリーレン & 魔法"])

        let reqs = await transport.requests()
        #expect(reqs.count == 1)
        let req = reqs[0]
        #expect(req.url?.host == "api.bgm.tv")
        #expect(req.url?.path(percentEncoded: true) == "/search/subject/Sousou%20no%20Frieren")
        #expect(req.queryMap == ["type": "2", "responseGroup": "small", "max_results": "5"])
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Tidyreel/1.0-test")
        await bgm.close()
    }

    @Test("Excludes exact copy of query so CN query yields official JP name first")
    func excludesExactQueryCopy() async {
        let transport = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "results": 1,
                "list": [
                    ["id": 400_602, "type": 2, "name": "葬送のフリーレン", "name_cn": "葬送的芙莉莲"],
                ],
            ])
        }
        let bgm = BangumiTitles(transport: transport, minIntervalMs: 0)
        #expect(await bgm.altTitles("葬送的芙莉莲") == ["葬送のフリーレン"])
    }

    @Test("Caches hits and empty results with whitespace and case normalization")
    func cacheNormalizationAndNegativeCache() async {
        let transport = MockHTTPTransport { req in
            if req.url?.path.contains("Frieren") == true {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "results": 1,
                    "list": [["name": "葬送のフリーレン", "name_cn": "葬送的芙莉莲"]],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["results": 0, "list": []])
        }
        let bgm = BangumiTitles(transport: transport, minIntervalMs: 0)

        let r1 = await bgm.altTitles("  Frieren  ")
        let r2 = await bgm.altTitles("frieren")
        #expect(r1 == ["葬送的芙莉莲", "葬送のフリーレン"])
        #expect(r2 == r1)
        #expect(await transport.requests().count == 1)

        #expect(await bgm.altTitles("Unknown Anime").isEmpty)
        #expect(await bgm.altTitles("  unknown   anime ").isEmpty)
        #expect(await transport.requests().count == 2)

        #expect(await bgm.altTitles("   ").isEmpty)
        #expect(await transport.requests().count == 2)
    }

    @Test("Swallows 404, 429, 503, missing list on 200, and network errors cleanly")
    func resilienceAndEviction() async {
        actor StepCounter {
            var step = 0
            func next() -> Int {
                step += 1
                return step
            }
        }
        let counter = StepCounter()
        let transport = MockHTTPTransport { req in
            let step = await counter.next()
            switch step {
            case 1:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["title": "Not Found"])
            case 2:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 429, headers: ["Retry-After": "1"], jsonObject: ["title": "Too Many Requests"])
            case 3:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 503, jsonObject: ["title": "Server Error"])
            case 4:
                throw URLError(.timedOut)
            case 5:
                return MockHTTPTransport.makeJSONResponse(for: req, status: 200, jsonObject: ["code": 500, "error": "temporary error"])
            default:
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "results": 1,
                    "list": [["name": "銀魂", "name_cn": "银魂"]],
                ])
            }
        }

        let sleeper = RecordingSleeper()
        let bgm = BangumiTitles(transport: transport, minIntervalMs: 0, sleeper: sleeper.sleep)
        #expect(await bgm.altTitles("Missing").isEmpty)
        // 404 is negative-cached, so repeating 'Missing' makes no new request
        #expect(await bgm.altTitles("Missing").isEmpty)
        #expect(await transport.requests().count == 1)

        #expect(await bgm.altTitles("RateLimited").isEmpty)
        #expect(await bgm.altTitles("ServerDown").isEmpty)
        #expect(await bgm.altTitles("TimedOut").isEmpty)
        #expect(await bgm.altTitles("Malformed200").isEmpty)
        let sleeps = await sleeper.recorded()
        #expect(sleeps.count == 1)
        #expect(sleeps[0] >= 0.85 && sleeps[0] <= 1.05)
        // Evicted entries succeed on retry
        #expect(await bgm.altTitles("TimedOut") == ["银魂", "銀魂"])
        #expect(await bgm.altTitles("Malformed200") == ["银魂", "銀魂"])
    }

    @Test("429 sets cooldown blocking subsequent requests")
    func cooldownOn429() async {
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
            func total() -> Int { count }
        }
        let calls = CallCounter()
        let transport = MockHTTPTransport { req in
            let call = await calls.next()
            if call == 1 {
                return MockHTTPTransport.makeJSONResponse(
                    for: req,
                    status: 429,
                    headers: ["Retry-After": "1"],
                    jsonObject: ["title": "Too Many Requests"]
                )
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "results": 1,
                "list": [["name": "銀魂", "name_cn": "银魂"]],
            ])
        }

        let sleeper = RecordingSleeper()
        let bgm = BangumiTitles(transport: transport, minIntervalMs: 0, sleeper: sleeper.sleep)
        #expect(await bgm.altTitles("银魂").isEmpty)
        #expect(await sleeper.recorded().isEmpty)
        #expect(await bgm.altTitles("银魂") == ["銀魂"])
        #expect(await calls.total() == 2)
        let sleeps = await sleeper.recorded()
        #expect(sleeps.count == 1)
        #expect(sleeps[0] >= 0.85 && sleeps[0] <= 1.05)
    }

    @Test("CompositeAltTitleSource runs sources in parallel and merges in deterministic index order")
    func compositeSource() async {
        let composite = CompositeAltTitleSource([
            FakeAltSource(titles: ["葬送的芙莉莲", "Frieren"]),
            FakeAltSource(titles: ["  frieren  ", "葬送のフリーレン", ""]),
        ])
        let res = await composite.altTitles("Sousou no Frieren")
        #expect(res == ["葬送的芙莉莲", "Frieren", "葬送のフリーレン"])
        await composite.close()

        // Prove concurrency: source 0 waits until source 1 finishes first, yet source 0 wins ordering & dedupe
        actor ParallelHandshake {
            private var secondFinished = false
            private var firstWaiter: CheckedContinuation<Void, Never>?

            func waitForSecond() async {
                if secondFinished { return }
                await withCheckedContinuation { cont in
                    firstWaiter = cont
                }
            }

            func markSecondFinished() {
                secondFinished = true
                firstWaiter?.resume()
                firstWaiter = nil
            }
        }

        struct WaitingSource: AltTitleSource {
            let handshake: ParallelHandshake
            let isFirst: Bool
            let titles: [String]

            func altTitles(_ query: String) async -> [String] {
                if isFirst {
                    await handshake.waitForSecond()
                } else {
                    await handshake.markSecondFinished()
                }
                return titles
            }
        }

        let handshake = ParallelHandshake()
        let parallelComposite = CompositeAltTitleSource([
            WaitingSource(handshake: handshake, isFirst: true, titles: ["First Only", "SharedTitle"]),
            WaitingSource(handshake: handshake, isFirst: false, titles: ["sharedtitle", "Second Only"]),
        ])
        let ordered = await parallelComposite.altTitles("Test")
        #expect(ordered == ["First Only", "SharedTitle", "Second Only"])
    }

    @Test("BangumiTitles persistent cache uses bgm: prefix, honors positive/negative TTL, and supports clearCache")
    func persistentCacheTTLAndClearCache() async {
        let cache = MapTmdbCache()
        let transport1 = MockHTTPTransport { req in
            if req.url?.path.contains("Frieren") == true {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "results": 1,
                    "list": [["name": "葬送のフリーレン", "name_cn": "葬送的芙莉莲"]],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, status: 404, jsonObject: ["title": "Not Found"])
        }

        let bgm1 = BangumiTitles(transport: transport1, cache: cache, minIntervalMs: 0)
        #expect(await bgm1.altTitles("Frieren") == ["葬送的芙莉莲", "葬送のフリーレン"])
        #expect(await bgm1.altTitles("NoSuchShow").isEmpty)
        #expect(await transport1.requests().count == 2)

        let keys = Set(await cache.keys())
        #expect(keys.contains("bgm:frieren"))
        #expect(keys.contains("bgm:nosuchshow"))

        // Second instance sharing L2 cache serves both positive and negative hits with zero HTTP traffic
        let transport2 = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: ["results": 0, "list": []])
        }
        let bgm2 = BangumiTitles(transport: transport2, cache: cache, minIntervalMs: 0)
        #expect(await bgm2.altTitles("  FRIEREN ") == ["葬送的芙莉莲", "葬送のフリーレン"])
        #expect(await bgm2.altTitles("nosuchshow").isEmpty)
        #expect(await transport2.requests().isEmpty)

        // Expired positive (> 14d) and expired negative (> 24h) entries re-fetch from network
        let expiredCache = MapTmdbCache()
        let oldPosTs = Int64(Date().timeIntervalSince1970 - AltTitleCacheCodec.positiveTTL - 120)
        let oldNegTs = Int64(Date().timeIntervalSince1970 - AltTitleCacheCodec.negativeTTL - 120)
        await expiredCache.put("bgm:frieren", json: #"{"titles":["Stale"],"ts":\#(oldPosTs)}"#)
        await expiredCache.put("bgm:gintama", json: #"{"titles":[],"ts":\#(oldNegTs)}"#)

        let transport3 = MockHTTPTransport { req in
            if req.url?.path.contains("frieren") == true || req.url?.path.contains("Frieren") == true {
                return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                    "results": 1,
                    "list": [["name": "葬送のフリーレン", "name_cn": "葬送的芙莉莲"]],
                ])
            }
            return MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "results": 1,
                "list": [["name": "銀魂", "name_cn": "银魂"]],
            ])
        }
        let bgm3 = BangumiTitles(transport: transport3, cache: expiredCache, minIntervalMs: 0)
        #expect(await bgm3.altTitles("Frieren") == ["葬送的芙莉莲", "葬送のフリーレン"])
        #expect(await bgm3.altTitles("Gintama") == ["银魂", "銀魂"])
        #expect(await transport3.requests().count == 2)

        // clearCache on BangumiTitles and CompositeAltTitleSource clears L1
        let transport4 = MockHTTPTransport { req in
            MockHTTPTransport.makeJSONResponse(for: req, jsonObject: [
                "results": 1,
                "list": [["name": "銀魂", "name_cn": "银魂"]],
            ])
        }
        let bgm4 = BangumiTitles(transport: transport4, minIntervalMs: 0)
        let composite = CompositeAltTitleSource([bgm4])
        _ = await composite.altTitles("Gintama")
        _ = await composite.altTitles("Gintama")
        #expect(await transport4.requests().count == 1)
        await composite.clearCache()
        _ = await composite.altTitles("Gintama")
        #expect(await transport4.requests().count == 2)
    }

    @Test("parseBangumi rejects unrelated fuzzy hits and unescapes HTML without double-unescaping")
    func parseBangumiHardening() {
        let fuzzyList: [[String: Any]] = [
            ["name": "進撃の巨人", "name_cn": "进击的巨人"],
            ["name": "BLEACH", "name_cn": "死神"],
        ]
        #expect(parseBangumi(fuzzyList, query: "不存在的动画").isEmpty)
        #expect(parseBangumi(fuzzyList, query: "Naruto") == ["进击的巨人", "進撃の巨人"])
        #expect(parseBangumi([["name": "BLEACH", "name_cn": "死神"]], query: "Naruto").isEmpty)
        #expect(parseBangumi([["name": "Steins;Gate", "name_cn": "命运石之门"]], query: "Steins Gate") == ["命运石之门", "Steins;Gate"])
        #expect(parseBangumi([["name": "A &amp;lt; B &#39;C&#39;", "name_cn": ""]]) == ["A &lt; B 'C'"])
    }
}
