import Foundation
import Testing
import TidyreelModels
@testable import TidyreelStorage

// MARK: - Shared Contract Seed & Helpers

let contractSeed: [String: Int] = [
    "/剧集/示例 [1080p]/第01集.mkv": 10,
    "/剧集/示例 [1080p]/S01E02 (final).mkv": 20,
    "/a.txt": 5,
    "/b.txt": 7,
    "/空 目录/x.nfo": 1,
]

func expectStorageError<T>(
    _ code: StorageErrorCode,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        Issue.record("Expected StorageError(\(code)), but operation succeeded")
    } catch let err as StorageError {
        #expect(err.code == code, "Expected \(code), got \(err.code): \(err.message)")
    } catch {
        Issue.record("Expected StorageError(\(code)), got unexpected error: \(error)")
    }
}

func entrySizes(_ backend: any StorageBackend, _ dir: String) async throws -> [String: Int64] {
    let entries = try await backend.list(dir)
    var out: [String: Int64] = [:]
    for e in entries {
        out[e.name] = e.isDir ? -1 : e.size
    }
    return out
}

func runStorageContract(
    make: ([String: Int]) async throws -> (backend: any StorageBackend, cleanup: @Sendable () async -> Void)
) async throws {
    // 1. list direct children with CJK & brackets + missing dir
    do {
        let (be, cleanup) = try await make(contractSeed)
        defer { Task { await cleanup() } }

        let subSizes = try await entrySizes(be, "/剧集/示例 [1080p]")
        #expect(subSizes == [
            "第01集.mkv": 10,
            "S01E02 (final).mkv": 20,
        ])

        let rootEntries = try await be.list("/")
        var rootMap: [String: Bool] = [:]
        for e in rootEntries { rootMap[e.name] = e.isDir }
        #expect(rootMap == ["剧集": true, "a.txt": false, "b.txt": false, "空 目录": true])

        let firstEp = try #require(
            try await be.list("/剧集/示例 [1080p]").first(where: { $0.name == "第01集.mkv" })
        )
        #expect(firstEp.path == "/剧集/示例 [1080p]/第01集.mkv")

        await expectStorageError(.notFound) {
            try await be.list("/nope")
        }

        // exists
        #expect(try await be.exists("/a.txt") == true)
        #expect(try await be.exists("/剧集/示例 [1080p]") == true)
        #expect(try await be.exists("/剧集/示例 [1080p]/第01集.mkv") == true)
        #expect(try await be.exists("/nope.txt") == false)
        #expect(try await be.exists("/剧集/nope") == false)

        // mkdirs creates parents and is idempotent
        try await be.mkdirs("/新 库/电影 (2020)/extras")
        try await be.mkdirs("/新 库/电影 (2020)/extras")
        try await be.mkdirs("/剧集")
        #expect(try await be.list("/新 库/电影 (2020)/extras").isEmpty)
        let newLib = try await be.list("/新 库")
        #expect(newLib.count == 1 && newLib[0].isDir == true)

        // ping
        try await be.ping()
        await be.close()
        await cleanup()
    }

    // 2. rename & renameMany never overwrite + directory rename preserves children
    do {
        let (be, cleanup) = try await make(contractSeed)
        try await be.rename("/剧集/示例 [1080p]/第01集.mkv", newName: "Show - S01E01 [x].mkv")
        #expect(try await entrySizes(be, "/剧集/示例 [1080p]") == [
            "Show - S01E01 [x].mkv": 10,
            "S01E02 (final).mkv": 20,
        ])
        await expectStorageError(.alreadyExists) {
            try await be.rename("/a.txt", newName: "b.txt")
        }
        let rootAfter = try await entrySizes(be, "/")
        #expect(rootAfter["a.txt"] == 5)
        #expect(rootAfter["b.txt"] == 7)

        await expectStorageError(.notFound) {
            try await be.rename("/nope.txt", newName: "x.txt")
        }

        try await be.rename("/空 目录", newName: "已整理")
        #expect(try await be.exists("/空 目录") == false)
        #expect(try await entrySizes(be, "/已整理") == ["x.nfo": 1])

        await be.close()
        await cleanup()
    }

    // 3. renameMany
    do {
        let (be, cleanup) = try await make(contractSeed)
        try await be.renameMany("/剧集/示例 [1080p]", names: [
            "第01集.mkv": "S01E01.mkv",
            "S01E02 (final).mkv": "S01E02.mkv",
        ])
        #expect(try await entrySizes(be, "/剧集/示例 [1080p]") == [
            "S01E01.mkv": 10,
            "S01E02.mkv": 20,
        ])
        await expectStorageError(.alreadyExists) {
            try await be.renameMany("/", names: ["a.txt": "b.txt"])
        }
        #expect((try await entrySizes(be, "/"))["b.txt"] == 7)
        await be.close()
        await cleanup()
    }

    // 4. move, remove, write & read
    do {
        let (be, cleanup) = try await make(contractSeed)
        try await be.mkdirs("/库/电影")
        try await be.move(srcDir: "/", dstDir: "/库/电影", names: ["a.txt"])
        #expect(try await entrySizes(be, "/库/电影") == ["a.txt": 5])
        #expect(try await be.exists("/a.txt") == false)

        try await be.mkdirs("/c")
        try await be.move(srcDir: "/", dstDir: "/c", names: ["b.txt"])
        try await be.rename("/c/b.txt", newName: "a.txt")
        await expectStorageError(.alreadyExists) {
            try await be.move(srcDir: "/c", dstDir: "/库/电影", names: ["a.txt"])
        }
        #expect(try await entrySizes(be, "/库/电影") == ["a.txt": 5])
        #expect(try await entrySizes(be, "/c") == ["a.txt": 7])

        try await be.mkdirs("/to")
        try await be.move(srcDir: "/", dstDir: "/to", names: ["空 目录"])
        #expect(try await entrySizes(be, "/to/空 目录") == ["x.nfo": 1])

        await expectStorageError(.notFound) {
            try await be.move(srcDir: "/", dstDir: "/missing", names: ["x.txt"])
        }

        // write & read
        let xmlBytes = Data("<tvshow><title>示例</title></tvshow>".utf8)
        try await be.write("/剧集/新 剧 (2024)/tvshow.nfo", bytes: xmlBytes)
        #expect(try await be.read("/剧集/新 剧 (2024)/tvshow.nfo") == xmlBytes)
        #expect(try await be.exists("/剧集/新 剧 (2024)/tvshow.nfo") == true)

        await expectStorageError(.alreadyExists) {
            try await be.write("/库/电影/a.txt", bytes: Data([1, 2]))
        }
        await expectStorageError(.notFound) {
            _ = try await be.read("/nope.nfo")
        }

        // remove recursive
        try await be.remove(dir: "/", names: ["剧集"])
        #expect(try await be.exists("/剧集/示例 [1080p]/第01集.mkv") == false)
        await expectStorageError(.notFound) {
            try await be.remove(dir: "/", names: ["nope.txt"])
        }

        await be.close()
        await cleanup()
    }
}

// MARK: - In-Memory Mock Tree & Mock Transports

final class MockTree: @unchecked Sendable {
    private let lock = NSLock()
    var nodes: [String: Int] = ["/": -1]
    var content: [String: Data] = [:]

    init(_ files: [String: Int] = [:]) {
        for (path, size) in files {
            mkdirsUnlocked(posixDirname(path))
            nodes[path] = size
            content[path] = Data(repeating: 0, count: max(0, size))
        }
    }

    func withLock<T>(_ body: (MockTree) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    func isDirUnlocked(_ path: String) -> Bool {
        nodes[path] == -1
    }

    func mkdirsUnlocked(_ dir: String) {
        var cur = dir
        while cur != "/" && nodes[cur] == nil {
            nodes[cur] = -1
            cur = posixDirname(cur)
        }
    }

    func childrenUnlocked(_ dir: String) -> [String] {
        nodes.keys
            .filter { $0 != "/" && posixDirname($0) == dir }
            .sorted()
    }

    func relocateUnlocked(from: String, to: String) {
        let toRemove = nodes.keys.filter { $0 == to || $0.hasPrefix(to + "/") }
        for k in toRemove {
            nodes.removeValue(forKey: k)
            content.removeValue(forKey: k)
        }
        let moving = nodes.keys.filter { $0 == from || $0.hasPrefix(from + "/") }
        for k in moving {
            let suffix = String(k.dropFirst(from.count))
            let dstKey = to + suffix
            if let sz = nodes.removeValue(forKey: k) {
                nodes[dstKey] = sz
            }
            if let data = content.removeValue(forKey: k) {
                content[dstKey] = data
            }
        }
    }

    func deleteUnlocked(_ path: String) {
        let toDelete = nodes.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        for k in toDelete {
            nodes.removeValue(forKey: k)
            content.removeValue(forKey: k)
        }
    }
}

func makeHTTPResponse(
    url: URL,
    status: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

final class ClosureHTTPTransport: StorageHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Bool) async throws -> (Data, HTTPURLResponse)
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        try await handler(request, followRedirects)
    }
}

final class MockAlistTransport: StorageHTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    let tree: MockTree
    let password: String
    let origin: String
    var token = "tok-1"
    var logins = 0
    var maxPerPage: Int?
    var failNext: (Int, String)?
    var listRequests: [[String: Any]] = []
    var calls: [String] = []
    var batchRenameSupported = true

    init(
        files: [String: Int],
        password: String = "pw",
        origin: String = "http://alist.local"
    ) {
        self.tree = MockTree(files)
        self.password = password
        self.origin = origin
    }

    func expireToken() {
        lock.lock()
        defer { lock.unlock() }
        token = "expired-\(logins + 1)"
    }

    private func jsonReply(url: URL, code: Int, message: String, data: Any? = nil) -> (Data, HTTPURLResponse) {
        var obj: [String: Any] = ["code": code, "message": message]
        obj["data"] = data ?? NSNull()
        let bytes = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return (bytes, makeHTTPResponse(url: url, status: 200, headers: ["Content-Type": "application/json; charset=utf-8"]))
    }

    func send(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        try sendSync(request)
    }

    private func sendSync(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        let apiPath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        lock.lock()
        defer { lock.unlock() }

        if request.httpMethod == "GET" && apiPath.hasPrefix("d/") {
            let decodedSegs = comps.percentEncodedPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .dropFirst()
                .map { String($0).removingPercentEncoding ?? String($0) }
            let filePath = "/" + decodedSegs.joined(separator: "/")
            return tree.withLock { t in
                guard t.nodes[filePath] != nil else {
                    return (Data(), makeHTTPResponse(url: url, status: 404))
                }
                return (t.content[filePath] ?? Data(), makeHTTPResponse(url: url, status: 200))
            }
        }

        if apiPath == "api/fs/put" {
            if request.value(forHTTPHeaderField: "Authorization") != token {
                return jsonReply(url: url, code: 401, message: "token is invalidated")
            }
            let rawFilePath = request.value(forHTTPHeaderField: "File-Path") ?? ""
            let path = rawFilePath.removingPercentEncoding ?? rawFilePath
            let bytes = request.httpBody ?? Data()
            tree.withLock { t in
                t.mkdirsUnlocked(posixDirname(path))
                t.nodes[path] = bytes.count
                t.content[path] = bytes
            }
            calls.append(apiPath)
            return jsonReply(url: url, code: 200, message: "success")
        }

        let body = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]) ?? [:]

        if apiPath == "api/auth/login" {
            let u = body["username"] as? String
            let p = body["password"] as? String
            if u != "admin" || p != password {
                return jsonReply(url: url, code: 400, message: "password is incorrect")
            }
            logins += 1
            token = "tok-\(logins + 1)"
            return jsonReply(url: url, code: 200, message: "success", data: ["token": token])
        }

        if request.value(forHTTPHeaderField: "Authorization") != token {
            return jsonReply(url: url, code: 401, message: "token is invalidated")
        }

        if let (failCode, failMsg) = failNext {
            failNext = nil
            return jsonReply(url: url, code: failCode, message: failMsg)
        }

        let notFoundMsg = "object not found"
        calls.append(apiPath)

        switch apiPath {
        case "api/fs/batch_rename" where batchRenameSupported:
            let dir = (body["src_dir"] as? String) ?? "/"
            let objs = (body["rename_objects"] as? [[String: Any]]) ?? []
            return tree.withLock { t in
                for o in objs {
                    let src = posixJoin(dir, (o["src_name"] as? String) ?? "")
                    let dst = posixJoin(dir, (o["new_name"] as? String) ?? "")
                    if t.nodes[src] == nil {
                        return jsonReply(url: url, code: 500, message: notFoundMsg)
                    }
                    t.relocateUnlocked(from: src, to: dst)
                }
                return jsonReply(url: url, code: 200, message: "success")
            }

        case "api/fs/get":
            let path = (body["path"] as? String) ?? "/"
            return tree.withLock { t in
                guard t.nodes[path] != nil else {
                    return jsonReply(url: url, code: 500, message: "failed get: \(notFoundMsg)")
                }
                let isDir = t.isDirUnlocked(path)
                let encodedPath = path.split(separator: "/", omittingEmptySubsequences: true)
                    .map { encodeURIComponent(String($0)) }
                    .joined(separator: "/")
                let rawURL = isDir ? "" : "\(origin)/d/\(encodedPath)"
                return jsonReply(url: url, code: 200, message: "success", data: [
                    "name": posixBasename(path),
                    "is_dir": isDir,
                    "raw_url": rawURL,
                ])
            }

        case "api/fs/list":
            listRequests.append(body)
            let dir = (body["path"] as? String) ?? "/"
            return tree.withLock { t in
                guard t.isDirUnlocked(dir) else {
                    return jsonReply(url: url, code: 500, message: "failed get: \(notFoundMsg)")
                }
                let all = t.childrenUnlocked(dir)
                let page = (body["page"] as? Int) ?? 1
                var per = (body["per_page"] as? Int) ?? all.count
                if per <= 0 || (maxPerPage != nil && per > maxPerPage!) {
                    per = maxPerPage ?? max(1, all.count)
                }
                let startIdx = min(all.count, max(0, (page - 1) * per))
                let endIdx = min(all.count, startIdx + per)
                let slice = all[startIdx..<endIdx]
                let items: [[String: Any]] = slice.map { k in
                    let isDir = t.isDirUnlocked(k)
                    return [
                        "name": posixBasename(k),
                        "is_dir": isDir,
                        "size": isDir ? 0 : (t.nodes[k] ?? 0),
                        "modified": "2024-01-02T03:04:05Z",
                    ]
                }
                return jsonReply(url: url, code: 200, message: "success", data: [
                    "content": items,
                    "total": all.count,
                ])
            }

        case "api/fs/mkdir":
            let path = (body["path"] as? String) ?? "/"
            tree.withLock { $0.mkdirsUnlocked(path) }
            return jsonReply(url: url, code: 200, message: "success")

        case "api/fs/rename":
            let path = (body["path"] as? String) ?? "/"
            let newName = (body["name"] as? String) ?? ""
            return tree.withLock { t in
                guard t.nodes[path] != nil else {
                    return jsonReply(url: url, code: 500, message: notFoundMsg)
                }
                t.relocateUnlocked(from: path, to: posixJoin(posixDirname(path), newName))
                return jsonReply(url: url, code: 200, message: "success")
            }

        case "api/fs/move":
            let srcDir = (body["src_dir"] as? String) ?? "/"
            let dstDir = (body["dst_dir"] as? String) ?? "/"
            let names = (body["names"] as? [String]) ?? []
            return tree.withLock { t in
                guard t.isDirUnlocked(dstDir) else {
                    return jsonReply(url: url, code: 500, message: notFoundMsg)
                }
                for n in names {
                    let from = posixJoin(srcDir, n)
                    guard t.nodes[from] != nil else {
                        return jsonReply(url: url, code: 500, message: notFoundMsg)
                    }
                    t.relocateUnlocked(from: from, to: posixJoin(dstDir, n))
                }
                return jsonReply(url: url, code: 200, message: "success")
            }

        case "api/fs/remove":
            let dir = (body["dir"] as? String) ?? "/"
            let names = (body["names"] as? [String]) ?? []
            tree.withLock { t in
                for n in names {
                    t.deleteUnlocked(posixJoin(dir, n))
                }
            }
            return jsonReply(url: url, code: 200, message: "success")

        default:
            return (Data("?".utf8), makeHTTPResponse(url: url, status: 404))
        }
    }
}

final class MockWebDAVTransport: StorageHTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    let tree: MockTree
    let mount: String
    let absoluteHrefs: Bool
    let redirectCollections: Bool
    let caseInsensitive: Bool
    var seenWirePaths: [String] = []
    var seenDestinations: [String] = []

    init(
        files: [String: Int],
        mount: String = "/dav",
        absoluteHrefs: Bool = false,
        redirectCollections: Bool = false,
        caseInsensitive: Bool = false
    ) {
        self.tree = MockTree(files)
        self.mount = mount
        self.absoluteHrefs = absoluteHrefs
        self.redirectCollections = redirectCollections
        self.caseInsensitive = caseInsensitive
    }

    private func decodeURLPath(_ url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        let segs = comps.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        return "/" + segs.joined(separator: "/")
    }

    private func localPath(for url: URL) -> String? {
        let full = decodeURLPath(url)
        if mount.isEmpty { return full }
        if full != mount && !full.hasPrefix(mount + "/") { return nil }
        let rest = String(full.dropFirst(mount.count))
        return rest.isEmpty ? "/" : rest
    }

    private func buildHref(_ path: String, originURL: URL) -> String {
        let mountSegs = mount.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let pathSegs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let all = mountSegs + pathSegs
        var h = "/" + all.map(encodePathSegment).joined(separator: "/")
        if tree.isDirUnlocked(path) && h != "/" {
            h += "/"
        }
        if absoluteHrefs {
            var comps = URLComponents()
            comps.scheme = originURL.scheme
            comps.host = originURL.host
            comps.port = originURL.port
            comps.percentEncodedPath = h
            return comps.string ?? h
        }
        return h
    }

    private func entryXML(_ path: String, originURL: URL) -> String {
        let isDir = tree.isDirUnlocked(path)
        let resourcePart = isDir
            ? "<D:resourcetype><D:collection/></D:resourcetype>"
            : "<D:resourcetype/><D:getcontentlength>\(tree.nodes[path] ?? 0)</D:getcontentlength>"
        return "<D:response><D:href>\(buildHref(path, originURL: originURL))</D:href><D:propstat><D:prop>"
            + resourcePart
            + "<D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified>"
            + "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    func send(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        sendSync(request)
    }

    private func sendSync(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        let wirePath = comps.percentEncodedPath

        lock.lock()
        defer { lock.unlock() }

        seenWirePaths.append(wirePath)

        let expectedAuth = "Basic " + Data("admin:pw".utf8).base64EncodedString()
        if request.value(forHTTPHeaderField: "Authorization") != expectedAuth {
            return (Data(), makeHTTPResponse(url: url, status: 401, headers: ["WWW-Authenticate": #"Basic realm="x""#]))
        }

        guard let path = localPath(for: url) else {
            return (Data(), makeHTTPResponse(url: url, status: 404))
        }

        let method = (request.httpMethod ?? "GET").uppercased()
        if redirectCollections && method == "PROPFIND" && tree.isDirUnlocked(path) && !wirePath.hasSuffix("/") {
            return (Data(), makeHTTPResponse(url: url, status: 301, headers: ["Location": wirePath + "/"]))
        }

        return tree.withLock { t in
            switch method {
            case "PROPFIND":
                guard t.nodes[path] != nil else {
                    return (Data(), makeHTTPResponse(url: url, status: 404))
                }
                let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
                let paths = [path] + (depth == "0" ? [] : t.childrenUnlocked(path))
                let xml = #"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">"#
                    + paths.map { entryXML($0, originURL: url) }.joined()
                    + "</D:multistatus>"
                return (
                    Data(xml.utf8),
                    makeHTTPResponse(url: url, status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"])
                )

            case "MKCOL":
                if t.nodes[path] != nil {
                    return (Data(), makeHTTPResponse(url: url, status: 405))
                }
                if !t.isDirUnlocked(posixDirname(path)) {
                    return (Data(), makeHTTPResponse(url: url, status: 409))
                }
                t.nodes[path] = -1
                return (Data(), makeHTTPResponse(url: url, status: 201))

            case "MOVE":
                guard t.nodes[path] != nil else {
                    return (Data(), makeHTTPResponse(url: url, status: 404))
                }
                let rawDst = request.value(forHTTPHeaderField: "Destination") ?? ""
                seenDestinations.append(rawDst)
                guard let dstURL = URL(string: rawDst),
                      let dst = localPath(for: dstURL),
                      t.isDirUnlocked(posixDirname(dst)) else {
                    return (Data(), makeHTTPResponse(url: url, status: 409))
                }
                let dstExists = caseInsensitive
                    ? t.nodes.keys.contains(where: { $0.lowercased() == dst.lowercased() })
                    : (t.nodes[dst] != nil)
                if dstExists && request.value(forHTTPHeaderField: "Overwrite") == "F" {
                    return (Data(), makeHTTPResponse(url: url, status: 412))
                }
                t.relocateUnlocked(from: path, to: dst)
                return (Data(), makeHTTPResponse(url: url, status: dstExists ? 204 : 201))

            case "DELETE":
                guard t.nodes[path] != nil else {
                    return (Data(), makeHTTPResponse(url: url, status: 404))
                }
                t.deleteUnlocked(path)
                return (Data(), makeHTTPResponse(url: url, status: 204))

            case "GET":
                guard t.nodes[path] != nil && !t.isDirUnlocked(path) else {
                    return (Data(), makeHTTPResponse(url: url, status: 404))
                }
                return (t.content[path] ?? Data(), makeHTTPResponse(url: url, status: 200))

            case "PUT":
                guard t.isDirUnlocked(posixDirname(path)) else {
                    return (Data(), makeHTTPResponse(url: url, status: 409))
                }
                if t.nodes[path] != nil && request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                    return (Data(), makeHTTPResponse(url: url, status: 412))
                }
                let bytes = request.httpBody ?? Data()
                t.nodes[path] = bytes.count
                t.content[path] = bytes
                return (Data(), makeHTTPResponse(url: url, status: 201))

            default:
                return (Data(), makeHTTPResponse(url: url, status: 405))
            }
        }
    }
}
