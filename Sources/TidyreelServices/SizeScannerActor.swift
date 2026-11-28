import Foundation
import TidyreelModels
import TidyreelParser
import TidyreelPersistence

public struct FolderStats: Equatable, Hashable, Sendable {
    public var organized: Int64
    public var unorganized: Int64
    public var other: Int64
    public var files: Int

    public static let zero = FolderStats()

    public init(organized: Int64 = 0, unorganized: Int64 = 0, other: Int64 = 0, files: Int = 0) {
        self.organized = organized
        self.unorganized = unorganized
        self.other = other
        self.files = files
    }

    public var total: Int64 { organized + unorganized + other }
    public var video: Int64 { organized + unorganized }

    public static func + (lhs: FolderStats, rhs: FolderStats) -> FolderStats {
        FolderStats(
            organized: lhs.organized + rhs.organized,
            unorganized: lhs.unorganized + rhs.unorganized,
            other: lhs.other + rhs.other,
            files: lhs.files + rhs.files
        )
    }
}

public enum MapBlockState: String, CaseIterable, Sendable {
    case organized
    case mixed
    case unorganized
    case other

    public static func of(_ s: FolderStats) -> MapBlockState {
        if s.video == 0 { return .other }
        let ratio = Double(s.organized) / Double(s.video)
        if ratio >= 0.8 { return .organized }
        if ratio <= 0.2 { return .unorganized }
        return .mixed
    }
}

public struct MapChildNode: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { entry.path }
    public var entry: RemoteEntry
    public var stats: FolderStats
    public var state: MapBlockState

    public init(entry: RemoteEntry, stats: FolderStats) {
        self.entry = entry
        self.stats = stats
        self.state = MapBlockState.of(stats)
    }
}

public struct SizeScanSnapshot: Equatable, Sendable {
    public var rootDir: String
    public var rootStats: FolderStats
    public var children: [MapChildNode]
    public var isRunning: Bool
    public var isComplete: Bool
    public var dirsListed: Int
    public var skipped: [String: String]
    public var errorMessage: String?

    public init(
        rootDir: String,
        rootStats: FolderStats = .zero,
        children: [MapChildNode] = [],
        isRunning: Bool = false,
        isComplete: Bool = false,
        dirsListed: Int = 0,
        skipped: [String: String] = [:],
        errorMessage: String? = nil
    ) {
        self.rootDir = rootDir
        self.rootStats = rootStats
        self.children = children
        self.isRunning = isRunning
        self.isComplete = isComplete
        self.dirsListed = dirsListed
        self.skipped = skipped
        self.errorMessage = errorMessage
    }
}

/// Pure background `actor` replacement for Flutter's main-isolate `SizeScanner`.
/// All SQLite hydration, JSON decoding, `RuleBasedParser.classify`, and `looksOrganized`
/// run 100% off `@MainActor`, emitting pre-aggregated `SizeScanSnapshot` values.
public actor SizeScannerActor {
    private static let dbFlushBatchSize = 32
    private static let dbFlushInterval: Duration = .milliseconds(500)
    private static let snapshotEmitInterval: Duration = .milliseconds(250)

    private struct MemoKey: Hashable {
        let dir: String
        let inheritedOrg: Bool
    }

    private enum WalkDirAction: Sendable {
        case stop
        case cached([String])
        case fetch(refresh: Bool)
    }

    private let connectionId: ConnectionId
    private let backend: any StorageBackend
    private let historyStore: any HistoryStore
    private let cacheStore: SQLiteFolderStatsStore?
    private let parser: RuleBasedParser
    private let cacheTTL: TimeInterval

    private var listings: [String: [RemoteEntry]] = [:]
    private var organizedPaths: Set<String> = []
    private var checkedOrganized: Set<String> = []
    private var completeDirs: Set<String> = []
    private var staleDirs: Set<String> = []
    private var invalidatedDirs: Set<String> = []
    private var invalidatedAncestors: Set<String> = []
    private var memo: [MemoKey: FolderStats] = [:]
    private var memoNaming: NamingProfile?
    private var skipped: [String: String] = [:]
    private var pendingPersist: [CachedFolderRecord] = []
    private var lastPersistFlushTime: ContinuousClock.Instant = .now
    private var hydratedRoots: Set<String> = []
    private var generation = 0
    private var releaseGeneration: UInt64 = 0
    private var stopRequested = false
    private var pendingReleaseAfterScan = false
    private var dirsListed = 0
    private var runningRoot: String?
    private var lastEmitTime: ContinuousClock.Instant = .now

    public init(
        connectionId: ConnectionId,
        backend: any StorageBackend,
        historyStore: any HistoryStore,
        cacheStore: SQLiteFolderStatsStore?,
        parser: RuleBasedParser = RuleBasedParser(),
        cacheTTL: TimeInterval = 24 * 60 * 60
    ) {
        self.connectionId = connectionId
        self.backend = backend
        self.historyStore = historyStore
        self.cacheStore = cacheStore
        self.parser = parser
        self.cacheTTL = cacheTTL
    }

    /// Evicts cached directory trees and completion metadata when leaving the map to keep idle RAM minimal.
    /// If a scan is currently unwinding, schedules eviction immediately after it finishes.
    public func releaseMemoryCache() {
        if runningRoot != nil {
            pendingReleaseAfterScan = true
            return
        }
        performMemoryRelease()
    }

    private func performMemoryRelease() {
        releaseGeneration &+= 1
        listings.removeAll(keepingCapacity: false)
        completeDirs.removeAll(keepingCapacity: false)
        organizedPaths.removeAll(keepingCapacity: false)
        checkedOrganized.removeAll(keepingCapacity: false)
        skipped.removeAll(keepingCapacity: false)
        staleDirs.removeAll(keepingCapacity: false)
        invalidatedDirs.removeAll(keepingCapacity: false)
        invalidatedAncestors.removeAll(keepingCapacity: false)
        memo.removeAll(keepingCapacity: false)
        memoNaming = nil
        pendingPersist.removeAll(keepingCapacity: false)
        hydratedRoots.removeAll()
    }

    /// Targeted invalidation for mutated directories (e.g. after organize, undo, or empty-dir cleanup):
    /// drops `listings` and `completeDirs` for each normalized dir, marks all ancestor directories up
    /// to `"/"` incomplete, and invalidates affected `memo` and organized-status entries.
    public func invalidate(dirs: [String]) {
        guard !dirs.isEmpty else { return }
        var targetSet: Set<String> = []
        targetSet.reserveCapacity(dirs.count)
        for raw in dirs {
            targetSet.insert(normalizeDir(raw))
        }

        for norm in targetSet {
            invalidatedDirs.insert(norm)
            listings.removeValue(forKey: norm)
            staleDirs.remove(norm)
            completeDirs.remove(norm)
            var cur = norm
            while true {
                memo.removeValue(forKey: MemoKey(dir: cur, inheritedOrg: false))
                memo.removeValue(forKey: MemoKey(dir: cur, inheritedOrg: true))
                if cur != norm {
                    invalidatedAncestors.insert(cur)
                    completeDirs.remove(cur)
                }
                if cur == "/" { break }
                let parent = normalizeDir(dirOf(cur))
                if parent == cur { break }
                cur = parent
            }
        }

        if !pendingPersist.isEmpty {
            pendingPersist.removeAll { targetSet.contains($0.dirPath) }
        }
        if !organizedPaths.isEmpty {
            organizedPaths = organizedPaths.filter { path in
                !targetSet.contains(path) && !targetSet.contains(normalizeDir(dirOf(path)))
            }
        }
        if !checkedOrganized.isEmpty {
            checkedOrganized = checkedOrganized.filter { path in
                !targetSet.contains(path) && !targetSet.contains(normalizeDir(dirOf(path)))
            }
        }
    }

    public func cancel() {
        stopRequested = true
    }

    public func hydrateIfNeeded(for dir: String = "/") async {
        let root = normalizeDir(dir)
        guard !hydratedRoots.contains(where: { isWithinDir(root, root: $0) }), let cacheStore else { return }
        let startReleaseGen = releaseGeneration
        guard let rows = try? await cacheStore.loadBelow(connection: connectionId, root: root),
              let ancestors = try? await cacheStore.completeAncestors(connection: connectionId, root: root),
              releaseGeneration == startReleaseGen else { return }

        let now = Date()
        var toCheck: [String] = []
        var path = root
        while true {
            if !checkedOrganized.contains(path) { toCheck.append(path) }
            if path == "/" { break }
            path = dirOf(path)
        }
        var incompleteDirs: Set<String> = []
        for (dir, rec) in rows {
            let norm = normalizeDir(dir)
            if invalidatedDirs.contains(norm) { continue }
            if listings[norm] == nil {
                listings[norm] = rec.entries
            }
            let isStale = cacheTTL > 0 && now.timeIntervalSince(rec.scannedAt) > cacheTTL
            if isStale {
                staleDirs.insert(norm)
                incompleteDirs.insert(norm)
            } else if rec.complete && !invalidatedAncestors.contains(norm) {
                completeDirs.insert(norm)
            }
            for e in rec.entries {
                if e.isDir && rows[normalizeDir(e.path)] == nil && listings[normalizeDir(e.path)] == nil {
                    incompleteDirs.insert(norm)
                }
                if (e.isDir || parser.classify(e.name) == .video) && !checkedOrganized.contains(e.path) {
                    toCheck.append(e.path)
                }
            }
        }
        // A root completion marker can be newer than reused child listings.
        // Remove all affected ancestors after every row has been considered.
        var incompleteAncestors: Set<String> = []
        for dir in incompleteDirs {
            var ancestor = dir
            while incompleteAncestors.insert(ancestor).inserted && ancestor != "/" {
                ancestor = dirOf(ancestor)
            }
        }
        completeDirs.subtract(incompleteAncestors)
        await checkOrganizedBatches(toCheck)
        guard releaseGeneration == startReleaseGen else { return }
        if rows[root] != nil, !invalidatedDirs.contains(root), !invalidatedAncestors.contains(root),
           !incompleteAncestors.contains(root),
           !staleDirs.contains(where: { isWithinDir($0, root: root) }),
           ancestors.contains(where: { dir, scannedAt in
               !invalidatedAncestors.contains(dir) && !invalidatedDirs.contains(dir)
                   && (cacheTTL <= 0 || now.timeIntervalSince(scannedAt) <= cacheTTL)
           }) {
            completeDirs.insert(root)
        }
        hydratedRoots = hydratedRoots.filter { !isWithinDir($0, root: root) }
        hydratedRoots.insert(root)
        memo.removeAll()
    }

    public func snapshot(for dir: String, naming: NamingProfile) async -> SizeScanSnapshot {
        await hydrateIfNeeded(for: dir)
        let norm = normalizeDir(dir)
        return buildSnapshot(for: norm, naming: naming, errorMessage: nil)
    }

    public func childrenEntries(of dir: String) -> [RemoteEntry] {
        listings[normalizeDir(dir)] ?? []
    }

    public func scan(
        root: String,
        fresh: Bool = false,
        naming: NamingProfile,
        onUpdate: @escaping @Sendable (SizeScanSnapshot) async -> Void
    ) async {
        let normRoot = normalizeDir(root)
        generation += 1
        let myGen = generation
        stopRequested = false
        pendingReleaseAfterScan = false
        skipped.removeAll()
        dirsListed = 0

        if fresh {
            dropBelow(normRoot)
            if let cacheStore {
                try? await cacheStore.deleteBelow(connection: connectionId, root: normRoot)
            }
        } else {
            await hydrateIfNeeded(for: normRoot)
            if isComplete(normRoot) {
                await onUpdate(buildSnapshot(for: normRoot, naming: naming, errorMessage: nil))
                return
            }
        }

        runningRoot = normRoot
        let startInstant = ContinuousClock.now
        lastEmitTime = startInstant
        lastPersistFlushTime = startInstant
        await onUpdate(buildSnapshot(for: normRoot, naming: naming, errorMessage: nil))

        var errorMsg: String?

        do {
            try await walkDirs(
                roots: [normRoot],
                parallel: 4,
                stop: { [weak self] in
                    self == nil || Task.isCancelled
                }
            ) { [self] curDir in
                let normDir = normalizeDir(curDir)
                let action = await self.prepareWalkDir(normDir, gen: myGen, fresh: fresh)
                let refreshRemote: Bool
                switch action {
                case .stop:
                    return []
                case .cached(let subdirs):
                    return subdirs
                case .fetch(let refresh):
                    refreshRemote = refresh
                }

                let fetched: [RemoteEntry]
                do {
                    fetched = try await backend.list(normDir, refresh: refreshRemote)
                } catch let e as StorageError {
                    if normDir == normRoot || e.code == .unauthorized || e.code == .network || e.code == .rateLimited {
                        throw e
                    }
                    await self.recordSkipped(dir: normDir, message: e.message)
                    return []
                }

                let subdirs = await self.ingestFetched(
                    dir: normDir,
                    entries: fetched,
                    naming: naming,
                    root: normRoot,
                    onUpdate: onUpdate
                )
                return subdirs
            }

            await flushPendingPersist(force: true)

            if skipped.isEmpty && !stopRequested && !Task.isCancelled && myGen == generation {
                completeDirs.insert(normRoot)
                invalidatedAncestors.remove(normRoot)
                if let cacheStore {
                    try? await cacheStore.markComplete(connection: connectionId, dirPath: normRoot, scannedAt: Date())
                }
            }
        } catch {
            await flushPendingPersist(force: true)
            errorMsg = error.localizedDescription
        }

        if myGen == generation {
            runningRoot = nil
        }
        await onUpdate(buildSnapshot(for: normRoot, naming: naming, errorMessage: errorMsg))

        if runningRoot == nil && pendingReleaseAfterScan {
            pendingReleaseAfterScan = false
            performMemoryRelease()
        }
    }

    private func prepareWalkDir(_ dir: String, gen: Int, fresh: Bool) -> WalkDirAction {
        if stopRequested || gen != generation || Task.isCancelled {
            return .stop
        }
        if !fresh && !staleDirs.contains(dir), let cached = listings[dir] {
            dirsListed += 1
            return .cached(cached.filter(\.isDir).map(\.path))
        }
        return .fetch(refresh: fresh || staleDirs.contains(dir) || invalidatedDirs.contains(dir))
    }

    private func recordSkipped(dir: String, message: String) {
        skipped[dir] = message
        staleDirs.insert(normalizeDir(dirOf(dir)))
    }

    private func ingestFetched(
        dir: String,
        entries: [RemoteEntry],
        naming: NamingProfile,
        root: String,
        onUpdate: @escaping @Sendable (SizeScanSnapshot) async -> Void
    ) async -> [String] {
        listings[dir] = entries
        staleDirs.remove(dir)
        invalidatedDirs.remove(dir)
        dirsListed += 1
        invalidateMemoAncestors(of: dir)

        let candidates = entries
            .filter { ($0.isDir || parser.classify($0.name) == .video) && !checkedOrganized.contains($0.path) }
            .map(\.path)
        if !candidates.isEmpty {
            await checkOrganizedBatches(candidates)
            invalidateMemoAncestors(of: dir)
        }

        if cacheStore != nil {
            pendingPersist.append(CachedFolderRecord(
                dirPath: dir,
                entries: entries,
                complete: false,
                scannedAt: Date()
            ))
            await flushPendingPersist(force: false)
        }

        let now = ContinuousClock.now
        if now - lastEmitTime >= Self.snapshotEmitInterval {
            lastEmitTime = now
            let snap = buildSnapshot(for: root, naming: naming, errorMessage: nil)
            await onUpdate(snap)
        }
        return entries.filter(\.isDir).map(\.path)
    }

    private func flushPendingPersist(force: Bool) async {
        guard let cacheStore, !pendingPersist.isEmpty else { return }
        let now = ContinuousClock.now
        if !force && pendingPersist.count < Self.dbFlushBatchSize && (now - lastPersistFlushTime) < Self.dbFlushInterval {
            return
        }
        let batch = pendingPersist
        pendingPersist.removeAll(keepingCapacity: !force)
        lastPersistFlushTime = now
        try? await cacheStore.saveBatch(connection: connectionId, records: batch)
    }

    private func checkOrganizedBatches(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        checkedOrganized.formUnion(paths)
        if let found = try? await historyStore.areOrganized(connection: connectionId, paths: paths), !found.isEmpty {
            organizedPaths.formUnion(found)
        }
    }

    private func isComplete(_ dir: String) -> Bool {
        completeDirs.contains { r in r == dir || r == "/" || dir.hasPrefix(r + "/") }
    }

    private func dropBelow(_ root: String) {
        func below(_ p: String) -> Bool { p == root || root == "/" || p.hasPrefix(root + "/") }
        listings = listings.filter { !below($0.key) }
        staleDirs = staleDirs.filter { !below($0) }
        organizedPaths = organizedPaths.filter { !below($0) }
        checkedOrganized = checkedOrganized.filter { !below($0) }
        completeDirs = completeDirs.filter { r in !below(r) && r != "/" && !root.hasPrefix(r + "/") }
        pendingPersist.removeAll { below($0.dirPath) }
        memo.removeAll()
    }

    private func invalidateMemoAncestors(of dir: String) {
        var cur = normalizeDir(dir)
        while true {
            memo.removeValue(forKey: MemoKey(dir: cur, inheritedOrg: false))
            memo.removeValue(forKey: MemoKey(dir: cur, inheritedOrg: true))
            if cur == "/" { break }
            let parent = normalizeDir(dirOf(cur))
            if parent == cur { break }
            cur = parent
        }
    }

    private func buildSnapshot(for dir: String, naming: NamingProfile, errorMessage: String?) -> SizeScanSnapshot {
        if memoNaming != naming {
            memo.removeAll(keepingCapacity: true)
            memoNaming = naming
        }
        let rootInherited = inheritedOrganized(dir)
        var visiting: Set<String> = []
        let rootStats = computeDirStats(dir, inheritedOrg: rootInherited, naming: naming, visiting: &visiting)
        let entries = listings[dir] ?? []
        var children: [MapChildNode] = []
        children.reserveCapacity(entries.count)
        for e in entries {
            let inh = rootInherited || organizedPaths.contains(e.path)
            let st = e.isDir
                ? computeDirStats(e.path, inheritedOrg: inh, naming: naming, visiting: &visiting)
                : computeFileStats(e, inheritedOrg: inh, naming: naming)
            children.append(MapChildNode(entry: e, stats: st))
        }
        children.sort { $0.stats.total > $1.stats.total }

        return SizeScanSnapshot(
            rootDir: dir,
            rootStats: rootStats,
            children: children,
            isRunning: runningRoot != nil,
            isComplete: isComplete(dir),
            dirsListed: dirsListed,
            skipped: skipped,
            errorMessage: errorMessage
        )
    }

    private func inheritedOrganized(_ path: String) -> Bool {
        var cur = path
        while true {
            if organizedPaths.contains(cur) { return true }
            let parent = dirOf(cur)
            if parent == cur || cur == "/" { return false }
            cur = parent
        }
    }

    private func computeFileStats(_ e: RemoteEntry, inheritedOrg: Bool, naming: NamingProfile) -> FolderStats {
        guard parser.classify(e.name) == .video else {
            return FolderStats(other: e.size, files: 1)
        }
        let isOrg = inheritedOrg || organizedPaths.contains(e.path) || looksOrganized(e, naming: naming)
        return isOrg
            ? FolderStats(organized: e.size, files: 1)
            : FolderStats(unorganized: e.size, files: 1)
    }

    private func computeDirStats(
        _ dir: String,
        inheritedOrg: Bool,
        naming: NamingProfile,
        visiting: inout Set<String>
    ) -> FolderStats {
        let key = MemoKey(dir: dir, inheritedOrg: inheritedOrg)
        if let hit = memo[key] { return hit }
        guard visiting.insert(dir).inserted else { return .zero }
        defer { visiting.remove(dir) }

        var sum = FolderStats.zero
        for e in listings[dir] ?? [] {
            let org = inheritedOrg || organizedPaths.contains(e.path)
            sum = sum + (e.isDir
                ? computeDirStats(e.path, inheritedOrg: org, naming: naming, visiting: &visiting)
                : computeFileStats(e, inheritedOrg: org, naming: naming))
        }
        memo[key] = sum
        return sum
    }
}
