import Darwin
import Foundation
import TidyreelModels

/// Dedicated bounded I/O executor that keeps blocking POSIX / FileManager calls
/// (including slow local disks and macOS SMB mounts) off Swift's cooperative thread pool.
final class LocalIOExecutor: @unchecked Sendable {
    static let shared = LocalIOExecutor()

    private let queue: OperationQueue

    private init() {
        let q = OperationQueue()
        q.name = "com.tidyreel.storage.local-io"
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        self.queue = q
    }

    func run<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public final class LocalBackend: RangeReadableBackend, Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        var cleaned = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        while cleaned.count > 1 && cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        self.rootPath = cleaned.isEmpty ? "/" : cleaned
    }

    /// Maps an OS error code to `StorageErrorCode`, distinguishing Windows Win32
    /// error codes from POSIX `errno` values.
    public static func mapOsErrorCode(_ errorCode: Int?, isWindows: Bool = false) -> StorageErrorCode {
        guard let errorCode else { return .other }
        if isWindows {
            switch errorCode {
            case 2, 3:
                return .notFound
            case 80, 183:
                return .alreadyExists
            case 5, 32, 33:
                return .busy
            default:
                return .other
            }
        }
        switch errorCode {
        case 2: // ENOENT
            return .notFound
        case 1, 13: // EPERM, EACCES
            return .unauthorized
        case 16: // EBUSY
            return .busy
        case 17, 39, 66: // EEXIST, ENOTEMPTY (Linux 39, Darwin 66)
            return .alreadyExists
        default:
            return .other
        }
    }

    private enum LocalEntityType {
        case notFound
        case directory
        case regular
        case symlink
    }

    private func entityType(_ realPath: String, followSymlinks: Bool = false) -> (type: LocalEntityType, stat: Darwin.stat?) {
        var st = Darwin.stat()
        let flags: Int32 = followSymlinks ? 0 : AT_SYMLINK_NOFOLLOW
        let rc = fstatat(AT_FDCWD, realPath, &st, flags)
        guard rc == 0 else {
            return (.notFound, nil)
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            return (.directory, st)
        case S_IFLNK:
            return (.symlink, st)
        default:
            return (.regular, st)
        }
    }

    /// Maps a `/`-rooted virtual path to a real filesystem path, refusing anything that escapes `rootPath`.
    func resolveRealPath(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        var segs: [String] = []
        for raw in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(raw)
            if s == "." { continue }
            if s == ".." {
                throw StorageError(.other, "路径超出根目录范围：\(path)")
            }
            segs.append(s)
        }

        let resolved: String
        if segs.isEmpty {
            resolved = rootPath
        } else if rootPath == "/" {
            resolved = "/" + segs.joined(separator: "/")
        } else {
            resolved = rootPath + "/" + segs.joined(separator: "/")
        }

        let standardized = URL(fileURLWithPath: resolved).standardizedFileURL.path
        let insideRoot: Bool
        if rootPath == "/" {
            insideRoot = standardized.hasPrefix("/")
        } else {
            insideRoot = standardized == rootPath || standardized.hasPrefix(rootPath + "/")
        }
        guard insideRoot else {
            throw StorageError(.other, "路径超出根目录范围：\(path)")
        }
        return standardized
    }

    private func mapError(_ error: Error, virtualPath: String) -> StorageError {
        if let storageErr = error as? StorageError {
            return storageErr
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let code = Self.mapOsErrorCode(nsError.code, isWindows: false)
            return StorageError(code, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            let code = Self.mapOsErrorCode(underlying.code, isWindows: false)
            return StorageError(code, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return StorageError(.notFound, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
            case .fileWriteFileExists:
                return StorageError(.alreadyExists, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
            case .fileReadNoPermission, .fileWriteNoPermission:
                return StorageError(.unauthorized, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
            default:
                break
            }
        }
        return StorageError(.other, "本地存储操作失败（\(virtualPath)）：\(nsError.localizedDescription)")
    }

    private func posixThrow(_ errnoValue: Int32, virtualPath: String, op: String) throws -> Never {
        let code = Self.mapOsErrorCode(Int(errnoValue), isWindows: false)
        let msg = String(cString: strerror(errnoValue))
        throw StorageError(code, "本地存储操作失败（\(virtualPath)）：\(op)（\(msg)）")
    }

    private func io<T>(_ virtualPath: String, _ block: () throws -> T) throws -> T {
        do {
            return try block()
        } catch {
            throw mapError(error, virtualPath: virtualPath)
        }
    }

    public func read(_ path: String) async throws -> Data {
        let real = try resolveRealPath(path)
        return try await LocalIOExecutor.shared.run {
            try self.io(path) {
                let (kind, _) = self.entityType(real, followSymlinks: true)
                if kind == .notFound {
                    throw StorageError(.notFound, "文件不存在：\(path)")
                }
                if kind == .directory {
                    throw StorageError(.other, "路径是目录而非文件：\(path)")
                }
                return try Data(contentsOf: URL(fileURLWithPath: real))
            }
        }
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        let real = try resolveRealPath(path)
        if start < 0 || length <= 0 {
            return Data()
        }
        return try await LocalIOExecutor.shared.run {
            try self.io(path) {
                let (kind, _) = self.entityType(real, followSymlinks: true)
                if kind == .notFound {
                    throw StorageError(.notFound, "文件不存在：\(path)")
                }
                if kind == .directory {
                    throw StorageError(.notFound, "路径是目录而非文件：\(path)")
                }
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: real))
                defer {
                    try? handle.close()
                }
                let fileLen = try handle.seekToEnd()
                let uStart = UInt64(start)
                if uStart >= fileLen {
                    return Data()
                }
                let avail = fileLen - uStart
                let toRead = Int(min(UInt64(length), avail))
                try handle.seek(toOffset: uStart)
                return try handle.read(upToCount: toRead) ?? Data()
            }
        }
    }

    public func write(_ path: String, bytes: Data) async throws {
        let real = try resolveRealPath(path)
        try await LocalIOExecutor.shared.run {
            try self.io(path) {
                let parent = (real as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                }
                // O_EXCL refuses existing files, directories, and broken symlinks atomically.
                let fd = Darwin.open(real, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd < 0 {
                    try self.posixThrow(errno, virtualPath: path, op: "create")
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                do {
                    try handle.write(contentsOf: bytes)
                    try handle.close()
                } catch {
                    try? handle.close()
                    _ = Darwin.unlink(real)
                    throw error
                }
            }
        }
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        let real = try resolveRealPath(dir)
        return try await LocalIOExecutor.shared.run {
            let (dirKind, _) = self.entityType(real, followSymlinks: true)
            guard dirKind == .directory else {
                throw StorageError(.notFound, "目录不存在：\(dir)")
            }
            return try self.io(dir) {
                let names = try FileManager.default.contentsOfDirectory(atPath: real)
                var out: [RemoteEntry] = []
                out.reserveCapacity(names.count)
                let cleanDir = posixTrimDir(dir)
                let virtualPrefix = cleanDir == "/" ? "/" : cleanDir + "/"
                let realPrefix = real == "/" ? "/" : real + "/"
                for name in names {
                    let childReal = realPrefix + name
                    let (lkind, lstatInfo) = self.entityType(childReal, followSymlinks: false)
                    let isDir = (lkind == .directory)

                    var size: Int64 = 0
                    var modified: Date?

                    if lkind == .symlink {
                        var targetStat = Darwin.stat()
                        if fstatat(AT_FDCWD, childReal, &targetStat, 0) == 0 {
                            if targetStat.st_size > 0 {
                                size = Int64(targetStat.st_size)
                            }
                            modified = Date(
                                timeIntervalSince1970: TimeInterval(targetStat.st_mtimespec.tv_sec)
                                    + TimeInterval(targetStat.st_mtimespec.tv_nsec) / 1_000_000_000
                            )
                        } else if let lstatInfo {
                            // Broken symlink: clamp size to 0 and use symlink's own mtime.
                            size = 0
                            modified = Date(
                                timeIntervalSince1970: TimeInterval(lstatInfo.st_mtimespec.tv_sec)
                                    + TimeInterval(lstatInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                            )
                        }
                    } else if let lstatInfo {
                        if !isDir && lstatInfo.st_size > 0 {
                            size = Int64(lstatInfo.st_size)
                        }
                        modified = Date(
                            timeIntervalSince1970: TimeInterval(lstatInfo.st_mtimespec.tv_sec)
                                + TimeInterval(lstatInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                        )
                    }

                    out.append(
                        RemoteEntry(
                            path: virtualPrefix + name,
                            name: name,
                            isDir: isDir,
                            size: size,
                            modified: modified
                        )
                    )
                }
                return out
            }
        }
    }

    public func mkdirs(_ dir: String) async throws {
        let real = try resolveRealPath(dir)
        try await LocalIOExecutor.shared.run {
            let (kind, _) = self.entityType(real, followSymlinks: false)
            if kind != .notFound && kind != .directory {
                throw StorageError(.alreadyExists, "路径已存在且不是目录：\(dir)")
            }
            if kind == .directory {
                return
            }
            try self.io(dir) {
                try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
            }
        }
    }

    /// Returns true if `dst` resolves to `src` solely because of case-insensitivity or
    /// Unicode normalization on the underlying filesystem (not a hard link or symlink).
    private func isSameFoldedEntry(src: String, dst: String) throws -> Bool {
        let (dstLinkKind, _) = entityType(dst, followSymlinks: false)
        if dstLinkKind == .symlink || dstLinkKind == .notFound {
            return false
        }
        var srcStat = Darwin.stat()
        var dstStat = Darwin.stat()
        guard fstatat(AT_FDCWD, src, &srcStat, 0) == 0,
              fstatat(AT_FDCWD, dst, &dstStat, 0) == 0,
              srcStat.st_dev == dstStat.st_dev,
              srcStat.st_ino == dstStat.st_ino else {
            return false
        }
        let dstName = (dst as NSString).lastPathComponent
        let parentDir = (dst as NSString).deletingLastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(atPath: parentDir)
        return !entries.contains(dstName)
    }

    private func relocate(from: String, to: String) throws {
        let src = try resolveRealPath(from)
        let dst = try resolveRealPath(to)
        let (srcKind, _) = entityType(src, followSymlinks: false)
        if srcKind == .notFound {
            throw StorageError(.notFound, "源路径不存在：\(from)")
        }
        if posixTrimDir(from) == posixTrimDir(to) {
            return
        }
        let (dstKind, _) = entityType(dst, followSymlinks: false)
        var isFoldedSame = false
        if dstKind != .notFound {
            isFoldedSame = try isSameFoldedEntry(src: src, dst: dst)
            if !isFoldedSame {
                throw StorageError(.alreadyExists, "目标已存在：\(to)")
            }
        }

        try io(from) {
            if Darwin.rename(src, dst) == 0 {
                if isFoldedSame {
                    let parentDir = (dst as NSString).deletingLastPathComponent
                    let dstName = (dst as NSString).lastPathComponent
                    let updatedEntries = (try? FileManager.default.contentsOfDirectory(atPath: parentDir)) ?? []
                    if updatedEntries.contains(dstName) {
                        return
                    }
                    // Underlying filesystem (e.g. certain SMB shares) ignored in-place case rename; hop via temp name.
                    let tmp = (parentDir as NSString).appendingPathComponent(".tidyreel-case-\(UUID().uuidString)")
                    if Darwin.rename(src, tmp) != 0 {
                        try posixThrow(errno, virtualPath: from, op: "rename")
                    }
                    if Darwin.rename(tmp, dst) != 0 {
                        let err = errno
                        _ = Darwin.rename(tmp, src)
                        try posixThrow(err, virtualPath: from, op: "rename")
                    }
                }
                return
            }

            let renameErr = errno
            if isFoldedSame && (renameErr == EEXIST || renameErr == EINVAL) {
                let parentDir = (dst as NSString).deletingLastPathComponent
                let tmp = (parentDir as NSString).appendingPathComponent(".tidyreel-case-\(UUID().uuidString)")
                if Darwin.rename(src, tmp) != 0 {
                    try posixThrow(errno, virtualPath: from, op: "rename")
                }
                if Darwin.rename(tmp, dst) != 0 {
                    let err = errno
                    _ = Darwin.rename(tmp, src)
                    try posixThrow(err, virtualPath: from, op: "rename")
                }
                return
            }
            if renameErr == EXDEV {
                try FileManager.default.moveItem(atPath: src, toPath: dst)
                return
            }
            try posixThrow(renameErr, virtualPath: from, op: "rename")
        }
    }

    public var supportsAtomicRelocate: Bool { true }

    public func atomicRelocate(from src: String, to dst: String) async throws {
        let realSrc = try resolveRealPath(src)
        _ = try resolveRealPath(dst)
        let cleanSrc = posixTrimDir(src)
        let cleanDst = posixTrimDir(dst)
        if cleanSrc == cleanDst {
            try await LocalIOExecutor.shared.run {
                let (srcKind, _) = self.entityType(realSrc, followSymlinks: false)
                if srcKind == .notFound {
                    throw StorageError(.notFound, "源路径不存在：\(src)")
                }
            }
            return
        }
        if cleanSrc == "/" {
            throw StorageError(.other, "无法移动根目录：\(src)")
        }
        let srcParentVirtual = posixDirname(cleanSrc)
        let dstParentVirtual = posixDirname(cleanDst)
        let realDstParent = try resolveRealPath(dstParentVirtual)
        try await LocalIOExecutor.shared.run {
            let (srcKind, _) = self.entityType(realSrc, followSymlinks: false)
            if srcKind == .notFound {
                throw StorageError(.notFound, "源路径不存在：\(src)")
            }
            if srcKind == .directory && cleanDst.hasPrefix(cleanSrc + "/") {
                throw StorageError(.other, "无法将目录移动到自身子目录：\(src) -> \(dst)")
            }
            if srcParentVirtual != dstParentVirtual {
                let (parentKind, _) = self.entityType(realDstParent, followSymlinks: true)
                if parentKind == .notFound {
                    try self.io(dstParentVirtual) {
                        try FileManager.default.createDirectory(
                            atPath: realDstParent,
                            withIntermediateDirectories: true
                        )
                    }
                } else if parentKind != .directory {
                    throw StorageError(.alreadyExists, "路径已存在且不是目录：\(dstParentVirtual)")
                }
            }
            try self.relocate(from: src, to: dst)
        }
    }

    public func rename(_ path: String, newName: String) async throws {
        try validateChildName(newName)
        let target = posixJoin(posixDirname(path), newName)
        try await LocalIOExecutor.shared.run {
            try self.relocate(from: path, to: target)
        }
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        _ = try resolveRealPath(dir)
        for (oldName, newName) in names {
            try validateChildName(oldName)
            try validateChildName(newName)
        }
        if names.isEmpty { return }
        let sortedPairs: [(old: String, new: String)] = names.keys.sorted().compactMap { key in
            guard let newName = names[key] else { return nil }
            return (key, newName)
        }
        try await LocalIOExecutor.shared.run {
            for pair in sortedPairs {
                try self.relocate(from: posixJoin(dir, pair.old), to: posixJoin(dir, pair.new))
            }
        }
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        _ = try resolveRealPath(srcDir)
        let realDst = try resolveRealPath(dstDir)
        for name in names {
            try validateChildName(name)
        }
        if names.isEmpty { return }
        try await LocalIOExecutor.shared.run {
            let (dstKind, _) = self.entityType(realDst, followSymlinks: true)
            guard dstKind == .directory else {
                throw StorageError(.notFound, "目标目录不存在：\(dstDir)")
            }
            for name in names {
                try self.relocate(from: posixJoin(srcDir, name), to: posixJoin(dstDir, name))
            }
        }
    }

    public func remove(dir: String, names: [String]) async throws {
        _ = try resolveRealPath(dir)
        for name in names {
            try validateChildName(name)
        }
        if names.isEmpty { return }
        try await LocalIOExecutor.shared.run {
            for name in names {
                let vpath = posixJoin(dir, name)
                let real = try self.resolveRealPath(vpath)
                let (kind, _) = self.entityType(real, followSymlinks: false)
                if kind == .notFound {
                    throw StorageError(.notFound, "路径不存在：\(vpath)")
                }
                try self.io(vpath) {
                    if kind == .symlink {
                        if Darwin.unlink(real) != 0 {
                            try self.posixThrow(errno, virtualPath: vpath, op: "unlink")
                        }
                    } else {
                        try FileManager.default.removeItem(atPath: real)
                    }
                }
            }
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        let real = try resolveRealPath(path)
        return try await LocalIOExecutor.shared.run {
            let (kind, _) = self.entityType(real, followSymlinks: false)
            return kind != .notFound
        }
    }

    public func ping() async throws {
        try await LocalIOExecutor.shared.run {
            let (kind, _) = self.entityType(self.rootPath, followSymlinks: true)
            guard kind == .directory else {
                throw StorageError(.notFound, "本地目录不存在：\(self.rootPath)")
            }
        }
    }

    public func close() async {}
}
