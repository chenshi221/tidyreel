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
    directoryExists: (String) -> Bool = { path in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
) -> String? {
    let (wantedHost, wantedPort) = splitHostAndPort(target.host)
    let wantedShare = target.share.precomposedStringWithCanonicalMapping.lowercased()

    for entry in entries where entry.fsType.lowercased() == "smbfs" {
        var raw = entry.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("smb:") {
            raw = String(raw.dropFirst(4))
        }
        let segs = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segs.count >= 2 else { continue }

        let (mountedHost, mountedPort) = splitHostAndPort(segs[0])
        let rawShare = segs[1].removingPercentEncoding ?? segs[1]
        let mountedShare = rawShare.precomposedStringWithCanonicalMapping.lowercased()

        if mountedHost == wantedHost && mountedPort == wantedPort && mountedShare == wantedShare {
            if directoryExists(entry.onName) {
                return entry.onName
            }
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
    let count = Int(getmntinfo(&mntbuf, MNT_NOWAIT))
    guard count > 0, let mntbuf else { return [] }
    var entries: [MountedFilesystemEntry] = []
    entries.reserveCapacity(count)
    for i in 0..<count {
        let fs = mntbuf[i]
        entries.append(
            MountedFilesystemEntry(
                fsType: cCharTupleToString(fs.f_fstypename),
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

private func mountSmbShareViaNetFS(
    target: SmbTarget,
    username: String?,
    password: String?
) async throws -> String {
    let shareURL = try buildSmbShareURL(target)
    let cleanUser = (username?.isEmpty == false) ? username : nil
    let cleanPass = (password?.isEmpty == false) ? password : nil

    return try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let openOpts = NSMutableDictionary()
            openOpts[kNAUIOptionKey] = kNAUIOptionNoUI
            if cleanUser == nil && cleanPass == nil {
                openOpts["Guest"] = true
            }

            let mountOpts = NSMutableDictionary()
            mountOpts[kNetFSSoftMountKey] = true

            var mountpoints: Unmanaged<CFArray>?
            let rc = NetFSMountURLSync(
                shareURL as CFURL,
                nil,
                cleanUser as CFString?,
                cleanPass as CFString?,
                openOpts as CFMutableDictionary,
                mountOpts as CFMutableDictionary,
                &mountpoints
            )

            if rc == 0,
               let array = mountpoints?.takeRetainedValue() as? [String],
               let firstMount = array.first,
               !firstMount.isEmpty {
                cont.resume(returning: firstMount)
                return
            }

            // Re-check getmntinfo in case macOS mounted it concurrently without populating mountpoints.
            if rc == 0 || rc == EEXIST {
                if let found = findMatchingSmbMount(entries: currentMountedFilesystems(), target: target) {
                    cont.resume(returning: found)
                    return
                }
            }

            let errCode = mapSmbMountErrorCode(rc)
            cont.resume(
                throwing: StorageError(
                    errCode,
                    "挂载 SMB 共享失败（smb://\(target.host)/\(target.share)）：错误码 \(rc)"
                )
            )
        }
    }
}

// MARK: - SMBBackend

public actor SMBBackend: RangeReadableBackend {
    typealias ShareMountResolver = @Sendable (SmbTarget, ConnectionConfig, Credentials) async throws -> String

    private let config: ConnectionConfig
    private let credentials: Credentials
    private let mountResolver: ShareMountResolver
    private let healthCheckTTL: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var activeMountRoot: String?
    private var localDelegate: LocalBackend?
    private var mountTask: Task<LocalBackend, Error>?
    private var lastMountCheckAt: TimeInterval?
    private var mountGeneration: UInt64 = 0

    public init(config: ConnectionConfig, credentials: Credentials) {
        self.config = config
        self.credentials = credentials
        self.healthCheckTTL = 8.0
        self.now = { ProcessInfo.processInfo.systemUptime }
        self.mountResolver = { target, cfg, creds in
            if let existing = try await LocalIOExecutor.shared.run({
                findMatchingSmbMount(entries: currentMountedFilesystems(), target: target)
            }) {
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
        self.healthCheckTTL = healthCheckTTL
        self.now = now
        self.mountResolver = mountResolver
    }

    private func ensureMounted() async throws -> LocalBackend {
        if let localDelegate,
           let activeMountRoot {
            if let lastCheck = lastMountCheckAt, (now() - lastCheck) < healthCheckTTL {
                return localDelegate
            }
            let mountPath = activeMountRoot
            let gen = mountGeneration
            let stillMounted = (try? await LocalIOExecutor.shared.run {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: mountPath, isDirectory: &isDir) && isDir.boolValue
            }) ?? false

            if mountGeneration == gen {
                if stillMounted, let currentDelegate = self.localDelegate {
                    self.lastMountCheckAt = now()
                    return currentDelegate
                }
                self.localDelegate = nil
                self.activeMountRoot = nil
                self.lastMountCheckAt = nil
            } else if let currentDelegate = self.localDelegate,
                      let lastCheck = self.lastMountCheckAt,
                      (now() - lastCheck) < healthCheckTTL {
                return currentDelegate
            }
        }

        if let existingTask = mountTask {
            return try await existingTask.value
        }

        guard let target = parseSmbEndpoint(config.endpoint) else {
            throw StorageError(.other, "地址应为 smb://主机/共享名：\(config.endpoint)")
        }

        let baseSegments = try validatedPathSegments(target.base)
        let resolver = self.mountResolver
        let cfg = self.config
        let creds = self.credentials

        let task = Task<LocalBackend, Error> {
            let shareMount = try await resolver(target, cfg, creds)
            let scopedRoot: String
            if baseSegments.isEmpty {
                scopedRoot = shareMount
            } else {
                let trimmedMount = shareMount.hasSuffix("/") ? String(shareMount.dropLast()) : shareMount
                scopedRoot = trimmedMount + "/" + baseSegments.joined(separator: "/")
            }
            return (shareMount, LocalBackend(rootPath: scopedRoot)).1
        }
        // Keep track of shareMount separately after resolution:
        self.mountTask = task
        defer {
            self.mountTask = nil
        }

        let delegate = try await task.value
        // Recover shareMount root by stripping baseSegments from delegate.rootPath
        if baseSegments.isEmpty {
            self.activeMountRoot = delegate.rootPath
        } else {
            var root = delegate.rootPath
            for _ in baseSegments {
                root = (root as NSString).deletingLastPathComponent
            }
            self.activeMountRoot = root
        }
        self.localDelegate = delegate
        self.lastMountCheckAt = now()
        self.mountGeneration &+= 1
        return delegate
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
        mountTask = nil
        localDelegate = nil
        activeMountRoot = nil
        lastMountCheckAt = nil
        mountGeneration &+= 1
    }
}
