import Foundation
import TidyreelModels

/// Returns days since 1970-01-01 for a valid proleptic Gregorian date (Howard Hinnant's algorithm).
func daysFromCivil(year yIn: Int, month m: Int, day d: Int) -> Int64? {
    guard m >= 1, m <= 12, d >= 1 else { return nil }
    let isLeap = (yIn % 4 == 0 && (yIn % 100 != 0 || yIn % 400 == 0))
    let maxDay: Int
    switch m {
    case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
    case 4, 6, 9, 11: maxDay = 30
    case 2: maxDay = isLeap ? 29 : 28
    default: return nil
    }
    guard d <= maxDay else { return nil }

    let y = Int64(m <= 2 ? yIn - 1 : yIn)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * Int64(m + (m > 2 ? -3 : 9)) + 2) / 5 + Int64(d) - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

/// Zero-allocation pure-Swift RFC 3339 / ISO-8601 timestamp parser.
/// Handles `YYYY-MM-DD[T|t| ]HH:MM:SS[.frac](Z|z|±HH:MM|±HHMM|±HH)`.
func parseFastISO8601Date(_ str: String) -> Date? {
    let utf8 = str.utf8
    var idx = utf8.startIndex
    var end = utf8.endIndex

    @inline(__always)
    func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    while idx < end && isSpace(utf8[idx]) {
        utf8.formIndex(after: &idx)
    }
    while end > idx {
        let prev = utf8.index(before: end)
        if isSpace(utf8[prev]) {
            end = prev
        } else {
            break
        }
    }

    @inline(__always)
    func readByte() -> UInt8? {
        guard idx < end else { return nil }
        let b = utf8[idx]
        utf8.formIndex(after: &idx)
        return b
    }

    @inline(__always)
    func readDigits(_ count: Int) -> Int? {
        var val = 0
        for _ in 0..<count {
            guard let b = readByte(), b >= 0x30, b <= 0x39 else { return nil }
            val = val * 10 + Int(b - 0x30)
        }
        return val
    }

    guard let year = readDigits(4),
          readByte() == 0x2D,
          let month = readDigits(2),
          readByte() == 0x2D,
          let day = readDigits(2),
          let sep = readByte(),
          sep == 0x54 || sep == 0x74 || sep == 0x20,
          let hour = readDigits(2),
          readByte() == 0x3A,
          let minute = readDigits(2),
          readByte() == 0x3A,
          let second = readDigits(2) else {
        return nil
    }
    guard hour <= 23, minute <= 59, second <= 60 else { return nil }
    guard let days = daysFromCivil(year: year, month: month, day: day) else { return nil }

    var fracSeconds = 0.0
    if idx < end && (utf8[idx] == 0x2E || utf8[idx] == 0x2C) {
        utf8.formIndex(after: &idx)
        var fracDigits = 0
        var nanos: Int64 = 0
        var scale: Int64 = 100_000_000
        while idx < end {
            let b = utf8[idx]
            guard b >= 0x30, b <= 0x39 else { break }
            if scale > 0 {
                nanos += Int64(b - 0x30) * scale
                scale /= 10
            }
            fracDigits += 1
            utf8.formIndex(after: &idx)
        }
        guard fracDigits > 0 else { return nil }
        fracSeconds = Double(nanos) / 1_000_000_000.0
    }

    guard let tzMarker = readByte() else { return nil }
    let tzOffsetSeconds: Int64
    if tzMarker == 0x5A || tzMarker == 0x7A {
        tzOffsetSeconds = 0
    } else if tzMarker == 0x2B || tzMarker == 0x2D {
        let sign: Int64 = (tzMarker == 0x2B) ? 1 : -1
        guard let tzH = readDigits(2), tzH <= 23 else { return nil }
        let tzM: Int
        if idx < end {
            if utf8[idx] == 0x3A {
                utf8.formIndex(after: &idx)
            }
            guard let m = readDigits(2), m <= 59 else { return nil }
            tzM = m
        } else {
            tzM = 0
        }
        tzOffsetSeconds = sign * Int64(tzH * 3600 + tzM * 60)
    } else {
        return nil
    }

    guard idx == end else { return nil }

    let totalSeconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - tzOffsetSeconds
    return Date(timeIntervalSince1970: Double(totalSeconds) + fracSeconds)
}

public actor AlistBackend: RangeReadableBackend {
    private static let perPage = 500
    private static let maxListConcurrency = 4
    private static let rawURLCacheTTL: TimeInterval = 90
    private static let rawURLCacheCap = 256

    private struct CachedRawURL: Sendable {
        let url: URL
        let headers: [String: String]
        let expiresAt: TimeInterval
    }

    private struct DecodedListPage: Sendable {
        let code: Int
        let message: String
        let entries: [RemoteEntry]
        let total: Int
    }

    private let baseEndpoint: String
    private let endpointURL: URL?
    private let username: String?
    private let password: String?
    private let credentials: Credentials
    private var token: String?
    private let transport: any StorageHTTPTransport
    private var loginTask: Task<String, Error>?
    private var rawURLCache: [String: CachedRawURL] = [:]

    public init(
        config: ConnectionConfig,
        credentials: Credentials,
        transport: (any StorageHTTPTransport)? = nil
    ) {
        var trimmed = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        self.baseEndpoint = trimmed
        self.endpointURL = URL(string: config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: trimmed)
        self.username = config.username
        self.password = credentials.password
        self.credentials = credentials
        let rawToken = credentials.token ?? ""
        self.token = rawToken.isEmpty ? nil : rawToken
        self.transport = transport ?? URLSessionStorageTransport.shared
    }

    public nonisolated var supportsServerBatching: Bool { true }

    private var canLogin: Bool {
        !(username ?? "").isEmpty && !(password ?? "").isEmpty
    }

    private struct AlistEnvelope {
        var code: Int
        var message: String
        var data: Any?
    }

    private func apiURL(_ apiPath: String) throws -> URL {
        let joined = apiPath.hasPrefix("/") ? "\(baseEndpoint)\(apiPath)" : "\(baseEndpoint)/\(apiPath)"
        guard let url = URL(string: joined), url.scheme != nil, url.host != nil else {
            throw StorageError(.network, "Alist 地址无效：\(baseEndpoint)")
        }
        return url
    }

    private func parseEnvelope(data: Data, response: HTTPURLResponse) -> AlistEnvelope {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = (json["code"] as? NSNumber)?.intValue {
            let message = (json["message"] as? String) ?? (json["message"].map { "\($0)" } ?? "")
            let payload = json["data"] is NSNull ? nil : json["data"]
            return AlistEnvelope(code: code, message: message, data: payload)
        }
        let status = response.statusCode
        if status == 200 {
            return AlistEnvelope(
                code: 0,
                message: "服务器返回了非 JSON 响应（HTTP 200），请检查 Alist 地址是否正确",
                data: nil
            )
        }
        return AlistEnvelope(code: status, message: "HTTP \(status)", data: nil)
    }

    private func postJSON(_ api: String, body: [String: Any], token: String?) async throws -> AlistEnvelope {
        let url = try apiURL(api)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await transport.send(req, followRedirects: true)
        } catch let sErr as StorageError {
            throw sErr
        } catch {
            throw StorageError(.network, "Alist 请求失败（\(api)）：\(describeTransportError(error))")
        }
        return parseEnvelope(data: data, response: http)
    }

    private func extractData(_ env: AlistEnvelope, what: String) throws -> Any? {
        if env.code == 200 {
            return env.data
        }
        let rawMsg = env.message
        let msg = rawMsg.isEmpty
            ? "\(what) 失败（code \(env.code)）"
            : "\(what) 失败：\(rawMsg)（code \(env.code)）"
        let lower = rawMsg.lowercased()

        let code: StorageErrorCode
        switch env.code {
        case 401, 403:
            code = .unauthorized
        case 404:
            code = .notFound
        case 429:
            code = .rateLimited
        case 502, 503, 504:
            code = .network
        default:
            if lower.contains("not found") {
                code = .notFound
            } else if lower.contains("already exist") {
                code = .alreadyExists
            } else if lower.contains("too many") {
                code = .rateLimited
            } else if lower.contains("access is denied")
                || lower.contains("used by another process")
                || lower.contains("resource busy") {
                code = .busy
            } else {
                code = .other
            }
        }
        throw StorageError(code, msg)
    }

    private func login() async throws {
        if let existing = loginTask {
            let newToken = try await existing.value
            self.token = newToken
            return
        }
        let task = Task<String, Error> {
            try await performLogin()
        }
        self.loginTask = task
        defer {
            self.loginTask = nil
        }
        let newToken = try await task.value
        self.token = newToken
    }

    private func performLogin() async throws -> String {
        let env = try await postJSON(
            "/api/auth/login",
            body: [
                "username": username ?? "",
                "password": password ?? "",
            ],
            token: nil
        )
        let lower = env.message.lowercased()
        if env.code == 400 && (
            lower.contains("password")
                || lower.contains("user")
                || lower.contains("auth")
                || lower.contains("credential")
                || lower.contains("otp")
                || lower.contains("2fa")
        ) {
            throw StorageError(.unauthorized, "Alist 登录失败：用户名或密码错误（\(env.message)）")
        }
        let data = try extractData(env, what: "登录")
        guard let dict = data as? [String: Any],
              let tok = dict["token"] as? String,
              !tok.isEmpty else {
            throw StorageError(.other, "Alist 登录失败：服务器未返回有效令牌")
        }
        return tok
    }

    private func withAuthRaw(
        _ send: (String?) async throws -> AlistEnvelope
    ) async throws -> AlistEnvelope {
        var attempt = 0
        while true {
            if token == nil && canLogin {
                try await login()
            }
            let used = token
            let res = try await send(used)
            if res.code == 401 && attempt == 0 && canLogin {
                if token == used {
                    token = nil
                }
                attempt += 1
                continue
            }
            return res
        }
    }

    @discardableResult
    private func call(_ api: String, body: [String: Any]) async throws -> Any? {
        let env = try await withAuthRaw { tok in
            try await postJSON(api, body: body, token: tok)
        }
        return try extractData(env, what: api)
    }

    private nonisolated static func parseISODate(_ raw: Any?) -> Date? {
        guard let str = raw as? String, !str.isEmpty else { return nil }
        return parseFastISO8601Date(str)
    }

    private nonisolated static func decodeListPage(
        data: Data,
        response: HTTPURLResponse,
        dir: String
    ) -> DecodedListPage {
        autoreleasepool {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = (json["code"] as? NSNumber)?.intValue else {
                let status = response.statusCode
                if status == 200 {
                    return DecodedListPage(
                        code: 0,
                        message: "服务器返回了非 JSON 响应（HTTP 200），请检查 Alist 地址是否正确",
                        entries: [],
                        total: 0
                    )
                }
                return DecodedListPage(code: status, message: "HTTP \(status)", entries: [], total: 0)
            }
            let message = (json["message"] as? String) ?? (json["message"].map { "\($0)" } ?? "")
            guard code == 200, let payload = json["data"] as? [String: Any] else {
                return DecodedListPage(code: code, message: message, entries: [], total: 0)
            }
            let content = (payload["content"] as? [Any]) ?? []
            let total = (payload["total"] as? NSNumber)?.intValue ?? 0
            var entries: [RemoteEntry] = []
            entries.reserveCapacity(content.count)
            let cleanDir = posixTrimDir(dir)
            let dirPrefix = cleanDir == "/" ? "/" : cleanDir + "/"
            for item in content {
                guard let dict = item as? [String: Any],
                      let name = dict["name"] as? String else {
                    continue
                }
                let isDir = (dict["is_dir"] as? Bool) == true
                let rawSize = (dict["size"] as? NSNumber)?.int64Value ?? 0
                entries.append(
                    RemoteEntry(
                        path: dirPrefix + name,
                        name: name,
                        isDir: isDir,
                        size: isDir ? 0 : max(0, rawSize),
                        modified: parseISODate(dict["modified"])
                    )
                )
            }
            return DecodedListPage(code: code, message: message, entries: entries, total: total)
        }
    }

    private func fetchListPage(
        dir: String,
        dirPassword: String,
        page: Int,
        refresh: Bool
    ) async throws -> (entries: [RemoteEntry], total: Int) {
        let url = try apiURL("/api/fs/list")
        let bodyBytes = try JSONSerialization.data(withJSONObject: [
            "path": dir,
            "password": dirPassword,
            "page": page,
            "per_page": Self.perPage,
            "refresh": refresh,
        ] as [String: Any])

        var attempt = 0
        while true {
            if token == nil && canLogin {
                try await login()
            }
            let used = token
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if let used {
                req.setValue(used, forHTTPHeaderField: "Authorization")
            }
            req.httpBody = bodyBytes

            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.send(req, followRedirects: true)
            } catch let sErr as StorageError {
                throw sErr
            } catch {
                throw StorageError(.network, "Alist 请求失败（/api/fs/list）：\(describeTransportError(error))")
            }

            let decoded = Self.decodeListPage(data: data, response: http, dir: dir)
            if decoded.code == 401 && attempt == 0 && canLogin {
                if token == used {
                    token = nil
                }
                attempt += 1
                continue
            }
            if decoded.code != 200 {
                _ = try extractData(
                    AlistEnvelope(code: decoded.code, message: decoded.message, data: nil),
                    what: "/api/fs/list"
                )
            }
            return (decoded.entries, decoded.total)
        }
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        let dirPassword = credentials.passwordForPath(dir)
        let first = try await fetchListPage(dir: dir, dirPassword: dirPassword, page: 1, refresh: refresh)
        if first.entries.isEmpty || first.entries.count >= first.total {
            return first.entries
        }

        var out: [RemoteEntry] = []
        out.reserveCapacity(min(max(first.total, first.entries.count), 100_000))
        out.append(contentsOf: first.entries)

        let effectivePerPage = first.entries.count
        if first.total > Self.perPage {
            let remainingItems = first.total - effectivePerPage
            let extraPages = (remainingItems / effectivePerPage) + (remainingItems % effectivePerPage == 0 ? 0 : 1)
            let totalPages = 1 + extraPages
            if totalPages >= 2 {
                var pages = Array<[RemoteEntry]?>(repeating: nil, count: totalPages - 1)
                try await withThrowingTaskGroup(of: (Int, [RemoteEntry]).self) { group in
                    var nextPage = 2
                    var inFlight = 0
                    while nextPage <= totalPages && inFlight < Self.maxListConcurrency {
                        let p = nextPage
                        nextPage += 1
                        inFlight += 1
                        group.addTask {
                            let res = try await self.fetchListPage(
                                dir: dir,
                                dirPassword: dirPassword,
                                page: p,
                                refresh: false
                            )
                            return (p, res.entries)
                        }
                    }
                    while let (p, entries) = try await group.next() {
                        pages[p - 2] = entries
                        inFlight -= 1
                        if nextPage <= totalPages {
                            let next = nextPage
                            nextPage += 1
                            inFlight += 1
                            group.addTask {
                                let res = try await self.fetchListPage(
                                    dir: dir,
                                    dirPassword: dirPassword,
                                    page: next,
                                    refresh: false
                                )
                                return (next, res.entries)
                            }
                        }
                    }
                }
                for pageEntries in pages {
                    if let pageEntries {
                        out.append(contentsOf: pageEntries)
                    }
                }
                return out
            }
        }

        var page = 2
        while out.count < first.total {
            let next = try await fetchListPage(dir: dir, dirPassword: dirPassword, page: page, refresh: false)
            if next.entries.isEmpty {
                break
            }
            out.append(contentsOf: next.entries)
            page += 1
        }
        return out
    }

    private func getInfo(_ path: String) async throws -> [String: Any]? {
        do {
            let res = try await call(
                "/api/fs/get",
                body: [
                    "path": path,
                    "password": credentials.passwordForPath(path),
                ]
            )
            return res as? [String: Any]
        } catch let err as StorageError where err.code == .notFound {
            return nil
        }
    }

    private static func extractDownloadHeaders(_ rawHeader: Any?) -> [String: String] {
        var decoded: Any? = rawHeader
        if let str = rawHeader as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                return [:]
            }
            decoded = obj
        }
        guard let map = decoded as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in map {
            if k.isEmpty || v is NSNull { continue }
            if let s = v as? String {
                out[k] = s
            } else if let list = v as? [Any], !list.isEmpty {
                out[k] = list.map { "\($0)" }.joined(separator: ", ")
            } else {
                out[k] = "\(v)"
            }
        }
        return out
    }

    private static func httpStatusToCode(_ status: Int) -> StorageErrorCode {
        switch status {
        case 401, 403:
            return .unauthorized
        case 404:
            return .notFound
        case 429:
            return .rateLimited
        case 500..<600:
            return .network
        default:
            return .other
        }
    }

    private func resolveDownloadURL(_ rawUrl: String, path: String) throws -> URL {
        guard let base = endpointURL,
              let url = resolveValidURL(rawUrl, relativeTo: base) else {
            throw StorageError(.network, "读取文件失败（\(path)）：下载地址无效")
        }
        return url
    }

    public func exists(_ path: String) async throws -> Bool {
        try await getInfo(path) != nil
    }

    public func read(_ path: String) async throws -> Data {
        guard let info = try await getInfo(path),
              let raw = info["raw_url"] as? String,
              !raw.isEmpty else {
            throw StorageError(.notFound, "文件不存在：\(path)")
        }
        let url = try resolveDownloadURL(raw, path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in Self.extractDownloadHeaders(info["header"]) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await transport.send(req, followRedirects: true)
        } catch let sErr as StorageError {
            throw sErr
        } catch {
            throw StorageError(.network, "读取文件失败（\(path)）：\(describeTransportError(error))")
        }

        if http.statusCode != 200 {
            throw StorageError(
                Self.httpStatusToCode(http.statusCode),
                "读取文件失败（\(path)）：HTTP \(http.statusCode)"
            )
        }
        return data
    }

    private func cachedRawURL(forKey key: String) -> CachedRawURL? {
        guard let entry = rawURLCache[key] else { return nil }
        if ProcessInfo.processInfo.systemUptime >= entry.expiresAt {
            rawURLCache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private func storeCachedRawURL(_ entry: CachedRawURL, forKey key: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if rawURLCache[key] == nil && rawURLCache.count >= Self.rawURLCacheCap {
            // Sweep expired entries first; if still at cap, evict the soonest-expiring entry.
            rawURLCache = rawURLCache.filter { $0.value.expiresAt > now }
            if rawURLCache.count >= Self.rawURLCacheCap,
               let oldestKey = rawURLCache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                rawURLCache.removeValue(forKey: oldestKey)
            }
        }
        rawURLCache[key] = entry
    }

    private func invalidateRawURLCacheSubtree(_ path: String) {
        guard !rawURLCache.isEmpty else { return }
        let norm = posixTrimDir(path)
        if norm == "/" {
            rawURLCache.removeAll()
            return
        }
        let prefix = norm + "/"
        rawURLCache = rawURLCache.filter { k, _ in
            k != norm && !k.hasPrefix(prefix)
        }
    }

    private func fetchAndCacheRawURL(path: String, cacheKey: String) async throws -> CachedRawURL {
        guard let info = try await getInfo(path),
              let raw = info["raw_url"] as? String,
              !raw.isEmpty else {
            throw StorageError(.notFound, "文件不存在：\(path)")
        }
        let url = try resolveDownloadURL(raw, path: path)
        let headers = Self.extractDownloadHeaders(info["header"])
        let entry = CachedRawURL(
            url: url,
            headers: headers,
            expiresAt: ProcessInfo.processInfo.systemUptime + Self.rawURLCacheTTL
        )
        storeCachedRawURL(entry, forKey: cacheKey)
        return entry
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        if start < 0 || length <= 0 {
            return Data()
        }
        let cacheKey = posixTrimDir(path)
        var usedCache = false
        var resolved: CachedRawURL
        if let cached = cachedRawURL(forKey: cacheKey) {
            resolved = cached
            usedCache = true
        } else {
            resolved = try await fetchAndCacheRawURL(path: path, cacheKey: cacheKey)
        }

        let end = start + Int64(length) - 1
        let rangeHeader = "bytes=\(start)-\(end)"

        while true {
            var req = URLRequest(url: resolved.url)
            req.httpMethod = "GET"
            for (k, v) in resolved.headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")

            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.send(req, followRedirects: true)
            } catch let sErr as StorageError {
                throw sErr
            } catch {
                throw StorageError(.network, "分段读取文件失败（\(path)）：\(describeTransportError(error))")
            }

            let status = http.statusCode
            if usedCache && (status == 401 || status == 403 || status == 404 || status == 410) {
                rawURLCache.removeValue(forKey: cacheKey)
                usedCache = false
                resolved = try await fetchAndCacheRawURL(path: path, cacheKey: cacheKey)
                continue
            }
            if status == 416 {
                return Data()
            }
            if status == 206 {
                return data.count <= length ? data : Data(data.prefix(length))
            }
            if status == 200 {
                if start > maxUnrangedSkipBytes {
                    throw StorageError(.other, "服务器不支持分段读取（\(path)）：HTTP 200")
                }
                let s = Int(start)
                if s >= data.count {
                    return Data()
                }
                let e = min(data.count, s + length)
                return data.subdata(in: s..<e)
            }
            throw StorageError(
                Self.httpStatusToCode(status),
                "分段读取文件失败（\(path)）：HTTP \(status)"
            )
        }
    }

    public func write(_ path: String, bytes: Data) async throws {
        if try await exists(path) {
            throw StorageError(.alreadyExists, "文件已存在：\(path)")
        }
        let parent = posixDirname(path)
        if parent != "/" {
            try await mkdirs(parent)
        }
        let dirPassword = credentials.passwordForPath(path)
        let putURL = try apiURL("/api/fs/put")

        let env = try await withAuthRaw { tok in
            var req = URLRequest(url: putURL)
            req.httpMethod = "PUT"
            if let tok {
                req.setValue(tok, forHTTPHeaderField: "Authorization")
            }
            req.setValue(encodeURIComponent(path), forHTTPHeaderField: "File-Path")
            req.setValue("false", forHTTPHeaderField: "As-Task")
            if !dirPassword.isEmpty {
                req.setValue(dirPassword, forHTTPHeaderField: "Password")
            }
            req.setValue("\(bytes.count)", forHTTPHeaderField: "Content-Length")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = bytes

            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.send(req, followRedirects: true)
            } catch let sErr as StorageError {
                throw sErr
            } catch {
                throw StorageError(.network, "上传文件失败（\(path)）：\(describeTransportError(error))")
            }
            return parseEnvelope(data: data, response: http)
        }
        _ = try extractData(env, what: "上传 \(path)")
        rawURLCache.removeValue(forKey: posixTrimDir(path))
    }

    public func mkdirs(_ dir: String) async throws {
        if let cur = try await getInfo(dir) {
            if (cur["is_dir"] as? Bool) == true {
                return
            }
            throw StorageError(.alreadyExists, "路径已存在且不是目录：\(dir)")
        }
        do {
            try await call("/api/fs/mkdir", body: ["path": dir])
        } catch let err as StorageError where err.code == .alreadyExists {
            if let after = try await getInfo(dir), (after["is_dir"] as? Bool) == true {
                return
            }
            throw err
        }
    }

    public func rename(_ path: String, newName: String) async throws {
        try validateChildName(newName)
        let dir = posixDirname(path)
        let oldName = posixBasename(path)
        if oldName == newName {
            return
        }
        let target = posixJoin(dir, newName)
        if oldName.lowercased() == newName.lowercased() {
            let entries = try await list(dir, refresh: true)
            if entries.contains(where: { $0.name == newName }) {
                throw StorageError(.alreadyExists, "目标已存在：\(target)")
            }
        } else if try await exists(target) {
            throw StorageError(.alreadyExists, "目标已存在：\(target)")
        }
        try await call("/api/fs/rename", body: ["path": path, "name": newName])
        invalidateRawURLCacheSubtree(path)
        invalidateRawURLCacheSubtree(target)
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        for (oldName, newName) in names {
            try validateChildName(oldName)
            try validateChildName(newName)
        }
        let sortedKeys = names.keys.sorted()
        var effective: [(src: String, dst: String)] = []
        for k in sortedKeys {
            if let v = names[k], k != v {
                effective.append((k, v))
            }
        }
        if effective.isEmpty {
            return
        }

        var seenTargets: Set<String> = []
        var seenTargetsLower: Set<String> = []
        for (_, target) in effective {
            let lower = target.lowercased()
            if !seenTargets.insert(target).inserted || !seenTargetsLower.insert(lower).inserted {
                throw StorageError(.alreadyExists, "目标文件名重复：\(posixJoin(dir, target))")
            }
        }

        let listed = try await list(dir, refresh: true)
        let have = Set(listed.map(\.name))
        let haveLower = Set(have.map { $0.lowercased() })

        for (srcName, dstName) in effective {
            if !have.contains(srcName) {
                throw StorageError(.notFound, "源文件不存在：\(posixJoin(dir, srcName))")
            }
            let targetPath = posixJoin(dir, dstName)
            if have.contains(dstName) {
                throw StorageError(.alreadyExists, "目标已存在：\(targetPath)")
            }
            let srcLower = srcName.lowercased()
            let dstLower = dstName.lowercased()
            if srcLower != dstLower && haveLower.contains(dstLower), try await exists(targetPath) {
                throw StorageError(.alreadyExists, "目标已存在：\(targetPath)")
            }
        }

        defer {
            if !rawURLCache.isEmpty {
                for (srcName, dstName) in effective {
                    invalidateRawURLCacheSubtree(posixJoin(dir, srcName))
                    invalidateRawURLCacheSubtree(posixJoin(dir, dstName))
                }
            }
        }

        let renameObjects: [[String: String]] = effective.map {
            ["src_name": $0.src, "new_name": $0.dst]
        }
        let env = try await withAuthRaw { tok in
            try await postJSON(
                "/api/fs/batch_rename",
                body: [
                    "src_dir": dir,
                    "rename_objects": renameObjects,
                ],
                token: tok
            )
        }
        if env.code == 404 || env.code == 405 {
            for (srcName, dstName) in effective {
                try await call(
                    "/api/fs/rename",
                    body: [
                        "path": posixJoin(dir, srcName),
                        "name": dstName,
                    ]
                )
            }
            return
        }
        _ = try extractData(env, what: "/api/fs/batch_rename")
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        for name in names {
            try validateChildName(name)
        }
        if names.isEmpty {
            return
        }
        let listedDst = try await list(dstDir, refresh: true)
        let taken = Set(listedDst.map(\.name))
        let takenLower = Set(taken.map { $0.lowercased() })
        for name in names {
            let targetPath = posixJoin(dstDir, name)
            if taken.contains(name) {
                throw StorageError(.alreadyExists, "目标已存在：\(targetPath)")
            }
            if takenLower.contains(name.lowercased()), try await exists(targetPath) {
                throw StorageError(.alreadyExists, "目标已存在：\(targetPath)")
            }
        }
        try await call(
            "/api/fs/move",
            body: [
                "src_dir": srcDir,
                "dst_dir": dstDir,
                "names": names,
            ]
        )
        if !rawURLCache.isEmpty {
            for name in names {
                invalidateRawURLCacheSubtree(posixJoin(srcDir, name))
                invalidateRawURLCacheSubtree(posixJoin(dstDir, name))
            }
        }
    }

    public func remove(dir: String, names: [String]) async throws {
        for name in names {
            try validateChildName(name)
        }
        if names.isEmpty {
            return
        }
        let listed = try await list(dir, refresh: true)
        let have = Set(listed.map(\.name))
        for name in names {
            if !have.contains(name) {
                throw StorageError(.notFound, "文件不存在：\(posixJoin(dir, name))")
            }
        }
        try await call(
            "/api/fs/remove",
            body: [
                "dir": dir,
                "names": names,
            ]
        )
        if !rawURLCache.isEmpty {
            for name in names {
                invalidateRawURLCacheSubtree(posixJoin(dir, name))
            }
        }
    }

    public func ping() async throws {
        let res = try await call(
            "/api/fs/get",
            body: [
                "path": "/",
                "password": credentials.passwordForPath("/"),
            ]
        )
        guard res is [String: Any] else {
            throw StorageError(.other, "连接检测失败：服务器返回数据格式异常")
        }
    }

    public func close() async {
        rawURLCache.removeAll()
    }
}
