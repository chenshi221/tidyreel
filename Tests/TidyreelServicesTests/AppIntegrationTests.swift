import Foundation
import Testing
import TidyreelFakes
@testable import TidyreelModels
@testable import TidyreelPersistence
@testable import TidyreelServices

@Suite("Integrated AppStore, SizeScanner & HealthScanner Tests")
struct AppIntegrationTests {
    @Test("Health deletion stops on WAL failure and leaves unattempted paths intact")
    @MainActor
    func journalHealthDeletion() async throws {
        let fs = MemoryStorageBackend(initialSizes: ["/a": 1, "/b": 2, "/c": 3])
        try await fs.mkdirs("/empty")
        let entries = try await fs.list("/").filter { !$0.isDir }
        let db = try SQLiteDatabase.inMemory()
        let history = SQLiteHistoryStore(db: db)
        var removed: [String] = []
        func confirm() async throws {
            try await HealthDeletion.run(
                confirmation: UUID(), connection: "c", root: "/",
                files: entries.map { ($0.path, $0.deleteIdentity) }, directories: ["/empty", "/"],
                history: history, backend: fs, willAttempt: { _ in }, didRemove: { removed.append($0.src) }
            )
        }

        try await db.executeScript("""
            CREATE TRIGGER fail_intent BEFORE INSERT ON history_records WHEN NEW.src = '/b'
            BEGIN SELECT RAISE(ABORT, 'WAL insert failed'); END;
            """)
        await #expect(throws: SQLiteError.self) { try await confirm() }
        #expect(removed.isEmpty)
        #expect(try await history.batches().isEmpty)
        #expect(try await fs.exists("/a"))

        try await db.executeScript("""
            DROP TRIGGER fail_intent;
            CREATE TRIGGER fail_result BEFORE UPDATE ON history_records WHEN NEW.src = '/b'
            BEGIN SELECT RAISE(ABORT, 'WAL update failed'); END;
            """)
        await #expect(throws: SQLiteError.self) { try await confirm() }
        #expect(removed == ["/a", "/b"])
        let batch = try #require(try await history.batches().first)
        let records = try await history.records(batch: batch.id)
        #expect(records.map(\.op.src) == ["/a", "/b", "/c", "/empty"])
        #expect(records.map(\.status) == [.done, .pending, .pending, .pending])
        #expect(records.last?.op.kind == .healthDeleteEmptyDirectory)
        #expect(try await !fs.exists("/b"))
        #expect(try await fs.exists("/c"))
        #expect(try await fs.exists("/empty"))
        await db.close()
    }

    @Test("Duplicate cleanup verifies a surviving copy against a fresh listing")
    func retainOriginalDuplicateVersion() async throws {
        let fs = MemoryStorageBackend(initialSizes: ["/keeper": 1])
        let entry = try #require(try await fs.list("/").first)
        let keeper = DuplicateMediaCopy(path: entry.path, name: entry.name, fileSize: entry.size,
                                        deleteIdentity: entry.deleteIdentity, qualityRank: 1)
        #expect(try await HealthScannerActor.hasSurvivingCopy([keeper], backend: fs))
        try await fs.removeScannedFile(entry.path, identity: entry.deleteIdentity)
        #expect(try await !HealthScannerActor.hasSurvivingCopy([keeper], backend: fs))
        try await fs.write(entry.path, bytes: Data([0]))
        #expect(try await !HealthScannerActor.hasSurvivingCopy([keeper], backend: fs))
    }

    @Test("End-to-end demo AppStore submits, recognizes, reviews, executes, and undoes cleanly")
    @MainActor
    func demoEndToEndWorkflow() async throws {
        let store = try AppStore.makeDemo()
        #expect(store.connections.count == 2)

        let taskId = try await store.submitTask(
            connection: "demo-alist",
            paths: ["/下载/完成"],
            mode: .inPlace,
            scrape: false,
            scrapeOnly: false
        )

        // Wait until recognition reaches awaitingReview
        var stage: TaskStage = .importing
        for _ in 0..<80 {
            let summaries = await store.taskManager.currentSummaries()
            if let s = summaries.first(where: { $0.id == taskId }) {
                stage = s.stage
                if stage == .awaitingReview || !stage.isActive { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(stage == .awaitingReview)

        let review = try await store.taskManager.review(taskId)
        #expect(!review.scan.groups.isEmpty)
        #expect(review.preview.canExecute)

        try await store.taskManager.run(taskId, onlyConfident: false)
        let afterRun = await store.taskManager.currentSummaries().first(where: { $0.id == taskId })
        #expect(afterRun?.stage == .done)
        #expect(afterRun?.batch != nil)

        try await store.taskManager.undo(taskId, only: nil)
        let afterUndo = await store.taskManager.currentSummaries().first(where: { $0.id == taskId })
        #expect(afterUndo?.stage == .undone)
    }

    @Test("SizeScannerActor and HealthScannerActor audit media tree off MainActor")
    func backgroundSizeAndHealthScanners() async throws {
        let backend = MemoryStorageBackend(initialSizes: [
            "/影视库/盗梦空间 (2010)/Inception.2010.2160p.DV.Atmos.mkv": 20_000_000,
            "/影视库/盗梦空间 (2010)/Inception.2010.1080p.mkv": 5_000_000,
            "/影视库/广告推广 www.example.com.url": 128,
        ])
        let db = try SQLiteDatabase.inMemory()
        let hist = SQLiteHistoryStore(db: db)
        let fStore = SQLiteFolderStatsStore(db: db)

        let sizeScanner = SizeScannerActor(
            connectionId: "c1",
            backend: backend,
            historyStore: hist,
            cacheStore: fStore
        )
        actor SnapBox {
            var value: SizeScanSnapshot?
            func set(_ s: SizeScanSnapshot) { value = s }
        }
        let box = SnapBox()
        await sizeScanner.scan(root: "/影视库", fresh: true, naming: .vidhub) { snap in
            await box.set(snap)
        }
        let finalSnap = await box.value
        #expect(finalSnap?.isComplete == true)
        #expect((finalSnap?.rootStats.total ?? 0) > 20_000_000)

        let healthScanner = HealthScannerActor(
            backend: backend,
            connectionId: "c1",
            folderStatsStore: fStore,
            probeMedia: false
        )
        let report = try await healthScanner.scan(rootDir: "/影视库", fresh: false)
        #expect(report.duplicates.count == 1)
        #expect(report.duplicates[0].recommendedKeepPath.contains("2160p"))
        #expect(!report.missingAssets.isEmpty)
        #expect(report.cleanupItems.contains { $0.kind == .junkFile })
    }

    @Test("SizeScannerActor.releaseMemoryCache clears completeDirs, targeted invalidate preserves siblings, and stale cache TTL refreshes")
    func sizeScannerCacheEvictionInvalidationAndTTL() async throws {
        let backend = MemoryStorageBackend(initialSizes: [
            "/媒体库/电影A/Movie.A.2020.mkv": 4_096,
            "/媒体库/电影B/Movie.B.2021.mkv": 8_192,
        ])
        let db = try SQLiteDatabase.inMemory()
        let hist = SQLiteHistoryStore(db: db)
        let fStore = SQLiteFolderStatsStore(db: db)

        let scanner = SizeScannerActor(
            connectionId: "c-cache",
            backend: backend,
            historyStore: hist,
            cacheStore: fStore
        )

        actor SnapBox {
            var value: SizeScanSnapshot?
            func set(_ s: SizeScanSnapshot) { value = s }
        }
        let box = SnapBox()
        await scanner.scan(root: "/媒体库", fresh: true, naming: .vidhub) { snap in
            await box.set(snap)
        }
        let firstSnap = await box.value
        #expect(firstSnap?.isComplete == true)
        #expect(firstSnap?.rootStats.files == 2)

        // Verify batched SQLite persistence flushed every scanned directory & completion marker.
        let persistedRows = try await fStore.loadFor("c-cache")
        #expect(persistedRows["/媒体库"]?.complete == true)
        #expect(persistedRows["/媒体库/电影A"] != nil)
        #expect(persistedRows["/媒体库/电影B"] != nil)

        // Targeted invalidation clears the mutated folder and marks ancestors incomplete while keeping siblings cached.
        await scanner.invalidate(dirs: ["/媒体库/电影A"])
        let afterInvalidate = await scanner.snapshot(for: "/媒体库", naming: .vidhub)
        let childrenA = await scanner.childrenEntries(of: "/媒体库/电影A")
        let childrenB = await scanner.childrenEntries(of: "/媒体库/电影B")
        #expect(afterInvalidate.isComplete == false)
        #expect(childrenA.isEmpty)
        #expect(!childrenB.isEmpty)

        // Re-scan to restore completion state, then verify P0 regression:
        // clearing DB + releaseMemoryCache() MUST clear completeDirs so subsequent snapshot/scan never stays stuck empty & complete.
        await scanner.scan(root: "/媒体库", fresh: false, naming: .vidhub) { snap in
            await box.set(snap)
        }
        let restoredSnap = await box.value
        #expect(restoredSnap?.isComplete == true)

        try await fStore.clearFor("c-cache")
        await scanner.releaseMemoryCache()

        let afterRelease = await scanner.snapshot(for: "/媒体库", naming: .vidhub)
        #expect(afterRelease.isComplete == false)
        #expect(afterRelease.rootStats.files == 0)

        await scanner.scan(root: "/媒体库", fresh: false, naming: .vidhub) { snap in
            await box.set(snap)
        }
        let rescannedSnap = await box.value
        #expect(rescannedSnap?.isComplete == true)
        #expect(rescannedSnap?.rootStats.files == 2)

        // Verify 24h staleness TTL on hydration: expired rows display immediately but are NOT marked complete.
        let staleDate = Date(timeIntervalSinceNow: -48 * 60 * 60)
        try await fStore.saveBatch(connection: "c-ttl", records: [
            CachedFolderRecord(
                dirPath: "/旧库",
                entries: [RemoteEntry(path: "/旧库/Old.2020.mkv", name: "Old.2020.mkv", isDir: false, size: 1_024)],
                complete: true,
                scannedAt: staleDate
            ),
        ])
        let ttlScanner = SizeScannerActor(
            connectionId: "c-ttl",
            backend: backend,
            historyStore: hist,
            cacheStore: fStore,
            cacheTTL: 24 * 60 * 60
        )
        let staleSnap = await ttlScanner.snapshot(for: "/旧库", naming: .vidhub)
        #expect(staleSnap.children.count == 1)
        #expect(staleSnap.isComplete == false)
    }

    @Test("Storage location edits retire the identity used by historical tasks")
    @MainActor
    func connectionLocationIdentity() throws {
        let store = AppStore(db: try .inMemory(), prefs: .memory(), secrets: .memory(), tmdbCache: nil, isDemoMode: false)
        let original = ConnectionConfig(id: "old", name: "Original", type: .local, endpoint: "/tmp/a")
        store.upsertConnection(original)
        var edited = original
        edited.name = "Renamed"
        #expect(store.upsertConnection(edited).id == original.id)
        edited.endpoint = "/tmp/b"
        let replacement = store.upsertConnection(edited)
        #expect(replacement.id != original.id)
        #expect(throws: StorageError.self) { try store.backend(for: original.id) }
        #expect(store.connections == [replacement])
    }

    @Test("A cold map restores only the requested subtree and inherits its parent's completion")
    func scopedSizeMapHydration() async throws {
        let db = try SQLiteDatabase.inMemory()
        let folders = SQLiteFolderStatsStore(db: db)
        let scanner = SizeScannerActor(
            connectionId: "scope", backend: MemoryStorageBackend(), historyStore: SQLiteHistoryStore(db: db),
            cacheStore: folders
        )
        let video = RemoteEntry(path: "/library/chosen/title.mkv", name: "title.mkv", isDir: false, size: 120)
        try await folders.saveDir(connection: "scope", dirPath: "/library", entries: [], complete: true)
        try await folders.saveDir(connection: "scope", dirPath: "/library/chosen", entries: [video])
        let sibling = RemoteEntry(path: "/other/b.mkv", name: "b.mkv", isDir: false, size: 80)
        try await folders.saveDir(connection: "scope", dirPath: "/other", entries: [sibling])
        let chosen = await scanner.snapshot(for: "/library/chosen", naming: .vidhub)
        #expect(chosen.isComplete)
        #expect(chosen.rootStats.total == 120)
        #expect(await scanner.childrenEntries(of: "/other").isEmpty)
        let other = await scanner.snapshot(for: "/other", naming: .vidhub)
        #expect(other.rootStats.total == 80)
    }

    @Test("A fresh completion marker cannot hide an expired or missing child listing")
    func incompleteDescendantsRequireRefresh() async throws {
        let db = try SQLiteDatabase.inMemory()
        let folders = SQLiteFolderStatsStore(db: db)
        let backend = MemoryStorageBackend(initialSizes: ["/old/A.mkv": 42, "/missing/B.mkv": 5])
        let scanner = SizeScannerActor(connectionId: "ttl", backend: backend, historyStore: SQLiteHistoryStore(db: db),
                                       cacheStore: folders)
        try await folders.saveDir(connection: "ttl", dirPath: "/", entries: try await backend.list("/"), complete: true)
        let old = RemoteEntry(path: "/old/A.mkv", name: "A.mkv", isDir: false, size: 9)
        try await folders.saveDir(connection: "ttl", dirPath: "/old", entries: [old],
                                  scannedAt: Date(timeIntervalSinceNow: -48 * 3600))
        let partial = await scanner.snapshot(for: "/", naming: .vidhub)
        #expect(!partial.isComplete)
        await scanner.scan(root: "/", naming: .vidhub) { _ in }
        let final = await scanner.snapshot(for: "/", naming: .vidhub)
        #expect(final.isComplete)
        #expect(final.rootStats.total == 47)
    }

    @Test("Health scan separates conflicting show IDs and keeps true duplicate episodes")
    func duplicateEpisodeIdentity() async throws {
        let alpha = "/TV/Alpha/Alpha.S01E01.{tmdb-100}"
        let backend = MemoryStorageBackend(initialSizes: [
            alpha + ".720p.mkv": 1, alpha + ".1080p.mkv": 2,
            "/TV/Alpha/Alpha.S01E02.{tmdb-100}.mkv": 1,
            "/TV/Alpha/Beta.S01E01.{tmdb-200}.mkv": 1,
            "/TV/Disc/BDMV/STREAM/00001.m2ts": 1,
        ])
        try await backend.mkdirs("/TV/Empty")
        let scanner = HealthScannerActor(backend: backend, connectionId: "tv", probeMedia: false)
        let report = try await scanner.scan(rootDir: "/TV", fresh: true)
        #expect(report.duplicates.count == 1)
        let issue = try #require(report.duplicates.first)
        #expect(issue.tmdbId == 100)
        #expect(Set(issue.copies.map(\.path)) == Set([alpha + ".720p.mkv", alpha + ".1080p.mkv"]))
        #expect(report.cleanupItems.filter { $0.kind == .emptyDir }.map(\.path) == ["/TV/Empty"])
    }

    @Test("Skipped children keep the map incomplete until a successful retry")
    func partialSizeMapCanRetry() async throws {
        let db = try SQLiteDatabase.inMemory()
        let folders = SQLiteFolderStatsStore(db: db)
        let backend = MemoryStorageBackend()
        let scanner = SizeScannerActor(
            connectionId: "retry", backend: backend, historyStore: SQLiteHistoryStore(db: db), cacheStore: folders
        )
        let child = RemoteEntry(path: "/child", name: "child", isDir: true, size: 0)
        try await folders.saveDir(connection: "retry", dirPath: "/", entries: [child])
        await scanner.scan(root: "/", naming: .vidhub) { _ in }
        let partial = await scanner.snapshot(for: "/", naming: .vidhub)
        #expect(!partial.isComplete)
        #expect(partial.skipped["/child"] != nil)
        #expect(try await folders.loadFor("retry")["/"]?.complete == false)
        try await backend.mkdirs("/child")
        await scanner.scan(root: "/", naming: .vidhub) { _ in }
        let final = await scanner.snapshot(for: "/", naming: .vidhub)
        #expect(final.isComplete)
        #expect(final.skipped.isEmpty)
    }

    @Test("AppStore.clearCaches clears SQLite/probe/folder caches, bumps cacheClearEpoch, and shutdownSync finishes cleanly")
    @MainActor
    func appStoreClearCachesAndShutdown() async throws {
        let db = try SQLiteDatabase.inMemory()
        let tmdbCache = SQLiteTmdbCache(db: db)
        let store = AppStore(
            db: db,
            prefs: .memory(),
            secrets: .memory(),
            tmdbCache: tmdbCache,
            isDemoMode: false
        )

        #expect(store.cacheClearEpoch == 0)
        #expect(store.mediaProbeCache != nil)

        let connId = ConnectionId("local-test")
        store.upsertConnection(ConnectionConfig(
            id: connId,
            name: "Local Test",
            type: .local,
            endpoint: "/tmp"
        ))

        await tmdbCache.put("tmdb:/search/movie?query=test", json: #"{"results":[]}"#)
        await store.mediaProbeCache?.put(
            connection: connId,
            path: "/tmp/sample.mkv",
            fileSize: 2048,
            info: MediaProbeInfo(width: 1920, height: 1080, videoCodec: "hevc")
        )
        try await store.folderStatsStore?.saveDir(
            connection: connId,
            dirPath: "/tmp",
            entries: [RemoteEntry(path: "/tmp/sample.mkv", name: "sample.mkv", isDir: false, size: 2048)],
            complete: true,
            scannedAt: Date()
        )

        let tmdbCountBefore = await tmdbCache.count()
        let probeCountBefore = await store.mediaProbeCache?.count()
        let folderRowsBefore = try await store.folderStatsStore?.loadFor(connId)
        #expect(tmdbCountBefore == 1)
        #expect(probeCountBefore == 1)
        #expect(folderRowsBefore?.count == 1)

        await store.clearCaches()

        let tmdbCountAfter = await tmdbCache.count()
        let probeCountAfter = await store.mediaProbeCache?.count()
        let folderRowsAfter = try await store.folderStatsStore?.loadFor(connId)
        #expect(store.cacheClearEpoch == 1)
        #expect(tmdbCountAfter == 0)
        #expect(probeCountAfter == 0)
        #expect(folderRowsAfter?.isEmpty == true)

        store.shutdownSync()
    }
}

private actor HealthWindowBackend: StorageBackend {
    private var fifthStarted = false
    private(set) var refilledBeforeSlowRequestEnded = false

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] {
        if dir == "/" {
            return (1...5).map { RemoteEntry(path: "/d\($0)", name: "d\($0)", isDir: true, size: 0) }
        }
        if dir == "/d5" { fifthStarted = true }
        if dir == "/d1" {
            let deadline = ContinuousClock.now + .seconds(2)
            while !fifthStarted && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            refilledBeforeSlowRequestEnded = fifthStarted
        }
        return []
    }

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

@Test("Health scanning schedules the next directory while a slow listing is still active")
func healthScanRefillsWindow() async throws {
    let backend = HealthWindowBackend()
    let scanner = HealthScannerActor(backend: backend, connectionId: "window", folderStatsStore: nil, probeMedia: false)
    _ = try await scanner.scan(rootDir: "/")
    #expect(await backend.refilledBeforeSlowRequestEnded)
}
