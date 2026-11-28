import Darwin
import Foundation
import Network
import Testing
import TidyreelModels
@testable import TidyreelStorage

private func makeTempLocal(_ files: [String: Int]) throws -> (URL, LocalBackend) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidyreel_local_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (rel, size) in files {
        let full = dir.appendingPathComponent(String(rel.dropFirst(rel.hasPrefix("/") ? 1 : 0)))
        try FileManager.default.createDirectory(at: full.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: max(0, size)).write(to: full)
    }
    return (dir, LocalBackend(rootPath: dir.path))
}

@Suite("LocalBackend, SMB, LAN & Transport Tests")
struct LocalAndSMBTests {
    @Test("LocalBackend satisfies storage contract")
    func localContract() async throws {
        try await runStorageContract { files in
            let (dir, be) = try makeTempLocal(files)
            return (be, { try? FileManager.default.removeItem(at: dir) })
        }
    }

    @Test("LocalBackend refuses paths that escape root and invalid child names")
    func localPathTraversalGuard() async throws {
        let (dir, be) = try makeTempLocal(["/a.txt": 1])
        defer { try? FileManager.default.removeItem(at: dir) }

        for bad in ["/../x", "/a/../../x", "/..", #"/..\evil"#, #"/a\..\..\evil"#] {
            await expectStorageError(.other) { try await be.list(bad) }
            await expectStorageError(.other) { try await be.exists(bad) }
            await expectStorageError(.other) { try await be.mkdirs(bad) }
        }

        for badName in ["../evil", #"..\evil"#, ".", "", "sub/x", #"sub\x"#] {
            await expectStorageError(.other) { try await be.rename("/a.txt", newName: badName) }
            await expectStorageError(.other) { try await be.renameMany("/", names: ["a.txt": badName]) }
            await expectStorageError(.other) { try await be.renameMany("/", names: [badName: "b.txt"]) }
            await expectStorageError(.other) { try await be.move(srcDir: "/", dstDir: "/", names: [badName]) }
            await expectStorageError(.other) { try await be.remove(dir: "/", names: [badName]) }
        }

        await expectStorageError(.notFound) {
            try await be.rename("/missing.txt", newName: "missing.txt")
        }
        await expectStorageError(.other) {
            try await be.move(srcDir: "/", dstDir: "/..", names: ["a.txt"])
        }
        await expectStorageError(.other) {
            try await be.remove(dir: "/..", names: ["x"])
        }
    }

    @Test("Conditional directory cleanup preserves newly populated directories and only unlinks metadata files")
    func conditionalDirectoryCleanup() async throws {
        let (root, backend) = try makeTempLocal(["/dir/.DS_Store": 1, "/nested/Thumbs.db/keep.mkv": 1])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await backend.list("/dir").count == 1)
        try await backend.write("/dir/new.mkv", bytes: Data([1]))
        #expect(try await !backend.removeDirectoryIfEmpty("/dir", removingSystemFiles: true))
        #expect(try await backend.exists("/dir/new.mkv"))
        #expect(try await !backend.removeDirectoryIfEmpty("/nested", removingSystemFiles: true))
        #expect(try await backend.exists("/nested/Thumbs.db/keep.mkv"))
        try await backend.remove(dir: "/dir", names: ["new.mkv"])
        #expect(try await !backend.removeDirectoryIfEmpty("/dir", removingSystemFiles: false))
        #expect(try await backend.removeDirectoryIfEmpty("/dir", removingSystemFiles: true))
        #expect(try await !backend.exists("/dir"))
        #expect(try await !backend.removeDirectoryIfEmpty("/", removingSystemFiles: true))
    }

    @Test("Concurrent moves to one target preserve all source payloads")
    func concurrentExclusiveRename() async throws {
        let sourceNames = (1...16).map { "/source-\($0)" }
        let (root, backend) = try makeTempLocal(Dictionary(uniqueKeysWithValues: sourceNames.enumerated().map { ($1, $0 + 1) }))
        defer { try? FileManager.default.removeItem(at: root) }
        let successes = try await withThrowingTaskGroup(of: Int.self) { group in
            for path in sourceNames {
                group.addTask {
                    do {
                        try await backend.atomicRelocate(from: path, to: "/target")
                        return 1
                    } catch let error as StorageError where error.code == .alreadyExists {
                        return 0
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(successes == 1)
        let entries = try await backend.list("/")
        #expect(entries.map(\.size).sorted() == (1...16).map(Int64.init))
    }

    @Test("LocalBackend supports case-only rename on APFS for files and directories")
    func localCaseOnlyRename() async throws {
        let (dir, be) = try makeTempLocal([
            "/foo.mkv": 5,
            "/the office/s01e01.mkv": 12,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        try await be.rename("/foo.mkv", newName: "Foo.mkv")
        let rootNames = try await be.list("/").map(\.name)
        #expect(rootNames.contains("Foo.mkv"))
        #expect(!rootNames.contains("foo.mkv"))

        try await be.rename("/the office", newName: "The Office")
        let updatedRootNames = try await be.list("/").map(\.name)
        #expect(updatedRootNames.contains("The Office"))
        #expect(try await entrySizes(be, "/The Office") == ["s01e01.mkv": 12])
    }

    @Test("LocalBackend refuses hard link and symlink targets on rename")
    func localHardLinkAndSymlinkProtection() async throws {
        let (dir, be) = try makeTempLocal(["/a.mkv": 3])
        defer { try? FileManager.default.removeItem(at: dir) }

        let aPath = dir.appendingPathComponent("a.mkv").path
        let hardPath = dir.appendingPathComponent("b.mkv").path
        #expect(Darwin.link(aPath, hardPath) == 0)

        await expectStorageError(.alreadyExists) {
            try await be.rename("/a.mkv", newName: "b.mkv")
        }
        #expect(FileManager.default.fileExists(atPath: aPath))
        #expect(FileManager.default.fileExists(atPath: hardPath))

        let symPath = dir.appendingPathComponent("sym.mkv").path
        try FileManager.default.createSymbolicLink(atPath: symPath, withDestinationPath: aPath)
        await expectStorageError(.alreadyExists) {
            try await be.rename("/a.mkv", newName: "sym.mkv")
        }
        var st = Darwin.stat()
        #expect(Darwin.lstat(symPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK)
    }

    @Test("LocalBackend handles broken symlinks, dir symlinks, and trailing slashes")
    func localSymlinksAndTrailingSlash() async throws {
        let (dir, be) = try makeTempLocal([
            "/target/keep.mkv": 3,
            "/sub/a.mkv": 5,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("broken.mkv").path,
            withDestinationPath: dir.appendingPathComponent("missing.mkv").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("dir_link").path,
            withDestinationPath: dir.appendingPathComponent("target").path
        )

        let entries = try await be.list("/")
        let broken = try #require(entries.first(where: { $0.name == "broken.mkv" }))
        #expect(broken.size == 0)

        try await be.remove(dir: "/", names: ["dir_link"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("target/keep.mkv").path))

        let subEntries = try await be.list("/sub/")
        #expect(subEntries.count == 1)
        #expect(subEntries[0].path == "/sub/a.mkv")
    }

    @Test("LocalBackend mapOsErrorCode distinguishes Windows and POSIX errno values")
    func osErrorMapping() {
        #expect(LocalBackend.mapOsErrorCode(17, isWindows: true) == .other)
        #expect(LocalBackend.mapOsErrorCode(39, isWindows: true) == .other)
        #expect(LocalBackend.mapOsErrorCode(32, isWindows: true) == .busy)
        #expect(LocalBackend.mapOsErrorCode(5, isWindows: true) == .busy)
        #expect(LocalBackend.mapOsErrorCode(183, isWindows: true) == .alreadyExists)

        #expect(LocalBackend.mapOsErrorCode(17, isWindows: false) == .alreadyExists)
        #expect(LocalBackend.mapOsErrorCode(39, isWindows: false) == .alreadyExists)
        #expect(LocalBackend.mapOsErrorCode(66, isWindows: false) == .alreadyExists)
        #expect(LocalBackend.mapOsErrorCode(32, isWindows: false) == .other)
        #expect(LocalBackend.mapOsErrorCode(13, isWindows: false) == .unauthorized)
        #expect(LocalBackend.mapOsErrorCode(16, isWindows: false) == .busy)
    }

    @Test("LocalBackend readRange slices head, middle, EOF, and rejects missing/escape paths")
    func localReadRange() async throws {
        let (dir, be) = try makeTempLocal([:])
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data((0..<20).map(UInt8.init))
        try await be.write("/data.bin", bytes: payload)

        #expect(Array(try await be.readRange(path: "/data.bin", start: 0, length: 5)) == [0, 1, 2, 3, 4])
        #expect(Array(try await be.readRange(path: "/data.bin", start: 7, length: 4)) == [7, 8, 9, 10])
        #expect(Array(try await be.readRange(path: "/data.bin", start: 17, length: 10)) == [17, 18, 19])
        #expect(try await be.readRange(path: "/data.bin", start: 20, length: 5).isEmpty)
        #expect(try await be.readRange(path: "/data.bin", start: 50, length: 5).isEmpty)
        #expect(try await be.readRange(path: "/data.bin", start: 0, length: 0).isEmpty)
        #expect(try await be.readRange(path: "/data.bin", start: -1, length: 4).isEmpty)

        await expectStorageError(.notFound) {
            _ = try await be.readRange(path: "/missing.bin", start: 0, length: 4)
        }
        await expectStorageError(.other) {
            _ = try await be.readRange(path: "/../escape.bin", start: 0, length: 4)
        }
    }

    @Test("parseSmbEndpoint handles URL, UNC, percent-encoded share, and subfolder base")
    func smbEndpointParsing() {
        #expect(
            parseSmbEndpoint("smb://nas:4445/影视")
                == SmbTarget(host: "nas:4445", share: "影视", base: "")
        )
        #expect(
            parseSmbEndpoint(#"\\nas\影视\下载"#)
                == SmbTarget(host: "nas", share: "影视", base: "下载")
        )
        #expect(
            parseSmbEndpoint("smb://nas/%E5%BD%B1%E8%A7%86")
                == SmbTarget(host: "nas", share: "影视", base: "")
        )
        #expect(
            parseSmbEndpoint("nas/Media/TV/Anime")
                == SmbTarget(host: "nas", share: "Media", base: "TV/Anime")
        )
        #expect(parseSmbEndpoint("smb://nas") == nil)
        #expect(parseSmbEndpoint("") == nil)
    }

    @Test("findMatchingSmbMount matches mounted smbfs shares across user, port, encoding, and Unicode normalization")
    func smbMountMatching() {
        let entries = [
            MountedFilesystemEntry(fsType: "apfs", fromName: "/dev/disk3s1", onName: "/"),
            MountedFilesystemEntry(fsType: "smbfs", fromName: "//admin@192.168.1.10:445/%E5%BD%B1%E8%A7%86", onName: "/Volumes/影视"),
            MountedFilesystemEntry(fsType: "smbfs", fromName: "//guest@nas.local:4445/Anime%20Vault", onName: "/Volumes/Anime Vault"),
        ]

        let match1 = findMatchingSmbMount(
            entries: entries,
            target: SmbTarget(host: "192.168.1.10", share: "影视"),
            directoryExists: { _ in true }
        )
        #expect(match1 == "/Volumes/影视")

        let match2 = findMatchingSmbMount(
            entries: entries,
            target: SmbTarget(host: "NAS.LOCAL:4445", share: "anime vault"),
            directoryExists: { _ in true }
        )
        #expect(match2 == "/Volumes/Anime Vault")

        let mismatchPort = findMatchingSmbMount(
            entries: entries,
            target: SmbTarget(host: "nas.local", share: "Anime Vault"),
            directoryExists: { _ in true }
        )
        #expect(mismatchPort == nil)
    }

    @Test("SMBBackend delegates filesystem and readRange operations scoped to share + base")
    func smbBackendDelegationAndContract() async throws {
        try await runStorageContract { files in
            let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent("tidyreel_smb_\(UUID().uuidString)")
            let scopedBase = shareDir.appendingPathComponent("媒体库/子目录")
            try FileManager.default.createDirectory(at: scopedBase, withIntermediateDirectories: true)
            for (rel, size) in files {
                let full = scopedBase.appendingPathComponent(String(rel.dropFirst(rel.hasPrefix("/") ? 1 : 0)))
                try FileManager.default.createDirectory(at: full.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0, count: max(0, size)).write(to: full)
            }

            let config = ConnectionConfig(
                id: "smb-1",
                name: "SMB",
                type: .smb,
                endpoint: "smb://nas.local/Share/媒体库/子目录",
                username: "admin"
            )
            let be = SMBBackend(config: config, credentials: Credentials(password: "pw")) { _, _, _ in
                shareDir.path
            }
            return (be, { try? FileManager.default.removeItem(at: shareDir) })
        }

        // Also test readRange and invalid SMB endpoint error
        let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent("tidyreel_smb_range_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: shareDir) }
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try Data([10, 20, 30, 40, 50]).write(to: shareDir.appendingPathComponent("clip.mkv"))

        let be = SMBBackend(
            config: ConnectionConfig(id: "smb-2", name: "SMB", type: .smb, endpoint: "smb://nas/Share"),
            credentials: Credentials()
        ) { _, _, _ in shareDir.path }

        #expect(Array(try await be.readRange(path: "/clip.mkv", start: 1, length: 3)) == [20, 30, 40])

        let badSmb = SMBBackend(
            config: ConnectionConfig(id: "smb-bad", name: "Bad", type: .smb, endpoint: "smb://only-host"),
            credentials: Credentials()
        )
        await expectStorageError(.other) {
            try await badSmb.ping()
        }
    }

    @Test("isPrivateHost matches LAN, loopback, Tailscale, IPv6 ULA, and local domain names")
    func privateHostDetection() {
        let privateHosts = [
            "100.95.147.79",
            "192.168.1.10",
            "10.0.0.5",
            "172.20.1.1",
            "127.0.0.1",
            "169.254.10.20",
            "nas",
            "nas.local",
            "nas.local.",
            "box.tail1234.ts.net",
            "box.tail1234.ts.net.",
            "router.home.arpa",
            "nas.home.arpa.",
            "server.lan",
            "hub.internal",
            "[fd7a:115c:a1e0::1]",
            "[::1]",
            "fe80::1",
            "fe80::1%en0",
            "::ffff:192.168.1.10",
            "[::ffff:10.0.0.1]",
            "::ffff:127.0.0.1",
            "::ffff:100.95.147.79",
        ]
        for h in privateHosts {
            #expect(isPrivateHost(h) == true, "Expected \(h) to be private")
        }

        let publicHosts = [
            "api.themoviedb.org",
            "api.themoviedb.org.",
            "8.8.8.8",
            "100.200.1.1",
            "172.32.0.1",
            "172.15.255.255",
            "::ffff:8.8.8.8",
            "[2606:4700:4700::1111]",
            "",
            "   ",
        ]
        for h in publicHosts {
            #expect(isPrivateHost(h) == false, "Expected \(h) to be public")
        }
    }

    @Test("createStorageBackend constructs the matching backend type")
    func factoryCreatesExpectedTypes() throws {
        let creds = Credentials(password: "pw")
        #expect(
            createStorageBackend(
                config: ConnectionConfig(id: "1", name: "L", type: .local, endpoint: "/tmp"),
                credentials: creds
            ) is LocalBackend
        )
        #expect(
            createStorageBackend(
                config: ConnectionConfig(id: "2", name: "A", type: .alist, endpoint: "http://nas:5244"),
                credentials: creds
            ) is AlistBackend
        )
        #expect(
            createStorageBackend(
                config: ConnectionConfig(id: "3", name: "W", type: .webdav, endpoint: "http://nas:5005/dav"),
                credentials: creds
            ) is WebDAVBackend
        )
        #expect(
            createStorageBackend(
                config: ConnectionConfig(id: "4", name: "S", type: .smb, endpoint: "smb://nas/Media"),
                credentials: creds
            ) is SMBBackend
        )
    }

    @Test("Redirected downloads preserve Range and keep credentials within their origin")
    func downloadRedirectHeaders() throws {
        let origin = URL(string: "https://files.example/media")!
        var request = URLRequest(url: origin)
        request.setValue("bytes=1-4", forHTTPHeaderField: "Range")
        request.setValue("test", forHTTPHeaderField: "Authorization")
        request.setValue("test", forHTTPHeaderField: "Cookie")
        request.setValue("test", forHTTPHeaderField: "X-Provider-Key")
        let local = try #require(URLSessionStorageTransport.redirectRequest(
            request, to: URL(string: "https://FILES.example:443/next")!, status: 302
        ))
        #expect(local.allHTTPHeaderFields == request.allHTTPHeaderFields)
        for url in ["https://cdn.example/file", "https://nas.local/file", "https://files.example:444/file", "http://files.example/file"] {
            let target = URL(string: url)!
            let redirected = try #require(URLSessionStorageTransport.redirectRequest(local, to: target, status: 302))
            let final = try #require(URLSessionStorageTransport.redirectRequest(redirected, to: target.appendingPathComponent("next"), status: 302))
            #expect(final.value(forHTTPHeaderField: "Range") == "bytes=1-4")
            #expect(final.allHTTPHeaderFields?.count == 1)
        }
        #expect(resolveValidURL("file:///tmp/example", relativeTo: origin) == nil)
    }

    @Test("Cross-origin redirects cannot replay request bodies")
    func uploadRedirectBody() throws {
        let origin = URL(string: "https://files.example/upload")!
        let other = URL(string: "https://other.example/upload")!
        var request = URLRequest(url: origin)
        request.httpMethod = "PUT"
        request.httpBody = Data([1, 2, 3])
        request.setValue("test", forHTTPHeaderField: "Password")
        for status in [307, 308] {
            #expect(URLSessionStorageTransport.redirectRequest(request, to: other, status: status) == nil)
            let same = try #require(URLSessionStorageTransport.redirectRequest(request, to: origin, status: status))
            #expect(same.httpBody == request.httpBody)
        }
        let read = try #require(URLSessionStorageTransport.redirectRequest(request, to: other, status: 303))
        #expect(read.httpMethod == "GET")
        #expect(read.httpBody == nil)
        #expect(read.value(forHTTPHeaderField: "Password") == nil)
    }

    @Test("URLSessionStorageTransport preserves Authorization and Range across LAN redirects")
    func urlSessionTransportLANRedirect() async throws {
        // Start a tiny local HTTP listener on 127.0.0.1 using POSIX sockets.
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(listenFD >= 0)
        defer { Darwin.close(listenFD) }

        var yes: Int32 = 1
        _ = setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRC == 0)
        #expect(Darwin.listen(listenFD, 8) == 0)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listenFD, $0, &addrLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        final class CapturedHeaders: @unchecked Sendable {
            let lock = NSLock()
            var targetAuth: String?
            var targetRange: String?
        }
        let captured = CapturedHeaders()

        DispatchQueue.global().async {
            for _ in 0..<3 {
                let client = Darwin.accept(listenFD, nil, nil)
                if client < 0 { break }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(client, &buf, buf.count)
                let reqStr = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                let lines = reqStr.components(separatedBy: "\r\n")
                let firstLine = lines.first ?? ""
                if firstLine.contains(" /start ") {
                    let resp = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    _ = resp.withCString { Darwin.write(client, $0, strlen($0)) }
                } else {
                    captured.lock.lock()
                    for line in lines {
                        let lower = line.lowercased()
                        if lower.hasPrefix("authorization:") {
                            captured.targetAuth = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                        } else if lower.hasPrefix("range:") {
                            captured.targetRange = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                        }
                    }
                    captured.lock.unlock()
                    let body = [UInt8]([11, 22, 33, 44])
                    let header = "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
                    _ = header.withCString { Darwin.write(client, $0, strlen($0)) }
                    _ = body.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, body.count) }
                }
                Darwin.close(client)
            }
        }

        let transport = URLSessionStorageTransport(requestTimeout: 5, resourceTimeout: 5)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/start")!)
        req.setValue("Bearer secret-lan-token", forHTTPHeaderField: "Authorization")
        req.setValue("bytes=0-3", forHTTPHeaderField: "Range")

        // followRedirects: false returns the raw 302
        let (_, noRedirResp) = try await transport.send(req, followRedirects: false)
        #expect(noRedirResp.statusCode == 302)

        // followRedirects: true follows to /target and keeps Authorization & Range
        let (data, redirResp) = try await transport.send(req, followRedirects: true)
        #expect(redirResp.statusCode == 206)
        #expect(Array(data) == [11, 22, 33, 44])

        let (seenAuth, seenRange) = captured.lock.withLock {
            (captured.targetAuth, captured.targetRange)
        }
        #expect(seenAuth == "Bearer secret-lan-token")
        #expect(seenRange == "bytes=0-3")
    }

    @Test("URLSessionStorageTransport reuses HTTP/1.1 keep-alive for bounded 206 and enforces unranged hard cap")
    func urlSessionTransportKeepAliveAndHardCap() async throws {
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(listenFD >= 0)
        defer { Darwin.close(listenFD) }

        var yes: Int32 = 1
        _ = setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRC == 0)
        #expect(Darwin.listen(listenFD, 8) == 0)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listenFD, $0, &addrLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        final class ServerStats: @unchecked Sendable {
            let lock = NSLock()
            var requestsOnFirstSocket = 0
        }
        let stats = ServerStats()

        DispatchQueue.global().async {
            var servedTotal = 0
            var socketIndex = 0
            while servedTotal < 3 {
                let client = Darwin.accept(listenFD, nil, nil)
                if client < 0 { break }
                socketIndex += 1
                var noSigPipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var reqsOnThisSocket = 0
                while servedTotal < 3 {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    let n = Darwin.read(client, &buf, buf.count)
                    if n <= 0 { break }
                    servedTotal += 1
                    reqsOnThisSocket += 1
                    if socketIndex == 1 {
                        stats.lock.withLock { stats.requestsOnFirstSocket = reqsOnThisSocket }
                    }
                    let reqStr = String(decoding: buf[0..<n], as: UTF8.self)
                    let firstLine = reqStr.components(separatedBy: "\r\n").first ?? ""
                    if firstLine.contains(" /huge ") {
                        let header = "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n"
                        _ = header.withCString { Darwin.write(client, $0, strlen($0)) }
                        let body = [UInt8](repeating: 0xAB, count: 4096)
                        _ = body.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, body.count) }
                        break
                    } else {
                        let closeNow = (servedTotal >= 2)
                        let connHeader = closeNow ? "close" : "keep-alive"
                        let body: [UInt8] = [11, 22, 33, 44]
                        let header = "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: \(connHeader)\r\n\r\n"
                        _ = header.withCString { Darwin.write(client, $0, strlen($0)) }
                        _ = body.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, body.count) }
                        if closeNow { break }
                    }
                }
                Darwin.close(client)
            }
        }

        let transport = URLSessionStorageTransport(
            requestTimeout: 5,
            resourceTimeout: 5,
            maxUnrangedBytes: 128
        )
        var rangeReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/range")!)
        rangeReq.setValue("bytes=0-3", forHTTPHeaderField: "Range")

        let (d1, r1) = try await transport.send(rangeReq, followRedirects: false)
        #expect(r1.statusCode == 206)
        #expect(Array(d1) == [11, 22, 33, 44])

        let (d2, r2) = try await transport.send(rangeReq, followRedirects: false)
        #expect(r2.statusCode == 206)
        #expect(Array(d2) == [11, 22, 33, 44])

        #expect(stats.lock.withLock { stats.requestsOnFirstSocket } == 2)

        let hugeReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/huge")!)
        do {
            _ = try await transport.send(hugeReq, followRedirects: false)
            Issue.record("Expected URLError.dataLengthExceedsMaximum for oversized unranged response")
        } catch let err as URLError {
            #expect(err.code == .dataLengthExceedsMaximum)
        }
    }

    @Test("SMBBackend caches mount health checks within TTL and invalidates immediately on I/O error")
    func smbMountHealthCacheAndInvalidation() async throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent("tidyreel_smb_h1_\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent("tidyreel_smb_h2_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir1.appendingPathComponent("a.txt"))
        try Data([4, 5, 6]).write(to: dir2.appendingPathComponent("a.txt"))

        final class HealthState: @unchecked Sendable {
            let lock = NSLock()
            var now: TimeInterval = 100.0
            var mountCalls = 0
        }
        let state = HealthState()

        let be = SMBBackend(
            config: ConnectionConfig(id: "smb-h", name: "SMB", type: .smb, endpoint: "smb://nas.local/Share"),
            credentials: Credentials(),
            healthCheckTTL: 8.0,
            now: { state.lock.withLock { state.now } }
        ) { _, _, _ in
            let call = state.lock.withLock { () -> Int in
                state.mountCalls += 1
                return state.mountCalls
            }
            return call == 1 ? dir1.path : dir2.path
        }

        #expect(Array(try await be.read("/a.txt")) == [1, 2, 3])
        #expect(state.lock.withLock { state.mountCalls } == 1)

        // Remove mount root while still inside 8s TTL.
        try FileManager.default.removeItem(at: dir1)
        state.lock.withLock { state.now = 102.0 }

        // A failing read throws .notFound and immediately invalidates the cached health check.
        await expectStorageError(.notFound) {
            _ = try await be.read("/a.txt")
        }

        // Next call re-checks mount health immediately (even within TTL) and remounts to dir2.
        #expect(Array(try await be.read("/a.txt")) == [4, 5, 6])
        #expect(state.lock.withLock { state.mountCalls } == 2)
    }
}
