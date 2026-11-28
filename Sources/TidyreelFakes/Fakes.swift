import Foundation
import TidyreelModels

// MARK: - In-Memory Test & Demo Fakes

public actor MemoryStorageBackend: RangeReadableBackend {
    private var files: [String: Data] = [:]
    private var dirs: Set<String> = ["/"]
    private var fileIDs: [String: String] = [:]
    private var modDates: [String: Date] = [:]

    public init(initialSizes: [String: Int] = [:], initialFiles: [String: Data] = [:]) {
        var initFiles: [String: Data] = [:]
        var initDirs: Set<String> = ["/"]
        func addParents(_ path: String) {
            var cur = dirOf(path)
            while true {
                initDirs.insert(cur)
                if cur == "/" { break }
                cur = dirOf(cur)
            }
        }
        for (rawPath, size) in initialSizes {
            let p = normalizeDir(rawPath)
            initFiles[p] = Data(count: max(0, size))
            addParents(p)
        }
        for (rawPath, data) in initialFiles {
            let p = normalizeDir(rawPath)
            initFiles[p] = data
            addParents(p)
        }
        self.fileIDs = Dictionary(uniqueKeysWithValues: initFiles.keys.map { ($0, "seed:" + $0) })
        self.files = initFiles
        self.dirs = initDirs
    }

    private func registerParents(of path: String) {
        var cur = dirOf(path)
        while true {
            dirs.insert(cur)
            if cur == "/" { break }
            cur = dirOf(cur)
        }
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        let norm = normalizeDir(dir)
        guard dirs.contains(norm) else {
            throw StorageError(.notFound, "目录不存在：\(norm)")
        }
        var out: [RemoteEntry] = []
        var seenDirs: Set<String> = []
        for d in dirs where d != norm && dirOf(d) == norm {
            if seenDirs.insert(d).inserted {
                out.append(RemoteEntry(path: d, name: baseOf(d), isDir: true, size: 0, modified: modDates[d]))
            }
        }
        for (f, data) in files where dirOf(f) == norm {
            out.append(RemoteEntry(path: f, name: baseOf(f), isDir: false, size: Int64(data.count), modified: modDates[f], deleteIdentity: fileIDs[f]))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func mkdirs(_ dir: String) async throws {
        let norm = normalizeDir(dir)
        if files[norm] != nil {
            throw StorageError(.alreadyExists, "同名文件已存在：\(norm)")
        }
        dirs.insert(norm)
        registerParents(of: norm)
    }

    public func rename(_ path: String, newName: String) async throws {
        let norm = normalizeDir(path)
        let dst = joinPath(dirOf(norm), newName)
        if norm == dst { return }
        if files[dst] != nil || dirs.contains(dst) {
            throw StorageError(.alreadyExists, "目标已存在：\(dst)")
        }
        if let data = files.removeValue(forKey: norm) {
            files[dst] = data
            fileIDs[dst] = fileIDs.removeValue(forKey: norm)
            modDates[dst] = Date()
            return
        }
        if dirs.contains(norm) {
            let prefix = norm + "/"
            let subDirs = dirs.filter { $0 == norm || $0.hasPrefix(prefix) }
            for d in subDirs {
                dirs.remove(d)
                let moved = dst + String(d.dropFirst(norm.count))
                dirs.insert(moved)
            }
            let subFiles = files.keys.filter { $0.hasPrefix(prefix) }
            for f in subFiles {
                if let val = files.removeValue(forKey: f) {
                    let moved = dst + String(f.dropFirst(norm.count))
                    files[moved] = val
                    fileIDs[moved] = fileIDs.removeValue(forKey: f)
                }
            }
            return
        }
        throw StorageError(.notFound, "路径不存在：\(norm)")
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        let norm = normalizeDir(dir)
        for (old, new) in names {
            try await rename(joinPath(norm, old), newName: new)
        }
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        let sNorm = normalizeDir(srcDir)
        let dNorm = normalizeDir(dstDir)
        try await mkdirs(dNorm)
        for name in names {
            let src = joinPath(sNorm, name)
            let dst = joinPath(dNorm, name)
            if src == dst { continue }
            if files[dst] != nil || dirs.contains(dst) {
                throw StorageError(.alreadyExists, "目标已存在：\(dst)")
            }
            if let data = files.removeValue(forKey: src) {
                files[dst] = data
                fileIDs[dst] = fileIDs.removeValue(forKey: src)
            } else if dirs.contains(src) {
                let prefix = src + "/"
                for d in dirs.filter({ $0 == src || $0.hasPrefix(prefix) }) {
                    dirs.remove(d)
                    dirs.insert(dst + String(d.dropFirst(src.count)))
                }
                for f in files.keys.filter({ $0.hasPrefix(prefix) }) {
                    if let val = files.removeValue(forKey: f) {
                        let moved = dst + String(f.dropFirst(src.count))
                        files[moved] = val
                        fileIDs[moved] = fileIDs.removeValue(forKey: f)
                    }
                }
            } else {
                throw StorageError(.notFound, "源路径不存在：\(src)")
            }
        }
    }

    public func removeScannedFile(_ path: String, identity: String?) async throws {
        let norm = normalizeDir(path)
        guard let identity else { throw StorageError(.other, "缺少文件标识：\(path)") }
        if !dirs.contains(norm) && files[norm] == nil { return }
        guard files[norm] != nil, fileIDs[norm] == identity else { throw StorageError(.other, "文件已变更：\(path)") }
        files.removeValue(forKey: norm)
        fileIDs.removeValue(forKey: norm)
    }

    public func removeDirectoryIfEmpty(_ dir: String, removingSystemFiles: Bool) async throws -> Bool {
        let norm = normalizeDir(dir)
        guard norm != "/", dirs.contains(norm) else { return false }
        guard !dirs.contains(where: { dirOf($0) == norm && $0 != norm }) else { return false }
        let children = files.keys.filter { dirOf($0) == norm }
        guard children.allSatisfy({ removingSystemFiles && ignorableEmptyDirFiles.contains(baseOf($0).lowercased()) }) else {
            return false
        }
        for path in children {
            files.removeValue(forKey: path)
            fileIDs.removeValue(forKey: path)
        }
        dirs.remove(norm)
        return true
    }

    public func remove(dir: String, names: [String]) async throws {
        let norm = normalizeDir(dir)
        for name in names {
            let target = joinPath(norm, name)
            if files.removeValue(forKey: target) != nil {
                fileIDs.removeValue(forKey: target)
                continue
            }
            if dirs.contains(target) {
                let prefix = target + "/"
                dirs = dirs.filter { $0 != target && !$0.hasPrefix(prefix) }
                for k in files.keys.filter({ $0.hasPrefix(prefix) }) {
                    files.removeValue(forKey: k)
                    fileIDs.removeValue(forKey: k)
                }
            }
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        let norm = normalizeDir(path)
        return files[norm] != nil || dirs.contains(norm)
    }

    public func read(_ path: String) async throws -> Data {
        let norm = normalizeDir(path)
        guard let data = files[norm] else {
            throw StorageError(.notFound, "文件不存在：\(norm)")
        }
        return data
    }

    public func write(_ path: String, bytes: Data) async throws {
        let norm = normalizeDir(path)
        if files[norm] != nil || dirs.contains(norm) {
            throw StorageError(.alreadyExists, "目标已存在：\(norm)")
        }
        registerParents(of: norm)
        fileIDs[norm] = UUID().uuidString
        files[norm] = bytes
        modDates[norm] = Date()
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        let data = try await read(path)
        guard start >= 0, length > 0, Int(start) < data.count else { return Data() }
        let s = Int(start)
        let e = min(data.count, s + length)
        return data.subdata(in: s..<e)
    }

    public func ping() async throws {}
    public func close() async {}
}

public actor MemoryTaskStore: TaskStore {
    private var summaries: [TaskId: TaskSummary] = [:]
    private var reviews: [TaskId: StoredTaskReview] = [:]

    public init() {}

    public func saveSummary(_ summary: TaskSummary) async throws {
        summaries[summary.id] = summary
    }

    public func saveReview(
        id: TaskId,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        unassignedDeletes: [String: Bool] = [:]
    ) async throws {
        reviews[id] = StoredTaskReview(scan: scan, decisions: decisions, unassignedDeletes: unassignedDeletes)
    }

    public func clearReview(id: TaskId) async throws {
        reviews.removeValue(forKey: id)
    }

    public func loadSummaries() async throws -> [TaskSummary] {
        Array(summaries.values)
    }

    public func loadReview(id: TaskId) async throws -> StoredTaskReview? {
        reviews[id]
    }

    public func loadAll() async throws -> [StoredTask] {
        summaries.values.map { s in
            let r = reviews[s.id]
            return StoredTask(
                summary: s,
                scan: r?.scan,
                decisions: r?.decisions ?? [:],
                unassignedDeletes: r?.unassignedDeletes ?? [:]
            )
        }
    }

    public func delete(id: TaskId) async throws {
        summaries.removeValue(forKey: id)
        reviews.removeValue(forKey: id)
    }
}

public actor MemoryHistoryStore: HistoryStore {
    private struct BatchEntry {
        var id: BatchId
        var task: TaskId
        var connection: ConnectionId
        var createdAt: Date
        var records: [HistoryRecord]
    }

    private var store: [BatchId: BatchEntry] = [:]
    private var order: [BatchId] = []
    private var seq = 0

    public init() {}

    public func setCyclePhase(_ phase: RelocationCyclePhase, batch: BatchId, ops: [OpId]) async throws {
        guard var entry = store[batch] else { throw StorageError(.notFound, batch.value) }
        let ids = Set(ops)
        for index in entry.records.indices where ids.contains(entry.records[index].op.id) {
            entry.records[index].cyclePhase = phase
        }
        store[batch] = entry
    }

    public func saveWrittenDigest(_ digest: String, batch: BatchId, op: OpId) async throws {
        guard let i = store[batch]?.records.firstIndex(where: { $0.op.id == op }) else { return }
        store[batch]?.records[i].writtenDigest = digest
    }

    public func beginBatch(task: TaskId, connection: ConnectionId, ops: [RenameOp]) async throws -> BatchId {
        seq += 1
        let id = BatchId("B\(seq)")
        let now = Date()
        let recs = ops.map { HistoryRecord(batch: id, op: $0, status: .pending, cyclePhase: .planned, updatedAt: now) }
        store[id] = BatchEntry(id: id, task: task, connection: connection, createdAt: now, records: recs)
        order.append(id)
        return id
    }

    public func mark(batch: BatchId, op: OpId, status: OpStatus, error: String? = nil) async throws {
        guard var entry = store[batch] else { return }
        if let idx = entry.records.firstIndex(where: { $0.op.id == op }) {
            entry.records[idx].status = status
            entry.records[idx].error = error
            entry.records[idx].updatedAt = Date()
            store[batch] = entry
        }
    }

    public func records(batch: BatchId) async throws -> [HistoryRecord] {
        store[batch]?.records ?? []
    }

    public func batches() async throws -> [BatchSummary] {
        order.reversed().compactMap { id in
            guard let e = store[id] else { return nil }
            let done = e.records.filter { $0.status == .done }.count
            let failed = e.records.filter { $0.status == .failed }.count
            let undone = !e.records.isEmpty && e.records.allSatisfy { $0.status == .undone || $0.status == .skipped }
            return BatchSummary(
                id: e.id,
                task: e.task,
                connection: e.connection,
                createdAt: e.createdAt,
                total: e.records.count,
                done: done,
                failed: failed,
                undone: undone
            )
        }
    }

    public func isOrganized(connection: ConnectionId, path: String) async throws -> Bool {
        let set = try await areOrganized(connection: connection, paths: [path])
        return set.contains(path)
    }

    public func areOrganized(connection: ConnectionId, paths: [String]) async throws -> Set<String> {
        let targets = Set(paths)
        var organized: Set<String> = []
        for entry in store.values where entry.connection == connection {
            for r in entry.records where r.status == .done && targets.contains(r.op.dst) {
                organized.insert(r.op.dst)
            }
        }
        return organized
    }

    public func deleteTask(_ task: TaskId) async throws {
        let ids = store.values.filter { $0.task == task }.map(\.id)
        for id in ids {
            store.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
    }
}

public struct FakeMetadataProvider: MetadataProvider, ExternalIdLookup, Sendable {
    public var showsById: [Int: ShowDetail]
    public var moviesById: [Int: MovieDetail]
    public var seasonsByShow: [Int: [Int: [Episode]]]
    public var groupsByShow: [Int: [EpisodeGroup]]

    public init(
        showsById: [Int: ShowDetail] = [:],
        moviesById: [Int: MovieDetail] = [:],
        seasonsByShow: [Int: [Int: [Episode]]] = [:],
        groupsByShow: [Int: [EpisodeGroup]] = [:]
    ) {
        self.showsById = showsById
        self.moviesById = moviesById
        self.seasonsByShow = seasonsByShow
        self.groupsByShow = groupsByShow
    }

    public static func demo() -> FakeMetadataProvider {
        let doro = Candidate(
            tmdbId: 95479,
            kind: .episode,
            title: "异兽魔都",
            englishTitle: "Dorohedoro",
            originalTitle: "ドロヘドロ",
            year: 2020,
            originCountry: "JP",
            voteAverage: 8.2,
            overview: "在魔法师横行的洞穴里寻找记忆的蜥蜴头男子开曼。"
        )
        let inception = Candidate(
            tmdbId: 27205,
            kind: .movie,
            title: "盗梦空间",
            englishTitle: "Inception",
            originalTitle: "Inception",
            year: 2010,
            originCountry: "US",
            voteAverage: 8.4,
            overview: "潜入梦境深处植入想法的盗梦团队。"
        )
        let friends = Candidate(
            tmdbId: 1668,
            kind: .episode,
            title: "老友记",
            englishTitle: "Friends",
            originalTitle: "Friends",
            year: 1994,
            originCountry: "US",
            voteAverage: 8.6
        )
        return FakeMetadataProvider(
            showsById: [
                95479: ShowDetail(info: doro, seasons: [SeasonInfo(number: 1, episodeCount: 12, name: "第 1 季")]),
                1668: ShowDetail(info: friends, seasons: [
                    SeasonInfo(number: 1, episodeCount: 24, name: "第 1 季"),
                    SeasonInfo(number: 2, episodeCount: 24, name: "第 2 季"),
                ]),
            ],
            moviesById: [
                27205: MovieDetail(info: inception),
            ],
            seasonsByShow: [
                95479: [1: (1...12).map { Episode(season: 1, number: $0, title: "第\($0)话") }],
                1668: [2: (1...24).map { Episode(season: 2, number: $0, title: "Episode \($0)") }],
            ]
        )
    }

    public func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
        let nq = normTitle(query)
        var all: [Candidate] = []
        if kind == nil || kind == .episode || kind == .special {
            all.append(contentsOf: showsById.values.map(\.info))
        }
        if kind == nil || kind == .movie {
            all.append(contentsOf: moviesById.values.map(\.info))
        }
        return all.filter { c in
            let names = [c.title, c.englishTitle, c.originalTitle].compactMap { $0 } + c.aliases
            return names.contains { titleSimilarity($0, nq) >= 0.4 || normTitle($0).contains(nq) || nq.contains(normTitle($0)) }
        }
    }

    public func show(_ tmdbId: Int) async throws -> ShowDetail {
        guard let s = showsById[tmdbId] else {
            throw TmdbError(statusCode: 404, message: "Show \(tmdbId) not found")
        }
        return s
    }

    public func season(_ tmdbId: Int, season: Int) async throws -> [Episode] {
        seasonsByShow[tmdbId]?[season] ?? []
    }

    public func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
        groupsByShow[tmdbId] ?? []
    }

    public func movie(_ tmdbId: Int) async throws -> MovieDetail {
        guard let m = moviesById[tmdbId] else {
            throw TmdbError(statusCode: 404, message: "Movie \(tmdbId) not found")
        }
        return m
    }

    public func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate? {
        if source.lowercased() == "tmdb", let num = Int(id) {
            if let m = moviesById[num]?.info, kind == nil || kind == .movie { return m }
            if let s = showsById[num]?.info, kind == nil || kind == .episode || kind == .special { return s }
        }
        return nil
    }
}
