import CoreFoundation
import Darwin
import Foundation
import NetFS
import TidyreelModels

public struct SmbTarget: Equatable, Sendable {
    public var host: String
    public var share: String
    public var base: String

    public init(host: String, share: String, base: String = "") {
        self.host = host
        self.share = share
        self.base = base
    }
}

/// Parses `smb://nas[:port]/影视[/子目录]`, `\\nas\影视\下载`, or `nas/影视`.
/// Returns `nil` when no share name is present.
public func parseSmbEndpoint(_ endpoint: String) -> SmbTarget? {
    var s = endpoint
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\", with: "/")
    if s.lowercased().hasPrefix("smb:") {
        s = String(s.dropFirst(4))
    }
    let segs = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard segs.count >= 2 else { return nil }

    func dec(_ x: String) -> String {
        x.removingPercentEncoding ?? x
    }

    return SmbTarget(
        host: segs[0],
        share: dec(segs[1]),
        base: segs.dropFirst(2).map(dec).joined(separator: "/")
    )
}

// MARK: - Mount Discovery & NetFS Helpers

struct MountedFilesystemEntry: Equatable, Sendable {
    var fsType: String
    var fromName: String
    var onName: String
}

private func splitHostAndPort(_ authority: String) -> (host: String, port: Int) {
    var auth = authority.trimmingCharacters(in: .whitespacesAndNewlines)
    if let atIdx = auth.lastIndex(of: "@") {
        auth = String(auth[auth.index(after: atIdx)...])
    }
    if auth.hasPrefix("["), let closeBracket = auth.firstIndex(of: "]") {
        let ipv6 = String(auth[auth.index(after: auth.startIndex)..<closeBracket])
        let rest = auth[auth.index(after: closeBracket)...]
        if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
            return (ipv6.lowercased(), port)
        }
        return (ipv6.lowercased(), 445)
    }
    if let colon = auth.lastIndex(of: ":"), !auth[..<colon].contains(":") {
        let hostPart = String(auth[..<colon])
        let portPart = String(auth[auth.index(after: colon)...])
        if let port = Int(portPart) {
            return (hostPart.lowercased(), port)
        }
    }
    return (auth.lowercased(), 445)
}

func findMatchingSmbMount(
    entries: [MountedFilesystemEntry],
    target: SmbTarget,
    username: String?,
    mountPaths: Set<String>? = nil
) -> String? {
    let (wantedHost, wantedPort) = splitHostAndPort(target.host)
    let wantedShare = target.share.precomposedStringWithCanonicalMapping.lowercased()

    // smbfs encodes a Windows domain as DOMAIN;user in f_mntfromname.
    func principal(_ user: String) -> String {
        user.replacingOccurrences(of: "\\", with: ";").precomposedStringWithCanonicalMapping
    }
    let expectedUser = principal(username.flatMap { $0.isEmpty ? nil : $0 } ?? "guest")

    for entry in entries where entry.fsType.lowercased() == "smbfs" {
        var raw = entry.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("smb:") {
            raw = String(raw.dropFirst(4))
        }
        let segs = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segs.count == 2, let at = segs[0].lastIndex(of: "@"),
              mountPaths?.contains(entry.onName) != false else { continue }
        var rawUser = String(segs[0][..<at])
        if rawUser.hasSuffix(":") { rawUser.removeLast() }
        guard let mountedUser = rawUser.removingPercentEncoding, !mountedUser.isEmpty else { continue }
        guard principal(mountedUser).caseInsensitiveCompare(expectedUser) == .orderedSame else { continue }

        let (mountedHost, mountedPort) = splitHostAndPort(segs[0])
        let rawShare = segs[1].removingPercentEncoding ?? segs[1]
        let mountedShare = rawShare.precomposedStringWithCanonicalMapping.lowercased()

        if mountedHost == wantedHost && mountedPort == wantedPort && mountedShare == wantedShare {
            return entry.onName
        }
    }
    return nil
}

private func cCharTupleToString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let prefix = raw.prefix { $0 != 0 }
        return String(decoding: prefix, as: UTF8.self)
    }
}

private func currentMountedFilesystems() -> [MountedFilesystemEntry] {
    var mntbuf: UnsafeMutablePointer<statfs>?
    let count = Int(getmntinfo_r_np(&mntbuf, MNT_NOWAIT))
    guard count > 0, let mntbuf else { return [] }
    defer { free(mntbuf) }
    var entries: [MountedFilesystemEntry] = []
    entries.reserveCapacity(count)
    for i in 0..<count {
        let fs = mntbuf[i]
        let fsType = cCharTupleToString(fs.f_fstypename)
        guard fsType == "smbfs" else { continue }
        entries.append(
            MountedFilesystemEntry(
                fsType: fsType,
                fromName: cCharTupleToString(fs.f_mntfromname),
                onName: cCharTupleToString(fs.f_mntonname)
            )
        )
    }
    return entries
}

func mapSmbMountErrorCode(_ status: Int32) -> StorageErrorCode {
    switch status {
    case EACCES, EPERM, EAUTH, -5014, -5015, -5016, -5019, -5020, -5021, -5023, -5029:
        return .unauthorized
    case ENOENT:
        return .notFound
    case EBUSY:
        return .busy
    case ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ENOTCONN:
        return .network
    default:
        return status > 0 ? LocalBackend.mapOsErrorCode(Int(status), isWindows: false) : .network
    }
}

private func buildSmbShareURL(_ target: SmbTarget) throws -> URL {
    let (host, port) = splitHostAndPort(target.host)
    guard !host.isEmpty else {
        throw StorageError(.other, "SMB 主机名无效：\(target.host)")
    }
    var comps = URLComponents()
    comps.scheme = "smb"
    comps.host = host.contains(":") ? "[\(host)]" : host
    if port != 445 {
        comps.port = port
    }
    comps.percentEncodedPath = "/" + encodePathSegment(target.share)
    guard let url = comps.url else {
        throw StorageError(.other, "SMB 地址无效：\(target.host)/\(target.share)")
    }
    return url
}

/// The NetFS completion block is suppressed after cancellation. Serialize completion, timeout
/// and cancellation so exactly one of them resumes the caller.
actor SmbMountRequest {
    typealias Reply = (status: Int32, paths: [String])
    typealias Completion = @Sendable (Int32, [String]) -> Void
    typealias Start = (@escaping Completion) -> (status: Int32, cancel: () -> Void)
    private var continuation: CheckedContinuation<Reply, Error>?
    private var cancelMount: (() -> Void)?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration = .seconds(30), start: Start) async throws -> Reply {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let request = start { status, paths in
                    Task { await self.complete((status, paths)) }
                }
                if request.status != 0 {
                    complete((request.status, []))
                    return
                }
                cancelMount = request.cancel
                timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    abort(StorageError(.network, "SMB 挂载超时"))
                }
            }
        } onCancel: {
            Task { await self.abort(CancellationError()) }
        }
    }

    private func complete(_ reply: Reply) {
        timer?.cancel()
        timer = nil
        cancelMount = nil
        continuation?.resume(returning: reply)
        continuation = nil
    }

    private func abort(_ error: Error) {
        timer?.cancel()
        timer = nil
        cancelMount?()
        cancelMount = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

func verifiedSmbMount(status: Int32, paths: [String], entries: [MountedFilesystemEntry],
                      target: SmbTarget, username: String?) throws -> String {
    guard status == 0 || status == EEXIST else {
        throw StorageError(mapSmbMountErrorCode(status), "挂载 SMB 共享失败（错误码 \(status)）")
    }
    guard let path = findMatchingSmbMount(entries: entries, target: target, username: username,
                                          mountPaths: paths.isEmpty ? nil : Set(paths)) else {
        throw StorageError(.unauthorized, "无法验证 SMB 共享的挂载位置或登录账号")
    }
    return path
}

private func mountSmbShareViaNetFS(
    target: SmbTarget,
    username: String?,
    password: String?
) async throws -> String {
    let shareURL = try buildSmbShareURL(target)
    let user = username.flatMap { $0.isEmpty ? nil : $0 }
    let pass = password.flatMap { $0.isEmpty ? nil : $0 }
    let reply = try await SmbMountRequest().run { completion in
        let openOpts = NSMutableDictionary()
        openOpts[kNAUIOptionKey] = kNAUIOptionNoUI
        openOpts[kNetFSForceNewSessionKey] = true
        if user == nil { openOpts[kNetFSUseGuestKey] = true }
        let mountOpts = NSMutableDictionary()
        mountOpts[kNetFSSoftMountKey] = true
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(shareURL as CFURL, nil, user as CFString?, pass as CFString?,
                                        openOpts, mountOpts, &requestID, .global(qos: .userInitiated)) { status, _, paths in
            completion(status, paths as? [String] ?? [])
        }
        return (status, { if let requestID { _ = NetFSMountURLCancel(requestID) } })
    }
    return try verifiedSmbMount(status: reply.status, paths: reply.paths, entries: currentMountedFilesystems(),
                                target: target, username: user)
}

// MARK: - SMBBackend

public actor SMBBackend: RangeReadableBackend {
    typealias ShareMountResolver = @Sendable (SmbTarget, ConnectionConfig, Credentials) async throws -> String

    private let config: ConnectionConfig
    private let credentials: Credentials
    private let mountResolver: ShareMountResolver
    private let isMountValid: @Sendable (String) -> Bool
    private let healthCheckTTL: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var activeMountRoot: String?
    private var localDelegate: LocalBackend?
    private var mountTask: Task<Void, Never>?
    private var mountWaiters: [UUID: CheckedContinuation<LocalBackend, Error>] = [:]
    private var lastMountCheckAt: TimeInterval?
    private var mountGeneration: UInt64 = 0

    public init(config: ConnectionConfig, credentials: Credentials) {
        self.config = config
        self.credentials = credentials
        // Revalidate the mount-table identity before each operation. A mount point may
        // still exist as a local folder or be reused by another account after unmount.
        self.healthCheckTTL = 0
        self.isMountValid = { path in
            guard let target = parseSmbEndpoint(config.endpoint) else { return false }
            return findMatchingSmbMount(entries: currentMountedFilesystems(), target: target,
                                        username: config.username, mountPaths: [path]) != nil
        }
        self.now = { ProcessInfo.processInfo.systemUptime }
        self.mountResolver = { target, cfg, creds in
            if let existing = findMatchingSmbMount(entries: currentMountedFilesystems(), target: target, username: cfg.username) {
                return existing
            }
            return try await mountSmbShareViaNetFS(
                target: target,
                username: cfg.username,
                password: creds.password
            )
        }
    }

    init(
        config: ConnectionConfig,
        credentials: Credentials,
        healthCheckTTL: TimeInterval = 8.0,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        mountResolver: @escaping ShareMountResolver
    ) {
        self.config = config
        self.credentials = credentials
        self.isMountValid = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        self.healthCheckTTL = healthCheckTTL
        self.now = now
        self.mountResolver = mountResolver
    }

    private func ensureMounted() async throws -> LocalBackend {
        try Task.checkCancellation()
        if let delegate = localDelegate, let path = activeMountRoot {
            if let lastCheck = lastMountCheckAt, now() - lastCheck < healthCheckTTL { return delegate }
            if isMountValid(path) {
                lastMountCheckAt = now()
                return delegate
            }
            localDelegate = nil
            activeMountRoot = nil
            lastMountCheckAt = nil
        }
        guard let target = parseSmbEndpoint(config.endpoint) else {
            throw StorageError(.other, "地址应为 smb://主机/共享名：\(config.endpoint)")
        }
        let baseSegments = try validatedPathSegments(target.base)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                mountWaiters[waiter] = continuation
                guard mountTask == nil else { return }
                mountGeneration &+= 1
                let generation = mountGeneration
                mountTask = Task {
                    do {
                        let root = try await mountResolver(target, config, credentials)
                        guard generation == mountGeneration else { return }
                        let scopedRoot = baseSegments.reduce(URL(fileURLWithPath: root)) { $0.appendingPathComponent($1) }
                        let delegate = LocalBackend(rootPath: scopedRoot.path)
                        activeMountRoot = root
                        localDelegate = delegate
                        lastMountCheckAt = now()
                        finishMount(.success(delegate))
                    } catch {
                        guard generation == mountGeneration else { return }
                        finishMount(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelMountWaiter(waiter) }
        }
    }

    private func finishMount(_ result: Result<LocalBackend, Error>) {
        mountTask = nil
        for waiter in mountWaiters.values { waiter.resume(with: result) }
        mountWaiters.removeAll()
    }

    private func cancelMountWaiter(_ id: UUID) {
        guard let waiter = mountWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if mountWaiters.isEmpty {
            mountGeneration &+= 1
            mountTask?.cancel()
            mountTask = nil
        }
    }

    private static func shouldInvalidateMountHealth(_ error: Error) -> Bool {
        if let storageErr = error as? StorageError {
            switch storageErr.code {
            case .notFound, .network, .other:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        let posixCode: Int32?
        if ns.domain == NSPOSIXErrorDomain {
            posixCode = Int32(ns.code)
        } else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posixCode = Int32(underlying.code)
        } else {
            posixCode = nil
        }
        if let code = posixCode {
            return code == ENOENT
                || code == ENOTCONN
                || code == ESTALE
                || code == EIO
                || code == ENXIO
                || code == EHOSTDOWN
                || code == ETIMEDOUT
        }
        return false
    }

    private func withMountedDelegate<T: Sendable>(
        _ operation: (LocalBackend) async throws -> T
    ) async throws -> T {
        let delegate = try await ensureMounted()
        try Task.checkCancellation()
        do {
            return try await operation(delegate)
        } catch {
            if Self.shouldInvalidateMountHealth(error) {
                lastMountCheckAt = nil
            }
            throw error
        }
    }

    private func validateSmbPath(_ path: String) throws {
        _ = try validatedPathSegments(path)
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        try validateSmbPath(dir)
        return try await withMountedDelegate { delegate in
            try await delegate.list(dir, refresh: refresh)
        }
    }

    public func mkdirs(_ dir: String) async throws {
        try validateSmbPath(dir)
        try await withMountedDelegate { delegate in
            try await delegate.mkdirs(dir)
        }
    }

    public nonisolated var supportsAtomicRelocate: Bool { true }

    public func atomicRelocate(from src: String, to dst: String) async throws {
        try validateSmbPath(src)
        try validateSmbPath(dst)
        try await withMountedDelegate { delegate in
            try await delegate.atomicRelocate(from: src, to: dst)
        }
    }

    public func rename(_ path: String, newName: String) async throws {
        try validateChildName(newName)
        try validateSmbPath(path)
        try await withMountedDelegate { delegate in
            try await delegate.rename(path, newName: newName)
        }
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        try validateSmbPath(dir)
        for (oldName, newName) in names {
            try validateChildName(oldName)
            try validateChildName(newName)
        }
        try await withMountedDelegate { delegate in
            try await delegate.renameMany(dir, names: names)
        }
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        try validateSmbPath(srcDir)
        try validateSmbPath(dstDir)
        for name in names {
            try validateChildName(name)
        }
        try await withMountedDelegate { delegate in
            try await delegate.move(srcDir: srcDir, dstDir: dstDir, names: names)
        }
    }

    public func removeScannedFile(_ path: String, identity: String?) async throws {
        try validateSmbPath(path)
        try await withMountedDelegate { delegate in
            try await delegate.removeScannedFile(path, identity: identity)
        }
    }

    public func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool {
        try validateSmbPath(dir)
        return try await withMountedDelegate { delegate in
            try await delegate.removeDirectoryIfEmpty(dir, removingSystemFiles: removingSystemFiles)
        }
    }

    public func remove(dir: String, names: [String]) async throws {
        try validateSmbPath(dir)
        for name in names {
            try validateChildName(name)
        }
        try await withMountedDelegate { delegate in
            try await delegate.remove(dir: dir, names: names)
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        try validateSmbPath(path)
        return try await withMountedDelegate { delegate in
            try await delegate.exists(path)
        }
    }

    public func read(_ path: String) async throws -> Data {
        try validateSmbPath(path)
        return try await withMountedDelegate { delegate in
            try await delegate.read(path)
        }
    }

    public func write(_ path: String, bytes: Data) async throws {
        try validateSmbPath(path)
        try await withMountedDelegate { delegate in
            try await delegate.write(path, bytes: bytes)
        }
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        try validateSmbPath(path)
        if start < 0 || length <= 0 {
            return Data()
        }
        return try await withMountedDelegate { delegate in
            try await delegate.readRange(path: path, start: start, length: length)
        }
    }

    public func ping() async throws {
        try await withMountedDelegate { delegate in
            try await delegate.ping()
        }
    }

    public func close() async {
        mountTask?.cancel()
        finishMount(.failure(CancellationError()))
        localDelegate = nil
        activeMountRoot = nil
        lastMountCheckAt = nil
        mountGeneration &+= 1
    }
}
