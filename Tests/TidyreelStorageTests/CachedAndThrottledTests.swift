import Foundation
import Testing
import TidyreelFakes
import TidyreelModels
@testable import TidyreelStorage

private actor CountingStorageBackend: RangeReadableBackend {
    private let mem: MemoryStorageBackend
    private(set) var lists: [String] = []
    private(set) var existsCalls: [String] = []
    private(set) var moves: [[String]] = []
    private(set) var removes: [[String]] = []
    private(set) var closed = false

    init(_ files: [String: Int] = [:]) {
        self.mem = MemoryStorageBackend(initialSizes: files)
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] {
        lists.append(dir)
        return try await mem.list(dir, refresh: refresh)
    }

    func mkdirs(_ dir: String) async throws {
        try await mem.mkdirs(dir)
    }

    func rename(_ path: String, newName: String) async throws {
        try await mem.rename(path, newName: newName)
    }

    func renameMany(_ dir: String, names: [String: String]) async throws {
        try await mem.renameMany(dir, names: names)
    }

    func move(srcDir: String, dstDir: String, names: [String]) async throws {
        moves.append([srcDir, dstDir] + names)
        try await mem.move(srcDir: srcDir, dstDir: dstDir, names: names)
    }

    func remove(dir: String, names: [String]) async throws {
        removes.append([dir] + names)
        try await mem.remove(dir: dir, names: names)
    }

    func exists(_ path: String) async throws -> Bool {
        existsCalls.append(path)
        return try await mem.exists(path)
    }

    func read(_ path: String) async throws -> Data {
        try await mem.read(path)
    }

    func write(_ path: String, bytes: Data) async throws {
        try await mem.write(path, bytes: bytes)
    }

    func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        try await mem.readRange(path: path, start: start, length: length)
    }

    func ping() async throws {
        try await mem.ping()
    }

    func close() async {
        closed = true
        await mem.close()
    }
}

private struct NonRangeBackend: StorageBackend {
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { [] }
    func mkdirs(_ dir: String) async throws {}
    func rename(_ path: String, newName: String) async throws {}
    func renameMany(_ dir: String, names: [String: String]) async throws {}
    func move(srcDir: String, dstDir: String, names: [String]) async throws {}
    func remove(dir: String, names: [String]) async throws {}
    func exists(_ path: String) async throws -> Bool { true }
    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, bytes: Data) async throws {}
    func ping() async throws {}
    func close() async {}
}

private actor FlakyRangeBackend: RangeReadableBackend {
    private let mem = MemoryStorageBackend()
    private let failCodes: [StorageErrorCode]
    private(set) var attempts = 0

    init(failCodes: [StorageErrorCode]) {
        self.failCodes = failCodes
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { try await mem.list(dir, refresh: refresh) }
    func mkdirs(_ dir: String) async throws { try await mem.mkdirs(dir) }
    func rename(_ path: String, newName: String) async throws { try await mem.rename(path, newName: newName) }
    func renameMany(_ dir: String, names: [String: String]) async throws { try await mem.renameMany(dir, names: names) }
    func move(srcDir: String, dstDir: String, names: [String]) async throws { try await mem.move(srcDir: srcDir, dstDir: dstDir, names: names) }
    func remove(dir: String, names: [String]) async throws { try await mem.remove(dir: dir, names: names) }
    func exists(_ path: String) async throws -> Bool { try await mem.exists(path) }
    func read(_ path: String) async throws -> Data { try await mem.read(path) }
    func write(_ path: String, bytes: Data) async throws { try await mem.write(path, bytes: bytes) }
    func ping() async throws {}
    func close() async {}

    func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        let idx = attempts
        attempts += 1
        if idx < failCodes.count {
            throw StorageError(failCodes[idx], "fail #\(idx)")
        }
        return try await mem.readRange(path: path, start: start, length: length)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@Suite("CachedBackend & ThrottledBackend Tests")
struct CachedAndThrottledTests {
    // MARK: - CachedBackend

    @Test("CachedBackend deduplicates concurrent & repeat listings, expires by TTL, and supports listRecent")
    func cachedListingsAndTTL() async throws {
        let clock = MutableClock()
        let inner = CountingStorageBackend(["/a/x.mkv": 1, "/a/b/y.mkv": 1])
        let be = CachedBackend(inner, ttl: 600, now: { clock.now() })

        async let l1 = be.list("/a")
        async let l2 = be.list("/a")
        _ = try await (l1, l2)
        _ = try await be.list("/a/")
        #expect(await be.isCached("/a") == true)
        #expect(await be.isCached("/a/") == true)
        #expect(await inner.lists == ["/a"])

        // listRecent within maxAge reuses cache; past maxAge refreshes
        _ = try await be.listRecent("/a", maxAge: 120)
        #expect(await inner.lists.count == 1)

        clock.advance(180)
        _ = try await listFresh(be, dir: "/a", maxAge: 120)
        #expect(await inner.lists.count == 2)

        // Past TTL re-fetches
        clock.advance(660)
        #expect(await be.isCached("/a") == false)
        _ = try await be.list("/a")
        #expect(await inner.lists.count == 3)

        await be.close()
        #expect(await inner.closed == true)
    }

    @Test("CachedBackend invalidates touched folders on mutations, does not cache errors, and enforces maxEntries")
    func cachedInvalidationErrorsAndEviction() async throws {
        let clock = MutableClock()
        let inner = CountingStorageBackend(["/a/x.mkv": 1, "/a/b/y.mkv": 1])
        let be = CachedBackend(inner, ttl: 600, now: { clock.now() })

        // Failures are not cached
        await expectStorageError(.notFound) {
            _ = try await be.list("/nope")
        }
        try await inner.write("/nope/z.mkv", bytes: Data([1]))
        let nopeEntries = try await be.list("/nope")
        #expect(nopeEntries.map(\.name) == ["z.mkv"])

        // Ancestor & targeted invalidation
        _ = try await be.list("/")
        _ = try await be.list("/a")
        _ = try await be.list("/a/b")

        try await be.write("/a/b/new.nfo", bytes: Data([1, 2]))
        #expect(await be.isCached("/a/b") == false)
        #expect(await be.isCached("/a") == true)
        #expect(await be.isCached("/") == true)

        _ = try await be.list("/a/b")
        try await be.rename("/a/b/y.mkv", newName: "z.mkv")
        #expect(await be.isCached("/a/b") == false)
        #expect(await be.isCached("/a") == true)

        try await be.mkdirs("/a/newdir/deep")
        #expect(await be.isCached("/a") == false)
        #expect(await be.isCached("/") == true)

        await be.invalidate("/")
        #expect(await be.isCached("/") == false)

        // LRU cap eviction
        var capSeed: [String: Int] = [:]
        for i in 0..<6 { capSeed["/d\(i)/f.mkv"] = 1 }
        let capInner = CountingStorageBackend(capSeed)
        let capped = CachedBackend(capInner, maxEntries: 3, now: { clock.now() })
        for i in 0..<5 {
            _ = try await capped.list("/d\(i)")
        }
        #expect(await capped.isCached("/d0") == false)
        #expect(await capped.isCached("/d1") == false)
        #expect(await capped.isCached("/d2") == true)
        #expect(await capped.isCached("/d3") == true)
        #expect(await capped.isCached("/d4") == true)

        // readRange delegates and rejects non-range inner
        try await inner.write("/a/video.mkv", bytes: Data([0, 1, 2, 3, 4, 5]))
        #expect(Array(try await be.readRange(path: "/a/video.mkv", start: 2, length: 3)) == [2, 3, 4])

        let nonRangeCached = CachedBackend(NonRangeBackend())
        await expectStorageError(.other) {
            _ = try await nonRangeCached.readRange(path: "/x.mkv", start: 0, length: 4)
        }
    }

    // MARK: - ThrottledBackend

    @Test("ThrottledBackend applies dynamic minIntervalMs immediately on every request")
    func throttledDynamicInterval() async throws {
        let fs = MemoryStorageBackend(initialFiles: ["/a.bin": Data([0, 1, 2, 3])])
        final class PaceBox: @unchecked Sendable {
            var interval = 200
            var delays: [Int] = []
            var clockMs: Int64 = 10_000
        }
        let box = PaceBox()

        let be = ThrottledBackend(
            testing: fs,
            minIntervalMs: { box.interval },
            sleepMs: { ms in box.delays.append(ms) },
            nowMs: { box.clockMs }
        )

        // Public 2-argument initializer also compiles & works
        let publicBe = ThrottledBackend(fs, minIntervalMs: { 0 })
        #expect(try await publicBe.exists("/a.bin") == true)

        _ = try await be.exists("/a.bin")
        #expect(box.delays.isEmpty)

        _ = try await be.exists("/a.bin")
        #expect(box.delays == [200])

        box.interval = 500
        _ = try await be.exists("/a.bin")
        #expect(box.delays.last == 700)

        box.interval = 0
        _ = try await be.exists("/a.bin")
        #expect(box.delays.count == 2)

        box.interval = -50
        _ = try await be.exists("/a.bin")
        #expect(box.delays.count == 2)
    }

    @Test("ThrottledBackend retries transient errors on readRange and fails immediately on non-range inner")
    func throttledRetriesAndReadRange() async throws {
        let flaky = FlakyRangeBackend(failCodes: [.rateLimited, .network])
        try await flaky.write("/video.mkv", bytes: Data([10, 20, 30, 40, 50]))

        final class RetryBox: @unchecked Sendable {
            var delays: [Int] = []
            var clockMs: Int64 = 1_000
        }
        let box = RetryBox()

        let be = ThrottledBackend(
            testing: flaky,
            minIntervalMs: { 100 },
            backoffMs: [1000, 2000, 4000],
            sleepMs: { ms in
                box.delays.append(ms)
                box.clockMs += Int64(ms)
            },
            nowMs: { box.clockMs }
        )

        let bytes = try await be.readRange(path: "/video.mkv", start: 1, length: 3)
        #expect(Array(bytes) == [20, 30, 40])
        #expect(await flaky.attempts == 3)
        #expect(box.delays == [1000, 2000])

        // Non-range inner fails immediately without sleeping
        box.delays.removeAll()
        let nonRangeBe = ThrottledBackend(
            testing: NonRangeBackend(),
            minIntervalMs: { 100 },
            sleepMs: { ms in box.delays.append(ms) },
            nowMs: { box.clockMs }
        )
        await expectStorageError(.other) {
            _ = try await nonRangeBe.readRange(path: "/a.mkv", start: 0, length: 16)
        }
        #expect(box.delays.isEmpty)
    }

    @Test("ThrottledBackend paces per-file on non-Alist backends and keeps batch ops for Alist behind CachedBackend")
    func throttledAlistUnwrapVsPerFilePacing() async throws {
        let recorder = CountingStorageBackend([
            "/src/a.mkv": 1,
            "/src/b.mkv": 2,
            "/src/c.mkv": 3,
        ])
        try await recorder.mkdirs("/dst")

        final class ClockBox: @unchecked Sendable {
            var delays: [Int] = []
            var clockMs: Int64 = 5_000
        }
        let box = ClockBox()

        let be = ThrottledBackend(
            testing: recorder,
            minIntervalMs: { 100 },
            sleepMs: { ms in
                box.delays.append(ms)
                box.clockMs += Int64(ms)
            },
            nowMs: { box.clockMs }
        )

        try await be.move(srcDir: "/src", dstDir: "/dst", names: ["a.mkv", "b.mkv", "c.mkv"])
        #expect(await recorder.moves == [
            ["/src", "/dst", "a.mkv"],
            ["/src", "/dst", "b.mkv"],
            ["/src", "/dst", "c.mkv"],
        ])
        #expect(box.delays == [100, 100])

        box.delays.removeAll()
        box.clockMs += 1000
        try await be.remove(dir: "/dst", names: ["a.mkv", "b.mkv", "c.mkv"])
        #expect(await recorder.removes == [
            ["/dst", "a.mkv"],
            ["/dst", "b.mkv"],
            ["/dst", "c.mkv"],
        ])
        #expect(box.delays == [100, 100])

        // Alist wrapped inside CachedBackend + ThrottledBackend still sends single batch_rename / move / remove
        let mockAlist = MockAlistTransport(files: [
            "/src/1": 1,
            "/src/2": 1,
            "/dst/keep": 1,
        ])
        let alist = AlistBackend(
            config: ConnectionConfig(id: "a", name: "a", type: .alist, endpoint: "http://alist.local", username: "admin"),
            credentials: Credentials(password: "pw"),
            transport: mockAlist
        )
        let cachedAlist = CachedBackend(alist)
        let throttledAlist = ThrottledBackend(cachedAlist, minIntervalMs: { 0 })

        try await throttledAlist.renameMany("/src", names: ["1": "a.mkv", "2": "b.mkv"])
        #expect(mockAlist.calls.filter { $0.contains("rename") } == ["api/fs/batch_rename"])

        try await throttledAlist.move(srcDir: "/src", dstDir: "/dst", names: ["a.mkv", "b.mkv"])
        #expect(mockAlist.calls.filter { $0 == "api/fs/move" }.count == 1)

        try await throttledAlist.remove(dir: "/dst", names: ["a.mkv", "b.mkv"])
        #expect(mockAlist.calls.filter { $0 == "api/fs/remove" }.count == 1)
    }

    @Test("A single oversized listing bypasses the cache and preserves smaller listings")
    func oversizedListingBypassesCache() async throws {
        let inner = CountingStorageBackend(["/small/a": 1, "/big/a": 1, "/big/b": 1, "/big/c": 1])
        let cache = CachedBackend(inner, maxEntries: 1, maxTotalEntries: 2)
        _ = try await cache.list("/small")
        #expect(try await cache.list("/big").count == 3)
        #expect(await cache.isCached("/small"))
        #expect(await !cache.isCached("/big"))
    }

    @Test("CachedBackend enforces maxTotalEntries, normalizes // and NFC, serves exists from cache, and clears on close")
    func cachedTotalBudgetNormalizationExistsAndClose() async throws {
        let clock = MutableClock()
        let inner = CountingStorageBackend([
            "/a/b/x.mkv": 1,
            "/caf\u{00E9}/ep.mkv": 2,
            "/d1/f1.mkv": 1,
            "/d1/f2.mkv": 1,
            "/d1/f3.mkv": 1,
            "/d2/g1.mkv": 1,
            "/d2/g2.mkv": 1,
            "/d2/g3.mkv": 1,
        ])
        let be = CachedBackend(inner, ttl: 600, maxEntries: 100, maxTotalEntries: 5, now: { clock.now() })

        // Repeated // and NFC/NFD normalization share the same cache key.
        _ = try await be.list("/a//b///")
        _ = try await be.list("/a/b")
        #expect(await inner.lists == ["/a/b"])

        _ = try await be.list("/caf\u{0065}\u{0301}")
        _ = try await be.list("/caf\u{00E9}")
        #expect(await inner.lists.count == 2)

        // exists() hits fresh resolved parent cache without querying inner.
        #expect(try await be.exists("/a/b/x.mkv") == true)
        #expect(try await be.exists("/a/b/missing.mkv") == false)
        #expect(await inner.existsCalls.isEmpty)

        // After mutation invalidates /a/b, exists() delegates to inner again.
        try await be.remove(dir: "/a/b", names: ["x.mkv"])
        #expect(try await be.exists("/a/b/x.mkv") == false)
        #expect(await inner.existsCalls == ["/a/b/x.mkv"])

        // maxTotalEntries (5) evicts older directories once total cached entries exceed budget.
        _ = try await be.list("/d1")
        #expect(await be.isCached("/d1") == true)
        _ = try await be.list("/d2")
        #expect(await be.isCached("/d2") == true)
        #expect(await be.isCached("/d1") == false)

        await be.close()
        #expect(await be.isCached("/d2") == false)
        #expect(await inner.closed == true)
    }

    @Test("ThrottledBackend shares rate-limit cooldown across subsequent callers")
    func throttledRateLimitSharedCooldown() async throws {
        let flaky = FlakyRangeBackend(failCodes: [.rateLimited])
        try await flaky.write("/video.mkv", bytes: Data([1, 2, 3, 4]))

        final class CooldownBox: @unchecked Sendable {
            var delays: [Int] = []
            var clockMs: Int64 = 1_000
        }
        let box = CooldownBox()

        let be = ThrottledBackend(
            testing: flaky,
            minIntervalMs: { 100 },
            backoffMs: [],
            sleepMs: { ms in
                box.delays.append(ms)
                box.clockMs += Int64(ms)
            },
            nowMs: { box.clockMs }
        )

        // First call fails with .rateLimited and advances cooldownUntilMs to 2_000.
        await expectStorageError(.rateLimited) {
            _ = try await be.readRange(path: "/video.mkv", start: 0, length: 2)
        }
        #expect(box.delays.isEmpty)

        // Another caller arriving 200ms later (past minIntervalMs=100) still waits for cooldown (800ms).
        box.clockMs = 1_200
        let data = try await be.readRange(path: "/video.mkv", start: 0, length: 2)
        #expect(Array(data) == [1, 2])
        #expect(box.delays == [800])
    }
}
