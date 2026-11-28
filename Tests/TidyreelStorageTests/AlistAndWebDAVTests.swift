import Foundation
import Testing
import TidyreelModels
@testable import TidyreelStorage

private func alistCfg(_ endpoint: String = "http://alist.local/") -> ConnectionConfig {
    ConnectionConfig(id: "a", name: "alist", type: .alist, endpoint: endpoint, username: "admin")
}

private func webdavCfg(_ endpoint: String = "http://dav.local/dav", username: String? = "admin") -> ConnectionConfig {
    ConnectionConfig(id: "w", name: "dav", type: .webdav, endpoint: endpoint, username: username)
}

@Suite("AlistBackend & WebDAVBackend Tests")
struct AlistAndWebDAVTests {
    // MARK: - Alist Contract & Unit Tests

    @Test("AlistBackend satisfies storage contract")
    func alistContract() async throws {
        try await runStorageContract { files in
            let mock = MockAlistTransport(files: files)
            let be = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: mock)
            return (be, {})
        }
    }

    @Test("AlistBackend handles login, token caching, 401 re-login, and auth errors")
    func alistAuthLifecycle() async throws {
        let mock = MockAlistTransport(files: ["/a.txt": 1])
        let be = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw", token: ""), transport: mock)

        try await be.ping()
        #expect(mock.logins == 1)

        mock.expireToken()
        #expect(try await be.exists("/a.txt") == true)
        #expect(mock.logins == 2)

        // Supplied token used directly without login
        let mockDirect = MockAlistTransport(files: ["/a.txt": 1])
        let beDirect = AlistBackend(config: alistCfg(), credentials: Credentials(token: "tok-1"), transport: mockDirect)
        try await beDirect.ping()
        #expect(mockDirect.logins == 0)

        // Expired supplied token without password -> unauthorized
        let beStale = AlistBackend(config: alistCfg(), credentials: Credentials(token: "stale"), transport: mockDirect)
        await expectStorageError(.unauthorized) {
            try await beStale.ping()
        }

        // Wrong password -> unauthorized
        let beWrong = AlistBackend(config: alistCfg(), credentials: Credentials(password: "bad"), transport: mock)
        await expectStorageError(.unauthorized) {
            try await beWrong.ping()
        }
    }

    @Test("AlistBackend paginates capped per_page, passes refresh only on page 1, and maps error codes")
    func alistPaginationAndErrorMapping() async throws {
        var files: [String: Int] = [:]
        for i in 0..<23 { files["/d/文件 \(i).mkv"] = i }
        let mock = MockAlistTransport(files: files)
        mock.maxPerPage = 10
        let be = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: mock)

        let listed = try await be.list("/d", refresh: true)
        #expect(Set(listed.map(\.name)) == Set((0..<23).map { "文件 \($0).mkv" }))
        #expect(mock.listRequests.compactMap { $0["page"] as? Int } == [1, 2, 3])
        #expect(mock.listRequests.compactMap { $0["refresh"] as? Bool } == [true, false, false])

        let cases: [((Int, String), StorageErrorCode)] = [
            ((403, "permission denied"), .unauthorized),
            ((404, "x"), .notFound),
            ((429, "x"), .rateLimited),
            ((503, "x"), .network),
            ((500, "failed get: object not found"), .notFound),
            ((500, #"rename D:\bit\d: Access is denied."#), .busy),
            ((500, "storage is busy"), .other),
        ]
        for (failSpec, expectedCode) in cases {
            mock.failNext = failSpec
            await expectStorageError(expectedCode) {
                _ = try await be.list("/")
            }
        }
    }

    @Test("AlistBackend handles non-JSON HTML 200, HTTP 404, HTTP 500, and network transport errors")
    func alistAbnormalHTTPResponses() async throws {
        let htmlTransport = ClosureHTTPTransport { req, _ in
            (Data("<html>gateway</html>".utf8), makeHTTPResponse(url: req.url!, status: 200))
        }
        let beHtml = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: htmlTransport)
        await expectStorageError(.other) { try await beHtml.ping() }

        let notFoundTransport = ClosureHTTPTransport { req, _ in
            (Data("nope".utf8), makeHTTPResponse(url: req.url!, status: 404))
        }
        let be404 = AlistBackend(config: alistCfg(), credentials: Credentials(token: "tok"), transport: notFoundTransport)
        await expectStorageError(.notFound) { try await be404.ping() }

        let server500Transport = ClosureHTTPTransport { req, _ in
            (Data("boom".utf8), makeHTTPResponse(url: req.url!, status: 500))
        }
        let be500 = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: server500Transport)
        await expectStorageError(.other) { try await be500.ping() }

        let unreachableTransport = ClosureHTTPTransport { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let beOffline = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: unreachableTransport)
        await expectStorageError(.network) { try await beOffline.ping() }
    }

    @Test("AlistBackend batch_rename, fallback to rename on 404/405, dup/case collision checks, and mkdirs race")
    func alistBatchRenameAndCollisions() async throws {
        let mock = MockAlistTransport(files: ["/d/1": 1, "/d/2": 1])
        let be = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: mock)

        try await be.renameMany("/d", names: ["1": "a", "2": "b"])
        #expect(mock.calls.filter { $0.contains("rename") } == ["api/fs/batch_rename"])
        #expect(mock.tree.nodes["/d/a"] == 1 && mock.tree.nodes["/d/b"] == 1)

        // Fallback on older Alist without batch_rename (HTTP 404)
        let mockOld = MockAlistTransport(files: ["/d/1": 1, "/d/2": 1])
        mockOld.batchRenameSupported = false
        let beOld = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: mockOld)
        try await beOld.renameMany("/d", names: ["1": "a", "2": "b"])
        #expect(mockOld.calls.filter { $0 == "api/fs/rename" }.count == 2)

        // Duplicate targets differing only in case
        await expectStorageError(.alreadyExists) {
            try await be.renameMany("/d", names: ["a": "Show.mkv", "b": "show.mkv"])
        }

        // Invalid child names
        for bad in ["", ".", "..", "sub/x", #"sub\x"#] {
            await expectStorageError(.other) { try await be.rename("/d/a", newName: bad) }
            await expectStorageError(.other) { try await be.renameMany("/d", names: ["a": bad]) }
            await expectStorageError(.other) { try await be.move(srcDir: "/d", dstDir: "/d", names: [bad]) }
            await expectStorageError(.other) { try await be.remove(dir: "/d", names: [bad]) }
        }

        // mkdirs concurrent alreadyExists race
        final class RaceState: @unchecked Sendable {
            var gets = 0
            var isDir = true
        }
        let state = RaceState()
        let raceTransport = ClosureHTTPTransport { req, _ in
            let path = req.url!.path
            if path.hasSuffix("/api/fs/get") {
                state.gets += 1
                if state.gets == 1 {
                    let data = Data(#"{"code":500,"message":"object not found","data":null}"#.utf8)
                    return (data, makeHTTPResponse(url: req.url!, status: 200))
                }
                let data = Data(#"{"code":200,"message":"success","data":{"name":"race","is_dir":\#(state.isDir)}}"#.utf8)
                return (data, makeHTTPResponse(url: req.url!, status: 200))
            }
            if path.hasSuffix("/api/fs/mkdir") {
                let data = Data(#"{"code":500,"message":"file already exists","data":null}"#.utf8)
                return (data, makeHTTPResponse(url: req.url!, status: 200))
            }
            return (Data(), makeHTTPResponse(url: req.url!, status: 404))
        }
        let beRace = AlistBackend(config: alistCfg(), credentials: Credentials(token: "tok"), transport: raceTransport)
        try await beRace.mkdirs("/race")
        #expect(state.gets == 2)

        state.gets = 0
        state.isDir = false
        await expectStorageError(.alreadyExists) {
            try await beRace.mkdirs("/race")
        }
    }

    @Test("AlistBackend sends per-dir password and supports readRange 206, 416, headers, and 200 cap")
    func alistDirPasswordsAndReadRange() async throws {
        final class RangeState: @unchecked Sendable {
            let lock = NSLock()
            var mode = "206"
            var seenListPasswords: [String: String] = [:]
            var seenGetPasswords: [String: String] = [:]
            var seenRange: String?
            var seenDriveAuth: String?
            let payload = Data((0..<256).map(UInt8.init))
        }
        let state = RangeState()

        let transport = ClosureHTTPTransport { req, _ in
            let url = req.url!
            if url.path == "/api/fs/list" {
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
                state.lock.withLock {
                    state.seenListPasswords[body["path"] as! String] = body["password"] as? String
                }
                let data = Data(#"{"code":200,"message":"success","data":{"content":[],"total":0}}"#.utf8)
                return (data, makeHTTPResponse(url: url, status: 200))
            }
            if url.path == "/api/fs/get" {
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
                let p = body["path"] as! String
                state.lock.withLock {
                    state.seenGetPasswords[p] = body["password"] as? String
                }
                if p == "/badurl.mkv" {
                    let bad = Data(#"{"code":200,"message":"success","data":{"name":"bad","is_dir":false,"raw_url":"http://[::bad-uri"}}"#.utf8)
                    return (bad, makeHTTPResponse(url: url, status: 200))
                }
                let obj: [String: Any] = [
                    "code": 200,
                    "message": "success",
                    "data": [
                        "name": "movie.mkv",
                        "is_dir": false,
                        "raw_url": "/d/movie.mkv",
                        "header": ["X-Drive-Auth": "drive-token"],
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: obj), makeHTTPResponse(url: url, status: 200))
            }
            if url.path == "/d/movie.mkv" {
                let rangeVal = req.value(forHTTPHeaderField: "Range")
                let driveAuth = req.value(forHTTPHeaderField: "X-Drive-Auth")
                let mode = state.lock.withLock { () -> String in
                    state.seenRange = rangeVal
                    state.seenDriveAuth = driveAuth
                    return state.mode
                }

                if mode == "206", let parsed = parseRangeHeader(rangeVal) {
                    if Int(parsed.start) >= state.payload.count {
                        return (Data(), makeHTTPResponse(url: url, status: 416))
                    }
                    let s = Int(parsed.start)
                    let e = min(state.payload.count, s + parsed.length)
                    return (state.payload.subdata(in: s..<e), makeHTTPResponse(url: url, status: 206))
                }
                return (state.payload, makeHTTPResponse(url: url, status: 200))
            }
            return (Data(), makeHTTPResponse(url: url, status: 404))
        }

        let creds = Credentials(
            token: "tok",
            dirPasswords: [
                "/": "root-pw",
                "/私密": "secret-1",
                "/私密/深层": "secret-2",
            ]
        )
        let be = AlistBackend(config: alistCfg("http://alist.local"), credentials: creds, transport: transport)

        try await be.ping()
        _ = try await be.list("/公开")
        _ = try await be.list("/私密")
        _ = try await be.list("/私密/深层/电影")

        #expect(state.seenGetPasswords["/"] == "root-pw")
        #expect(state.seenListPasswords["/公开"] == "root-pw")
        #expect(state.seenListPasswords["/私密"] == "secret-1")
        #expect(state.seenListPasswords["/私密/深层/电影"] == "secret-2")

        // 206 Partial Content
        let slice = try await be.readRange(path: "/私密/movie.mkv", start: 10, length: 5)
        #expect(Array(slice) == [10, 11, 12, 13, 14])
        #expect(state.seenRange == "bytes=10-14")
        #expect(state.seenDriveAuth == "drive-token")
        #expect(state.seenGetPasswords["/私密/movie.mkv"] == "secret-1")

        // 416 Past EOF
        #expect(try await be.readRange(path: "/私密/movie.mkv", start: 999, length: 10).isEmpty)

        // 200 OK within 512 KiB cap
        state.lock.withLock { state.mode = "200" }
        #expect(Array(try await be.readRange(path: "/私密/movie.mkv", start: 100, length: 4)) == [100, 101, 102, 103])

        // 200 OK beyond 512 KiB cap refuses full download
        await expectStorageError(.other) {
            _ = try await be.readRange(path: "/私密/movie.mkv", start: 1024 * 1024, length: 16)
        }

        // Malformed raw_url -> network error
        await expectStorageError(.network) {
            _ = try await be.read("/badurl.mkv")
        }
    }

    // MARK: - WebDAV Contract & Unit Tests

    @Test("WebDAVBackend satisfies storage contract across diverse mounts and redirect modes")
    func webdavMountContracts() async throws {
        let mountConfigs: [(mount: String, endpointSuffix: String, absolute: Bool, redirect: Bool)] = [
            ("/dav", "/dav", false, false),
            ("", "", false, false),
            ("", "/", false, false),
            ("/remote.php/webdav", "/remote.php/webdav", false, false),
            ("/网盘 1", "/网盘 1/", true, false),
            ("/webdav", "/webdav", false, true),
        ]

        for spec in mountConfigs {
            try await runStorageContract { files in
                let mock = MockWebDAVTransport(
                    files: files,
                    mount: spec.mount,
                    absoluteHrefs: spec.absolute,
                    redirectCollections: spec.redirect
                )
                let be = WebDAVBackend(
                    config: webdavCfg("http://dav.local\(spec.endpointSuffix)"),
                    credentials: Credentials(password: "pw"),
                    transport: mock
                )
                return (be, {})
            }
        }
    }

    @Test("WebDAVBackend handles case-only rename, wire percent-encoding, and auth omission")
    func webdavCaseOnlyRenameAndEncoding() async throws {
        // Case-insensitive server: folder case rename via monotonic temp names
        let mockCI = MockWebDAVTransport(
            files: [
                "/the office/S01E01.mkv": 1,
                "/d1/file.mkv": 1,
                "/d2/file.mkv": 2,
                "/d3/file.mkv": 3,
            ],
            caseInsensitive: true
        )
        let beCI = WebDAVBackend(config: webdavCfg(), credentials: Credentials(password: "pw"), transport: mockCI)
        try await beCI.rename("/the office", newName: "The Office")
        #expect(mockCI.tree.nodes["/The Office/S01E01.mkv"] == 1)
        #expect(mockCI.tree.nodes["/the office"] == nil)
        mockCI.lock.withLock { mockCI.seenDestinations.removeAll() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await beCI.rename("/d1/file.mkv", newName: "File.mkv") }
            group.addTask { try await beCI.rename("/d2/file.mkv", newName: "File.mkv") }
            group.addTask { try await beCI.rename("/d3/file.mkv", newName: "File.mkv") }
            try await group.waitForAll()
        }
        let tempDests = mockCI.seenDestinations.filter { $0.contains(".tidyreel-case-") }
        #expect(tempDests.count == 3 && Set(tempDests).count == 3)

        // Case-sensitive server with both /a.mkv and /A.mkv refuses overwrite
        let mockCS = MockWebDAVTransport(files: ["/a.mkv": 1, "/A.mkv": 2], caseInsensitive: false)
        let beCS = WebDAVBackend(config: webdavCfg(), credentials: Credentials(password: "pw"), transport: mockCS)
        await expectStorageError(.alreadyExists) {
            try await beCS.rename("/a.mkv", newName: "A.mkv")
        }

        // Wire percent-encoding check
        let mockEnc = MockWebDAVTransport(files: ["/电影 [1].mkv": 1])
        let beEnc = WebDAVBackend(config: webdavCfg(), credentials: Credentials(password: "pw"), transport: mockEnc)
        try await beEnc.rename("/电影 [1].mkv", newName: "电影 (2020).mkv")
        #expect(mockEnc.seenWirePaths == ["/dav/%E7%94%B5%E5%BD%B1%20%5B1%5D.mkv"])

        // Anonymous omits Authorization header
        final class AuthBox: @unchecked Sendable { var auth: String? }
        let authBox = AuthBox()
        let anonTransport = ClosureHTTPTransport { req, _ in
            authBox.auth = req.value(forHTTPHeaderField: "Authorization")
            let xml = #"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"/>"#
            return (Data(xml.utf8), makeHTTPResponse(url: req.url!, status: 207))
        }
        let beAnon = WebDAVBackend(config: webdavCfg(username: ""), credentials: Credentials(), transport: anonTransport)
        try await beAnon.ping()
        #expect(authBox.auth == nil)
    }

    @Test("Malformed WebDAV listings fail without yielding an empty or partial snapshot")
    func incompleteWebDAVListings() async throws {
        for body in ["", "<html/>", "<multistatus><response><href>/dav/movie.mkv</href></response>"] {
            let transport = ClosureHTTPTransport { req, _ in
                (Data(body.utf8), makeHTTPResponse(url: req.url!, status: 207))
            }
            let backend = WebDAVBackend(config: webdavCfg(), credentials: Credentials(), transport: transport)
            await expectStorageError(.other) { try await backend.list("/") }
            #expect(try await !backend.removeDirectoryIfEmpty("/folder", removingSystemFiles: true))
        }
    }

    @Test("WebDAVBackend Foundation.XMLParser handles custom prefixes, 404 propstats, relative hrefs, %, #, and invalid entities")
    func webdavXMLParserEdgeCases() async throws {
        let xml = """
        <?xml version="1.0"?>
        <ns-1:multistatus xmlns:ns-1="DAV:">
          <ns-1:response>
            <ns-1:href>/dav/sub/</ns-1:href>
            <ns-1:propstat>
              <ns-1:prop><ns-1:resourcetype><ns-1:collection/></ns-1:resourcetype></ns-1:prop>
              <ns-1:status>HTTP/1.1 200 OK</ns-1:status>
            </ns-1:propstat>
          </ns-1:response>
          <ns-1:response>
            <ns-1:href>100%25%20Love.mkv</ns-1:href>
            <ns-1:propstat>
              <ns-1:prop><ns-1:resourcetype/><ns-1:getcontentlength>42</ns-1:getcontentlength></ns-1:prop>
              <ns-1:status>HTTP/1.1 200 OK</ns-1:status>
            </ns-1:propstat>
          </ns-1:response>
          <ns-1:response>
            <ns-1:href>/dav/sub/Show #1 &amp;lt; &#38;gt; &#999999999;.mkv</ns-1:href>
            <ns-1:propstat>
              <ns-1:prop><ns-1:resourcetype/><ns-1:getcontentlength>99</ns-1:getcontentlength></ns-1:prop>
              <ns-1:status>HTTP/1.1 200 OK</ns-1:status>
            </ns-1:propstat>
            <ns-1:propstat>
              <ns-1:prop><ns-1:resourcetype><ns-1:collection/></ns-1:resourcetype><ns-1:getcontentlength>9999</ns-1:getcontentlength></ns-1:prop>
              <ns-1:status>HTTP/1.1 404 Not Found</ns-1:status>
            </ns-1:propstat>
          </ns-1:response>
          <ns-1:response>
            <ns-1:href>http://[::bad-uri</ns-1:href>
            <ns-1:propstat><ns-1:prop><ns-1:resourcetype/></ns-1:prop></ns-1:propstat>
          </ns-1:response>
        </ns-1:multistatus>
        """

        let transport = ClosureHTTPTransport { req, _ in
            (Data(xml.utf8), makeHTTPResponse(url: req.url!, status: 207))
        }
        let be = WebDAVBackend(config: webdavCfg(), credentials: Credentials(password: "pw"), transport: transport)
        let entries = try await be.list("/sub")
        #expect(entries.count == 2)
        #expect(entries[0].path == "/sub/100% Love.mkv")
        #expect(entries[0].name == "100% Love.mkv")
        #expect(entries[0].isDir == false && entries[0].size == 42)

        #expect(entries[1].name == "Show #1 &lt; &gt; &#999999999;.mkv")
        #expect(entries[1].isDir == false && entries[1].size == 99)
    }

    @Test("WebDAV deletes only with the strong ETag captured by a successful PROPFIND")
    func deleteWithScannedETag() async throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/ad.txt</d:href><d:propstat>
        <d:prop><d:resourcetype/><d:getetag>"original"</d:getetag></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """
        let transport = ClosureHTTPTransport { req, _ in
            if req.httpMethod == "PROPFIND" {
                return (Data(xml.utf8), makeHTTPResponse(url: req.url!, status: 207))
            }
            #expect(req.httpMethod == "DELETE")
            #expect(req.value(forHTTPHeaderField: "If-Match") == "\"original\"")
            return (Data(), makeHTTPResponse(url: req.url!, status: 412))
        }
        let backend = WebDAVBackend(config: webdavCfg(), credentials: Credentials(), transport: transport)
        let identity = try #require(try await backend.list("/").first?.deleteIdentity)
        #expect(identity == "\"original\"")
        for invalid in [nil, "*", "W/\"weak\"", "\"a\", \"b\""] as [String?] {
            await expectStorageError(.other) { try await backend.removeScannedFile("/ad.txt", identity: invalid) }
        }
        await expectStorageError(.other) { try await backend.removeScannedFile("/ad.txt", identity: identity) }
    }

    @Test("A lost DELETE response requires a new confirmation before another attempt")
    func noAutomaticDeleteRetry() async throws {
        actor Attempts {
            var count = 0
            func record() { count += 1 }
        }
        let attempts = Attempts()
        let transport = ClosureHTTPTransport { _, _ in
            await attempts.record()
            throw StorageError(.network, "lost response")
        }
        let dav = WebDAVBackend(config: webdavCfg(), credentials: Credentials(), transport: transport)
        let backend = ThrottledBackend(testing: dav, minIntervalMs: { 0 }, backoffMs: [0],
                                       sleepMs: { _ in }, nowMs: { 0 })
        await expectStorageError(.network) {
            try await backend.removeScannedFile("/a", identity: "\"original\"")
        }
        #expect(await attempts.count == 1)
    }

    @Test("WebDAVBackend readRange, cross-origin redirect auth stripping, 307 PUT redirect, and traversal checks")
    func webdavReadRangeRedirectsAndValidation() async throws {
        final class DavRangeBox: @unchecked Sendable {
            let lock = NSLock()
            var mode = "206"
            var cdnAuth: String?
            var cdnRange: String?
            var uploaded: Data?
            let payload = Data((0..<256).map(UInt8.init))
        }
        let box = DavRangeBox()

        let transport = ClosureHTTPTransport { req, _ in
            let url = req.url!
            let method = req.httpMethod ?? "GET"

            if url.host == "cdn.example.com" {
                let auth = req.value(forHTTPHeaderField: "Authorization")
                let rng = req.value(forHTTPHeaderField: "Range")
                box.lock.withLock {
                    box.cdnAuth = auth
                    box.cdnRange = rng
                }
                return (box.payload.subdata(in: 5..<9), makeHTTPResponse(url: url, status: 206))
            }
            if url.path == "/dav/redir.mkv" {
                return (Data(), makeHTTPResponse(url: url, status: 302, headers: ["Location": "https://cdn.example.com/blob"]))
            }
            if url.path == "/dav/badredir.mkv" {
                return (Data(), makeHTTPResponse(url: url, status: 302, headers: ["Location": "http://[::bad-uri"]))
            }
            if method == "PROPFIND" && url.path == "/dav/a.nfo" {
                return (Data(), makeHTTPResponse(url: url, status: 404))
            }
            if method == "PUT" && url.path == "/dav/a.nfo" {
                return (Data(), makeHTTPResponse(url: url, status: 307, headers: ["Location": "/dav/final/a.nfo"]))
            }
            if method == "PUT" && url.path == "/dav/final/a.nfo" {
                let body = req.httpBody
                box.lock.withLock { box.uploaded = body }
                return (Data(), makeHTTPResponse(url: url, status: 201))
            }
            if url.path == "/dav/movie.mkv" {
                let mode = box.lock.withLock { box.mode }
                if mode == "206", let parsed = parseRangeHeader(req.value(forHTTPHeaderField: "Range")) {
                    if Int(parsed.start) >= box.payload.count {
                        return (Data(), makeHTTPResponse(url: url, status: 416))
                    }
                    let s = Int(parsed.start)
                    let e = min(box.payload.count, s + parsed.length)
                    return (box.payload.subdata(in: s..<e), makeHTTPResponse(url: url, status: 206))
                }
                return (box.payload, makeHTTPResponse(url: url, status: 200))
            }
            return (Data(), makeHTTPResponse(url: url, status: 404))
        }

        let be = WebDAVBackend(config: webdavCfg(), credentials: Credentials(password: "pw"), transport: transport)

        // 206, 416, 404
        #expect(Array(try await be.readRange(path: "/movie.mkv", start: 20, length: 6)) == [20, 21, 22, 23, 24, 25])
        #expect(try await be.readRange(path: "/movie.mkv", start: 500, length: 8).isEmpty)
        await expectStorageError(.notFound) {
            _ = try await be.readRange(path: "/missing.mkv", start: 0, length: 8)
        }

        // Cross-origin redirect strips Authorization while preserving Range
        #expect(Array(try await be.readRange(path: "/redir.mkv", start: 5, length: 4)) == [5, 6, 7, 8])
        #expect(box.cdnAuth == nil)
        #expect(box.cdnRange == "bytes=5-8")

        // 200 OK cap
        box.lock.withLock { box.mode = "200" }
        #expect(Array(try await be.readRange(path: "/movie.mkv", start: 50, length: 4)) == [50, 51, 52, 53])
        await expectStorageError(.other) {
            _ = try await be.readRange(path: "/movie.mkv", start: 1024 * 1024, length: 16)
        }

        // 307 redirect on PUT
        try await be.write("/a.nfo", bytes: Data([1, 2, 3]))
        #expect(Array(box.uploaded ?? Data()) == [1, 2, 3])

        // Malformed redirect Location -> network error
        await expectStorageError(.network) {
            _ = try await be.read("/badredir.mkv")
        }

        // Traversal segments & invalid child names
        for bad in ["/../x", "/a/../../x", "/.", #"/..\evil"#, #"/a\b"#] {
            await expectStorageError(.other) { _ = try await be.list(bad) }
            await expectStorageError(.other) { _ = try await be.exists(bad) }
            await expectStorageError(.other) { try await be.mkdirs(bad) }
            await expectStorageError(.other) { _ = try await be.read(bad) }
            await expectStorageError(.other) { _ = try await be.readRange(path: bad, start: 0, length: 4) }
        }
    }

    @Test("AlistBackend caches raw_url for readRange and retries once when cached link expires (403/410)")
    func alistRawURLCacheAndExpiryRetry() async throws {
        final class CacheBox: @unchecked Sendable {
            let lock = NSLock()
            var getCalls = 0
            var expireV1 = false
            let payload = Data((0..<64).map(UInt8.init))
        }
        let box = CacheBox()

        let transport = ClosureHTTPTransport { req, _ in
            let url = req.url!
            if url.path == "/api/fs/get" {
                let version = box.lock.withLock { () -> Int in
                    box.getCalls += 1
                    return box.getCalls
                }
                let obj: [String: Any] = [
                    "code": 200,
                    "message": "success",
                    "data": [
                        "name": "movie.mkv",
                        "is_dir": false,
                        "raw_url": "/d/v\(version)/movie.mkv",
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: obj), makeHTTPResponse(url: url, status: 200))
            }
            if url.path == "/d/v1/movie.mkv" {
                let expired = box.lock.withLock { box.expireV1 }
                if expired {
                    return (Data(), makeHTTPResponse(url: url, status: 403))
                }
                if let parsed = parseRangeHeader(req.value(forHTTPHeaderField: "Range")) {
                    let s = Int(parsed.start)
                    let e = min(box.payload.count, s + parsed.length)
                    return (box.payload.subdata(in: s..<e), makeHTTPResponse(url: url, status: 206))
                }
            }
            if url.path == "/d/v2/movie.mkv" {
                if let parsed = parseRangeHeader(req.value(forHTTPHeaderField: "Range")) {
                    let s = Int(parsed.start)
                    let e = min(box.payload.count, s + parsed.length)
                    return (box.payload.subdata(in: s..<e), makeHTTPResponse(url: url, status: 206))
                }
            }
            return (Data(), makeHTTPResponse(url: url, status: 404))
        }

        let be = AlistBackend(config: alistCfg("http://alist.local"), credentials: Credentials(token: "tok"), transport: transport)

        #expect(Array(try await be.readRange(path: "/movie.mkv", start: 0, length: 4)) == [0, 1, 2, 3])
        #expect(Array(try await be.readRange(path: "/movie.mkv", start: 10, length: 4)) == [10, 11, 12, 13])
        #expect(box.lock.withLock { box.getCalls } == 1)

        // Expire cached link -> 403 evicts cache, fetches /d/v2/movie.mkv, and succeeds on single retry.
        box.lock.withLock { box.expireV1 = true }
        #expect(Array(try await be.readRange(path: "/movie.mkv", start: 20, length: 4)) == [20, 21, 22, 23])
        #expect(box.lock.withLock { box.getCalls } == 2)
    }

    @Test("AlistBackend fetches large directories (>500 entries) concurrently while preserving page order")
    func alistParallelLargePaginationPreservesOrder() async throws {
        var files: [String: Int] = [:]
        var expectedNames: [String] = []
        for i in 0..<1250 {
            let name = String(format: "f_%04d.mkv", i)
            files["/big/\(name)"] = i + 1
            expectedNames.append(name)
        }
        let mock = MockAlistTransport(files: files)
        let be = AlistBackend(config: alistCfg(), credentials: Credentials(password: "pw"), transport: mock)

        let listed = try await be.list("/big", refresh: true)
        #expect(listed.count == 1250)
        #expect(listed.map(\.name) == expectedNames)
        #expect(mock.listRequests.count == 3)
        let page1Refresh = mock.listRequests.first(where: { ($0["page"] as? Int) == 1 })?["refresh"] as? Bool
        let otherRefreshes = mock.listRequests.filter { ($0["page"] as? Int) != 1 }.compactMap { $0["refresh"] as? Bool }
        #expect(page1Refresh == true)
        #expect(otherRefreshes == [false, false])
    }

    @Test("Fast pure-Swift ISO-8601 and HTTP date parsers handle RFC-1123, RFC-850, asctime, and ISO-8601")
    func fastDateParsers() throws {
        let expected: TimeInterval = 1_704_164_645 // 2024-01-02T03:04:05Z

        #expect(parseFastISO8601Date("2024-01-02T03:04:05Z")?.timeIntervalSince1970 == expected)
        #expect(parseFastISO8601Date("2024-01-02T03:04:05.5Z")?.timeIntervalSince1970 == expected + 0.5)
        #expect(parseFastISO8601Date("2024-01-02T11:04:05+08:00")?.timeIntervalSince1970 == expected)
        #expect(parseFastISO8601Date("2024-01-01T22:04:05-05:00")?.timeIntervalSince1970 == expected)
        #expect(parseFastISO8601Date("2024-02-29T00:00:00Z") != nil)
        #expect(parseFastISO8601Date("2023-02-29T00:00:00Z") == nil)
        #expect(parseFastISO8601Date("invalid") == nil)

        #expect(WebDAVBackend.parseHTTPDate("Tue, 02 Jan 2024 03:04:05 GMT")?.timeIntervalSince1970 == expected)
        #expect(WebDAVBackend.parseHTTPDate("Tuesday, 02-Jan-24 03:04:05 GMT")?.timeIntervalSince1970 == expected)
        #expect(WebDAVBackend.parseHTTPDate("Tue Jan  2 03:04:05 2024")?.timeIntervalSince1970 == expected)
        #expect(WebDAVBackend.parseHTTPDate("2024-01-02T03:04:05Z")?.timeIntervalSince1970 == expected)
        #expect(WebDAVBackend.parseHTTPDate("") == nil)
        #expect(WebDAVBackend.parseHTTPDate("not-a-date") == nil)
    }
}
