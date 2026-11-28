import Foundation
import TidyreelModels
import TidyreelParser
import TidyreelPersistence
import TidyreelProbe

public func computeMediaQualityRank(
    probe: MediaProbeInfo?,
    parsedResolution: String?,
    parsedExtraInfo: String?,
    fileSize: Int64,
    isDiscDir: Bool = false
) -> Int {
    let extra = (parsedExtraInfo ?? "").lowercased()
    let resText = (probe?.resolution ?? parsedResolution ?? extra).lowercased()
    let baseRes: Int
    if resText.contains("4320") || resText.contains("8k") {
        baseRes = 70
    } else if resText.contains("2160") || resText.contains("4k") || resText.contains("uhd") {
        baseRes = 60
    } else if resText.contains("1440") || resText.contains("2k") {
        baseRes = 45
    } else if resText.contains("1080") || resText.contains("fhd") {
        baseRes = 40
    } else if resText.contains("720") {
        baseRes = 30
    } else if resText.contains("576") {
        baseRes = 20
    } else if resText.contains("480") {
        baseRes = 15
    } else {
        baseRes = 10
    }
    let resScore = isDiscDir ? max(baseRes, 65) : baseRes

    let hdrText = (probe?.hdr ?? extra).lowercased()
    let hdrScore: Int
    if hdrText.range(of: #"(?:^|[^a-z0-9])(?:dv|dovi|dolby[\s._-]?vision)(?:$|[^a-z0-9])"#, options: .regularExpression) != nil {
        hdrScore = 40
    } else if hdrText.contains("hdr10+") || hdrText.contains("hdr10plus") {
        hdrScore = 30
    } else if hdrText.contains("hdr10") || hdrText.range(of: #"(?:^|[^a-z0-9])hdr(?:$|[^a-z0-9])"#, options: .regularExpression) != nil {
        hdrScore = 20
    } else if hdrText.range(of: #"(?:^|[^a-z0-9])hlg(?:$|[^a-z0-9])"#, options: .regularExpression) != nil {
        hdrScore = 10
    } else {
        hdrScore = 0
    }

    let audioText = (probe?.audioCodec ?? extra).lowercased()
    let audioScore: Int
    if audioText.contains("atmos") || audioText.contains("dts-x") || audioText.contains("dtsx") {
        audioScore = 5
    } else if audioText.contains("truehd") || audioText.contains("dts-hd") || audioText.contains("dtshd") {
        audioScore = 4
    } else if audioText.contains("flac") || audioText.contains("lpcm") {
        audioScore = 3
    } else if audioText.contains("eac3") || audioText.contains("ddp") || audioText.range(of: #"(?:^|[^a-z0-9])dts(?:$|[^a-z0-9])"#, options: .regularExpression) != nil {
        audioScore = 2
    } else if audioText.contains("ac3") || audioText.contains("aac") || audioText.contains("opus") {
        audioScore = 1
    } else {
        audioScore = 0
    }

    let sizeScore = fileSize <= 0 ? 0 : min(999, Int(fileSize / (100 * 1024 * 1024)))
    return resScore * 1_000_000 + hdrScore * 10_000 + audioScore * 1_000 + sizeScore
}

public struct HealthScanCancelledError: Error, Sendable {
    public init() {}
}

/// Pure background `actor` replacement for Flutter's `HealthScanner`.
/// Runs directory walking, local work grouping, duplicate MediaProbe range reads,
/// missing NFO/poster detection, and junk/empty-dir verification completely off `@MainActor`.
public actor HealthScannerActor {
    private static let maxSampleJunkBytes: Int64 = 150 * 1024 * 1024
    private static let cacheMaxAge: TimeInterval = 6 * 60 * 60
    private static let dbFlushBatchSize = 32
    private static let dbFlushInterval: Duration = .milliseconds(500)
    private static let walkingProgressInterval: Duration = .milliseconds(120)
    private static let structuralDirRegex = try! NSRegularExpression(
        pattern: #"^(season|series)[\s._\-]*\d+.*$|^s\d{1,2}$|^第\s*[0-9一二三四五六七八九十百]+\s*[季部].*$|^(specials?|sp|ova|oad|extras?|featurettes?|behind the scenes|bonus|特别篇|特典|花絮|番外|subs?|subtitles?|字幕)$|^(\d{3,4}[pi]|[248]k|uhd|fhd|hdr(10)?\+?|dv|dolby[\s._-]?vision|杜比视界|blu-?ray|web-?dl|remux|高清|超清|蓝光|原盘|国语|粤语|国配|中字|普通话)$"#,
        options: [.caseInsensitive]
    )
    private static let sampleRegex = try! NSRegularExpression(
        pattern: #"^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]"#,
        options: [.caseInsensitive]
    )
    private static let adKwRegex = try! NSRegularExpression(
        pattern: #"更多资源|更多精彩|更多电影|最新地址|最新网址|获取更多|公众号|扫码|发布页|永久地址|永久网址|免费下载|点击进入|关注微信|广告"#
    )
    private static let explicitUrlRegex = try! NSRegularExpression(
        pattern: #"https?://\S+|www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#,
        options: [.caseInsensitive]
    )
    private static let posterNames: Set<String> = [
        "poster.jpg", "poster.jpeg", "poster.png", "poster.webp",
        "folder.jpg", "folder.jpeg", "folder.png", "folder.webp",
    ]
    private static let unambiguousJunkExt: Set<String> = ["url", "lnk", "website", "webloc", "torrent!"]

    private let backend: any StorageBackend
    private let connectionId: ConnectionId
    private let folderStatsStore: SQLiteFolderStatsStore?
    private let parser: RuleBasedParser
    private let mediaProbe: any MediaProbe
    private let probeMedia: Bool
    private var cancelledFlag = false

    public init(
        backend: any StorageBackend,
        connectionId: ConnectionId,
        folderStatsStore: SQLiteFolderStatsStore? = nil,
        parser: RuleBasedParser = RuleBasedParser(),
        mediaProbe: any MediaProbe = ContainerMediaProbe(),
        probeMedia: Bool = true
    ) {
        self.backend = backend
        self.connectionId = connectionId
        self.folderStatsStore = folderStatsStore
        self.parser = parser
        self.mediaProbe = mediaProbe
        self.probeMedia = probeMedia
    }

    public func cancel() {
        cancelledFlag = true
    }

    public func scan(
        rootDir: String,
        fresh: Bool = false,
        onProgress: (@Sendable (HealthScanProgress) async -> Void)? = nil
    ) async throws -> HealthReport {
        cancelledFlag = false
        let normRoot = normalizeDir(rootDir)

        await onProgress?(HealthScanProgress(phase: .walking, message: "正在加载目录列表…", fraction: 0.08))
        var lastProgressEmit = ContinuousClock.now

        var cachedByDir: [String: [RemoteEntry]] = [:]
        if fresh, let folderStatsStore {
            try? await folderStatsStore.deleteBelow(connection: connectionId, root: normRoot)
        } else if !fresh, let folderStatsStore,
                  let rows = try? await folderStatsStore.loadBelow(connection: connectionId, root: normRoot) {
            let now = Date()
            for (k, v) in rows where now.timeIntervalSince(v.scannedAt) <= Self.cacheMaxAge {
                cachedByDir[normalizeDir(k)] = v.entries
            }
        }

        var listings: [String: [RemoteEntry]] = [:]
        var skippedDirs: [String: String] = [:]
        var discDirs: Set<String> = []
        var allFiles: [RemoteEntry] = []
        var allDirs: Set<String> = [normRoot]
        var dirsVisited = 0
        var pendingPersist: [CachedFolderRecord] = []
        var lastPersistFlush = ContinuousClock.now

        do {
            try await withThrowingTaskGroup(of: (String, [RemoteEntry]?, String?).self) { group in
                var queue = [normRoot]
                var head = 0
                var active = 0
                while head < queue.count || active > 0 {
                    if cancelledFlag || Task.isCancelled { throw HealthScanCancelledError() }
                    while active < 4 && head < queue.count {
                        let dir = queue[head]
                        head += 1
                        active += 1
                        let preCached = cachedByDir[dir]
                        group.addTask { [backend] in
                            if let preCached { return (dir, preCached, nil) }
                            do {
                                return (dir, try await backend.list(dir, refresh: fresh), nil)
                            } catch let e as StorageError {
                                if dir == normRoot || e.code == .unauthorized || e.code == .network || e.code == .rateLimited {
                                    throw e
                                }
                                return (dir, nil, e.message)
                            }
                        }
                    }
                    if head == queue.count {
                        queue.removeAll(keepingCapacity: true)
                        head = 0
                    } else if head >= 1024 && head >= queue.count / 2 {
                        queue.removeFirst(head)
                        head = 0
                    }
                    guard let (dir, entriesOpt, skipMsg) = try await group.next() else { break }
                    active -= 1
                    if let skipMsg {
                        skippedDirs[dir] = skipMsg
                        continue
                    }
                    guard let entries = entriesOpt else { continue }
                    if cachedByDir[dir] == nil && folderStatsStore != nil {
                        pendingPersist.append(CachedFolderRecord(
                            dirPath: dir,
                            entries: entries,
                            complete: false,
                            scannedAt: Date()
                        ))
                    }
                    listings[dir] = entries
                    dirsVisited += 1

                    let hasDiscChild = entries.contains { e in
                        e.isDir && (e.name.uppercased() == "BDMV" || e.name.uppercased() == "VIDEO_TS")
                    }
                    if hasDiscChild && dir != "/" {
                        discDirs.insert(dir)
                        allFiles.append(contentsOf: entries.filter { !$0.isDir })
                    } else {
                        for e in entries {
                            if e.isDir {
                                let up = e.name.uppercased()
                                if up == "BDMV" || up == "VIDEO_TS" { continue }
                                let child = normalizeDir(e.path)
                                if allDirs.insert(child).inserted {
                                    queue.append(child)
                                }
                            } else {
                                allFiles.append(e)
                            }
                        }
                    }

                    let batchToSave = drainPendingPersist(&pendingPersist, lastFlush: &lastPersistFlush, force: false)
                    if !batchToSave.isEmpty, let folderStatsStore {
                        try? await folderStatsStore.saveBatch(connection: connectionId, records: batchToSave)
                    }

                    let now = ContinuousClock.now
                    if now - lastProgressEmit >= Self.walkingProgressInterval {
                        lastProgressEmit = now
                        await onProgress?(HealthScanProgress(
                            phase: .walking,
                            message: "已扫描 \(dirsVisited) 个目录 · \(allFiles.count) 个文件",
                            dirsVisited: dirsVisited,
                            filesFound: allFiles.count,
                            fraction: 0.40
                        ))
                    }
                }
            }
        } catch {
            let remaining = drainPendingPersist(&pendingPersist, lastFlush: &lastPersistFlush, force: true)
            if !remaining.isEmpty, let folderStatsStore {
                try? await folderStatsStore.saveBatch(connection: connectionId, records: remaining)
            }
            throw error
        }

        let finalPersist = drainPendingPersist(&pendingPersist, lastFlush: &lastPersistFlush, force: true)
        if !finalPersist.isEmpty, let folderStatsStore {
            try? await folderStatsStore.saveBatch(connection: connectionId, records: finalPersist)
        }

        // Staged memory release: walk cache and traversal queues are no longer needed.
        cachedByDir.removeAll(keepingCapacity: false)

        if cancelledFlag || Task.isCancelled { throw HealthScanCancelledError() }

        let scannedFileCount = allFiles.count

        // Classify locally
        var filesByDir: [String: [RemoteEntry]] = [:]
        var junkFiles: [(RemoteEntry, String)] = []
        var videos: [ScannedVideo] = []

        for e in allFiles {
            let dir = normalizeDir(dirOf(e.path))
            filesByDir[dir, default: []].append(e)
            switch parser.classify(e.name) {
            case .video:
                let chain = Self.ancestorChain(dir: dir, root: normRoot)
                let parsed = parser.parse(e.name, parentDirs: chain.map(baseOf))
                videos.append(ScannedVideo(
                    path: e.path,
                    name: e.name,
                    dir: dir,
                    size: e.size,
                    modifiedAt: e.modified,
                    parsed: parsed,
                    chain: chain,
                    isDiscDir: false
                ))
            case .junk:
                if let reason = Self.healthJunkReason(e) {
                    junkFiles.append((e, reason))
                } else if videoExtensions.contains(extOf(e.name).lowercased()) {
                    let chain = Self.ancestorChain(dir: dir, root: normRoot)
                    let parsed = parser.parse(e.name, parentDirs: chain.map(baseOf))
                    videos.append(ScannedVideo(
                        path: e.path,
                        name: e.name,
                        dir: dir,
                        size: e.size,
                        modifiedAt: e.modified,
                        parsed: parsed,
                        chain: chain,
                        isDiscDir: false
                    ))
                }
            case .subtitle, .sidecar, .other:
                break
            }
        }

        // Staged memory release: raw flat file list has been partitioned into filesByDir/videos/junkFiles.
        allFiles.removeAll(keepingCapacity: false)

        for discDir in discDirs.sorted() {
            let parentDir = normalizeDir(dirOf(discDir))
            let parentChain = Self.ancestorChain(dir: parentDir, root: normRoot)
            var parsed = parser.parse(baseOf(discDir), parentDirs: parentChain.map(baseOf))
            parsed.isDisc = true
            parsed.kind = .movie
            let sz = (filesByDir[discDir] ?? []).reduce(Int64(0)) { $0 + $1.size }
            videos.append(ScannedVideo(
                path: discDir,
                name: baseOf(discDir),
                dir: discDir,
                size: sz,
                modifiedAt: nil,
                parsed: parsed,
                chain: [discDir] + parentChain,
                isDiscDir: true
            ))
        }

        let works = groupWorks(videos: videos, normRoot: normRoot)

        await onProgress?(HealthScanProgress(
            phase: .probingDuplicates,
            message: "正在比对重复片源…",
            dirsVisited: dirsVisited,
            filesFound: scannedFileCount,
            fraction: 0.62
        ))
        let duplicates = await auditDuplicates(works: works)
        if cancelledFlag || Task.isCancelled { throw HealthScanCancelledError() }

        await onProgress?(HealthScanProgress(
            phase: .checkingAssets,
            message: "正在检查 NFO 与海报…",
            dirsVisited: dirsVisited,
            filesFound: scannedFileCount,
            fraction: 0.80
        ))
        let missingAssets = auditMissingAssets(works: works, filesByDir: filesByDir)
        filesByDir.removeAll(keepingCapacity: false)

        await onProgress?(HealthScanProgress(
            phase: .checkingCleanup,
            message: "正在扫描垃圾文件与空目录…",
            dirsVisited: dirsVisited,
            filesFound: scannedFileCount,
            fraction: 0.92
        ))
        let likelyEmpty = collectLikelyEmptyDirs(
            normRoot: normRoot,
            listings: listings,
            allDirs: allDirs,
            discDirs: discDirs
        )
        // Staged memory release: raw directory listings are no longer needed once empty candidates are computed.
        listings.removeAll(keepingCapacity: false)

        let cleanupItems = await auditCleanup(
            normRoot: normRoot,
            junkFiles: junkFiles,
            likelyEmpty: likelyEmpty
        )

        await onProgress?(HealthScanProgress(
            phase: .done,
            message: "体检完成",
            dirsVisited: dirsVisited,
            filesFound: scannedFileCount,
            fraction: 1.0
        ))

        return HealthReport(
            connection: connectionId,
            rootDir: normRoot,
            scannedAt: Date(),
            scannedDirs: dirsVisited,
            scannedFiles: scannedFileCount,
            totalWorks: works.count,
            duplicates: duplicates,
            missingAssets: missingAssets,
            cleanupItems: cleanupItems,
            skippedDirs: skippedDirs
        )
    }

    private func drainPendingPersist(
        _ pending: inout [CachedFolderRecord],
        lastFlush: inout ContinuousClock.Instant,
        force: Bool
    ) -> [CachedFolderRecord] {
        guard folderStatsStore != nil, !pending.isEmpty else { return [] }
        let now = ContinuousClock.now
        if !force && pending.count < Self.dbFlushBatchSize && (now - lastFlush) < Self.dbFlushInterval {
            return []
        }
        let batch = pending
        pending.removeAll(keepingCapacity: !force)
        lastFlush = now
        return batch
    }

    // MARK: - Internal Models & Audits

    private struct ScannedVideo: Sendable {
        var path: String
        var name: String
        var dir: String
        var size: Int64
        var modifiedAt: Date?
        var parsed: ParsedName
        var chain: [String]
        var isDiscDir: Bool
    }

    private struct WorkUnit: Sendable {
        var rootDir: String
        var videos: [ScannedVideo]
        var anchorTitle: String
        var anchorYear: Int?
        var kind: MediaKind
        var ownsDir: Bool
        var tmdbId: Int?
    }

    private func groupWorks(videos: [ScannedVideo], normRoot: String) -> [WorkUnit] {
        var buckets: [String: [ScannedVideo]] = [:]
        var works: [WorkUnit] = []

        for v in videos {
            if v.isDiscDir {
                works.append(WorkUnit(
                    rootDir: v.path,
                    videos: [v],
                    anchorTitle: v.parsed.title ?? v.name,
                    anchorYear: v.parsed.year,
                    kind: .movie,
                    ownsDir: true,
                    tmdbId: Self.extractTmdbId([v])
                ))
                continue
            }
            let titleDir = v.chain.first { d in
                guard d != "/" else { return false }
                let b = baseOf(d)
                let r = NSRange(b.startIndex..<b.endIndex, in: b)
                return Self.structuralDirRegex.firstMatch(in: b, range: r) == nil
            }
            buckets[titleDir ?? v.dir, default: []].append(v)
        }

        for (dir, vs) in buckets {
            let dirBase = baseOf(dir)
            let isGenericOrRoot = dir == normRoot || dir == "/" || isGenericContainerDir(dirBase)
            let folderParsed = isGenericOrRoot ? nil : parser.parse(dirBase)
            let folderTitle = folderParsed?.title?.trimmingCharacters(in: .whitespacesAndNewlines)

            var byTitle: [String: [ScannedVideo]] = [:]
            for v in vs {
                let k = normTitle(v.parsed.title ?? "")
                byTitle[k, default: []].append(v)
            }
            let nonEmptyKeys = byTitle.keys.filter { !$0.isEmpty }.sorted {
                (byTitle[$0]?.count ?? 0) > (byTitle[$1]?.count ?? 0)
            }
            var shouldSplit = false
            if nonEmptyKeys.count >= 2 {
                let explained = (folderTitle != nil && !folderTitle!.isEmpty) &&
                    nonEmptyKeys.contains { titleSimilarity(folderTitle!, $0) >= 0.6 }
                let dominant = Double(byTitle[nonEmptyKeys[0]]?.count ?? 0) / Double(vs.count) > 0.6
                shouldSplit = isGenericOrRoot || !(explained || dominant)
            }
            if !shouldSplit {
                works.append(makeWork(
                    rootDir: dir,
                    videos: vs,
                    folderTitle: folderTitle,
                    folderYear: folderParsed?.year,
                    folderExternalId: folderParsed?.externalId,
                    ownsDir: !isGenericOrRoot
                ))
            } else {
                let untitled = byTitle[""] ?? []
                for (idx, k) in nonEmptyKeys.enumerated() {
                    let gvs = (byTitle[k] ?? []) + (idx == 0 ? untitled : [])
                    works.append(makeWork(
                        rootDir: dir,
                        videos: gvs,
                        folderTitle: nil,
                        folderYear: nil,
                        folderExternalId: nil,
                        ownsDir: false
                    ))
                }
            }
        }
        return works.sorted { $0.rootDir != $1.rootDir ? $0.rootDir < $1.rootDir : $0.anchorTitle < $1.anchorTitle }
    }

    private func makeWork(
        rootDir: String,
        videos: [ScannedVideo],
        folderTitle: String?,
        folderYear: Int?,
        folderExternalId: ExternalId?,
        ownsDir: Bool
    ) -> WorkUnit {
        let mainVideos = videos.filter { $0.parsed.kind != .extra }
        let tvVotes = mainVideos.filter { p in
            p.parsed.kind == .episode || p.parsed.kind == .special || p.parsed.season != nil || !p.parsed.episodes.isEmpty || p.parsed.absolute != nil
        }.count
        let kind: MediaKind = (!mainVideos.isEmpty && tvVotes * 2 > mainVideos.count) ? .episode : .movie

        let titles = videos.compactMap { $0.parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let fileTitle = Self.mostCommonString(titles)
        let years = videos.compactMap(\.parsed.year)
        let fileYear = Self.mostCommonInt(years)
        let resolvedTitle: String
        if let folderTitle, !folderTitle.isEmpty {
            resolvedTitle = folderTitle
        } else if let fileTitle {
            resolvedTitle = fileTitle
        } else if let first = videos.first {
            resolvedTitle = stem(first.name)
        } else {
            resolvedTitle = baseOf(rootDir)
        }
        let folderTmdb = (folderExternalId?.source == "tmdb") ? Int(folderExternalId!.id) : nil
        return WorkUnit(
            rootDir: rootDir,
            videos: videos,
            anchorTitle: resolvedTitle,
            anchorYear: fileYear ?? folderYear,
            kind: kind,
            ownsDir: ownsDir,
            tmdbId: folderTmdb ?? Self.extractTmdbId(videos)
        )
    }

    private func auditDuplicates(works: [WorkUnit]) async -> [DuplicateMediaIssue] {
        struct Bucket {
            var id: String
            var title: String
            var kind: MediaKind
            var tmdbId: Int?
            var season: Int?
            var episode: Int?
            var videos: [String: ScannedVideo] = [:]
        }
        var buckets: [String: Bucket] = [:]

        for w in works {
            if w.kind == .movie {
                let nonExtras = w.videos.filter { $0.parsed.kind != .extra }
                for v in nonExtras {
                    let partKey = v.parsed.part ?? 0
                    let key: String
                    if let ext = v.parsed.externalId {
                        key = ext.source == "tmdb" && Int(ext.id) != nil
                            ? "movie:tmdb:\(ext.id):p\(partKey)"
                            : "movie:ext:\(ext.source):\(ext.id.lowercased()):p\(partKey)"
                    } else {
                        let rawT = v.parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let t = (rawT != nil && !rawT!.isEmpty) ? rawT! : w.anchorTitle
                        let nt = normTitle(t)
                        if nt.isEmpty { continue }
                        let yr = v.parsed.year ?? ((rawT == nil || rawT!.isEmpty) ? w.anchorYear : nil)
                        key = "movie:title:\(nt):\(yr ?? 0):p\(partKey)"
                    }
                    let yr = v.parsed.year ?? w.anchorYear
                    let label = yr != nil ? "\(w.anchorTitle) (\(yr!))" : w.anchorTitle
                    var b = buckets[key] ?? Bucket(id: "dup-\(stableHash(key))", title: label, kind: .movie, tmdbId: w.tmdbId)
                    b.videos[v.path] = v
                    buckets[key] = b
                }
            } else {
                for v in w.videos where v.parsed.kind != .extra {
                    let eps = !v.parsed.episodes.isEmpty ? v.parsed.episodes : (v.parsed.absolute.map { [$0] } ?? [])
                    if eps.isEmpty { continue }
                    let season = v.parsed.kind == .special ? 0 : (v.parsed.season ?? 1)
                    let sortedEps = Array(Set(eps)).sorted()
                    let epKey = sortedEps.map(String.init).joined(separator: "-")
                    let nt = normTitle(w.anchorTitle)
                    if w.tmdbId == nil && nt.isEmpty { continue }
                    let showKey = w.tmdbId != nil ? "tmdb:\(w.tmdbId!)" : "title:\(nt):\(w.anchorYear ?? 0)"
                    let key = "tv:\(showKey):s\(season):e\(epKey):p\(v.parsed.part ?? 0)"
                    let code = sortedEps.count == 1
                        ? String(format: "S%02dE%02d", season, sortedEps[0])
                        : String(format: "S%02dE%02d-E%02d", season, sortedEps.first!, sortedEps.last!)
                    var b = buckets[key] ?? Bucket(
                        id: "dup-\(stableHash(key))",
                        title: "\(w.anchorTitle) \(code)",
                        kind: .episode,
                        tmdbId: w.tmdbId,
                        season: season,
                        episode: sortedEps[0]
                    )
                    b.videos[v.path] = v
                    buckets[key] = b
                }
            }
        }

        let candidates = buckets.values.filter { $0.videos.count >= 2 }
        if candidates.isEmpty { return [] }

        var probeResults: [String: MediaProbeInfo] = [:]
        if probeMedia {
            var toProbe: [String: ScannedVideo] = [:]
            for b in candidates {
                for v in b.videos.values where !v.isDiscDir {
                    toProbe[v.path] = v
                }
            }
            let probeList = Array(toProbe.values)
            let probeTool = self.mediaProbe
            let be = self.backend
            let connId = self.connectionId
            await withTaskGroup(of: (String, MediaProbeInfo?).self) { group in
                var idx = 0
                let limit = min(4, probeList.count)
                for _ in 0..<limit {
                    let v = probeList[idx]
                    idx += 1
                    group.addTask {
                        (
                            v.path,
                            await probeTool.probe(
                                backend: be,
                                connection: connId,
                                path: v.path,
                                fileSize: v.size,
                                modifiedAt: v.modifiedAt
                            )
                        )
                    }
                }
                for await (p, info) in group {
                    if let info { probeResults[p] = info }
                    if idx < probeList.count && !Task.isCancelled {
                        let v = probeList[idx]
                        idx += 1
                        group.addTask {
                            (
                                v.path,
                                await probeTool.probe(
                                    backend: be,
                                    connection: connId,
                                    path: v.path,
                                    fileSize: v.size,
                                    modifiedAt: v.modifiedAt
                                )
                            )
                        }
                    }
                }
            }
        }

        var issues: [DuplicateMediaIssue] = []
        for b in candidates {
            let copies = b.videos.values.map { v in
                let pr = probeResults[v.path]
                return DuplicateMediaCopy(
                    path: v.path,
                    name: v.name,
                    fileSize: v.size,
                    probe: pr,
                    parsedResolution: v.parsed.resolution,
                    parsedExtraInfo: v.parsed.extraInfo,
                    isDiscDir: v.isDiscDir,
                    qualityRank: computeMediaQualityRank(
                        probe: pr,
                        parsedResolution: v.parsed.resolution,
                        parsedExtraInfo: v.parsed.extraInfo,
                        fileSize: v.size,
                        isDiscDir: v.isDiscDir
                    )
                )
            }.sorted {
                if $0.qualityRank != $1.qualityRank { return $0.qualityRank > $1.qualityRank }
                if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
                return $0.path < $1.path
            }
            if let best = copies.first {
                issues.append(DuplicateMediaIssue(
                    id: b.id,
                    title: b.title,
                    kind: b.kind,
                    tmdbId: b.tmdbId,
                    season: b.season,
                    episode: b.episode,
                    copies: copies,
                    recommendedKeepPath: best.path
                ))
            }
        }
        return issues.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private func auditMissingAssets(works: [WorkUnit], filesByDir: [String: [RemoteEntry]]) -> [MissingAssetIssue] {
        var lowerNamesByDir: [String: Set<String>] = [:]
        lowerNamesByDir.reserveCapacity(filesByDir.count)
        for (dir, entries) in filesByDir {
            var names = Set<String>()
            names.reserveCapacity(entries.count)
            for entry in entries {
                names.insert(entry.name.lowercased())
            }
            lowerNamesByDir[dir] = names
        }

        var issues: [MissingAssetIssue] = []
        for w in works {
            let workDirs = Set([w.rootDir] + w.videos.map(\.dir))
            let rootNames = lowerNamesByDir[w.rootDir] ?? []
            let hasPosterInAnyDir = !rootNames.isDisjoint(with: Self.posterNames)
                || workDirs.contains { dir in
                    guard let names = lowerNamesByDir[dir] else { return false }
                    return !names.isDisjoint(with: Self.posterNames)
                }

            let hasNfo: Bool
            if w.kind == .episode {
                hasNfo = rootNames.contains("tvshow.nfo")
            } else {
                hasNfo = rootNames.contains("movie.nfo") || w.videos.contains { v in
                    if v.isDiscDir { return rootNames.contains("movie.nfo") }
                    let nfo = "\(stem(v.name).lowercased()).nfo"
                    let dn = lowerNamesByDir[v.dir] ?? []
                    return dn.contains(nfo) || dn.contains("movie.nfo")
                }
            }

            let hasPoster = hasPosterInAnyDir
                || w.videos.contains { v in
                    if v.isDiscDir { return false }
                    let s = stem(v.name).lowercased()
                    let dn = lowerNamesByDir[v.dir] ?? []
                    return dn.contains("\(s)-poster.jpg")
                        || dn.contains("\(s)-poster.jpeg")
                        || dn.contains("\(s)-poster.png")
                        || dn.contains("\(s)-poster.webp")
                }

            if !hasNfo || !hasPoster {
                let targets = w.ownsDir ? [w.rootDir] : w.videos.map(\.path)
                let display = w.ownsDir ? w.rootDir : (w.videos.count == 1 ? w.videos[0].path : w.rootDir)
                issues.append(MissingAssetIssue(
                    workTitle: w.anchorTitle,
                    kind: w.kind,
                    folderPath: display,
                    targetPaths: targets,
                    missingNfo: !hasNfo,
                    missingPoster: !hasPoster
                ))
            }
        }
        return issues.sorted { $0.workTitle < $1.workTitle }
    }

    private func collectLikelyEmptyDirs(
        normRoot: String,
        listings: [String: [RemoteEntry]],
        allDirs: Set<String>,
        discDirs: Set<String>
    ) -> [String] {
        func insideDisc(_ dir: String) -> Bool {
            discDirs.contains { d in dir == d || dir.hasPrefix(d + "/") }
        }
        let sortedDirs = allDirs
            .filter { $0 != "/" && $0 != normRoot && !insideDisc($0) }
            .sorted { $0.filter({ $0 == "/" }).count > $1.filter({ $0 == "/" }).count }

        var likelyEmpty: Set<String> = []
        for dir in sortedDirs {
            guard let entries = listings[dir] else { continue }
            let empty = entries.allSatisfy { e in
                if e.isDir { return likelyEmpty.contains(normalizeDir(e.path)) }
                return ignorableEmptyDirFiles.contains(e.name.lowercased())
            }
            if empty { likelyEmpty.insert(dir) }
        }
        return Array(likelyEmpty)
    }

    private func auditCleanup(
        normRoot: String,
        junkFiles: [(RemoteEntry, String)],
        likelyEmpty: [String]
    ) async -> [CleanupIssue] {
        var items = junkFiles.map { f, reason in
            CleanupIssue(path: f.path, name: f.name, kind: .junkFile, size: f.size, reason: reason)
        }
        if !likelyEmpty.isEmpty && !cancelledFlag {
            if let verified = try? await findEmptySourceDirs(
                backend: backend,
                candidateDirs: likelyEmpty,
                protectedRoots: [normRoot, "/"]
            ) {
                for dir in verified {
                    items.append(CleanupIssue(path: dir, name: baseOf(dir), kind: .emptyDir, size: 0, reason: "空目录"))
                }
            }
        }
        return items.sorted {
            if $0.kind != $1.kind { return $0.kind == .junkFile }
            return $0.path < $1.path
        }
    }

    // MARK: - Static Helpers

    private static func healthJunkReason(_ e: RemoteEntry) -> String? {
        let low = e.name.lowercased()
        if low.hasPrefix("._") || ignorableEmptyDirFiles.contains(low) { return "系统隐藏垃圾" }
        let ext = extOf(e.name).lowercased()
        if ext.isEmpty { return nil }
        let st = stem(e.name)
        let rSt = NSRange(st.startIndex..<st.endIndex, in: st)

        if videoExtensions.contains(ext) {
            if e.size <= 0 || e.size >= maxSampleJunkBytes { return nil }
            if sampleRegex.firstMatch(in: st, range: rSt) != nil { return "样片文件" }
            if adKwRegex.firstMatch(in: st, range: rSt) != nil && stripPunct(st).count < 16 { return "广告 / 垃圾文件" }
            return nil
        }
        if unambiguousJunkExt.contains(ext) { return "广告 / 垃圾文件" }
        if adKwRegex.firstMatch(in: st, range: rSt) != nil || explicitUrlRegex.firstMatch(in: st, range: rSt) != nil {
            return "广告 / 垃圾文件"
        }
        return nil
    }

    private static func ancestorChain(dir: String, root: String) -> [String] {
        var chain: [String] = []
        var cur = normalizeDir(dir)
        let normRoot = normalizeDir(root)
        while true {
            chain.append(cur)
            if cur == normRoot || cur == "/" { break }
            let parent = normalizeDir(dirOf(cur))
            if parent == cur { break }
            cur = parent
        }
        return chain
    }

    private static func extractTmdbId(_ videos: [ScannedVideo]) -> Int? {
        for v in videos {
            if let ext = v.parsed.externalId, ext.source == "tmdb", let id = Int(ext.id) {
                return id
            }
        }
        return nil
    }

    private static func mostCommonString(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var firstSeen: [String: String] = [:]
        for x in items {
            let k = normTitle(x)
            guard !k.isEmpty else { continue }
            counts[k, default: 0] += 1
            if firstSeen[k] == nil { firstSeen[k] = x }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return firstSeen[best]
    }

    private static func mostCommonInt(_ items: [Int]) -> Int? {
        guard !items.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for x in items { counts[x, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
