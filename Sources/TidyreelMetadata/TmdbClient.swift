import CryptoKit
import Foundation
import TidyreelModels

/// Cached, rate-limited, retrying JSON GET client against the TMDB v3 API.
public actor TmdbClient {
    private struct InFlightEntry: Sendable {
        let token: UInt64
        let task: Task<[String: JSONValue], Error>
    }

    private enum MemoryCacheValue: Sendable {
        case positive(Data)
        case negative404(expiresAt: Date, message: String)

        var estimatedBytes: Int {
            switch self {
            case .positive(let data):
                return data.count
            case .negative404(_, let message):
                return message.utf8.count + 64
            }
        }
    }

    private let transport: any HTTPTransport
    private let cacheNamespace: String
    private let baseUrl: String
    private let apiKey: String
    private let isBearer: Bool
    private let cacheStore: (any TmdbResponseCache)?
    private let minInterval: TimeInterval
    private let networkRetryBaseDelay: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let maxMemoryBytes: Int

    private static let maxRetries = 3
    private static let backedCacheEntries = 128
    private static let memoryOnlyCacheEntries = 256
    private static let backedMaxMemoryBytes = 8 * 1024 * 1024
    private static let memoryOnlyMaxMemoryBytes = 16 * 1024 * 1024
    private static let requestTimeout: TimeInterval = 20
    static let negative404TTL: TimeInterval = 6 * 60 * 60
    static let negative404SentinelKey = "__tidyreel_negative_404"
    private static let apiKeyParamRegex = try! NSRegularExpression(
        pattern: #"([?&]api_key=)[^&\s)\]]+"#,
        options: [.caseInsensitive]
    )

    private var memoryCache: LRUCache<String, MemoryCacheValue>
    private var memoryCacheBytes: Int = 0
    private var inFlight: [String: InFlightEntry] = [:]
    private var tokenCounter: UInt64 = 0
    private var nextSlot: Date = .distantPast
    private var blockedUntil: Date = .distantPast
    private var simulatedTime: Date = .distantPast

    public init(
        apiKey: String,
        baseUrl: String = "https://api.themoviedb.org/3",
        transport: (any HTTPTransport)? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 50,
        networkRetryBaseDelay: TimeInterval = 1.0,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) {
        var trimmedBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedBase.hasSuffix("/") {
            trimmedBase.removeLast()
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Older keys carry no provider provenance and must never be used as a fallback.
        let scope = "\(trimmedBase.utf8.count):\(trimmedBase)\(trimmedKey)"
        self.cacheNamespace = "tmdb:v2:" + Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()
        self.baseUrl = trimmedBase
        self.apiKey = trimmedKey
        self.isBearer = trimmedKey.hasPrefix("eyJ") || trimmedKey.count > 40
        self.transport = transport ?? URLSessionHTTPTransport()
        self.cacheStore = cache
        self.minInterval = max(0, Double(minIntervalMs) / 1000.0)
        self.networkRetryBaseDelay = max(0, networkRetryBaseDelay)
        self.sleeper = sleeper
        let entryLimit = cache != nil ? Self.backedCacheEntries : Self.memoryOnlyCacheEntries
        self.maxMemoryBytes = cache != nil ? Self.backedMaxMemoryBytes : Self.memoryOnlyMaxMemoryBytes
        self.memoryCache = LRUCache<String, MemoryCacheValue>(capacity: entryLimit)
    }

    public func clearMemoryCache() {
        memoryCache.removeAll()
        memoryCacheBytes = 0
    }

    var memoryCacheEntryCount: Int {
        memoryCache.count
    }

    var memoryCacheByteCount: Int {
        memoryCacheBytes
    }

    public func close() async {
        let active = Array(inFlight.values)
        inFlight.removeAll()
        clearMemoryCache()
        for entry in active {
            entry.task.cancel()
        }
    }

    /// GET `path` with `query`; identical calls are served from memory, then `cacheStore`.
    /// `path` should have any dynamic path segments already percent-encoded.
    public func get(_ path: String, query: [String: String] = [:]) async throws -> [String: JSONValue] {
        let key = makeCacheKey(path: path, query: query)
        if let hit = memoryCache.get(key) {
            switch hit {
            case .positive(let data):
                if let parsed = await Self.parseObjectOffActor(from: data) {
                    return parsed
                }
                removeMemoryCacheEntry(key)
            case .negative404(let expiresAt, let message):
                if currentTime() < expiresAt {
                    throw TmdbError(statusCode: 404, message: message)
                }
                removeMemoryCacheEntry(key)
            }
        }

        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        tokenCounter &+= 1
        let token = tokenCounter
        let task = Task<[String: JSONValue], Error> {
            defer {
                self.removeInFlight(key: key, token: token)
            }
            return try await self.resolveMiss(key: key, path: path, query: query)
        }
        inFlight[key] = InFlightEntry(token: token, task: task)
        return try await task.value
    }

    private func resolveMiss(
        key: String,
        path: String,
        query: [String: String]
    ) async throws -> [String: JSONValue] {
        if let store = cacheStore, let storedRaw = await store.get(key) {
            if let parsed = await Self.parseObjectOffActor(from: storedRaw) {
                if let neg = Self.parseNegative404Sentinel(parsed, now: currentTime()) {
                    if !neg.expired {
                        putMemoryCache(key, .negative404(expiresAt: neg.expiresAt, message: neg.message))
                        throw TmdbError(statusCode: 404, message: neg.message)
                    }
                } else {
                    putMemoryCache(key, .positive(Data(storedRaw.utf8)))
                    return parsed
                }
            }
        }

        do {
            let (parsed, rawData) = try await fetch(path: path, query: query)
            putMemoryCache(key, .positive(rawData))
            if let store = cacheStore, let rawJson = String(data: rawData, encoding: .utf8) {
                await store.put(key, json: rawJson)
            }
            return parsed
        } catch let err as TmdbError where err.statusCode == 404 {
            let now = currentTime()
            let expiresAt = now.addingTimeInterval(Self.negative404TTL)
            putMemoryCache(key, .negative404(expiresAt: expiresAt, message: err.message))
            if let store = cacheStore {
                let epochSec = Int64(now.timeIntervalSince1970)
                let sentinel = #"{"\#(Self.negative404SentinelKey)":true,"ts":\#(epochSec)}"#
                await store.put(key, json: sentinel)
            }
            throw err
        }
    }

    private func removeInFlight(key: String, token: UInt64) {
        if inFlight[key]?.token == token {
            inFlight.removeValue(forKey: key)
        }
    }

    private func putMemoryCache(_ key: String, _ value: MemoryCacheValue) {
        let entryBytes = value.estimatedBytes
        if let replaced = memoryCache.removeValue(forKey: key) {
            memoryCacheBytes = max(0, memoryCacheBytes - replaced.estimatedBytes)
        }
        guard entryBytes <= maxMemoryBytes else {
            return
        }
        while memoryCache.count >= memoryCache.capacity || (memoryCacheBytes + entryBytes > maxMemoryBytes) {
            guard let evicted = memoryCache.removeOldest() else {
                break
            }
            memoryCacheBytes = max(0, memoryCacheBytes - evicted.value.estimatedBytes)
        }
        memoryCache.put(key, value)
        memoryCacheBytes += entryBytes
    }

    private func removeMemoryCacheEntry(_ key: String) {
        if let removed = memoryCache.removeValue(forKey: key) {
            memoryCacheBytes = max(0, memoryCacheBytes - removed.estimatedBytes)
        }
    }

    private static func parseObjectOffActor(from data: Data) async -> [String: JSONValue]? {
        JSONValue.parseObject(from: data)
    }

    private static func parseObjectOffActor(from string: String) async -> [String: JSONValue]? {
        JSONValue.parseObject(from: string)
    }

    private static func parseNegative404Sentinel(
        _ parsed: [String: JSONValue],
        now: Date
    ) -> (expired: Bool, expiresAt: Date, message: String)? {
        guard parsed[negative404SentinelKey] == .bool(true) else {
            return nil
        }
        let ts = parsed["ts"]?.doubleValue ?? 0
        let expiresAt = Date(timeIntervalSince1970: ts + negative404TTL)
        return (
            expired: now >= expiresAt,
            expiresAt: expiresAt,
            message: "TMDB 请求失败（HTTP 404）"
        )
    }

    nonisolated func makeCacheKey(path: String, query: [String: String]) -> String {
        let sorted = query
            .sorted { $0.key < $1.key }
            .map { pair -> String in
                let k = MetadataURLHelpers.encodeRFC3986Component(pair.key)
                let v = MetadataURLHelpers.encodeRFC3986Component(pair.value)
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return "\(cacheNamespace):\(path)?\(sorted)"
    }

    private func currentTime() -> Date {
        let real = Date()
        return real > simulatedTime ? real : simulatedTime
    }

    private func waitSlot() async throws {
        while true {
            if Task.isCancelled {
                throw TmdbError(statusCode: nil, message: "TMDB 请求已取消")
            }
            let now = currentTime()
            if blockedUntil > now {
                let delay = blockedUntil.timeIntervalSince(now)
                try await sleepOrCancel(delay)
                continue
            }
            if minInterval <= 0 {
                return
            }
            let slot = nextSlot > now ? nextSlot : now
            nextSlot = slot.addingTimeInterval(minInterval)
            let wait = slot.timeIntervalSince(now)
            if wait > 0 {
                try await sleepOrCancel(wait)
                if blockedUntil > currentTime() {
                    continue
                }
            }
            return
        }
    }

    private func sleepOrCancel(_ seconds: TimeInterval) async throws {
        let target = currentTime().addingTimeInterval(max(0, seconds))
        do {
            try await sleeper(seconds)
        } catch is CancellationError {
            throw TmdbError(statusCode: nil, message: "TMDB 请求已取消")
        }
        if target > simulatedTime {
            simulatedTime = target
        }
    }

    /// Parses an HTTP `Retry-After` header (integer seconds or HTTP-date), clamped to `1...30` seconds,
    /// falling back to exponential backoff `1 << attempt` clamped to `1...30`.
    public static func parseRetryAfter(_ raw: String?, attempt: Int) -> TimeInterval {
        if let raw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let secs = Int(trimmed) {
                    return TimeInterval(min(30, max(1, secs)))
                }
                if let until = parseHTTPDate(trimmed) {
                    let diff = Int(until.timeIntervalSinceNow.rounded(.towardZero))
                    return TimeInterval(min(30, max(1, diff)))
                }
            }
        }
        let exp = 1 << min(attempt, 10)
        return TimeInterval(min(30, max(1, exp)))
    }

    private static func parseHTTPDate(_ string: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "EEE MMM dd HH:mm:ss yyyy",
        ]
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: string) {
                return d
            }
        }
        return nil
    }

    private func redactSecrets(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out = Self.apiKeyParamRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1[REDACTED]"
        )
        if !apiKey.isEmpty {
            out = out.replacingOccurrences(of: apiKey, with: "[REDACTED]")
            let encoded = MetadataURLHelpers.encodeRFC3986Component(apiKey)
            if encoded != apiKey {
                out = out.replacingOccurrences(of: encoded, with: "[REDACTED]")
            }
        }
        return out
    }

    private static func isCertificateError(_ urlError: URLError) -> Bool {
        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func mapNetworkError(_ error: Error) -> TmdbError {
        if let tmdbErr = error as? TmdbError {
            return tmdbErr
        }
        if error is CancellationError {
            return TmdbError(statusCode: nil, message: "TMDB 请求已取消")
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return TmdbError(statusCode: nil, message: "TMDB 请求已取消")
            }
            if urlError.code == .timedOut {
                return TmdbError(
                    statusCode: nil,
                    message: "连接 TMDB 超时，如无法直连请在设置中配置 TMDB 代理地址（Base URL）"
                )
            }
            if Self.isCertificateError(urlError) {
                return TmdbError(
                    statusCode: nil,
                    message: "TMDB HTTPS 证书校验失败，请检查代理或网络环境"
                )
            }
        }
        let rawDesc = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let detail = redactSecrets(rawDesc)
        return TmdbError(
            statusCode: nil,
            message: "无法连接 TMDB（\(detail)），如无法直连请在设置中配置 TMDB 代理地址（Base URL）"
        )
    }

    private func fetch(
        path: String,
        query: [String: String]
    ) async throws -> ([String: JSONValue], Data) {
        var reqQuery = query
        if !isBearer {
            reqQuery["api_key"] = apiKey
        }
        guard let url = MetadataURLHelpers.buildURL(
            baseUrl: baseUrl,
            percentEncodedPath: path,
            query: reqQuery
        ) else {
            throw TmdbError(statusCode: nil, message: "无效的 TMDB 地址：\(baseUrl)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var attempt = 0
        while true {
            try await waitSlot()

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                let isCancel = (error is CancellationError) || ((error as? URLError)?.code == .cancelled)
                let isBadCert = (error as? URLError).map(Self.isCertificateError) ?? false
                if !isCancel && !isBadCert && attempt < Self.maxRetries {
                    let delay = networkRetryBaseDelay * Double(1 << attempt)
                    try await sleepOrCancel(delay)
                    attempt += 1
                    continue
                }
                throw mapNetworkError(error)
            }

            let code = response.statusCode
            let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After")
            let retryable = (code == 429 || code >= 500)

            if code == 429 {
                let delay = Self.parseRetryAfter(retryAfterHeader, attempt: attempt)
                let until = currentTime().addingTimeInterval(delay)
                if until > blockedUntil { blockedUntil = until }
                if until > nextSlot { nextSlot = until }
                if attempt < Self.maxRetries {
                    try await sleepOrCancel(delay)
                    attempt += 1
                    continue
                }
            } else if retryable && attempt < Self.maxRetries {
                let delay = Self.parseRetryAfter(retryAfterHeader, attempt: attempt)
                try await sleepOrCancel(delay)
                attempt += 1
                continue
            }

            if (200..<300).contains(code) {
                if let obj = await Self.parseObjectOffActor(from: data) {
                    return (obj, data)
                }
                throw TmdbError(
                    statusCode: code,
                    message: "TMDB 返回了非 JSON 响应（HTTP \(code)），请检查 TMDB 代理地址（Base URL）是否正确"
                )
            }

            if code == 401 {
                throw TmdbError(
                    statusCode: code,
                    message: "TMDB API Key 无效或已过期，请在设置中检查"
                )
            }
            if code == 429 {
                throw TmdbError(
                    statusCode: code,
                    message: "TMDB 请求过于频繁（HTTP 429），请稍后重试"
                )
            }

            let parsedBody = await Self.parseObjectOffActor(from: data)
            let rawMsg = parsedBody?["status_message"]?.lossyString
            let safeMsg = rawMsg.map(redactSecrets)
            let message = if let safeMsg, !safeMsg.isEmpty {
                "TMDB 请求失败（HTTP \(code)）：\(safeMsg)"
            } else {
                "TMDB 请求失败（HTTP \(code)）"
            }
            throw TmdbError(statusCode: code, message: message)
        }
    }
}
