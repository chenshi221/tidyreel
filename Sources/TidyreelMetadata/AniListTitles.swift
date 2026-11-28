import Foundation
import TidyreelModels

private let anilistWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
private let subtitleSepRegex = try! NSRegularExpression(pattern: #"\s*[~～:：]\s*|\s+-\s+"#)

/// AniList's public GraphQL API alt-title lookup for romaji/English/native anime names.
public final class AniListTitles: AltTitleSource, Sendable {
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
        private let sleeper: @Sendable (TimeInterval) async throws -> Void

        private static let maxCacheEntries = 1000
        private static let cacheKeyPrefix = "anilist:"
        private static let requestTimeout: TimeInterval = 12
        private static let graphqlQuery = """

query ($s: String) {
  Page(perPage: 2) {
    media(search: $s, type: ANIME) {
      title { native english romaji }
      synonyms
    }
  }
}
"""

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
            sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
        ) {
            self.transport = transport
            self.cacheStore = cache
            self.minInterval = max(0, Double(minIntervalMs) / 1000.0)
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
            let normalized = collapseAniListWhitespace(query.trimmingCharacters(in: .whitespacesAndNewlines))
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

        private func postQuery(_ search: String) async throws -> (Data, HTTPURLResponse) {
            let url = URL(string: "https://graphql.anilist.co")!
            let payload: [String: Any] = [
                "query": Self.graphqlQuery,
                "variables": ["s": search],
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: payload)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = bodyData

            var attempt = 0
            while true {
                try await waitSlot()
                let (data, response) = try await transport.send(request)
                if response.statusCode == 429 {
                    let ra = response.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    let delay = TimeInterval(min(15, max(1, ra ?? 2)))
                    let until = currentTime().addingTimeInterval(delay)
                    if until > blockedUntil { blockedUntil = until }
                    if until > nextSlot { nextSlot = until }
                    if attempt == 0 {
                        try await sleep(delay)
                        attempt += 1
                        continue
                    }
                }
                return (data, response)
            }
        }

        private func fetch(_ query: String) async -> (titles: [String], shouldCache: Bool) {
            let words = query.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return ([], true) }
            do {
                var n = words.count
                while n >= 1 && n > words.count - 4 {
                    let search = words.prefix(n).joined(separator: " ")
                    let (data, response) = try await postQuery(search)
                    if response.statusCode != 200 {
                        return ([], false)
                    }
                    guard let body = JSONValue.parseObject(from: data) else {
                        return ([], false)
                    }
                    if let errors = body["errors"]?.arrayValue, !errors.isEmpty {
                        return ([], false)
                    }
                    guard let dataObj = body["data"]?.objectValue,
                          let pageObj = dataObj["Page"]?.objectValue,
                          let media = pageObj["media"]?.arrayValue else {
                        return ([], false)
                    }
                    let hits = media.filter { plausibleAniList(query, $0) }
                    if !hits.isEmpty {
                        return (parseAniList(hits), true)
                    }
                    n -= 1
                }
                return ([], true)
            } catch {
                return ([], false)
            }
        }
    }

    private let engine: Engine

    public init(
        transport: (any HTTPTransport)? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 120,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) {
        self.engine = Engine(
            transport: transport ?? URLSessionHTTPTransport(),
            cache: cache,
            minIntervalMs: minIntervalMs,
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

// MARK: - AniList Parsing & Plausibility

/// Whether one of `item`'s Latin titles/synonyms and `query` share their start (ignoring spaces
/// and punctuation) or are near-identical (`titleSimilarity > 0.8`).
public func plausibleAniList(_ query: String, _ item: JSONValue) -> Bool {
    let q = normTitle(query)
    guard !q.isEmpty, let map = item.objectValue else { return false }
    let t = map["title"]?.objectValue ?? [:]
    let synonyms = map["synonyms"]?.arrayValue ?? []

    var candidates: [String] = []
    if let romaji = t["romaji"]?.stringValue { candidates.append(romaji) }
    if let english = t["english"]?.stringValue { candidates.append(english) }
    for syn in synonyms {
        if let s = syn.stringValue { candidates.append(s) }
    }

    let qCount = q.count
    for raw in candidates {
        let n = normTitle(raw)
        if n.isEmpty { continue }
        let nCount = n.count
        if n == q ||
            (qCount >= 4 && n.hasPrefix(q)) ||
            (nCount >= 6 && q.hasPrefix(n)) ||
            titleSimilarity(n, q) > 0.8 {
            return true
        }
    }
    return false
}

public func plausibleAniList(_ query: String, _ item: Any) -> Bool {
    plausibleAniList(query, JSONValue(any: item))
}

/// Titles from AniList `media` entries, deduplicated in usefulness order; meaningful
/// subtitle-stripped prefixes (`"Title ~Sub~"` -> `"Title"`) are appended after full titles.
public func parseAniList(_ media: [JSONValue]) -> [String] {
    var out: [String] = []
    var outSet: Set<String> = []
    var prefixes: [String] = []
    var prefixSet: Set<String> = []

    for item in media {
        guard let map = item.objectValue else { continue }
        let t = map["title"]?.objectValue ?? [:]
        let synonyms = map["synonyms"]?.arrayValue ?? []
        var values: [JSONValue?] = [t["native"], t["english"], t["romaji"]]
        values.append(contentsOf: synonyms.map { Optional($0) })

        for val in values {
            if let str = val?.stringValue {
                let full = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !full.isEmpty && outSet.insert(full).inserted {
                    out.append(full)
                }
                let range = NSRange(full.startIndex..<full.endIndex, in: full)
                if let match = subtitleSepRegex.firstMatch(in: full, range: range),
                   let swiftRange = Range(match.range, in: full) {
                    let prefix = String(full[..<swiftRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prefix.isEmpty && prefix != full && isMeaningfulSubtitlePrefix(prefix) {
                        if !outSet.contains(prefix) && prefixSet.insert(prefix).inserted {
                            prefixes.append(prefix)
                        }
                    }
                }
            }
        }
    }

    for p in prefixes where outSet.insert(p).inserted {
        out.append(p)
    }
    return out
}

public func parseAniList(_ media: [Any]) -> [String] {
    parseAniList(media.map(JSONValue.init(any:)))
}

private func isMeaningfulSubtitlePrefix(_ prefix: String) -> Bool {
    let norm = normTitle(prefix)
    if norm.isEmpty { return false }
    return hasCjk(norm) ? norm.unicodeScalars.count >= 2 : norm.count >= 4
}

private func collapseAniListWhitespace(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return anilistWhitespaceRegex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
}
