import Foundation
import TidyreelModels

// MARK: - Concurrency Primitives

internal final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

internal final class WorkQueue<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let items: [Element]
    private var index = 0

    init(_ items: [Element]) {
        self.items = items
    }

    func next() -> Element? {
        lock.withLock {
            guard index < items.count else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }
}

internal final class ActiveJobTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var finishedEarly: Set<UUID> = []

    func register(_ id: UUID, task: Task<Void, Never>) {
        lock.withLock {
            if finishedEarly.remove(id) == nil {
                tasks[id] = task
            }
        }
    }

    func unregister(_ id: UUID) {
        lock.withLock {
            if tasks.removeValue(forKey: id) == nil {
                finishedEarly.insert(id)
            }
        }
    }

    func snapshot() -> [Task<Void, Never>] {
        lock.withLock { Array(tasks.values) }
    }
}

// MARK: - Throttled & Retrying Backend Wrapper

internal final class ExecutionThrottledBackend: StorageBackend, RangeReadableBackend, @unchecked Sendable {
    let inner: any StorageBackend
    let minIntervalMs: Int
    let backoffMs: [Int]
    let sleepMs: @Sendable (Int) async -> Void

    private let lock = NSLock()
    private var lastSlot: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    init(
        inner: any StorageBackend,
        minIntervalMs: Int,
        backoffMs: [Int],
        sleepMs: @escaping @Sendable (Int) async -> Void
    ) {
        self.inner = inner
        self.minIntervalMs = max(0, minIntervalMs)
        self.backoffMs = backoffMs
        self.sleepMs = sleepMs
    }

    var supportsServerBatching: Bool { inner.supportsServerBatching }
    var supportsAtomicRelocate: Bool { inner.supportsAtomicRelocate }

    static func isAlreadyThrottled(_ backend: any StorageBackend) -> Bool {
        if backend is ExecutionThrottledBackend { return true }
        let typeName = String(describing: type(of: backend))
        if typeName == "ThrottledBackend" { return true }
        for child in Mirror(reflecting: backend).children {
            if let wrapped = child.value as? any StorageBackend, isAlreadyThrottled(wrapped) {
                return true
            }
        }
        return false
    }

    private func acquireSlot(afterOwnCooldown ownCooldown: TimeInterval) async {
        let intervalSec = Double(minIntervalMs) / 1000.0
        let waitMs: Int = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            var scheduled = now
            if minIntervalMs > 0 {
                scheduled = max(scheduled, lastSlot + intervalSec)
            }
            if cooldownUntil > ownCooldown && cooldownUntil > scheduled {
                scheduled = cooldownUntil
            }
            if minIntervalMs > 0 {
                lastSlot = scheduled
            }
            let diff = scheduled - now
            return diff > 0 ? Int((diff * 1000.0).rounded(.up)) : 0
        }
        if waitMs > 0 {
            await sleepMs(waitMs)
        }
    }

    @discardableResult
    private func advanceCooldown(delayMs: Int) -> TimeInterval {
        lock.withLock {
            let until = ProcessInfo.processInfo.systemUptime + Double(max(0, delayMs)) / 1000.0
            if until > cooldownUntil {
                cooldownUntil = until
            }
            return until
        }
    }

    private func call<T>(_ fn: () async throws -> T) async throws -> T {
        var attempt = 0
        var ownCooldown: TimeInterval = 0
        while true {
            await acquireSlot(afterOwnCooldown: ownCooldown)
            do {
                return try await fn()
            } catch let e as StorageError {
                let retryable = e.code == .rateLimited || e.code == .network || e.code == .busy
                if !retryable || attempt >= backoffMs.count {
                    if e.code == .rateLimited {
                        _ = advanceCooldown(delayMs: backoffMs.last ?? 1000)
                    }
                    throw e
                }
                let delay = backoffMs[attempt]
                if e.code == .rateLimited {
                    ownCooldown = advanceCooldown(delayMs: delay)
                }
                await sleepMs(delay)
                attempt += 1
            }
        }
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] {
        try await call { try await inner.list(dir, refresh: refresh) }
    }

    func mkdirs(_ dir: String) async throws {
        try await call { try await inner.mkdirs(dir) }
    }

    func rename(_ path: String, newName: String) async throws {
        try await call { try await inner.rename(path, newName: newName) }
    }

    func atomicRelocate(from src: String, to dst: String) async throws {
        try await call { try await inner.atomicRelocate(from: src, to: dst) }
    }

    func renameMany(_ dir: String, names: [String: String]) async throws {
        if inner.supportsServerBatching {
            try await call { try await inner.renameMany(dir, names: names) }
            return
        }
        for oldName in names.keys.sorted() {
            if let newName = names[oldName] {
                try await rename(joinPath(dir, oldName), newName: newName)
            }
        }
    }

    func move(srcDir: String, dstDir: String, names: [String]) async throws {
        if inner.supportsServerBatching {
            try await call { try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names) }
            return
        }
        for name in names {
            try await call { try await inner.move(srcDir: srcDir, dstDir: dstDir, names: [name]) }
        }
    }

    func remove(dir: String, names: [String]) async throws {
        if inner.supportsServerBatching {
            try await call { try await inner.remove(dir: dir, names: names) }
            return
        }
        for name in names {
            try await call { try await inner.remove(dir: dir, names: [name]) }
        }
    }

    func exists(_ path: String) async throws -> Bool {
        try await call { try await inner.exists(path) }
    }

    func read(_ path: String) async throws -> Data {
        try await call { try await inner.read(path) }
    }

    func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        guard let readable = inner as? any RangeReadableBackend else {
            throw StorageError(.other, "不支持分段读取")
        }
        return try await call { try await readable.readRange(path: path, start: start, length: length) }
    }

    func write(_ path: String, bytes: Data) async throws {
        try await call { try await inner.write(path, bytes: bytes) }
    }

    func ping() async throws {
        try await call { try await inner.ping() }
    }

    func close() async {
        await inner.close()
    }
}
