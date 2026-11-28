import Foundation
import TidyreelModels

public actor ThrottledBackend: RangeReadableBackend {
    public nonisolated let inner: any StorageBackend
    private let minIntervalMs: @Sendable () -> Int
    private let backoffMs: [Int]
    private let sleepMs: @Sendable (Int) async throws -> Void
    private let nowMs: @Sendable () -> Int64
    private var lastSlotMs: Int64?
    private var cooldownUntilMs: Int64 = 0

    public init(
        _ inner: any StorageBackend,
        minIntervalMs: @escaping @Sendable () -> Int = { 200 }
    ) {
        self.inner = inner
        self.minIntervalMs = minIntervalMs
        self.backoffMs = [1000, 2000, 4000]
        self.sleepMs = { ms in
            if ms > 0 {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
        }
        self.nowMs = {
            Int64(ProcessInfo.processInfo.systemUptime * 1000.0)
        }
    }

    init(
        testing inner: any StorageBackend,
        minIntervalMs: @escaping @Sendable () -> Int,
        backoffMs: [Int] = [1000, 2000, 4000],
        sleepMs: @escaping @Sendable (Int) async throws -> Void,
        nowMs: @escaping @Sendable () -> Int64
    ) {
        self.inner = inner
        self.minIntervalMs = minIntervalMs
        self.backoffMs = backoffMs
        self.sleepMs = sleepMs
        self.nowMs = nowMs
    }

    private func waitForSlot() async throws {
        let rawInterval = minIntervalMs()
        let current = nowMs()
        let interval = rawInterval > 0 ? Int64(rawInterval) : 0

        var scheduled = current
        if interval > 0, let last = lastSlotMs {
            scheduled = max(scheduled, last + interval)
        }
        if cooldownUntilMs > scheduled {
            scheduled = cooldownUntilMs
        }
        if interval > 0 {
            lastSlotMs = scheduled
        }
        let wait = scheduled - current
        if wait > 0 {
            try await sleepMs(Int(wait))
        }
    }

    private func throttledCall<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try await waitForSlot()
            do {
                return try await operation()
            } catch let err as StorageError {
                let retryable = err.code == .rateLimited || err.code == .network || err.code == .busy
                if !retryable || attempt >= backoffMs.count {
                    if err.code == .rateLimited {
                        let cooldownDelay = Int64(backoffMs.last ?? 1000)
                        let until = nowMs() + cooldownDelay
                        if until > cooldownUntilMs {
                            cooldownUntilMs = until
                        }
                    }
                    throw err
                }
                let delay = backoffMs[attempt]
                if err.code == .rateLimited {
                    let until = nowMs() + Int64(delay)
                    if until > cooldownUntilMs {
                        cooldownUntilMs = until
                    }
                }
                attempt += 1
                try await sleepMs(delay)
            }
        }
    }

    private static func unwrapped(_ backend: any StorageBackend) -> any StorageBackend {
        if let cached = backend as? CachedBackend {
            return unwrapped(cached.inner)
        }
        if let throttled = backend as? ThrottledBackend {
            return unwrapped(throttled.inner)
        }
        return backend
    }

    public nonisolated var supportsServerBatching: Bool {
        inner.supportsServerBatching
    }

    public nonisolated var supportsAtomicRelocate: Bool {
        inner.supportsAtomicRelocate
    }

    public func atomicRelocate(from src: String, to dst: String) async throws {
        try await throttledCall {
            try await inner.atomicRelocate(from: src, to: dst)
        }
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        if !refresh, let cached = inner as? CachedBackend, await cached.isCached(dir) {
            return try await cached.list(dir, refresh: false)
        }
        return try await throttledCall {
            try await inner.list(dir, refresh: refresh)
        }
    }

    public func mkdirs(_ dir: String) async throws {
        try await throttledCall {
            try await inner.mkdirs(dir)
        }
    }

    public func rename(_ path: String, newName: String) async throws {
        try await throttledCall {
            try await inner.rename(path, newName: newName)
        }
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        if Self.unwrapped(inner) is AlistBackend {
            try await throttledCall {
                try await inner.renameMany(dir, names: names)
            }
            return
        }
        for key in names.keys.sorted() {
            guard let newName = names[key] else { continue }
            try await rename(posixJoin(dir, key), newName: newName)
        }
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        if Self.unwrapped(inner) is AlistBackend {
            try await throttledCall {
                try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names)
            }
            return
        }
        for name in names {
            try await throttledCall {
                try await inner.move(srcDir: srcDir, dstDir: dstDir, names: [name])
            }
        }
    }

    public func removeScannedFile(_ path: String, identity: String?) async throws {
        try await throttledCall { try await inner.removeScannedFile(path, identity: identity) }
    }

    public func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool {
        try await throttledCall {
            try await inner.removeDirectoryIfEmpty(dir, removingSystemFiles: removingSystemFiles)
        }
    }

    public func remove(dir: String, names: [String]) async throws {
        if Self.unwrapped(inner) is AlistBackend {
            try await throttledCall {
                try await inner.remove(dir: dir, names: names)
            }
            return
        }
        for name in names {
            try await throttledCall {
                try await inner.remove(dir: dir, names: [name])
            }
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        try await throttledCall {
            try await inner.exists(path)
        }
    }

    public func read(_ path: String) async throws -> Data {
        try await throttledCall {
            try await inner.read(path)
        }
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        guard Self.unwrapped(inner) is any RangeReadableBackend,
              let rangeInner = inner as? any RangeReadableBackend else {
            throw StorageError(.other, "不支持分段读取")
        }
        return try await throttledCall {
            try await rangeInner.readRange(path: path, start: start, length: length)
        }
    }

    public func write(_ path: String, bytes: Data) async throws {
        try await throttledCall {
            try await inner.write(path, bytes: bytes)
        }
    }

    public func ping() async throws {
        try await throttledCall {
            try await inner.ping()
        }
    }

    public func close() async {
        await inner.close()
    }
}
