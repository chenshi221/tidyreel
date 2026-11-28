import Darwin
import Foundation
import SQLite3
import Testing
import TidyreelFakes
import TidyreelModels
@testable import TidyreelPersistence

// MARK: - Test Helpers

private func makeTempDir(_ prefix: String = "tidyreel-persistence-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func posixMode(at path: String) throws -> mode_t {
    var st = stat()
    let rc = lstat(path, &st)
    try #require(rc == 0, "lstat failed for \(path)")
    return st.st_mode & mode_t(0o777)
}

private func execRawSQLite(at path: String, sql: String) throws {
    var db: OpaquePointer?
    let openRc = sqlite3_open(path, &db)
    defer { if let db { sqlite3_close(db) } }
    try #require(openRc == SQLITE_OK)
    var errMsg: UnsafeMutablePointer<CChar>?
    let execRc = sqlite3_exec(db, sql, nil, nil, &errMsg)
    if execRc != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "sqlite3_exec failed"
        if let errMsg { sqlite3_free(errMsg) }
        Issue.record("Raw SQLite setup failed: \(msg)")
        throw SQLiteError(code: execRc, message: msg)
    }
}

private func makeOp(
    _ id: String,
    src: String,
    dst: String,
    kind: OpKind = .relocate,
    phase: ExecPhase = .files,
    group: GroupId? = GroupId("g1"),
    selected: Bool = true,
    warning: String? = nil,
    overwrite: Bool = false
) -> RenameOp {
    RenameOp(
        id: OpId(id),
        kind: kind,
        phase: phase,
        src: src,
        dst: dst,
        group: group,
        selected: selected,
        warning: warning,
        overwrite: overwrite
    )
}

private actor CountingMediaProbe: MediaProbe {
    private var results: [String: MediaProbeInfo?]
    private let delayNs: UInt64
    private(set) var callCount: Int = 0

    init(results: [String: MediaProbeInfo?] = [:], delayNs: UInt64 = 0) {
        self.results = results
        self.delayNs = delayNs
    }

    func setResult(_ info: MediaProbeInfo?, for path: String) {
        results[path] = info
    }

    func probe(backend: any StorageBackend, path: String, fileSize: Int64?) async -> MediaProbeInfo? {
        callCount += 1
        if delayNs > 0 {
            try? await Task.sleep(nanoseconds: delayNs)
        }
        return results[path] ?? nil
    }
}

// MARK: - 1. Schema & Drift Migration Tests

@Suite("SQLiteDatabase & Drift Schema Migrations")
struct SQLiteDatabaseMigrationTests {
    @Test("Fresh file database enables WAL, foreign_keys, tuning PRAGMAs, and creates v8 schema + indexes")
    func freshDatabasePragmasAndSchema() async throws {
        let dir = try makeTempDir("fresh-db")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("tidyreel.sqlite")
        let db = try SQLiteDatabase(url: dbURL)

        #expect(try await db.schemaVersion() == 8)

        let fkRows = try await db.query("PRAGMA foreign_keys")
        #expect(fkRows.first?.first == .integer(1))

        let journalRows = try await db.query("PRAGMA journal_mode")
        #expect(journalRows.first?.first?.stringValue?.lowercased() == "wal")

        let cacheSizeRows = try await db.query("PRAGMA cache_size")
        #expect(cacheSizeRows.first?.first == .integer(-16000))

        let tempStoreRows = try await db.query("PRAGMA temp_store")
        #expect(tempStoreRows.first?.first == .integer(2))

        let mmapRows = try await db.query("PRAGMA mmap_size")
        #expect((mmapRows.first?.first?.int64Value ?? -1) >= 0)

        let tables = try await db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.first?.stringValue }
        let tableSet = Set(tables)
        #expect(tableSet.isSuperset(of: [
            "batches",
            "history_records",
            "tasks",
            "task_reviews",
            "folder_stats_cache",
            "tmdb_http_cache",
            "media_probe_cache",
        ]))

        let indexes = try await db.query("SELECT name FROM sqlite_master WHERE type = 'index'")
            .compactMap { $0.first?.stringValue }
        let indexSet = Set(indexes)
        #expect(indexSet.isSuperset(of: [
            "history_records_dst_status",
            "idx_batches_conn",
            "idx_batches_task_created",
            "idx_history_batch_phase",
            "idx_history_batch_status",
            "idx_tmdb_http_cache_updated_at",
            "idx_media_probe_cache_updated_at",
        ]))
        #expect(!indexSet.contains("folder_stats_cache_conn"))

        await db.close()
    }

    @Test("Simulated Drift v5 tidyreel.sqlite upgrades cleanly to v8 moving scan_json to task_reviews")
    func upgradeFromSimulatedDriftV5Database() async throws {
        let dir = try makeTempDir("drift-v5-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("tidyreel.sqlite").path

        let sampleScan = ScanResult(
            connection: ConnectionId("conn-nas"),
            roots: ["/下载/完成"],
            groups: [
                MediaGroup(
                    id: GroupId("g-doro"),
                    kind: .episode,
                    anchorTitle: "异兽魔都",
                    anchorYear: 2020,
                    rootDir: "/下载/完成/异兽魔都",
                    files: [
                        ScanFile(
                            path: "/下载/完成/异兽魔都/S01E01.mkv",
                            name: "S01E01.mkv",
                            size: 1_073_741_824,
                            role: .video,
                            parsed: ParsedName(
                                title: "Dorohedoro",
                                year: 2020,
                                season: 1,
                                episodes: [1],
                                kind: .episode,
                                resolution: "1080p",
                                confidence: 0.95
                            )
                        ),
                    ],
                    match: Candidate(
                        tmdbId: 95479,
                        kind: .episode,
                        title: "异兽魔都",
                        englishTitle: "Dorohedoro",
                        year: 2020,
                        posterPath: "/doro.jpg",
                        genres: ["Animation", "Sci-Fi"]
                    ),
                    matchScore: 0.96
                ),
            ],
            unassigned: [
                ScanFile(path: "/下载/完成/ad.txt", name: "ad.txt", size: 42, role: .junk),
            ]
        )
        let sampleDecisions: [GroupId: GroupDecision] = [
            GroupId("g-doro"): GroupDecision(
                match: sampleScan.groups[0].match,
                strategy: .asParsed,
                episodeOffset: 0,
                selected: true
            ),
        ]
        let scanJson = try TidyreelCodecs.scanToJson(sampleScan)
        let decisionsJson = try TidyreelCodecs.decisionsToJson(sampleDecisions)
        let entriesJson = try TidyreelCodecs.entriesToCompactJson([
            RemoteEntry(
                path: "/影视库/异兽魔都 (2020)",
                name: "异兽魔都 (2020)",
                isDir: true,
                size: 0,
                modified: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ])

        func sqlQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        }

        // Exact Drift v5 schema & Unix-second timestamps
        try execRawSQLite(at: dbPath, sql: """
            CREATE TABLE batches (
              id TEXT NOT NULL PRIMARY KEY,
              task_id TEXT NOT NULL,
              connection_id TEXT NOT NULL,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE history_records (
              batch_id TEXT NOT NULL REFERENCES batches (id),
              op_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              kind TEXT NOT NULL,
              phase TEXT NOT NULL,
              src TEXT NOT NULL,
              dst TEXT NOT NULL,
              group_id TEXT NULL,
              selected INTEGER NOT NULL CHECK ("selected" IN (0, 1)),
              warning TEXT NULL,
              overwrite INTEGER NOT NULL DEFAULT 0 CHECK ("overwrite" IN (0, 1)),
              status TEXT NOT NULL,
              error TEXT NULL,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (batch_id, op_id),
              UNIQUE (batch_id, seq)
            );
            CREATE INDEX history_records_dst_status ON history_records (dst, status);
            CREATE INDEX idx_batches_conn ON batches(connection_id);
            CREATE INDEX idx_history_batch_phase ON history_records(batch_id, phase, kind, status);
            CREATE TABLE tasks (
              id TEXT NOT NULL PRIMARY KEY,
              connection_id TEXT NOT NULL,
              paths_json TEXT NOT NULL,
              mode TEXT NOT NULL,
              scrape INTEGER NOT NULL DEFAULT 0 CHECK ("scrape" IN (0, 1)),
              scrape_only INTEGER NOT NULL DEFAULT 0 CHECK ("scrape_only" IN (0, 1)),
              stage TEXT NOT NULL,
              message TEXT NOT NULL,
              imported_count INTEGER NOT NULL,
              video_count INTEGER NOT NULL,
              folder_count INTEGER NOT NULL,
              subtitle_count INTEGER NOT NULL,
              progress REAL NULL,
              batch_id TEXT NULL,
              created_at INTEGER NOT NULL,
              scan_json TEXT NULL,
              decisions_json TEXT NULL,
              unassigned_deletes_json TEXT NULL
            );
            CREATE TABLE folder_stats_cache (
              connection_id TEXT NOT NULL,
              dir_path TEXT NOT NULL,
              entries_json TEXT NOT NULL,
              complete INTEGER NOT NULL DEFAULT 0 CHECK ("complete" IN (0, 1)),
              scanned_at INTEGER NOT NULL,
              PRIMARY KEY (connection_id, dir_path)
            );
            CREATE INDEX folder_stats_cache_conn ON folder_stats_cache (connection_id);

            INSERT INTO batches VALUES ('B-v5', 'T-v5', 'conn-nas', 1700000100);
            INSERT INTO history_records VALUES (
              'B-v5', 'op-0', 0, 'relocate', 'files',
              '/下载/完成/异兽魔都/S01E01.mkv', '/影视库/异兽魔都 (2020)/Season 01/S01E01.mkv',
              'g-doro', 1, '注意季号', 1, 'done', NULL, 1700000120
            );
            INSERT INTO tasks VALUES (
              'T-v5', 'conn-nas', '["/下载/完成"]', 'moveToLibrary', 1, 0,
              'done', '整理完成', 2, 1, 1, 0, 1.0, 'B-v5', 1700000050,
              \(sqlQuote(scanJson)), \(sqlQuote(decisionsJson)), '["/下载/完成/ad.txt"]'
            );
            INSERT INTO folder_stats_cache VALUES (
              'conn-nas', '/影视库', \(sqlQuote(entriesJson)), 1, 1700000200
            );
            PRAGMA user_version = 5;
            """)

        let db = try SQLiteDatabase(path: dbPath)
        #expect(try await db.schemaVersion() == 8)

        // Verify redundant index was dropped and v7 indexes exist
        let indexNames = Set(
            try await db.query("SELECT name FROM sqlite_master WHERE type = 'index'")
                .compactMap { $0.first?.stringValue }
        )
        #expect(!indexNames.contains("folder_stats_cache_conn"))
        #expect(indexNames.contains("idx_batches_task_created"))
        #expect(indexNames.contains("idx_history_batch_status"))
        #expect(indexNames.contains("idx_media_probe_cache_updated_at"))

        // Verify legacy columns on tasks were nulled out and data moved to task_reviews
        let legacyCols = try await db.query(
            "SELECT scan_json, decisions_json, unassigned_deletes_json, card_meta_json FROM tasks WHERE id = 'T-v5'"
        )
        #expect(legacyCols.first?[0].isNull == true)
        #expect(legacyCols.first?[1].isNull == true)
        #expect(legacyCols.first?[2].isNull == true)
        #expect(legacyCols.first?[3].isNull == true)

        let reviewRows = try await db.query("SELECT task_id FROM task_reviews WHERE task_id = 'T-v5'")
        #expect(reviewRows.count == 1)

        // Verify batches & history_records preserved
        let historyStore = SQLiteHistoryStore(db: db)
        let batches = try await historyStore.batches()
        #expect(batches.count == 1)
        #expect(batches[0].id == BatchId("B-v5"))
        #expect(batches[0].task == TaskId("T-v5"))
        #expect(batches[0].connection == ConnectionId("conn-nas"))
        #expect(batches[0].createdAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(batches[0].done == 1)
        #expect(batches[0].total == 1)

        let recs = try await historyStore.records(batch: BatchId("B-v5"))
        #expect(recs.count == 1)
        #expect(recs[0].op.overwrite == true)
        #expect(recs[0].op.selected == true)
        #expect(recs[0].writtenDigest == nil)
        #expect(recs[0].op.warning == "注意季号")
        #expect(recs[0].updatedAt == Date(timeIntervalSince1970: 1_700_000_120))
        #expect(try await historyStore.isOrganized(
            connection: ConnectionId("conn-nas"),
            path: "/影视库/异兽魔都 (2020)/Season 01/S01E01.mkv"
        ))

        // Verify tasks summary & migrated review preserved
        let taskStore = SQLiteTaskStore(db: db)
        let summaries = try await taskStore.loadSummaries()
        #expect(summaries.count == 1)
        #expect(summaries[0].id == TaskId("T-v5"))
        #expect(summaries[0].mode == .moveToLibrary)
        #expect(summaries[0].scrape == true)
        #expect(summaries[0].scrapeOnly == false)
        #expect(summaries[0].stage == .done)
        #expect(summaries[0].batch == BatchId("B-v5"))
        #expect(summaries[0].createdAt == Date(timeIntervalSince1970: 1_700_000_050))

        let loadedReview = try #require(try await taskStore.loadReview(id: TaskId("T-v5")))
        #expect(loadedReview.scan == sampleScan)
        #expect(loadedReview.decisions == sampleDecisions)
        #expect(loadedReview.unassignedDeletes == ["/下载/完成/ad.txt"])

        // Verify loadCardMeta fallback decodes migrated blob and backfills tasks.card_meta_json
        let cardMetaMap = await taskStore.loadCardMeta(ids: [TaskId("T-v5")])
        let cardMeta = try #require(cardMetaMap[TaskId("T-v5")])
        #expect(cardMeta.unassignedCount == 1)
        #expect(cardMeta.works.first?.tmdbId == 95479)
        #expect(cardMeta.works.first?.title == "异兽魔都")
        #expect(cardMeta.works.first?.posterPath == "/doro.jpg")

        let backfilled = try await db.query("SELECT card_meta_json FROM tasks WHERE id = 'T-v5'")
        #expect(backfilled.first?.first?.stringValue != nil)

        // Verify folder_stats_cache preserved
        let statsStore = SQLiteFolderStatsStore(db: db)
        let folderStats = try await statsStore.loadFor(ConnectionId("conn-nas"))
        let rootRecord = try #require(folderStats["/影视库"])
        #expect(rootRecord.complete == false)
        #expect(rootRecord.scannedAt == Date(timeIntervalSince1970: 1_700_000_200))
        #expect(rootRecord.entries.count == 1)
        #expect(rootRecord.entries[0].name == "异兽魔都 (2020)")

        // Verify v6 tmdb_http_cache & v7 media_probe_cache work on the migrated DB
        let tmdbCache = SQLiteTmdbCache(db: db)
        await tmdbCache.put("tv:95479:zh-CN", json: #"{"id":95479}"#)
        #expect(await tmdbCache.get("tv:95479:zh-CN") == #"{"id":95479}"#)

        let probeCache = SQLiteMediaProbeCache(db: db)
        let info = MediaProbeInfo(width: 1920, height: 1080, videoCodec: "HEVC")
        await probeCache.put(connection: ConnectionId("conn-nas"), path: "/a.mkv", fileSize: 100, info: info)
        #expect(await probeCache.get(connection: ConnectionId("conn-nas"), path: "/a.mkv", fileSize: 100) == .hit(info))

        await db.close()
    }

    @Test("Simulated v6 database upgrades cleanly to v8 and migrates task reviews")
    func upgradeFromV6DatabaseToV7() async throws {
        let dir = try makeTempDir("v6-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("tidyreel.sqlite").path
        let scan = ScanResult(
            connection: ConnectionId("c6"),
            roots: ["/v6"],
            groups: [
                MediaGroup(
                    id: GroupId("g6"),
                    kind: .movie,
                    anchorTitle: "Inception",
                    anchorYear: 2010,
                    rootDir: "/v6",
                    files: [],
                    match: Candidate(tmdbId: 27205, kind: .movie, title: "盗梦空间", year: 2010, posterPath: "/inc.jpg"),
                    matchScore: 0.99
                ),
            ]
        )
        let scanJson = try TidyreelCodecs.scanToJson(scan)
        func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

        try execRawSQLite(at: dbPath, sql: """
            CREATE TABLE batches (id TEXT NOT NULL PRIMARY KEY, task_id TEXT NOT NULL, connection_id TEXT NOT NULL, created_at INTEGER NOT NULL);
            CREATE TABLE history_records (
              batch_id TEXT NOT NULL REFERENCES batches (id),
              op_id TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, phase TEXT NOT NULL,
              src TEXT NOT NULL, dst TEXT NOT NULL, group_id TEXT NULL,
              selected INTEGER NOT NULL CHECK ("selected" IN (0, 1)), warning TEXT NULL,
              overwrite INTEGER NOT NULL DEFAULT 0 CHECK ("overwrite" IN (0, 1)),
              status TEXT NOT NULL, error TEXT NULL, updated_at INTEGER NOT NULL,
              PRIMARY KEY (batch_id, op_id), UNIQUE (batch_id, seq)
            );
            CREATE TABLE tasks (
              id TEXT NOT NULL PRIMARY KEY, connection_id TEXT NOT NULL, paths_json TEXT NOT NULL,
              mode TEXT NOT NULL, scrape INTEGER NOT NULL DEFAULT 0, scrape_only INTEGER NOT NULL DEFAULT 0,
              stage TEXT NOT NULL, message TEXT NOT NULL, imported_count INTEGER NOT NULL,
              video_count INTEGER NOT NULL, folder_count INTEGER NOT NULL, subtitle_count INTEGER NOT NULL,
              progress REAL NULL, batch_id TEXT NULL, created_at INTEGER NOT NULL,
              scan_json TEXT NULL, decisions_json TEXT NULL, unassigned_deletes_json TEXT NULL
            );
            CREATE TABLE folder_stats_cache (
              connection_id TEXT NOT NULL, dir_path TEXT NOT NULL, entries_json TEXT NOT NULL,
              complete INTEGER NOT NULL DEFAULT 0, scanned_at INTEGER NOT NULL,
              PRIMARY KEY (connection_id, dir_path)
            );
            CREATE INDEX folder_stats_cache_conn ON folder_stats_cache (connection_id);
            CREATE TABLE tmdb_http_cache (
              cache_key TEXT NOT NULL PRIMARY KEY, json_text TEXT NOT NULL, updated_at INTEGER NOT NULL
            );
            CREATE INDEX idx_tmdb_http_cache_updated_at ON tmdb_http_cache (updated_at);
            INSERT INTO tasks VALUES (
              'T-v6', 'c6', '["/v6"]', 'inPlace', 0, 0, 'awaitingReview', 'ready',
              1, 1, 0, 0, NULL, NULL, 1700000000, \(sqlQuote(scanJson)), '{}', NULL
            );
            INSERT INTO tmdb_http_cache VALUES ('k-v6', '{"ok":true}', 1700000000000);
            PRAGMA user_version = 6;
            """)

        let db = try SQLiteDatabase(path: dbPath)
        #expect(try await db.schemaVersion() == 8)

        let store = SQLiteTaskStore(db: db)
        let loaded = try #require(try await store.loadReview(id: TaskId("T-v6")))
        #expect(loaded.scan == scan)

        // Saving review again rewrites as compressed TRZ1 blob + writes card_meta_json
        try await store.saveReview(id: TaskId("T-v6"), scan: scan, decisions: [:], unassignedDeletes: [])
        let blobRows = try await db.query("SELECT scan_blob FROM task_reviews WHERE task_id = 'T-v6'")
        let rawBlob = try #require(blobRows.first?.first?.dataValue)
        #expect(rawBlob.prefix(4) == Data("TRZ1".utf8))

        let reloaded = try #require(try await store.loadReview(id: TaskId("T-v6")))
        #expect(reloaded.scan == scan)

        await db.close()
    }

    @Test("Simulated Drift v1 database upgrades sequentially through v2..v8 with defaults")
    func upgradeFromSimulatedDriftV1Database() async throws {
        let dir = try makeTempDir("drift-v1-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("tidyreel.sqlite").path
        try execRawSQLite(at: dbPath, sql: """
            CREATE TABLE batches (
              id TEXT NOT NULL PRIMARY KEY,
              task_id TEXT NOT NULL,
              connection_id TEXT NOT NULL,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE history_records (
              batch_id TEXT NOT NULL REFERENCES batches(id),
              op_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              kind TEXT NOT NULL,
              phase TEXT NOT NULL,
              src TEXT NOT NULL,
              dst TEXT NOT NULL,
              group_id TEXT,
              selected INTEGER NOT NULL,
              warning TEXT,
              status TEXT NOT NULL,
              error TEXT,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (batch_id, op_id),
              UNIQUE (batch_id, seq)
            );
            CREATE TABLE tasks (
              id TEXT NOT NULL PRIMARY KEY,
              connection_id TEXT NOT NULL,
              paths_json TEXT NOT NULL,
              mode TEXT NOT NULL,
              stage TEXT NOT NULL,
              message TEXT NOT NULL,
              imported_count INTEGER NOT NULL,
              video_count INTEGER NOT NULL,
              folder_count INTEGER NOT NULL,
              subtitle_count INTEGER NOT NULL,
              progress REAL,
              batch_id TEXT,
              created_at INTEGER NOT NULL,
              scan_json TEXT,
              decisions_json TEXT
            );
            INSERT INTO batches VALUES ('B-v1', 'T-v1', 'c1', 1690000000);
            INSERT INTO history_records VALUES (
              'B-v1', 'o0', 0, 'relocate', 'files', '/a.mkv', '/b.mkv',
              NULL, 1, NULL, 'done', NULL, 1690000000
            );
            INSERT INTO tasks VALUES (
              'T-v1', 'c1', '["/a"]', 'inPlace', 'done', '',
              1, 1, 0, 0, NULL, 'B-v1', 1690000000, NULL, NULL
            );
            PRAGMA user_version = 1;
            """)

        let db = try SQLiteDatabase(path: dbPath)
        #expect(try await db.schemaVersion() == 8)

        let history = SQLiteHistoryStore(db: db)
        let recs = try await history.records(batch: BatchId("B-v1"))
        #expect(recs.count == 1)
        #expect(recs[0].op.overwrite == false)

        let tasks = SQLiteTaskStore(db: db)
        let loaded = try await tasks.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].summary.scrape == false)
        #expect(loaded[0].summary.scrapeOnly == false)
        #expect(loaded[0].unassignedDeletes.isEmpty)

        // Newly added folder_stats_cache works
        let stats = SQLiteFolderStatsStore(db: db)
        try await stats.saveDir(connection: ConnectionId("c1"), dirPath: "/", entries: [], complete: true)
        #expect(try await stats.loadFor(ConnectionId("c1")).count == 1)

        await db.close()
    }

    @Test("Prepared statement LRU cache caps at 64, clears bindings on reuse, and finalizes on close")
    func statementCacheLRUAndCleanClose() async throws {
        let db = try SQLiteDatabase.inMemory()
        let finalCount: Int = try await db.withConnection { conn in
            for i in 0..<75 {
                let stmt = try conn.prepareCached("SELECT ? + \(i)")
                try stmt.bindInt(1, 10)
                #expect(try stmt.step() == true)
                #expect(stmt.columnInt(0) == 10 + i)
                stmt.reset()
            }
            // Reuse a cached statement without rebinding to confirm bindings were cleared to NULL
            let reused = try conn.prepareCached("SELECT ? + 74")
            #expect(try reused.step() == true)
            #expect(reused.columnIsNull(0) == true)
            reused.reset()

            // Verify bindUTF8Data + columnOptionalBlob round-trip
            let dataStmt = try conn.prepareCached("SELECT ?")
            try dataStmt.bindUTF8Data(1, Data("hello-utf8".utf8))
            #expect(try dataStmt.step() == true)
            #expect(dataStmt.columnText(0) == "hello-utf8")
            #expect(dataStmt.columnOptionalBlob(0) == Data("hello-utf8".utf8))
            dataStmt.reset()

            return conn.cachedStatementCount
        }
        #expect(finalCount == SQLiteConnection.statementCacheCapacity)
        await db.close()
    }
}

// MARK: - 2. SQLiteHistoryStore Tests

@Suite("SQLiteHistoryStore")
struct SQLiteHistoryStoreTests {
    @Test("beginBatch, mark, records order, batches order & undone derivation, deleteTask")
    func batchLifecycleAndDeleteTask() async throws {
        let db = try SQLiteDatabase.inMemory()
        let history = SQLiteHistoryStore(db: db)
        let conn = ConnectionId("c1")
        let task1 = TaskId("T1")
        let task2 = TaskId("T2")

        let ops = [
            makeOp("o0", src: "", dst: "/d/New", kind: .mkdir),
            makeOp("o1", src: "/d/a.mkv", dst: "/d/New/a.mkv", warning: "超出 TMDB 总集数"),
            makeOp("o2", src: "/d/Old", dst: "/d/Newer", phase: .folders, overwrite: true),
        ]

        let b1 = try await history.beginBatch(task: task1, connection: conn, ops: ops)
        try await history.saveWrittenDigest("persisted-digest", batch: b1, op: ops[0].id)
        #expect(try await history.records(batch: b1).first?.writtenDigest == "persisted-digest")
        let b2 = try await history.beginBatch(task: task2, connection: conn, ops: [ops[1]])

        // Newest batch first even when created in the same second (rowid DESC tie-breaker)
        let initialBatches = try await history.batches()
        #expect(initialBatches.map(\.id) == [b2, b1])

        var recs = try await history.records(batch: b1)
        #expect(recs.map(\.op.id.value) == ["o0", "o1", "o2"])
        #expect(recs.allSatisfy { $0.status == .pending })
        #expect(recs[0].op.src == "")
        #expect(recs[1].op.warning == "超出 TMDB 总集数")
        #expect(recs[2].op.phase == .folders)
        #expect(recs[2].op.overwrite == true)

        try await history.mark(batch: b1, op: OpId("o1"), status: .done)
        try await history.mark(batch: b1, op: OpId("o2"), status: .failed, error: "boom")

        recs = try await history.records(batch: b1)
        #expect(recs.map(\.status) == [.pending, .done, .failed])
        #expect(recs[2].error == "boom")

        let summaryB1 = try #require(try await history.batches().first(where: { $0.id == b1 }))
        #expect(summaryB1.total == 3)
        #expect(summaryB1.done == 1)
        #expect(summaryB1.failed == 1)
        #expect(summaryB1.undone == false)

        // Marking b2's op undone -> done == 0 && undone > 0 => undone == true
        try await history.mark(batch: b2, op: OpId("o1"), status: .undone)
        let summaryB2 = try #require(try await history.batches().first(where: { $0.id == b2 }))
        #expect(summaryB2.undone == true)

        // deleteTask deletes child history_records + batches cleanly under foreign_keys = ON
        try await history.deleteTask(task1)
        let remaining = try await history.batches()
        #expect(remaining.map(\.id) == [b2])
        #expect(try await history.records(batch: b1).isEmpty)

        await db.close()
    }

    @Test("isOrganized and chunked areOrganized (>400 paths) including folder-phase reverse mapping")
    func organizedLookupAndChunking() async throws {
        let db = try SQLiteDatabase.inMemory()
        let history = SQLiteHistoryStore(db: db)
        let conn = ConnectionId("c1")
        let otherConn = ConnectionId("c2")

        // Batch with file rename followed by parent folder rename
        let folderBatch = try await history.beginBatch(
            task: TaskId("T-folder"),
            connection: conn,
            ops: [
                makeOp("f1", src: "/d/Show/a.mkv", dst: "/d/Show/S01/E01.mkv", phase: .files),
                makeOp("f2", src: "/d/Show/b.mkv", dst: "/d/Show/S01/E02.mkv", phase: .files),
                makeOp("d1", src: "/d/Show", dst: "/d/Show (2020)", phase: .folders),
            ]
        )
        try await history.mark(batch: folderBatch, op: OpId("f1"), status: .done)
        try await history.mark(batch: folderBatch, op: OpId("d1"), status: .done)
        // Note: f2 stays pending!

        #expect(try await history.isOrganized(connection: conn, path: "/d/Show (2020)/S01/E01.mkv") == true)
        #expect(try await history.isOrganized(connection: conn, path: "/d/Show (2020)/S01/E02.mkv") == false)
        #expect(try await history.isOrganized(connection: otherConn, path: "/d/Show (2020)/S01/E01.mkv") == false)

        // Bulk batch with 950 paths to verify <= 400 placeholder chunking across 3+ SQL queries
        var bulkOps: [RenameOp] = []
        for i in 0..<950 {
            bulkOps.append(makeOp("b-\(i)", src: "/raw/\(i).mkv", dst: "/lib/\(i).mkv"))
        }
        let bulkBatch = try await history.beginBatch(task: TaskId("T-bulk"), connection: conn, ops: bulkOps)
        for i in stride(from: 0, to: 950, by: 2) {
            try await history.mark(batch: bulkBatch, op: OpId("b-\(i)"), status: .done)
        }

        let queriedPaths = (0..<950).map { "/lib/\($0).mkv" } + ["/lib/missing.mkv"]
        let organized = try await history.areOrganized(connection: conn, paths: queriedPaths)
        #expect(organized.count == 475)
        #expect(organized.contains("/lib/0.mkv"))
        #expect(organized.contains("/lib/948.mkv"))
        #expect(!organized.contains("/lib/1.mkv"))
        #expect(!organized.contains("/lib/missing.mkv"))

        await db.close()
    }

    @Test("markBatch, resetFailedToPending, latestBatch, and folderMoves cache invalidation")
    func markBatchResetFailedLatestBatchAndCacheInvalidation() async throws {
        let db = try SQLiteDatabase.inMemory()
        let history = SQLiteHistoryStore(db: db)
        let conn = ConnectionId("c1")
        let taskId = TaskId("T-batch")

        #expect(try await history.latestBatch(task: taskId) == nil)

        // First batch
        let b1 = try await history.beginBatch(
            task: taskId,
            connection: conn,
            ops: [makeOp("o0", src: "/a.mkv", dst: "/b.mkv")]
        )
        try await history.mark(batch: b1, op: OpId("o0"), status: .done)

        // Second (newer) batch for same task with folder rename
        let b2 = try await history.beginBatch(
            task: taskId,
            connection: conn,
            ops: [
                makeOp("f1", src: "/s/1.mkv", dst: "/s/ep1.mkv", phase: .files),
                makeOp("f2", src: "/s/2.mkv", dst: "/s/ep2.mkv", phase: .files),
                makeOp("f3", src: "/s/3.mkv", dst: "/s/ep3.mkv", phase: .files),
                makeOp("f4", src: "/s/4.mkv", dst: "/s/ep4.mkv", phase: .files),
                makeOp("d1", src: "/s", dst: "/Show (2024)", phase: .folders),
            ]
        )

        // Prime folderMoves cache before folder move is done
        #expect(try await history.isOrganized(connection: conn, path: "/Show (2024)/ep1.mkv") == false)

        // Batch-mark multiple statuses in a single transaction
        try await history.markBatch(batch: b2, updates: [
            (op: OpId("f1"), status: .done, error: nil),
            (op: OpId("f2"), status: .failed, error: "timeout"),
            (op: OpId("f3"), status: .skipped, error: "依赖的操作失败"),
            (op: OpId("f4"), status: .undone, error: nil),
            (op: OpId("d1"), status: .done, error: nil),
        ])

        // folderMoves cache MUST be invalidated by markBatch so reverse mapping works immediately
        #expect(try await history.isOrganized(connection: conn, path: "/Show (2024)/ep1.mkv") == true)

        // latestBatch returns b2 (not b1) with accurate counts
        let latest = try #require(try await history.latestBatch(task: taskId))
        #expect(latest.id == b2)
        #expect(latest.total == 5)
        #expect(latest.done == 2)
        #expect(latest.failed == 1)
        #expect(latest.undone == false)

        // resetFailedToPending resets failed + skipped -> pending with error = nil, preserves done & undone
        try await history.resetFailedToPending(batch: b2)
        let afterReset = try await history.records(batch: b2)
        #expect(afterReset.map(\.status) == [.done, .pending, .pending, .undone, .done])
        #expect(afterReset[1].error == nil)
        #expect(afterReset[2].error == nil)

        // deleteTask invalidates folderMoves cache too
        try await history.deleteTask(taskId)
        #expect(try await history.latestBatch(task: taskId) == nil)
        #expect(try await history.isOrganized(connection: conn, path: "/Show (2024)/ep1.mkv") == false)

        await db.close()
    }
}

// MARK: - 3. SQLiteTaskStore Tests

@Suite("SQLiteTaskStore")
struct SQLiteTaskStoreTests {
    @Test("loadSummaries skips task_reviews, loadReview decodes lazily, and saveSummary preserves review & card_meta")
    func summaryVsReviewIsolationAndPreservation() async throws {
        let db = try SQLiteDatabase.inMemory()
        let store = SQLiteTaskStore(db: db)
        let conn = ConnectionId("c1")
        let taskId = TaskId("T-review")

        let initialSummary = TaskSummary(
            id: taskId,
            connection: conn,
            paths: ["/下载/完成", "/x"],
            mode: .moveToLibrary,
            scrape: true,
            scrapeOnly: false,
            stage: .awaitingReview,
            message: "识别完成",
            importedCount: 7,
            videoCount: 4,
            folderCount: 2,
            subtitleCount: 1,
            progress: 0.5,
            createdAt: Date(timeIntervalSince1970: 1_767_323_045)
        )
        try await store.saveSummary(initialSummary)

        // Before saveReview, loadReview returns nil
        #expect(try await store.loadReview(id: taskId) == nil)

        let candidate = Candidate(
            tmdbId: 27205,
            kind: .movie,
            title: "盗梦空间",
            englishTitle: "Inception",
            year: 2010,
            posterPath: "/inception.jpg",
            genres: ["Sci-Fi"]
        )
        let scan = ScanResult(
            connection: conn,
            roots: ["/下载/完成"],
            groups: [
                MediaGroup(
                    id: GroupId("g1"),
                    kind: .movie,
                    anchorTitle: "Inception",
                    anchorYear: 2010,
                    rootDir: "/下载/完成",
                    files: [
                        ScanFile(
                            path: "/下载/完成/Inception.mkv",
                            name: "Inception.mkv",
                            size: 20_000_000,
                            role: .video,
                            parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.9)
                        ),
                    ],
                    match: candidate,
                    matchScore: 0.92
                ),
            ],
            unassigned: [
                ScanFile(path: "/下载/完成/junk.txt", name: "junk.txt", size: 10, role: .junk),
            ]
        )
        let decisions: [GroupId: GroupDecision] = [
            GroupId("g1"): GroupDecision(
                match: candidate,
                strategy: .splitSequential,
                episodeOffset: -1,
                episodeGroupId: "eg1",
                overrides: [
                    "/下载/完成/Inception.mkv": FileOverride(season: 1, episode: 2, kind: .special, ignore: true),
                ],
                selected: false,
                separate: true
            ),
        ]
        try await store.saveReview(
            id: taskId,
            scan: scan,
            decisions: decisions,
            unassignedDeletes: ["/下载/完成/junk.txt", "/下载/完成/ad.nfo"]
        )

        // Updating summary MUST NOT overwrite task_reviews or card_meta_json!
        var updatedSummary = initialSummary
        updatedSummary.stage = .done
        updatedSummary.progress = nil
        updatedSummary.batch = BatchId("B1")
        try await store.saveSummary(updatedSummary)

        let summaries = try await store.loadSummaries()
        #expect(summaries == [updatedSummary])

        let review = try #require(try await store.loadReview(id: taskId))
        #expect(review.scan == scan)
        #expect(review.decisions == decisions)
        #expect(review.unassignedDeletes == ["/下载/完成/junk.txt", "/下载/完成/ad.nfo"])

        // Clear review keeps summary intact
        try await store.clearReview(id: taskId)
        #expect(try await store.loadReview(id: taskId) == nil)
        #expect(try await store.loadSummaries() == [updatedSummary])

        // Delete removes task completely
        try await store.delete(id: taskId)
        #expect(try await store.loadSummaries().isEmpty)

        await db.close()
    }

    @Test("saveReview compresses scan_blob with TRZ1, saveDecisions preserves scan_blob, pruneScanBlob keeps card_meta_json")
    func compressionSaveDecisionsPruneAndFastCardMeta() async throws {
        let db = try SQLiteDatabase.inMemory()
        let store = SQLiteTaskStore(db: db)
        let conn = ConnectionId("c1")
        let taskId = TaskId("T-v7-fast")

        let summary = TaskSummary(
            id: taskId,
            connection: conn,
            paths: ["/dl"],
            mode: .moveToLibrary,
            stage: .awaitingReview,
            createdAt: Date(timeIntervalSince1970: 1_767_323_045)
        )
        try await store.saveSummary(summary)

        let work1 = Candidate(tmdbId: 100, kind: .episode, title: "葬送的芙莉莲", year: 2023, posterPath: "/frieren.jpg")
        let work2 = Candidate(tmdbId: 200, kind: .movie, title: "盗梦空间", year: 2010, posterPath: "/inception.jpg")
        let files = (1...24).map { ep in
            ScanFile(
                path: "/dl/Frieren/Frieren.S01E\(String(format: "%02d", ep)).1080p.WEB-DL.x265.mkv",
                name: "Frieren.S01E\(String(format: "%02d", ep)).1080p.WEB-DL.x265.mkv",
                size: 1_500_000_000,
                role: .video,
                parsed: ParsedName(title: "Frieren", year: 2023, season: 1, episodes: [ep], kind: .episode, confidence: 0.95)
            )
        }
        let scan = ScanResult(
            connection: conn,
            roots: ["/dl"],
            groups: [
                MediaGroup(
                    id: GroupId("g1"),
                    kind: .episode,
                    anchorTitle: "Frieren",
                    anchorYear: 2023,
                    rootDir: "/dl/Frieren",
                    files: files,
                    match: work1,
                    matchScore: 0.96
                ),
            ],
            unassigned: [
                ScanFile(path: "/dl/readme.txt", name: "readme.txt", size: 12, role: .junk),
            ]
        )

        let rawScanJsonBytes = Data(try TidyreelCodecs.scanToJson(scan).utf8)
        try await store.saveReview(
            id: taskId,
            scan: scan,
            decisions: [GroupId("g1"): GroupDecision(match: work1, selected: true)],
            unassignedDeletes: []
        )

        // Verify scan_blob has TRZ1 header and is meaningfully compressed
        let blobBefore = try #require(
            try await db.query("SELECT scan_blob FROM task_reviews WHERE task_id = ?", bindings: [.text(taskId.value)])
                .first?.first?.dataValue
        )
        #expect(blobBefore.prefix(4) == Data("TRZ1".utf8))
        #expect(blobBefore.count < rawScanJsonBytes.count)

        // Verify fast-path loadCardMeta reads card_meta_json immediately
        let initialMeta = try #require(await store.loadCardMeta(ids: [taskId])[taskId])
        #expect(initialMeta.unassignedCount == 1)
        #expect(initialMeta.works.map(\.tmdbId) == [100])
        #expect(initialMeta.works.first?.posterPath == "/frieren.jpg")

        // saveDecisions updates ONLY decisions_json, unassigned_deletes_json (+ optional card_meta_json)
        let updatedDecisions: [GroupId: GroupDecision] = [
            GroupId("g1"): GroupDecision(match: work2, strategy: .mergeIntoOne, episodeOffset: 2, selected: false),
        ]
        let updatedMeta = TaskCardMeta(works: [work2], unassignedCount: 1)
        try await store.saveDecisions(
            id: taskId,
            decisions: updatedDecisions,
            unassignedDeletes: ["/dl/readme.txt"],
            cardMeta: updatedMeta
        )

        let blobAfter = try #require(
            try await db.query("SELECT scan_blob FROM task_reviews WHERE task_id = ?", bindings: [.text(taskId.value)])
                .first?.first?.dataValue
        )
        #expect(blobAfter == blobBefore)

        let reloadedReview = try #require(try await store.loadReview(id: taskId))
        #expect(reloadedReview.scan == scan)
        #expect(reloadedReview.decisions == updatedDecisions)
        #expect(reloadedReview.unassignedDeletes == ["/dl/readme.txt"])

        // pruneScanBlob clears scan_blob while preserving card_meta_json on tasks
        try await store.pruneScanBlob(id: taskId)
        #expect(try await store.loadReview(id: taskId) == nil)

        let fastMetaAfterPrune = try #require(await store.loadCardMeta(ids: [taskId])[taskId])
        #expect(fastMetaAfterPrune.unassignedCount == 1)
        #expect(fastMetaAfterPrune.works.count == 1)
        #expect(fastMetaAfterPrune.works[0].tmdbId == 200)
        #expect(fastMetaAfterPrune.works[0].title == "盗梦空间")
        #expect(fastMetaAfterPrune.works[0].year == 2010)
        #expect(fastMetaAfterPrune.works[0].posterPath == "/inception.jpg")

        // Deleting task cascades delete to task_reviews via ON DELETE CASCADE
        try await store.delete(id: taskId)
        let leftoverReviews = try await db.query(
            "SELECT COUNT(*) FROM task_reviews WHERE task_id = ?",
            bindings: [.text(taskId.value)]
        )
        #expect(leftoverReviews.first?.first == .integer(0))

        await db.close()
    }

    @Test("Corrupt JSON/blob fields degrade gracefully and unknown enums fall back")
    func corruptJsonAndUnknownEnumResilience() async throws {
        let db = try SQLiteDatabase.inMemory()
        let store = SQLiteTaskStore(db: db)
        let conn = ConnectionId("c1")

        let tGood = TaskSummary(
            id: TaskId("T-good"),
            connection: conn,
            paths: ["/ok"],
            mode: .inPlace,
            scrape: true,
            scrapeOnly: true,
            stage: .awaitingReview,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let tPartial = TaskSummary(
            id: TaskId("T-partial"),
            connection: conn,
            paths: ["/partial"],
            mode: .inPlace,
            stage: .awaitingReview,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let tBroken = TaskSummary(
            id: TaskId("T-broken"),
            connection: conn,
            paths: ["/broken"],
            mode: .inPlace,
            stage: .awaitingReview,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        try await store.saveSummary(tGood)
        try await store.saveSummary(tPartial)
        try await store.saveSummary(tBroken)
        try await store.saveReview(
            id: tPartial.id,
            scan: ScanResult(connection: conn, roots: ["/partial"], groups: []),
            decisions: [:],
            unassignedDeletes: ["/partial/a.txt"]
        )

        try await db.execute(
            "UPDATE tasks SET mode = 'futureMode', stage = 'futureStage' WHERE id = ?",
            bindings: [.text("T-good")]
        )
        try await db.execute(
            "INSERT OR REPLACE INTO task_reviews (task_id, scan_blob, decisions_json, unassigned_deletes_json) VALUES (?, ?, NULL, NULL)",
            bindings: [.text("T-good"), .blob(Data("TRZ1corrupt-zlib".utf8))]
        )
        try await db.execute(
            "UPDATE task_reviews SET decisions_json = '{bad', unassigned_deletes_json = 'not-json' WHERE task_id = ?",
            bindings: [.text("T-partial")]
        )
        try await db.execute(
            "UPDATE tasks SET paths_json = '{not-a-list' WHERE id = ?",
            bindings: [.text("T-broken")]
        )

        // loadSummaries never reads task_reviews and skips broken paths_json
        let summaries = try await store.loadSummaries()
        #expect(Set(summaries.map(\.id.value)) == ["T-good", "T-partial"])
        let goodSummary = try #require(summaries.first(where: { $0.id == TaskId("T-good") }))
        #expect(goodSummary.mode == .inPlace)
        #expect(goodSummary.stage == .failed)
        #expect(goodSummary.scrape == true)
        #expect(goodSummary.scrapeOnly == true)

        // Corrupt compressed TRZ1 blob returns nil cleanly
        #expect(try await store.loadReview(id: TaskId("T-good")) == nil)

        let all = try await store.loadAll()
        #expect(Set(all.map(\.summary.id.value)) == ["T-good", "T-partial"])
        let partial = try #require(all.first(where: { $0.summary.id == TaskId("T-partial") }))
        #expect(partial.scan != nil)
        #expect(partial.decisions.isEmpty)
        #expect(partial.unassignedDeletes.isEmpty)

        await db.close()
    }
}

// MARK: - 4. SQLiteFolderStatsStore Tests

@Suite("SQLiteFolderStatsStore")
struct SQLiteFolderStatsStoreTests {
    @Test("saveBatch, loadFor, markComplete, deleteBelow (>500 rows), and clearFor")
    func folderStatsRoundTripAndInvalidation() async throws {
        let db = try SQLiteDatabase.inMemory()
        let stats = SQLiteFolderStatsStore(db: db)
        let conn = ConnectionId("c1")
        let other = ConnectionId("c2")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        var initialRecords: [CachedFolderRecord] = [
            CachedFolderRecord(
                dirPath: "/",
                entries: [RemoteEntry(path: "/media", name: "media", isDir: true)],
                complete: true,
                scannedAt: t0
            ),
            CachedFolderRecord(
                dirPath: "/media",
                entries: [RemoteEntry(path: "/media/ep01.mkv", name: "ep01.mkv", isDir: false, size: 2048, modified: t0)],
                complete: false,
                scannedAt: t0
            ),
            CachedFolderRecord(
                dirPath: "/keep",
                entries: [],
                complete: true,
                scannedAt: t0
            ),
        ]
        for i in 0..<520 {
            initialRecords.append(
                CachedFolderRecord(dirPath: "/media/sub_\(i)", entries: [], complete: true, scannedAt: t0)
            )
        }

        try await stats.saveBatch(connection: conn, records: initialRecords)
        try await stats.saveDir(connection: other, dirPath: "/other_conn", entries: [], complete: true, scannedAt: t0)
        try await stats.markComplete(connection: conn, dirPath: "/media", scannedAt: t0)

        var loaded = try await stats.loadFor(conn)
        #expect(loaded.count == 523)
        #expect(loaded["/media"]?.complete == true)
        #expect(loaded["/media"]?.entries.first?.size == 2048)

        // Corrupt a single row's entries_json; loadFor skips only that corrupt row
        try await db.execute(
            "UPDATE folder_stats_cache SET entries_json = '{corrupt' WHERE connection_id = ? AND dir_path = ?",
            bindings: [.text(conn.value), .text("/media/sub_0")]
        )
        loaded = try await stats.loadFor(conn)
        #expect(loaded.count == 522)

        // deleteBelow /media removes /media and all 520 children and marks ancestor / incomplete
        try await stats.deleteBelow(connection: conn, root: "/media")
        loaded = try await stats.loadFor(conn)
        #expect(Set(loaded.keys) == ["/", "/keep"])
        #expect(loaded["/"]?.complete == false)
        #expect(loaded["/keep"]?.complete == true)

        // clearFor clears only target connection
        try await stats.clearFor(conn)
        #expect(try await stats.loadFor(conn).isEmpty)
        #expect(try await stats.loadFor(other).count == 1)

        await db.close()
    }

    @Test("loadBelow, deleteBelow prefix boundaries, deleteDirs, and single-pass numeric/ISO date decoding")
    func loadBelowDeleteBelowBoundariesAndDeleteDirs() async throws {
        let db = try SQLiteDatabase.inMemory()
        let stats = SQLiteFolderStatsStore(db: db)
        let conn = ConnectionId("c1")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let records: [CachedFolderRecord] = [
            CachedFolderRecord(dirPath: "/", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media/sub", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media/sub/deep", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media0", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media-alt", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/media2", entries: [], complete: true, scannedAt: t0),
            CachedFolderRecord(dirPath: "/keep", entries: [], complete: true, scannedAt: t0),
        ]
        try await stats.saveBatch(connection: conn, records: records)

        // Insert a row with mixed numeric epoch-ms and ISO-8601 date strings to verify single-pass decode
        let mixedJson = #"[{"p":"/media/a.mkv","n":"a.mkv","d":false,"s":100,"m":1700000000000},{"p":"/media/b.mkv","n":"b.mkv","d":false,"s":200,"m":"2023-11-14T22:13:20.000Z"}]"#
        try await db.execute(
            "UPDATE folder_stats_cache SET entries_json = ? WHERE connection_id = ? AND dir_path = ?",
            bindings: [.text(mixedJson), .text(conn.value), .text("/media")]
        )

        // loadBelow /media MUST include /media, /media/sub, /media/sub/deep and exclude /media0, /media-alt, /media2
        let subTree = try await stats.loadBelow(connection: conn, root: "/media")
        #expect(Set(subTree.keys) == ["/media", "/media/sub", "/media/sub/deep"])
        let mediaEntries = try #require(subTree["/media"]?.entries)
        #expect(mediaEntries.count == 2)
        #expect(mediaEntries[0].modified == t0)
        #expect(mediaEntries[1].modified == t0)

        // loadBelow "/" delegates to full connection load
        let allTree = try await stats.loadBelow(connection: conn, root: "/")
        #expect(allTree.count == 8)

        // deleteDirs removes ONLY /media/sub/deep and marks its ancestors incomplete without touching siblings
        try await stats.deleteDirs(connection: conn, dirs: ["/media/sub/deep"])
        var afterDeleteDirs = try await stats.loadFor(conn)
        #expect(afterDeleteDirs["/media/sub/deep"] == nil)
        #expect(afterDeleteDirs["/media/sub"]?.complete == false)
        #expect(afterDeleteDirs["/media"]?.complete == false)
        #expect(afterDeleteDirs["/"]?.complete == false)
        #expect(afterDeleteDirs["/media0"]?.complete == true)
        #expect(afterDeleteDirs["/media-alt"]?.complete == true)
        #expect(afterDeleteDirs["/media2"]?.complete == true)
        #expect(afterDeleteDirs["/keep"]?.complete == true)

        // Re-mark root complete and run deleteBelow /media: must NOT touch /media0, /media-alt, /media2
        try await stats.markComplete(connection: conn, dirPath: "/", scannedAt: t0)
        try await stats.deleteBelow(connection: conn, root: "/media")
        afterDeleteDirs = try await stats.loadFor(conn)
        #expect(Set(afterDeleteDirs.keys) == ["/", "/media0", "/media-alt", "/media2", "/keep"])
        #expect(afterDeleteDirs["/"]?.complete == false)
        #expect(afterDeleteDirs["/media0"]?.complete == true)
        #expect(afterDeleteDirs["/media-alt"]?.complete == true)
        #expect(afterDeleteDirs["/media2"]?.complete == true)

        await db.close()
    }
}

// MARK: - 5. SQLiteTmdbCache & Legacy Migration Tests

@Suite("SQLiteTmdbCache")
struct SQLiteTmdbCacheTests {
    @Test("LRU eviction, get touch refresh (touchInterval = 0), and TTL expiration")
    func lruEvictionAndTtl() async throws {
        let db = try SQLiteDatabase.inMemory()
        let cache = SQLiteTmdbCache(db: db, maxEntries: 3, ttl: 60, touchInterval: 0)

        await cache.put("k1", json: #"{"v":1}"#)
        await cache.put("k2", json: #"{"v":2}"#)
        await cache.put("k3", json: #"{"v":3}"#)
        #expect(await cache.count() == 3)

        // Touch k1 so k2 becomes the oldest LRU entry
        #expect(await cache.get("k1") == #"{"v":1}"#)

        // Inserting k4 trims cache to maxEntries = 3, evicting k2
        await cache.put("k4", json: #"{"v":4}"#)
        #expect(await cache.count() == 3)
        #expect(await cache.get("k2") == nil)
        #expect(await cache.get("k1") == #"{"v":1}"#)
        #expect(await cache.get("k3") == #"{"v":3}"#)
        #expect(await cache.get("k4") == #"{"v":4}"#)

        // Short TTL cache expires entries cleanly
        let expiringCache = SQLiteTmdbCache(db: db, maxEntries: 10, ttl: 0.03, touchInterval: 0)
        await expiringCache.put("ephemeral", json: #"{"temp":true}"#)
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(await expiringCache.get("ephemeral") == nil)

        await db.close()
    }

    @Test("Default 12h touchInterval skips read-path writes and indexed trim handles tied timestamps")
    func touchIntervalThrottlingAndTiedTrim() async throws {
        let db = try SQLiteDatabase.inMemory()
        let cache = SQLiteTmdbCache(db: db, maxEntries: 3, ttl: 3600)

        await cache.put("fresh", json: #"{"ok":1}"#)
        let tsBefore = try await db.query(
            "SELECT updated_at FROM tmdb_http_cache WHERE cache_key = 'fresh'"
        ).first?.first?.int64Value

        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(await cache.get("fresh") == #"{"ok":1}"#)

        let tsAfter = try await db.query(
            "SELECT updated_at FROM tmdb_http_cache WHERE cache_key = 'fresh'"
        ).first?.first?.int64Value
        #expect(tsBefore != nil)
        #expect(tsBefore == tsAfter)

        // Insert 5 rows with identical updated_at timestamps and verify trim enforces <= maxEntries
        await cache.clear()
        let sameTs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        for i in 1...5 {
            try await db.execute(
                "INSERT INTO tmdb_http_cache (cache_key, json_text, updated_at) VALUES (?, ?, ?)",
                bindings: [.text("tie-\(i)"), .text("{}"), .integer(sameTs)]
            )
        }
        await cache.trim()
        #expect(await cache.count() == 3)

        await db.close()
    }

    @Test("importLegacyJsonFileIfNeeded migrates Dart FileTmdbCache & entries formats and renames to .migrated")
    func legacyTmdbCacheMigration() async throws {
        let dir = try makeTempDir("tmdb-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try SQLiteDatabase.inMemory()
        let cache = SQLiteTmdbCache(db: db, maxEntries: 100)
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())

        // 1. Authoritative Dart FileTmdbCache format: {"key": [timestampMs, {jsonMap}]}
        let legacyFile1 = dir.appendingPathComponent("tmdb_cache.json")
        let dartPayload: [String: Any] = [
            "search:doro": [nowMs, ["results": [["id": 95479, "name": "异兽魔都"]]]],
            "expired:old": [1_000, ["results": []]],
        ]
        try JSONSerialization.data(withJSONObject: dartPayload).write(to: legacyFile1)

        await cache.importLegacyJsonFileIfNeeded(at: legacyFile1)

        #expect(!FileManager.default.fileExists(atPath: legacyFile1.path))
        #expect(FileManager.default.fileExists(atPath: legacyFile1.path + ".migrated"))
        #expect(await cache.get("expired:old") == nil)
        let imported1 = try #require(await cache.get("search:doro"))
        #expect(imported1.contains("95479"))

        // Calling again when file is already migrated is a safe no-op
        await cache.importLegacyJsonFileIfNeeded(at: legacyFile1)
        #expect(await cache.count() == 1)

        // 2. Wrapped {"entries": {"key": "{...}"}} format
        let legacyFile2 = dir.appendingPathComponent("tmdb_cache_wrapped.json")
        let wrappedPayload: [String: Any] = [
            "entries": [
                "movie:27205": #"{"id":27205,"title":"Inception"}"#,
            ],
        ]
        try JSONSerialization.data(withJSONObject: wrappedPayload).write(to: legacyFile2)

        await cache.importLegacyJsonFileIfNeeded(at: legacyFile2)
        #expect(!FileManager.default.fileExists(atPath: legacyFile2.path))
        #expect(FileManager.default.fileExists(atPath: legacyFile2.path + ".migrated"))
        #expect(await cache.get("movie:27205") == #"{"id":27205,"title":"Inception"}"#)

        await db.close()
    }
}

// MARK: - 6. SQLiteMediaProbeCache & CachingMediaProbe Tests

@Suite("SQLiteMediaProbeCache & CachingMediaProbe")
struct SQLiteMediaProbeCacheTests {
    @Test("Hit/miss across L1 & L2, (fileSize, modifiedAt) invalidation, fileSize-only fallback, negative TTL, singleflight & clear")
    func mediaProbeCacheLifecycleAndSingleflight() async throws {
        let db = try SQLiteDatabase.inMemory()
        let backend = MemoryStorageBackend()
        let conn = ConnectionId("nas-1")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_005_000)

        let expectedInfo = MediaProbeInfo(
            width: 3840,
            height: 2160,
            videoCodec: "HEVC",
            hdr: "DV",
            audioCodec: "Atmos",
            audioChannels: 8,
            durationMs: 7_200_000,
            container: "mkv"
        )
        let inner = CountingMediaProbe(
            results: [
                "/movies/Dune.mkv": expectedInfo,
                "/movies/Unparseable.mkv": nil,
            ],
            delayNs: 20_000_000
        )

        let cache = SQLiteMediaProbeCache(db: db, maxEntries: 100, l1Capacity: 50, negativeTTL: 0.06)
        let probe = CachingMediaProbe(inner: inner, cache: cache, connection: conn)

        // 1. Singleflight deduplication: 8 concurrent requests for the same path invoke inner probe ONCE
        let results = await withTaskGroup(of: MediaProbeInfo?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await probe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 5_000, modifiedAt: t0)
                }
            }
            var collected: [MediaProbeInfo?] = []
            for await r in group {
                collected.append(r)
            }
            return collected
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == expectedInfo })
        #expect(await inner.callCount == 1)

        // 2. L1 hit with same (fileSize, modifiedAt)
        let l1Hit = await probe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 5_000, modifiedAt: t0)
        #expect(l1Hit == expectedInfo)
        #expect(await inner.callCount == 1)

        // 3. fileSize-only fallback via standard MediaProbe.probe(backend:path:fileSize:) hits cached entry
        let fallbackHit = await probe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 5_000)
        #expect(fallbackHit == expectedInfo)
        #expect(await inner.callCount == 1)

        // 4. L2 hit from a fresh SQLiteMediaProbeCache instance (cold L1)
        let freshCache = SQLiteMediaProbeCache(db: db, maxEntries: 100, l1Capacity: 50, negativeTTL: 0.06)
        let freshProbe = CachingMediaProbe(inner: inner, cache: freshCache, connection: conn)
        let l2Hit = await freshProbe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 5_000, modifiedAt: t0)
        #expect(l2Hit == expectedInfo)
        #expect(await inner.callCount == 1)

        // 5. Invalidation when fileSize changes
        let updatedInfo = MediaProbeInfo(width: 1920, height: 1080, videoCodec: "AVC", container: "mkv")
        await inner.setResult(updatedInfo, for: "/movies/Dune.mkv")
        let sizeChanged = await probe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 9_999, modifiedAt: t0)
        #expect(sizeChanged == updatedInfo)
        #expect(await inner.callCount == 2)

        // 6. Invalidation when modifiedAt changes
        let modChanged = await probe.probe(backend: backend, path: "/movies/Dune.mkv", fileSize: 9_999, modifiedAt: t1)
        #expect(modChanged == updatedInfo)
        #expect(await inner.callCount == 3)

        // 7. Negative result caching (probe_json = NULL) prevents re-probing within negativeTTL
        let neg1 = await probe.probe(backend: backend, path: "/movies/Unparseable.mkv", fileSize: 4096, modifiedAt: t0)
        #expect(neg1 == nil)
        #expect(await inner.callCount == 4)

        let neg2 = await probe.probe(backend: backend, path: "/movies/Unparseable.mkv", fileSize: 4096, modifiedAt: t0)
        #expect(neg2 == nil)
        #expect(await inner.callCount == 4)

        // Verify negative entry expired after negativeTTL
        try await Task.sleep(nanoseconds: 80_000_000)
        let neg3 = await probe.probe(backend: backend, path: "/movies/Unparseable.mkv", fileSize: 4096, modifiedAt: t0)
        #expect(neg3 == nil)
        #expect(await inner.callCount == 5)

        // 8. Clear wipes L1 and SQLite
        await cache.clear()
        #expect(await cache.count() == 0)
        #expect(await cache.get(connection: conn, path: "/movies/Dune.mkv", fileSize: 9_999, modifiedAt: t1) == .miss)

        // 9. maxEntries trimming enforces strict cap
        let smallCache = SQLiteMediaProbeCache(db: db, maxEntries: 3, l1Capacity: 2, negativeTTL: 60)
        for i in 1...5 {
            await smallCache.put(
                connection: conn,
                path: "/trim/\(i).mkv",
                fileSize: Int64(i * 100),
                info: MediaProbeInfo(width: 1920, height: 1080)
            )
        }
        #expect(await smallCache.count() == 3)

        await db.close()
    }
}

// MARK: - 7. JsonPrefsStore, FileSecretStore & AppSupportPaths Tests

@Suite("JsonPrefsStore, FileSecretStore & AppSupportPaths")
struct FileStoresTests {
    @Test("JsonPrefsStore persists typed settings/connections/naming/rules and backs up corrupt files to .broken")
    func jsonPrefsStoreRoundTripAndCorruptBackup() throws {
        let dir = try makeTempDir("prefs-store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefsURL = try AppSupportPaths.prefsURL(in: dir, createDirectory: true)
        let store = JsonPrefsStore(fileURL: prefsURL)

        var settings = AppSettings()
        settings.concurrency = 6
        settings.accent = .bamboo
        settings.mapZoomStyle = .semantic
        store.saveSettings(settings)

        let conn = ConnectionConfig(
            id: ConnectionId("nas"),
            name: "家里 NAS",
            type: .alist,
            endpoint: "http://nas:5244",
            username: "admin",
            libraryRoot: "/影视库",
            favorites: ["/下载"],
            startDir: "/下载"
        )
        store.saveConnections([conn])

        let profile = NamingProfile.forPlayer(.plex)
        store.saveNamingProfile(profile)

        let rules = TitleRules(
            cleanups: [NameRewrite(#"^【.*?】"#, "")],
            pins: [TitlePin("复本", Candidate(tmdbId: 7, kind: .episode, title: "人生复本"))]
        )
        store.saveTitleRules(rules)

        // Reopen from disk and verify exact round-trip
        let reopened = JsonPrefsStore(fileURL: prefsURL)
        #expect(reopened.loadSettings().concurrency == 6)
        #expect(reopened.loadSettings().accent == .bamboo)
        #expect(reopened.loadSettings().mapZoomStyle == .semantic)
        #expect(reopened.loadConnections() == [conn])
        #expect(reopened.loadNamingProfile() == profile)
        #expect(reopened.loadTitleRules() == rules)

        // Corrupt prefs.json -> moved to prefs.json.broken and store recovers cleanly
        try Data("{not valid json".utf8).write(to: prefsURL)
        let recovered = JsonPrefsStore(fileURL: prefsURL)
        #expect(recovered.read("settings") == nil)
        #expect(FileManager.default.fileExists(atPath: prefsURL.path + ".broken"))

        // Root JSON array (non-object) is also treated as corrupt
        try Data("[1, 2, 3]".utf8).write(to: prefsURL)
        let recoveredFromArray = JsonPrefsStore(fileURL: prefsURL)
        #expect(recoveredFromArray.allKeys().isEmpty)
    }

    @Test("FileSecretStore enforces POSIX 0600 permissions on open, write, and .broken backups")
    func fileSecretStorePermissionsAndSemantics() throws {
        let dir = try makeTempDir("secret-store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let secretsURL = try AppSupportPaths.secretsURL(in: dir, createDirectory: true)
        let secrets = FileSecretStore(fileURL: secretsURL)

        // Immediately created with 0o600
        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))

        secrets.write("conn:c1", "pw1")
        secrets.writeTmdbApiKey("  my-tmdb-key  ")
        secrets.write("temp", "abc")
        secrets.write("temp", "")
        secrets.write("temp2", "xyz")
        secrets.write("temp2", nil)
        secrets.writeConnectionDirPasswords(ConnectionId("c1"), dirPasswords: ["download/sub/": "dirpw"])

        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))

        // Verify raw JSON contains no null/empty tombstones
        let rawObj = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: secretsURL)) as? [String: Any]
        )
        #expect(!rawObj.keys.contains("temp"))
        #expect(!rawObj.keys.contains("temp2"))

        let reopened = FileSecretStore(fileURL: secretsURL)
        #expect(reopened.read("conn:c1") == "pw1")
        #expect(reopened.readTmdbApiKey() == "my-tmdb-key")
        #expect(reopened.read("temp") == nil)
        let creds = reopened.readCredentials(for: ConnectionId("c1"))
        #expect(creds.password == "pw1")
        #expect(creds.passwordForPath("/download/sub/ep1.mkv") == "dirpw")

        // Non-string values in JSON return nil safely, and relaxed 0644 permissions are tightened to 0600
        try Data(#"{"num":42,"flag":true,"ok":"secret"}"#.utf8).write(to: secretsURL)
        _ = secretsURL.path.withCString { Darwin.chmod($0, mode_t(0o644)) }
        let typedCheck = FileSecretStore(fileURL: secretsURL)
        #expect(typedCheck.read("num") == nil)
        #expect(typedCheck.read("flag") == nil)
        #expect(typedCheck.read("ok") == "secret")
        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))

        // Corrupt file with 0644 -> moved to .broken with 0600 AND fresh secrets.json created with 0600
        try Data("{corrupt-secret".utf8).write(to: secretsURL)
        _ = secretsURL.path.withCString { Darwin.chmod($0, mode_t(0o644)) }
        _ = FileSecretStore(fileURL: secretsURL)

        let brokenPath = secretsURL.path + ".broken"
        #expect(FileManager.default.fileExists(atPath: brokenPath))
        #expect(FileManager.default.fileExists(atPath: secretsURL.path))
        #expect(try posixMode(at: brokenPath) == mode_t(0o600))
        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))
    }

    @Test("Debounced JsonPrefsStore and FileSecretStore coalesce writes and flush cleanly via flushSync and timer")
    func debouncedFlushAndFlushSync() async throws {
        let dir = try makeTempDir("debounced-stores")
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefsURL = try AppSupportPaths.prefsURL(in: dir, createDirectory: true)
        let prefs = JsonPrefsStore(fileURL: prefsURL, flushDebounceMs: 120)

        for i in 0..<20 {
            prefs.write("k\(i)", "v\(i)")
        }
        // In-memory state is immediately readable before disk flush
        #expect(prefs.readString("k19") == "v19")

        // flushSync writes all coalesced updates atomically to disk right away
        prefs.flushSync()
        let reopenedImmediate = JsonPrefsStore(fileURL: prefsURL)
        #expect(reopenedImmediate.readString("k0") == "v0")
        #expect(reopenedImmediate.readString("k19") == "v19")

        // Background timer flushes after debounce window without explicit flushSync
        prefs.write("asyncKey", "asyncVal")
        try await Task.sleep(nanoseconds: 250_000_000)
        let reopenedAfterTimer = JsonPrefsStore(fileURL: prefsURL)
        #expect(reopenedAfterTimer.readString("asyncKey") == "asyncVal")

        // Debounced FileSecretStore still creates 0o600 on open and flushes 0o600 on flushSync
        let secretsURL = try AppSupportPaths.secretsURL(in: dir, createDirectory: true)
        let secrets = FileSecretStore(fileURL: secretsURL, flushDebounceMs: 120)
        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))

        secrets.writeTmdbApiKey("debounced-key")
        #expect(secrets.readTmdbApiKey() == "debounced-key")
        secrets.flushSync()

        #expect(try posixMode(at: secretsURL.path) == mode_t(0o600))
        let reopenedSecrets = FileSecretStore(fileURL: secretsURL)
        #expect(reopenedSecrets.readTmdbApiKey() == "debounced-key")
    }

    @Test("AppSupportPaths resolves bundle identifier directory and standard filenames")
    func appSupportPathsResolution() throws {
        let resolvedDir = try AppSupportPaths.directoryURL(createIfMissing: false)
        #expect(resolvedDir.lastPathComponent == "app.tidyreel.tidyreel")

        let customDir = URL(fileURLWithPath: "/tmp/tidyreel-test-support", isDirectory: true)
        #expect(try AppSupportPaths.databaseURL(in: customDir).lastPathComponent == "tidyreel.sqlite")
        #expect(try AppSupportPaths.prefsURL(in: customDir).lastPathComponent == "prefs.json")
        #expect(try AppSupportPaths.secretsURL(in: customDir).lastPathComponent == "secrets.json")
        #expect(try AppSupportPaths.legacyTmdbCacheURL(in: customDir).lastPathComponent == "tmdb_cache.json")
    }
}
