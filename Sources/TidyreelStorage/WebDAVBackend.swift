import Foundation
import TidyreelModels

public actor WebDAVBackend: RangeReadableBackend {
    private static let propfindBody = Data(
        (
            #"<?xml version="1.0" encoding="utf-8"?>"#
            + #"<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/>"#
            + #"<d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>"#
        ).utf8
    )

    private static let sendRedirectCodes: Set<Int> = [301, 302, 307, 308]
    private static let getRedirectCodes: Set<Int> = [301, 302, 303, 307, 308]

    private let rawEndpoint: String
    private let baseComponents: URLComponents?
    private let baseURL: URL?
    private let baseSegments: [String]
    private let authHeader: String?
    private let transport: any StorageHTTPTransport
    private var tmpSeq: UInt64 = 0

    public init(
        config: ConnectionConfig,
        credentials: Credentials,
        transport: (any StorageHTTPTransport)? = nil
    ) {
        let raw = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawEndpoint = raw
        let encodedEndpoint = percentEncodeLooseURL(raw)
        let comps = URLComponents(string: encodedEndpoint)
        self.baseComponents = comps
        self.baseURL = comps?.url

        if let pctPath = comps?.percentEncodedPath, !pctPath.isEmpty {
            self.baseSegments = pctPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { seg in
                    let s = String(seg)
                    return s.removingPercentEncoding ?? s
                }
        } else {
            self.baseSegments = []
        }

        let user = config.username ?? ""
        let pass = credentials.password ?? ""
        if !user.isEmpty || !pass.isEmpty {
            let token = Data("\(user):\(pass)".utf8).base64EncodedString()
            self.authHeader = "Basic \(token)"
        } else {
            self.authHeader = nil
        }
        self.transport = transport ?? URLSessionStorageTransport.shared
    }

    private func buildURL(_ path: String, dir: Bool = false) throws -> URL {
        let relSegs = try validatedPathSegments(path)
        guard var comps = baseComponents,
              let scheme = comps.scheme, !scheme.isEmpty,
              let host = comps.host, !host.isEmpty else {
            throw StorageError(.network, "WebDAV 地址无效：\(rawEndpoint)")
        }
        comps.query = nil
        comps.fragment = nil

        let allSegs = baseSegments + relSegs
        if allSegs.isEmpty {
            comps.percentEncodedPath = "/"
        } else {
            let encoded = allSegs.map(encodePathSegment).joined(separator: "/")
            comps.percentEncodedPath = "/" + encoded + (dir ? "/" : "")
        }

        guard let url = comps.url else {
            throw StorageError(.network, "WebDAV 地址构造失败：\(path)")
        }
        return url
    }

    private nonisolated static func relativePath(of resolvedURL: URL, baseSegments: [String]) -> String {
        guard let comps = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true) else {
            return "/"
        }
        let fullSegs = comps.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { seg -> String in
                let s = String(seg)
                return s.removingPercentEncoding ?? s
            }
        var matchesBase = fullSegs.count >= baseSegments.count
        if matchesBase {
            for i in 0..<baseSegments.count where fullSegs[i] != baseSegments[i] {
                matchesBase = false
                break
            }
        }
        let relSegs = matchesBase ? Array(fullSegs.dropFirst(baseSegments.count)) : fullSegs
        return relSegs.isEmpty ? "/" : "/" + relSegs.joined(separator: "/")
    }

    private func toRelativePath(_ resolvedURL: URL) -> String {
        Self.relativePath(of: resolvedURL, baseSegments: baseSegments)
    }

    private nonisolated static func parseMultistatusEntries(
        data: Data,
        reqURL: URL,
        selfPath: String,
        baseSegments: [String]
    ) async throws -> [RemoteEntry] {
        let parsed = try WebDAVMultistatusParser.parse(data)

        var out: [RemoteEntry] = []
        out.reserveCapacity(parsed.count)
        for item in parsed {
            guard let rawHref = item.href,
                  let resolved = resolveValidURL(rawHref, relativeTo: reqURL, escapeHash: true) else {
                continue
            }
            let path = Self.relativePath(of: resolved, baseSegments: baseSegments)
            if path == selfPath {
                continue
            }
            let size: Int64 = item.isCollection ? 0 : (Int64(item.contentLength ?? "") ?? 0)
            let modified = item.lastModified.flatMap(Self.parseHTTPDate)
            out.append(
                RemoteEntry(
                    path: path,
                    name: posixBasename(path),
                    isDir: item.isCollection,
                    size: max(0, size),
                    modified: modified,
                    deleteIdentity: item.isCollection ? nil : Self.strongETag(item.etag)
                )
            )
        }
        return out
    }

    private func fail(method: String, path: String, status: Int) -> StorageError {
        let code: StorageErrorCode
        switch status {
        case 401, 403:
            code = .unauthorized
        case 404, 409:
            code = .notFound
        case 412:
            code = .alreadyExists
        case 423:
            code = .busy
        case 429:
            code = .rateLimited
        case 502, 503, 504:
            code = .network
        default:
            code = .other
        }
        return StorageError(code, "WebDAV \(method) \(path) 失败：HTTP \(status)")
    }

    private func send(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        dir: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var url = try buildURL(path, dir: dir)
        do {
            var hop = 0
            while true {
                var req = URLRequest(url: url)
                req.httpMethod = method
                if let authHeader {
                    req.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                req.httpBody = body

                let (data, http) = try await transport.send(req, followRedirects: false)
                guard hop == 0,
                      Self.sendRedirectCodes.contains(http.statusCode),
                      let location = http.value(forHTTPHeaderField: "Location") else {
                    return (data, http)
                }
                guard let next = resolveValidURL(location, relativeTo: url) else {
                    throw StorageError(.network, "WebDAV \(method) \(path) 重定向地址无效")
                }
                if !isSameOrigin(url, next) {
                    return (data, http)
                }
                url = next
                hop += 1
            }
        } catch let sErr as StorageError {
            throw sErr
        } catch {
            throw StorageError(.network, "WebDAV \(method) \(path) 失败：\(describeTransportError(error))")
        }
    }

    private func propfind(_ path: String, depth: Int, dir: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await send(
            method: "PROPFIND",
            path: path,
            headers: [
                "Depth": "\(depth)",
                "Content-Type": "application/xml",
            ],
            body: Self.propfindBody,
            dir: dir
        )
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        let (data, http) = try await propfind(dir, depth: 1, dir: true)
        if http.statusCode != 207 {
            throw fail(method: "PROPFIND", path: dir, status: http.statusCode)
        }
        let reqURL = try buildURL(dir, dir: true)
        let selfPath = toRelativePath(reqURL)
        return try await Self.parseMultistatusEntries(
            data: data,
            reqURL: reqURL,
            selfPath: selfPath,
            baseSegments: baseSegments
        )
    }

    public func exists(_ path: String) async throws -> Bool {
        let (_, http) = try await propfind(path, depth: 0)
        if http.statusCode == 207 {
            return true
        }
        if http.statusCode == 404 {
            return false
        }
        throw fail(method: "PROPFIND", path: path, status: http.statusCode)
    }

    public func read(_ path: String) async throws -> Data {
        var url = try buildURL(path)
        guard let originURL = baseURL else {
            throw StorageError(.network, "WebDAV 地址无效：\(rawEndpoint)")
        }
        do {
            var hop = 0
            while true {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                if let authHeader, isSameOrigin(originURL, url) {
                    req.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }
                let (data, http) = try await transport.send(req, followRedirects: false)
                if hop < 5,
                   Self.getRedirectCodes.contains(http.statusCode),
                   let location = http.value(forHTTPHeaderField: "Location") {
                    guard let next = resolveValidURL(location, relativeTo: url) else {
                        throw StorageError(.network, "WebDAV 读取 \(path) 重定向地址无效")
                    }
                    url = next
                    hop += 1
                    continue
                }
                if http.statusCode != 200 {
                    throw fail(method: "GET", path: path, status: http.statusCode)
                }
                return data
            }
        } catch let sErr as StorageError {
            throw sErr
        } catch {
            throw StorageError(.network, "WebDAV 读取 \(path) 失败：\(describeTransportError(error))")
        }
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        var url = try buildURL(path)
        if start < 0 || length <= 0 {
            return Data()
        }
        guard let originURL = baseURL else {
            throw StorageError(.network, "WebDAV 地址无效：\(rawEndpoint)")
        }
        let rangeHeader = "bytes=\(start)-\(start + Int64(length) - 1)"
        do {
            var hop = 0
            while true {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                if let authHeader, isSameOrigin(originURL, url) {
                    req.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }
                req.setValue(rangeHeader, forHTTPHeaderField: "Range")

                let (data, http) = try await transport.send(req, followRedirects: false)
                if hop < 5,
                   Self.getRedirectCodes.contains(http.statusCode),
                   let location = http.value(forHTTPHeaderField: "Location") {
                    guard let next = resolveValidURL(location, relativeTo: url) else {
                        throw StorageError(.network, "WebDAV 分段读取 \(path) 重定向地址无效")
                    }
                    url = next
                    hop += 1
                    continue
                }
                let status = http.statusCode
                if status == 416 {
                    return Data()
                }
                if status == 206 {
                    return data.count <= length ? data : Data(data.prefix(length))
                }
                if status == 200 {
                    if start > maxUnrangedSkipBytes {
                        throw StorageError(.other, "WebDAV 服务器不支持分段读取（\(path)）：HTTP 200")
                    }
                    let s = Int(start)
                    if s >= data.count {
                        return Data()
                    }
                    let e = min(data.count, s + length)
                    return data.subdata(in: s..<e)
                }
                throw fail(method: "GET", path: path, status: status)
            }
        } catch let sErr as StorageError {
            throw sErr
        } catch {
            throw StorageError(.network, "WebDAV 分段读取 \(path) 失败：\(describeTransportError(error))")
        }
    }

    public func write(_ path: String, bytes: Data) async throws {
        if try await exists(path) {
            throw StorageError(.alreadyExists, "文件已存在：\(path)")
        }
        try await mkdirs(posixDirname(path))
        let (_, http) = try await send(
            method: "PUT",
            path: path,
            headers: [
                "If-None-Match": "*",
                "Content-Length": "\(bytes.count)",
                "Content-Type": "application/octet-stream",
            ],
            body: bytes
        )
        if http.statusCode == 412 {
            throw StorageError(.alreadyExists, "文件已存在：\(path)")
        }
        if http.statusCode != 201 && http.statusCode != 204 && http.statusCode != 200 {
            throw fail(method: "PUT", path: path, status: http.statusCode)
        }
    }

    public func mkdirs(_ dir: String) async throws {
        let segs = try validatedPathSegments(dir)
        if segs.isEmpty {
            return
        }
        let norm = "/" + segs.joined(separator: "/")
        let (_, http) = try await send(method: "MKCOL", path: norm, dir: true)
        if http.statusCode == 201 || http.statusCode == 405 {
            return
        }
        if http.statusCode == 409 && segs.count > 1 {
            try await mkdirs(posixDirname(norm))
            let (_, retry) = try await send(method: "MKCOL", path: norm, dir: true)
            if retry.statusCode == 201 || retry.statusCode == 405 {
                return
            }
            throw fail(method: "MKCOL", path: norm, status: retry.statusCode)
        }
        throw fail(method: "MKCOL", path: norm, status: http.statusCode)
    }

    private func moveItem(from: String, to: String) async throws {
        let dstURL = try buildURL(to)
        let (_, http) = try await send(
            method: "MOVE",
            path: from,
            headers: [
                "Destination": dstURL.absoluteString,
                "Overwrite": "F",
            ]
        )
        if http.statusCode == 201 || http.statusCode == 204 {
            return
        }
        throw fail(method: "MOVE", path: from, status: http.statusCode)
    }

    public nonisolated var supportsAtomicRelocate: Bool { true }

    public func atomicRelocate(from src: String, to dst: String) async throws {
        let srcSegs = try validatedPathSegments(src)
        let dstSegs = try validatedPathSegments(dst)
        guard !srcSegs.isEmpty else {
            throw StorageError(.other, "无法移动根目录：\(src)")
        }
        guard !dstSegs.isEmpty else {
            throw StorageError(.alreadyExists, "目标已存在：\(dst)")
        }
        let cleanSrc = "/" + srcSegs.joined(separator: "/")
        let cleanDst = "/" + dstSegs.joined(separator: "/")
        if cleanSrc == cleanDst {
            return
        }
        let srcDir = posixDirname(cleanSrc)
        let dstDir = posixDirname(cleanDst)
        if srcDir == dstDir {
            try await rename(cleanSrc, newName: posixBasename(cleanDst))
            return
        }
        let dstURL = try buildURL(cleanDst)
        let (_, http) = try await send(
            method: "MOVE",
            path: cleanSrc,
            headers: [
                "Destination": dstURL.absoluteString,
                "Overwrite": "F",
            ]
        )
        if http.statusCode == 201 || http.statusCode == 204 {
            return
        }
        if http.statusCode == 409 {
            try await mkdirs(dstDir)
            try await moveItem(from: cleanSrc, to: cleanDst)
            return
        }
        throw fail(method: "MOVE", path: cleanSrc, status: http.statusCode)
    }

    public func rename(_ path: String, newName: String) async throws {
        try validateChildName(newName)
        _ = try validatedPathSegments(path)
        let dir = posixDirname(path)
        let oldName = posixBasename(path)
        let target = posixJoin(dir, newName)
        if oldName == newName {
            return
        }
        if oldName.lowercased() != newName.lowercased() {
            try await moveItem(from: path, to: target)
            return
        }
        let entries = try await list(dir, refresh: false)
        if entries.contains(where: { $0.name == newName }) {
            throw StorageError(.alreadyExists, "目标已存在：\(target)")
        }
        tmpSeq += 1
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let tmp = posixJoin(dir, ".tidyreel-case-\(micros)-\(tmpSeq)")
        try await moveItem(from: path, to: tmp)
        do {
            try await moveItem(from: tmp, to: target)
        } catch {
            try? await moveItem(from: tmp, to: path)
            throw error
        }
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        _ = try validatedPathSegments(dir)
        for (oldName, newName) in names {
            try validateChildName(oldName)
            try validateChildName(newName)
        }
        for key in names.keys.sorted() {
            guard let newName = names[key] else { continue }
            try await rename(posixJoin(dir, key), newName: newName)
        }
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        _ = try validatedPathSegments(srcDir)
        _ = try validatedPathSegments(dstDir)
        for name in names {
            try validateChildName(name)
        }
        for name in names {
            try await moveItem(from: posixJoin(srcDir, name), to: posixJoin(dstDir, name))
        }
    }

    private nonisolated static func strongETag(_ value: String?) -> String? {
        guard let value, value.utf8.count >= 2, value.first == "\"", value.last == "\"",
              value.utf8.dropFirst().dropLast().allSatisfy({ $0 == 0x21 || (0x23...0x7E).contains($0) })
        else { return nil }
        return value
    }

    public func removeScannedFile(_ path: String, identity: String?) async throws {
        guard let tag = Self.strongETag(identity) else {
            throw StorageError(.other, "WebDAV 未提供强 ETag，已保留：\(path)")
        }
        let (_, http) = try await send(method: "DELETE", path: path, headers: ["If-Match": tag])
        if http.statusCode == 412 { throw StorageError(.other, "文件已变更，已保留：\(path)") }
        guard [200, 204, 404].contains(http.statusCode) else {
            throw fail(method: "DELETE", path: path, status: http.statusCode)
        }
    }

    public func remove(dir: String, names: [String]) async throws {
        _ = try validatedPathSegments(dir)
        for name in names {
            try validateChildName(name)
        }
        for name in names {
            let path = posixJoin(dir, name)
            let (_, http) = try await send(method: "DELETE", path: path)
            if http.statusCode != 200 && http.statusCode != 204 {
                throw fail(method: "DELETE", path: path, status: http.statusCode)
            }
        }
    }

    public func ping() async throws {
        let (_, http) = try await propfind("/", depth: 0, dir: true)
        if http.statusCode != 207 {
            throw fail(method: "PROPFIND", path: "/", status: http.statusCode)
        }
    }

    public func close() async {}

    // MARK: - HTTP Date Parsing

    nonisolated static func parseHTTPDate(_ raw: String) -> Date? {
        if let fast = parseFastHTTPDate(raw) {
            return fast
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let iso = parseFastISO8601Date(trimmed) {
            return iso
        }
        return FallbackHTTPDateFormatters.shared.parse(trimmed)
    }
}

private final class FallbackHTTPDateFormatters: @unchecked Sendable {
    static let shared = FallbackHTTPDateFormatters()
    private let lock = NSLock()
    private let formatters: [DateFormatter]

    private init() {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "EEE MMM dd HH:mm:ss yyyy",
        ]
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = TimeZone(secondsFromGMT: 0)
        self.formatters = formats.map { fmt in
            let df = DateFormatter()
            df.locale = posix
            df.timeZone = utc
            df.dateFormat = fmt
            return df
        }
    }

    func parse(_ trimmed: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        for df in formatters {
            if let d = df.date(from: trimmed) {
                return d
            }
        }
        return nil
    }
}

/// Zero-allocation pure-Swift parser for RFC 1123, RFC 850, ANSI C `asctime()`,
/// and ISO-8601 HTTP date headers.
func parseFastHTTPDate(_ raw: String) -> Date? {
    let utf8 = raw.utf8
    var idx = utf8.startIndex
    var end = utf8.endIndex

    @inline(__always)
    func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    @inline(__always)
    func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
    }

    @inline(__always)
    func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    func isAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
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
    guard idx < end else { return nil }

    // Fast path for ISO-8601 dates (e.g. `2024-01-02T03:04:05Z`).
    if isDigit(utf8[idx]) {
        return parseFastISO8601Date(raw)
    }

    @inline(__always)
    func skipSpaces() {
        while idx < end && utf8[idx] == 0x20 {
            utf8.formIndex(after: &idx)
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
    func readDigits(min minCount: Int, max maxCount: Int) -> (value: Int, count: Int)? {
        var val = 0
        var count = 0
        while idx < end && count < maxCount {
            let b = utf8[idx]
            guard isDigit(b) else { break }
            val = val * 10 + Int(b - 0x30)
            count += 1
            utf8.formIndex(after: &idx)
        }
        guard count >= minCount else { return nil }
        return (val, count)
    }

    func readMonth3() -> Int? {
        guard let b0 = readByte(), let b1 = readByte(), let b2 = readByte() else { return nil }
        switch (asciiLower(b0), asciiLower(b1), asciiLower(b2)) {
        case (UInt8(ascii: "j"), UInt8(ascii: "a"), UInt8(ascii: "n")): return 1
        case (UInt8(ascii: "f"), UInt8(ascii: "e"), UInt8(ascii: "b")): return 2
        case (UInt8(ascii: "m"), UInt8(ascii: "a"), UInt8(ascii: "r")): return 3
        case (UInt8(ascii: "a"), UInt8(ascii: "p"), UInt8(ascii: "r")): return 4
        case (UInt8(ascii: "m"), UInt8(ascii: "a"), UInt8(ascii: "y")): return 5
        case (UInt8(ascii: "j"), UInt8(ascii: "u"), UInt8(ascii: "n")): return 6
        case (UInt8(ascii: "j"), UInt8(ascii: "u"), UInt8(ascii: "l")): return 7
        case (UInt8(ascii: "a"), UInt8(ascii: "u"), UInt8(ascii: "g")): return 8
        case (UInt8(ascii: "s"), UInt8(ascii: "e"), UInt8(ascii: "p")): return 9
        case (UInt8(ascii: "o"), UInt8(ascii: "c"), UInt8(ascii: "t")): return 10
        case (UInt8(ascii: "n"), UInt8(ascii: "o"), UInt8(ascii: "v")): return 11
        case (UInt8(ascii: "d"), UInt8(ascii: "e"), UInt8(ascii: "c")): return 12
        default: return nil
        }
    }

    func readTime() -> (hour: Int, minute: Int, second: Int)? {
        guard let h = readDigits(min: 2, max: 2),
              readByte() == 0x3A,
              let m = readDigits(min: 2, max: 2),
              readByte() == 0x3A,
              let s = readDigits(min: 2, max: 2),
              h.value <= 23, m.value <= 59, s.value <= 60 else {
            return nil
        }
        return (h.value, m.value, s.value)
    }

    func readTimezoneOffset() -> Int64? {
        guard idx < end else { return nil }
        let first = utf8[idx]
        if first == 0x2B || first == 0x2D { // '+' or '-'
            utf8.formIndex(after: &idx)
            let sign: Int64 = (first == 0x2B) ? 1 : -1
            guard let tzH = readDigits(min: 2, max: 2), tzH.value <= 23 else { return nil }
            let tzM: Int
            if idx < end {
                if utf8[idx] == 0x3A {
                    utf8.formIndex(after: &idx)
                }
                guard let m = readDigits(min: 2, max: 2), m.value <= 59 else { return nil }
                tzM = m.value
            } else {
                tzM = 0
            }
            guard idx == end else { return nil }
            return sign * Int64(tzH.value * 3600 + tzM * 60)
        }

        // Parse 1..4 ASCII letters for common HTTP timezones.
        var b0: UInt8 = 0
        var b1: UInt8 = 0
        var b2: UInt8 = 0
        var b3: UInt8 = 0
        var len = 0
        while idx < end {
            let b = asciiLower(utf8[idx])
            utf8.formIndex(after: &idx)
            switch len {
            case 0: b0 = b
            case 1: b1 = b
            case 2: b2 = b
            case 3: b3 = b
            default: return nil
            }
            len += 1
        }
        switch len {
        case 1:
            return b0 == UInt8(ascii: "z") ? 0 : nil
        case 2:
            return (b0 == UInt8(ascii: "u") && b1 == UInt8(ascii: "t")) ? 0 : nil
        case 3:
            switch (b0, b1, b2) {
            case (UInt8(ascii: "g"), UInt8(ascii: "m"), UInt8(ascii: "t")),
                 (UInt8(ascii: "u"), UInt8(ascii: "t"), UInt8(ascii: "c")):
                return 0
            case (UInt8(ascii: "e"), UInt8(ascii: "s"), UInt8(ascii: "t")): return -5 * 3600
            case (UInt8(ascii: "e"), UInt8(ascii: "d"), UInt8(ascii: "t")): return -4 * 3600
            case (UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "t")): return -6 * 3600
            case (UInt8(ascii: "c"), UInt8(ascii: "d"), UInt8(ascii: "t")): return -5 * 3600
            case (UInt8(ascii: "m"), UInt8(ascii: "s"), UInt8(ascii: "t")): return -7 * 3600
            case (UInt8(ascii: "m"), UInt8(ascii: "d"), UInt8(ascii: "t")): return -6 * 3600
            case (UInt8(ascii: "p"), UInt8(ascii: "s"), UInt8(ascii: "t")): return -8 * 3600
            case (UInt8(ascii: "p"), UInt8(ascii: "d"), UInt8(ascii: "t")): return -7 * 3600
            case (UInt8(ascii: "c"), UInt8(ascii: "e"), UInt8(ascii: "t")): return 1 * 3600
            case (UInt8(ascii: "j"), UInt8(ascii: "s"), UInt8(ascii: "t")): return 9 * 3600
            default: return nil
            }
        case 4:
            if b0 == UInt8(ascii: "c"), b1 == UInt8(ascii: "e"), b2 == UInt8(ascii: "s"), b3 == UInt8(ascii: "t") {
                return 2 * 3600
            }
            return nil
        default:
            return nil
        }
    }

    // Look for comma separating weekday name (RFC 1123 / RFC 850) vs asctime().
    var commaIdx: String.UTF8View.Index?
    var scan = idx
    while scan < end {
        let b = utf8[scan]
        if b == 0x2C { // ','
            commaIdx = scan
            break
        }
        if b == 0x20 {
            break
        }
        utf8.formIndex(after: &scan)
    }

    let year: Int
    let month: Int
    let day: Int
    let time: (hour: Int, minute: Int, second: Int)
    let tzOffset: Int64

    if let comma = commaIdx {
        idx = utf8.index(after: comma)
        skipSpaces()
        guard let d = readDigits(min: 1, max: 2), idx < end else { return nil }
        day = d.value
        let sep = utf8[idx]
        if sep == 0x20 {
            // RFC 1123: `Tue, 02 Jan 2024 03:04:05 GMT`
            skipSpaces()
            guard let m = readMonth3() else { return nil }
            month = m
            guard idx < end && utf8[idx] == 0x20 else { return nil }
            skipSpaces()
            guard let y = readDigits(min: 2, max: 4), y.count == 4 || y.count == 2 else { return nil }
            year = y.count == 2 ? (y.value < 70 ? 2000 + y.value : 1900 + y.value) : y.value
        } else if sep == 0x2D {
            // RFC 850: `Tuesday, 02-Jan-24 03:04:05 GMT`
            utf8.formIndex(after: &idx)
            guard let m = readMonth3(), readByte() == 0x2D else { return nil }
            month = m
            guard let y = readDigits(min: 2, max: 4), y.count == 2 || y.count == 4 else { return nil }
            year = y.count == 2 ? (y.value < 70 ? 2000 + y.value : 1900 + y.value) : y.value
        } else {
            return nil
        }
        guard idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let t = readTime() else { return nil }
        time = t
        guard idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let tz = readTimezoneOffset() else { return nil }
        tzOffset = tz
    } else {
        // ANSI C asctime(): `Tue Jan  2 03:04:05 2024`
        let wordStart = idx
        while idx < end && isAlpha(utf8[idx]) {
            utf8.formIndex(after: &idx)
        }
        guard idx > wordStart, idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let m = readMonth3() else { return nil }
        month = m
        guard idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let d = readDigits(min: 1, max: 2) else { return nil }
        day = d.value
        guard idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let t = readTime() else { return nil }
        time = t
        guard idx < end && utf8[idx] == 0x20 else { return nil }
        skipSpaces()
        guard let y = readDigits(min: 4, max: 4), idx == end else { return nil }
        year = y.value
        tzOffset = 0
    }

    guard let days = daysFromCivil(year: year, month: month, day: day) else { return nil }
    let totalSeconds = days * 86_400 + Int64(time.hour * 3600 + time.minute * 60 + time.second) - tzOffset
    return Date(timeIntervalSince1970: Double(totalSeconds))
}

// MARK: - Foundation.XMLParser Multistatus Parser

struct WebDAVParsedResponse: Sendable {
    var href: String?
    var isCollection: Bool = false
    var contentLength: String?
    var lastModified: String?
    var etag: String?
}

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct PropStatBlock {
        var isCollection: Bool = false
        var contentLength: String?
        var lastModified: String?
        var etag: String?
        var status: String?
    }

    private static let numericEntityRegex = try! NSRegularExpression(
        pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#
    )

    private var results: [WebDAVParsedResponse] = []
    private var inResponse = false
    private var currentHref: String?
    private var propStats: [PropStatBlock] = []
    private var currentPropStat: PropStatBlock?
    private var directProps = PropStatBlock()
    private var inResourceType = false
    private var activeTextTag: String?
    private var textBuffer = ""

    /// Fast byte scan for ASCII `"&#"` (`[0x26, 0x23]`) so XML payloads without
    /// numeric character references bypass UTF-8 String decoding + regex + re-encoding.
    private static func containsNumericEntityMarker(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let count = raw.count
            guard count >= 2, let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            let limit = count - 1
            var i = 0
            while i < limit {
                if base[i] == 0x26 && base[i + 1] == 0x23 {
                    return true
                }
                i += 1
            }
            return false
        }
    }

    /// Escapes invalid/out-of-range XML numeric character references (e.g. `&#999999999;`)
    /// so `Foundation.XMLParser` preserves them literally instead of aborting the parse.
    private static func sanitizeNumericEntities(_ xml: String) -> Data {
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = numericEntityRegex.matches(in: xml, range: nsRange)
        if matches.isEmpty {
            return Data(xml.utf8)
        }
        var out = xml
        for match in matches.reversed() {
            let valid: Bool
            if let hexRange = Range(match.range(at: 1), in: out) {
                if let cp = UInt32(out[hexRange], radix: 16) {
                    valid = isValidXMLCodePoint(cp)
                } else {
                    valid = false
                }
            } else if let decRange = Range(match.range(at: 2), in: out) {
                if let cp = UInt32(out[decRange], radix: 10) {
                    valid = isValidXMLCodePoint(cp)
                } else {
                    valid = false
                }
            } else {
                valid = false
            }
            if !valid, let fullRange = Range(match.range, in: out) {
                let literal = out[fullRange]
                out.replaceSubrange(fullRange, with: "&amp;" + literal.dropFirst())
            }
        }
        return Data(out.utf8)
    }

    private static func isValidXMLCodePoint(_ cp: UInt32) -> Bool {
        cp == 0x9
            || cp == 0xA
            || cp == 0xD
            || (cp >= 0x20 && cp <= 0xD7FF)
            || (cp >= 0xE000 && cp <= 0xFFFD)
            || (cp >= 0x10000 && cp <= 0x10FFFF)
    }

    private var rootElement: String?

    static func parse(_ data: Data) throws -> [WebDAVParsedResponse] {
        try autoreleasepool {
            let xmlData: Data
            if containsNumericEntityMarker(data) {
                let xmlString = String(decoding: data, as: UTF8.self)
                xmlData = sanitizeNumericEntities(xmlString)
            } else {
                xmlData = data
            }
            let delegate = WebDAVMultistatusParser()
            let parser = XMLParser(data: xmlData)
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), parser.parserError == nil, delegate.rootElement == "multistatus" else {
                throw StorageError(.other, "WebDAV 返回了无效的目录列表")
            }
            return delegate.results
        }
    }

    private static func localTagName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...]).lowercased()
        }
        return elementName.lowercased()
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39)
            || (b >= 0x41 && b <= 0x5A)
            || (b >= 0x61 && b <= 0x7A)
            || b == 0x5F
    }

    private static func is2xxStatus(_ status: String?) -> Bool {
        guard let status else { return true }
        let utf8 = status.utf8
        var i = utf8.startIndex
        let end = utf8.endIndex
        while i < end {
            if utf8[i] == 0x32 { // '2'
                let prevIsWord = (i > utf8.startIndex) && isWordByte(utf8[utf8.index(before: i)])
                let i1 = utf8.index(after: i)
                if !prevIsWord && i1 < end {
                    let i2 = utf8.index(after: i1)
                    if i2 < end {
                        let b1 = utf8[i1]
                        let b2 = utf8[i2]
                        if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39 {
                            let i3 = utf8.index(after: i2)
                            let nextIsWord = (i3 < end) && isWordByte(utf8[i3])
                            if !nextIsWord {
                                return true
                            }
                        }
                    }
                }
            }
            utf8.formIndex(after: &i)
        }
        return false
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = Self.localTagName(elementName)
        if rootElement == nil { rootElement = local }
        switch local {
        case "response":
            inResponse = true
            currentHref = nil
            propStats = []
            currentPropStat = nil
            directProps = PropStatBlock()
            inResourceType = false
            activeTextTag = nil
            textBuffer = ""
        case "propstat" where inResponse:
            currentPropStat = PropStatBlock()
        case "resourcetype" where inResponse:
            inResourceType = true
        case "collection" where inResponse && inResourceType:
            if currentPropStat != nil {
                currentPropStat?.isCollection = true
            } else {
                directProps.isCollection = true
            }
        case "href" where inResponse && currentHref == nil && currentPropStat == nil:
            activeTextTag = "href"
            textBuffer = ""
        case "getcontentlength" where inResponse,
             "getlastmodified" where inResponse,
             "getetag" where inResponse,
             "status" where inResponse && currentPropStat != nil:
            activeTextTag = local
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeTextTag != nil {
            textBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if activeTextTag != nil {
            textBuffer.append(String(decoding: CDATABlock, as: UTF8.self))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inResponse else { return }
        let local = Self.localTagName(elementName)
        switch local {
        case "href" where activeTextTag == "href":
            currentHref = textBuffer
            activeTextTag = nil
        case "getcontentlength" where activeTextTag == "getcontentlength":
            let val = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentPropStat != nil {
                currentPropStat?.contentLength = val
            } else {
                directProps.contentLength = val
            }
            activeTextTag = nil
        case "getetag" where activeTextTag == "getetag":
            let val = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentPropStat != nil {
                currentPropStat?.etag = val
            } else {
                directProps.etag = val
            }
            activeTextTag = nil
        case "getlastmodified" where activeTextTag == "getlastmodified":
            let val = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentPropStat != nil {
                currentPropStat?.lastModified = val
            } else {
                directProps.lastModified = val
            }
            activeTextTag = nil
        case "status" where activeTextTag == "status":
            currentPropStat?.status = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            activeTextTag = nil
        case "resourcetype":
            inResourceType = false
        case "propstat":
            if let ps = currentPropStat {
                propStats.append(ps)
                currentPropStat = nil
            }
        case "response":
            var merged = WebDAVParsedResponse(href: currentHref)
            let blocks = propStats.isEmpty ? [directProps] : propStats.filter { Self.is2xxStatus($0.status) }
            for b in blocks {
                if b.isCollection { merged.isCollection = true }
                if let len = b.contentLength, !len.isEmpty { merged.contentLength = len }
                if let etag = b.etag { merged.etag = etag }
                if let mod = b.lastModified, !mod.isEmpty { merged.lastModified = mod }
            }
            results.append(merged)
            inResponse = false
        default:
            break
        }
    }
}
