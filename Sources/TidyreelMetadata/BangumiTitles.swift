import Foundation
import TidyreelModels

private let bangumiWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
private let bangumiLatinWordRegex = try! NSRegularExpression(pattern: #"[A-Za-z]{4,}"#)

enum AltTitleCacheCodec {
    static let positiveTTL: TimeInterval = 14 * 24 * 60 * 60
    static let negativeTTL: TimeInterval = 24 * 60 * 60

    static func ttl(for titles: [String]) -> TimeInterval {
        titles.isEmpty ? negativeTTL : positiveTTL
    }

    static func encode(titles: [String], at now: Date) -> String? {
        let payload: [String: Any] = [
            "titles": titles,
            "ts": Int64(now.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String, now: Date) -> (titles: [String], expiresAt: Date)? {
        guard let obj = JSONValue.parseObject(from: json),
              let rawTitles = obj["titles"]?.arrayValue,
              let ts = obj["ts"]?.doubleValue else {
            return nil
        }
        let titles = rawTitles.compactMap(\.stringValue)
        let expiresAt = Date(timeIntervalSince1970: ts + ttl(for: titles))
        guard now < expiresAt else {
            return nil
        }
        return (titles, expiresAt)
    }
}

/// Bangumi (`bgm.tv`) public API alt-title lookup for anime Chinese/Japanese canonical names and synonyms.
public final class BangumiTitles: AltTitleSource, Sendable {
    private actor Engine {
        private struct CachedTitles: Sendable {
            let titles: [String]
            let expiresAt: Date
        }

        private struct InFlightEntry: Sendable {
            let token: UInt64
            let task: Task<[String], Never>
        }

        private let transport: any HTTPTransport
        private let cacheStore: (any TmdbResponseCache)?
        private let minInterval: TimeInterval
        private let userAgent: String
        private let sleeper: @Sendable (TimeInterval) async throws -> Void

        private static let maxCacheEntries = 1000
        private static let cacheKeyPrefix = "bgm:"
        private static let requestTimeout: TimeInterval = 12

        private var memoryCache = LRUCache<String, CachedTitles>(capacity: maxCacheEntries)
        private var inFlight: [String: InFlightEntry] = [:]
        private var tokenCounter: UInt64 = 0
        private var nextSlot: Date = .distantPast
        private var blockedUntil: Date = .distantPast
        private var simulatedTime: Date = .distantPast

        init(
            transport: any HTTPTransport,
            cache: (any TmdbResponseCache)?,
            minIntervalMs: Int,
            userAgent: String,
            sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
        ) {
            self.transport = transport
            self.cacheStore = cache
            self.minInterval = max(0, Double(minIntervalMs) / 1000.0)
            self.userAgent = userAgent
            self.sleeper = sleeper
        }

        func clearCache() {
            memoryCache.removeAll()
        }

        func close() {
            let active = Array(inFlight.values)
            inFlight.removeAll()
            memoryCache.removeAll()
            for entry in active {
                entry.task.cancel()
            }
        }

        func altTitles(_ query: String) async -> [String] {
            let normalized = collapseBangumiWhitespace(query.trimmingCharacters(in: .whitespacesAndNewlines))
            if normalized.isEmpty { return [] }
            let key = normalized.lowercased()
            if let hit = memoryCache.get(key) {
                if currentTime() < hit.expiresAt {
                    return hit.titles
                }
                memoryCache.remove(key)
            }

            if let existing = inFlight[key] {
                return await existing.task.value
            }

            tokenCounter &+= 1
            let token = tokenCounter
            let persistentKey = Self.cacheKeyPrefix + key
            let task = Task<[String], Never> {
                defer {
                    self.removeInFlight(key: key, token: token)
                }
                if let store = self.cacheStore,
                   let storedRaw = await store.get(persistentKey),
                   let decoded = AltTitleCacheCodec.decode(storedRaw, now: self.currentTime()) {
                    self.memoryCache.put(key, CachedTitles(titles: decoded.titles, expiresAt: decoded.expiresAt))
                    return decoded.titles
                }
                let (titles, shouldCache) = await self.fetch(normalized)
                if shouldCache {
                    let now = self.currentTime()
                    let expiresAt = now.addingTimeInterval(AltTitleCacheCodec.ttl(for: titles))
                    self.memoryCache.put(key, CachedTitles(titles: titles, expiresAt: expiresAt))
                    if let store = self.cacheStore,
                       let encoded = AltTitleCacheCodec.encode(titles: titles, at: now) {
                        await store.put(persistentKey, json: encoded)
                    }
                }
                return titles
            }
            inFlight[key] = InFlightEntry(token: token, task: task)
            return await task.value
        }

        private func removeInFlight(key: String, token: UInt64) {
            if inFlight[key]?.token == token {
                inFlight.removeValue(forKey: key)
            }
        }

        private func currentTime() -> Date {
            let real = Date()
            return real > simulatedTime ? real : simulatedTime
        }

        private func sleep(_ seconds: TimeInterval) async throws {
            let target = currentTime().addingTimeInterval(max(0, seconds))
            try await sleeper(seconds)
            if target > simulatedTime {
                simulatedTime = target
            }
        }

        private func waitSlot() async throws {
            while true {
                try Task.checkCancellation()
                let now = currentTime()
                if blockedUntil > now {
                    try await sleep(blockedUntil.timeIntervalSince(now))
                    continue
                }
                if minInterval <= 0 {
                    return
                }
                let slot = nextSlot > now ? nextSlot : now
                nextSlot = slot.addingTimeInterval(minInterval)
                let wait = slot.timeIntervalSince(now)
                if wait > 0 {
                    try await sleep(wait)
                    if blockedUntil > currentTime() {
                        continue
                    }
                }
                return
            }
        }

        private func fetch(_ query: String) async -> (titles: [String], shouldCache: Bool) {
            do {
                try await waitSlot()
                let encoded = MetadataURLHelpers.encodeURIComponent(query)
                guard let url = MetadataURLHelpers.buildURL(
                    baseUrl: "https://api.bgm.tv",
                    percentEncodedPath: "/search/subject/\(encoded)",
                    query: [
                        "type": "2",
                        "responseGroup": "small",
                        "max_results": "5",
                    ]
                ) else {
                    return ([], false)
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = Self.requestTimeout
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await transport.send(request)
                let code = response.statusCode
                if code == 404 {
                    // Bangumi returns 404 when a query has no matching subjects: keep in negative cache.
                    return ([], true)
                }
                if code == 429 {
                    let ra = response.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    let delay = TimeInterval(min(30, max(1, ra ?? 2)))
                    let until = currentTime().addingTimeInterval(delay)
                    if until > blockedUntil { blockedUntil = until }
                    if until > nextSlot { nextSlot = until }
                    return ([], false)
                }
                if code != 200 {
                    return ([], false)
                }
                guard let body = JSONValue.parseObject(from: data),
                      let list = body["list"]?.arrayValue else {
                    return ([], false)
                }
                return (parseBangumi(list, query: query), true)
            } catch {
                return ([], false)
            }
        }
    }

    public let userAgent: String
    private let engine: Engine

    public init(
        transport: (any HTTPTransport)? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 400,
        userAgent: String = "Tidyreel/1.0 (https://github.com/tidyreel)",
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) {
        self.userAgent = userAgent
        self.engine = Engine(
            transport: transport ?? URLSessionHTTPTransport(),
            cache: cache,
            minIntervalMs: minIntervalMs,
            userAgent: userAgent,
            sleeper: sleeper
        )
    }

    public func altTitles(_ query: String) async -> [String] {
        await engine.altTitles(query)
    }

    public func clearCache() async {
        await engine.clearCache()
    }

    public func close() async {
        await engine.close()
    }
}

// MARK: - Bangumi Parsing & Plausibility

/// Whether a Bangumi subject entry is plausible for `query`, rejecting unrelated fuzzy hits
/// while still allowing cross-script romaji/English -> CJK subjects.
public func plausibleBangumi(_ query: String, _ item: JSONValue) -> Bool {
    guard let map = item.objectValue else { return false }
    let q = normTitle(query)
    if q.isEmpty { return true }

    var rawTitles: [String] = []
    if let cn = map["name_cn"]?.stringValue { rawTitles.append(unescapeBangumiHtml(cn)) }
    if let name = map["name"]?.stringValue { rawTitles.append(unescapeBangumiHtml(name)) }

    let normTitles = rawTitles.map(normTitle).filter { !$0.isEmpty }
    if normTitles.isEmpty { return false }

    let qHasCjk = hasCjk(q)
    let qCount = q.count

    func matches(_ n: String) -> Bool {
        if n == q { return true }
        let nCount = n.count
        if qHasCjk {
            if qCount >= 2 && n.contains(q) { return true }
            if nCount >= 3 && q.contains(n) { return true }
        } else {
            if qCount >= 4 && (n.hasPrefix(q) || n.contains(q)) { return true }
            if nCount >= 6 && q.hasPrefix(n) { return true }
        }
        return titleSimilarity(n, q) > 0.6
    }

    if normTitles.contains(where: matches) {
        return true
    }

    // Cross-script fallback: non-CJK query against purely CJK subject titles
    // (no contradicting Latin title present in `name` / `name_cn`).
    let hasContradictingLatin = rawTitles.contains { raw in
        let r = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return bangumiLatinWordRegex.firstMatch(in: raw, range: r) != nil
    }
    if !qHasCjk && normTitles.allSatisfy({ hasCjk($0) }) && !hasContradictingLatin {
        return true
    }

    return false
}

public func plausibleBangumi(_ query: String, _ item: Any) -> Bool {
    plausibleBangumi(query, JSONValue(any: item))
}

/// Extracts deduplicated useful alt titles from a Bangumi search `list`, prioritizing `name_cn`
/// before `name` for each entry and excluding an identical copy of `query` or implausible fuzzy hits.
public func parseBangumi(_ list: [JSONValue], query: String = "") -> [String] {
    let queryKey = collapseBangumiWhitespace(query.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    var out: [String] = []
    var seen: Set<String> = []

    func add(_ raw: JSONValue?) {
        guard let str = raw?.stringValue else { return }
        let t = unescapeBangumiHtml(str).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        let key = collapseBangumiWhitespace(t).lowercased()
        if key.isEmpty || key == queryKey { return }
        if seen.insert(key).inserted {
            out.append(t)
        }
    }

    for item in list {
        guard let map = item.objectValue else { continue }
        if !queryKey.isEmpty && !plausibleBangumi(query, item) { continue }
        add(map["name_cn"])
        add(map["name"])
    }
    return out
}

public func parseBangumi(_ list: [Any], query: String = "") -> [String] {
    parseBangumi(list.map(JSONValue.init(any:)), query: query)
}

private func collapseBangumiWhitespace(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return bangumiWhitespaceRegex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
}

private func unescapeBangumiHtml(_ s: String) -> String {
    guard s.contains("&") else { return s }
    return s
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#039;", with: "'")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
}

// MARK: - CompositeAltTitleSource

/// Chains multiple `AltTitleSource` providers concurrently, merging and deduplicating results
/// in deterministic source priority order.
public struct CompositeAltTitleSource: AltTitleSource, Sendable {
    public let sources: [any AltTitleSource]

    public init(_ sources: [any AltTitleSource]) {
        self.sources = sources
    }

    public func altTitles(_ query: String) async -> [String] {
        guard !sources.isEmpty else { return [] }
        if sources.count == 1 {
            return Self.mergeAndDedupe([await sources[0].altTitles(query)])
        }
        let orderedLists: [[String]] = await withTaskGroup(of: (Int, [String]).self) { group in
            for (idx, src) in sources.enumerated() {
                group.addTask {
                    let titles = await src.altTitles(query)
                    return (idx, titles)
                }
            }
            var buckets = Array(repeating: [String](), count: sources.count)
            for await (idx, titles) in group {
                buckets[idx] = titles
            }
            return buckets
        }
        return Self.mergeAndDedupe(orderedLists)
    }

    private static func mergeAndDedupe(_ buckets: [[String]]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for titles in buckets {
            for raw in titles {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = trimmed.lowercased()
                if !key.isEmpty && seen.insert(key).inserted {
                    out.append(trimmed)
                }
            }
        }
        return out
    }

    public func clearCache() async {
        for src in sources {
            if let bgm = src as? BangumiTitles {
                await bgm.clearCache()
            } else if let ani = src as? AniListTitles {
                await ani.clearCache()
            } else if let comp = src as? CompositeAltTitleSource {
                await comp.clearCache()
            }
        }
    }

    public func close() async {
        for src in sources {
            if let bgm = src as? BangumiTitles {
                await bgm.close()
            } else if let ani = src as? AniListTitles {
                await ani.close()
            } else if let comp = src as? CompositeAltTitleSource {
                await comp.close()
            }
        }
    }
}
