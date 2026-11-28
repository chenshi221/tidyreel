import Foundation
import TidyreelFakes
import TidyreelModels

// MARK: - Async Gate & Test Helpers

final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(initiallyOpen: Bool = false) {
        self.isOpen = initiallyOpen
    }

    func wait() async {
        let alreadyOpen = lock.withLock { isOpen }
        if alreadyOpen { return }
        await withCheckedContinuation { cont in
            let openNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(cont)
                return false
            }
            if openNow { cont.resume() }
        }
    }

    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for w in toResume { w.resume() }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&_value) }
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

extension MemoryStorageBackend {
    func allFilePaths() async -> [String] {
        let found = LockedBox<[String]>([])
        try? await walkDirs(roots: ["/"], parallel: 4) { dir in
            guard let entries = try? await self.list(dir, refresh: true) else { return [] }
            var subDirs: [String] = []
            for e in entries {
                if e.isDir {
                    subDirs.append(e.path)
                } else {
                    found.withValue { $0.append(e.path) }
                }
            }
            return subDirs
        }
        return found.value.sorted()
    }

    func addFile(_ path: String, size: Int = 1) async {
        try? await write(path, bytes: Data(count: max(0, size)))
    }

    func textOf(_ path: String) async -> String? {
        guard let data = try? await read(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class HookBackend: StorageBackend, @unchecked Sendable {
    let inner: MemoryStorageBackend
    let supportsServerBatching: Bool
    let supportsAtomicRelocate: Bool
    let before: (@Sendable (String, [String]) async throws -> Void)?
    private let callsBox = LockedBox<[String]>([])

    init(
        _ inner: MemoryStorageBackend,
        supportsServerBatching: Bool = false,
        supportsAtomicRelocate: Bool = false,
        before: (@Sendable (String, [String]) async throws -> Void)? = nil
    ) {
        self.inner = inner
        self.supportsServerBatching = supportsServerBatching
        self.supportsAtomicRelocate = supportsAtomicRelocate
        self.before = before
    }

    var calls: [String] { callsBox.value }

    private func record<T>(_ method: String, _ args: [String], _ fn: () async throws -> T) async throws -> T {
        callsBox.withValue { $0.append(([method] + args).joined(separator: " ")) }
        try await before?(method, args)
        return try await fn()
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] {
        try await record("list", [dir]) { try await inner.list(dir, refresh: refresh) }
    }

    func mkdirs(_ dir: String) async throws {
        try await record("mkdirs", [dir]) { try await inner.mkdirs(dir) }
    }

    func rename(_ path: String, newName: String) async throws {
        try await record("rename", [path, newName]) { try await inner.rename(path, newName: newName) }
    }

    func atomicRelocate(from src: String, to dst: String) async throws {
        try await record("atomicRelocate", [src, dst]) {
            if src != dst, try await inner.exists(dst) {
                throw StorageError(.alreadyExists, "目标已存在：\(dst)")
            }
            try await inner.atomicRelocate(from: src, to: dst)
        }
    }

    func renameMany(_ dir: String, names: [String: String]) async throws {
        let pairs = names.keys.sorted().map { "\($0)>\(names[$0]!)" }
        try await record("renameMany", [dir] + pairs) { try await inner.renameMany(dir, names: names) }
    }

    func move(srcDir: String, dstDir: String, names: [String]) async throws {
        try await record("move", [srcDir, dstDir] + names) {
            try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names)
        }
    }

    func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool {
        try await record("removeDirectoryIfEmpty", [dir]) {
            try await inner.removeDirectoryIfEmpty(dir, removingSystemFiles: removingSystemFiles)
        }
    }

    func removeScannedFile(_ path: String, identity: String?) async throws {
        try await record("remove", [dirOf(path), baseOf(path)]) { try await inner.removeScannedFile(path, identity: identity) }
    }

    func remove(dir: String, names: [String]) async throws {
        try await record("remove", [dir] + names) { try await inner.remove(dir: dir, names: names) }
    }

    func exists(_ path: String) async throws -> Bool {
        try await record("exists", [path]) { try await inner.exists(path) }
    }

    func read(_ path: String) async throws -> Data {
        try await record("read", [path]) { try await inner.read(path) }
    }

    func write(_ path: String, bytes: Data) async throws {
        try await record("write", [path]) { try await inner.write(path, bytes: bytes) }
    }

    func ping() async throws {}
    func close() async { await inner.close() }
}

/// Mock backend named `AlistBackend` to verify true server-side batch delegation.
final class AlistBackend: StorageBackend, @unchecked Sendable {
    let hook: HookBackend
    init(_ hook: HookBackend) { self.hook = hook }
    var supportsServerBatching: Bool { true }
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { try await hook.list(dir, refresh: refresh) }
    func mkdirs(_ dir: String) async throws { try await hook.mkdirs(dir) }
    func rename(_ path: String, newName: String) async throws { try await hook.rename(path, newName: newName) }
    func renameMany(_ dir: String, names: [String: String]) async throws { try await hook.renameMany(dir, names: names) }
    func move(srcDir: String, dstDir: String, names: [String]) async throws { try await hook.move(srcDir: srcDir, dstDir: dstDir, names: names) }
    func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool {
        try await hook.removeDirectoryIfEmpty(dir, removingSystemFiles: removingSystemFiles)
    }
    func removeScannedFile(_ path: String, identity: String?) async throws { try await hook.removeScannedFile(path, identity: identity) }
    func remove(dir: String, names: [String]) async throws { try await hook.remove(dir: dir, names: names) }
    func exists(_ path: String) async throws -> Bool { try await hook.exists(path) }
    func read(_ path: String) async throws -> Data { try await hook.read(path) }
    func write(_ path: String, bytes: Data) async throws { try await hook.write(path, bytes: bytes) }
    func ping() async throws { try await hook.ping() }
    func close() async { await hook.close() }
}

func collectStream(_ stream: AsyncThrowingStream<ExecProgress, any Error>) async throws -> [ExecProgress] {
    var out: [ExecProgress] = []
    for try await item in stream {
        out.append(item)
    }
    return out
}

func statusCounts(_ records: [HistoryRecord]) -> [OpStatus: Int] {
    var counts: [OpStatus: Int] = [:]
    for r in records {
        counts[r.status, default: 0] += 1
    }
    return counts
}
