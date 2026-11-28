import Foundation
import TidyreelModels

public enum PlannerError: Error, LocalizedError, Equatable, Sendable {
    case missingLibraryRoot

    public var errorDescription: String? {
        switch self {
        case .missingLibraryRoot:
            return "moveToLibrary needs PlanOptions.libraryRoot"
        }
    }
}

internal enum PlannerRegex {
    static let idTag = try! NSRegularExpression(
        pattern: #"\s*(?:\{[^}]*\}|\[tmdb[^\]]*\])\s*$"#,
        options: [.caseInsensitive]
    )
    static let titleYear = try! NSRegularExpression(
        pattern: #"\S \((?:19|20)\d{2}\)$"#
    )
    static let fileLike = try! NSRegularExpression(
        pattern: #"\.[A-Za-z][A-Za-z0-9]{1,3}$"#
    )
    static let tmdbFolderTag = try! NSRegularExpression(
        pattern: #"tmdb(?:id)?[-=](\d+)(?![0-9])"#,
        options: [.caseInsensitive]
    )
    static let trailingSlashes = try! NSRegularExpression(pattern: #"/+$"#)
}

/// Turns a recognized `ScanResult` + user `GroupDecision`s into an ordered `RenamePlan`,
/// including subtitle/sidecar followers, season strategies, folder merges, NFO/artwork
/// scraping, junk deletion, and destination/existing conflict detection.
public final class DefaultPlanner: Planner, Sendable {
    public let metadata: any MetadataProvider

    public init(metadata: any MetadataProvider) {
        self.metadata = metadata
    }

    public convenience init(_ metadata: any MetadataProvider) {
        self.init(metadata: metadata)
    }

    public func build(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        options: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>?
    ) async throws -> RenamePlan {
        let builder = PlanBuilder(
            metadata: metadata,
            scan: scan,
            decisions: decisions,
            opts: options,
            existing: existing,
            existingDirs: existingDirs
        )
        return try await builder.run()
    }
}

// MARK: - Internal Plan Builder

internal final class PlanItem {
    let file: ScanFile
    var extra = false
    var ref: EpisodeRef?
    var warnings: [String] = []
    var selected = true
    var manual = false
    var dstDir = ""
    var newBase = ""
    var outName = ""

    init(_ file: ScanFile) {
        self.file = file
    }
}

internal final class PlanCompanion {
    let id: Int
    let file: ScanFile
    let override: FileOverride?
    let followed: PlanItem?
    let remainder: String
    let fallbackVideo: ScanFile?
    var extra = false
    var ref: EpisodeRef?
    var warnings: [String] = []
    var selected = false

    init(
        id: Int,
        file: ScanFile,
        override: FileOverride?,
        followed: PlanItem?,
        remainder: String,
        fallbackVideo: ScanFile? = nil
    ) {
        self.id = id
        self.file = file
        self.override = override
        self.followed = followed
        self.remainder = remainder
        self.fallbackVideo = fallbackVideo
    }
}

private let utcGregorianCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

internal struct SeasonKey: Hashable, Sendable {
    let tmdbId: Int
    let season: Int
}

private enum CachedMovie {
    case hit(MovieDetail)
    case miss

    var value: MovieDetail? {
        switch self {
        case .hit(let detail): return detail
        case .miss: return nil
        }
    }
}

private enum PrefetchRequest: Hashable, Sendable {
    case show(Int)
    case episodeGroups(Int)
    case movie(Int)
}

private enum PrefetchResult: Sendable {
    case show(Int, ShowDetail)
    case episodeGroups(Int, [EpisodeGroup])
    case movie(Int, MovieDetail?)
}

private struct SelectedGroupContext {
    let group: MediaGroup
    let groupIndex: Int
    let decision: GroupDecision
    let match: Candidate
}

internal struct ResolvedGroupItems {
    let items: [PlanItem]
    let companions: [PlanCompanion]
}

internal struct AirDayKey: Hashable {
    let year: Int
    let month: Int
    let day: Int

    init?(utcDate: Date?) {
        guard let utcDate else { return nil }
        let c = utcGregorianCalendar.dateComponents([.year, .month, .day], from: utcDate)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        self.year = y
        self.month = m
        self.day = d
    }
}

internal final class PlanBuilder {
    private let metadata: any MetadataProvider
    let scan: ScanResult
    private let decisions: [GroupId: GroupDecision]
    let opts: PlanOptions
    private let existing: Set<String>
    let sortedExisting: [String]
    let existingLower: Set<String>
    let existingDirsLower: Set<String>?

    var mkdirs: [String: GroupId?] = [:]
    var mkdirKeyToPath: [String: String] = [:]
    var selectedMkdirs: Set<String> = []
    var fileOps: [RenameOp] = []
    var seasonOps: [RenameOp] = []
    var folderOps: [RenameOp] = []
    var deleteOps: [RenameOp] = []

    var renamedSeasons: [String: String] = [:]
    var renamedSeasonBySrc: [String: (dst: String, order: Int)] = [:]
    var renamedSeasonByDst: [String: String] = [:]
    var renamedSeasonByDstLower: [String: (src: String, dst: String, order: Int)] = [:]
    var nextRenamedSeasonOrder = 0

    var renamedRoots: [String: String] = [:]
    var renamedRootBySrc: [String: (dst: String, order: Int)] = [:]
    var renamedRootByDstLower: [String: (src: String, dst: String, order: Int)] = [:]
    var nextRenamedRootOrder = 0

    var showFolders: [String: (group: GroupId, base: String)] = [:]
    var merges: [PlanMerge] = []
    var scraped: [String: Int] = [:]

    var knownDirs: Set<String> = []
    var knownDirParentsLower: Set<String> = []
    var scanFilePathsLower: Set<String> = []
    var movedSrcsLower: Set<String> = []
    var plannedFinalDstsLower: Set<String> = []

    var existingDirByLower: [String: String] = [:]
    var existingDirsByParentLower: [String: [String]] = [:]
    var rootDirOwnerGroup: [String: Int] = [:]
    var fileOwnerGroupByDir: [String: Int] = [:]
    var nonJunkUnassignedAncestors: Set<String> = []

    private var showCache: [Int: ShowDetail] = [:]
    private var episodeGroupsCache: [Int: [EpisodeGroup]] = [:]
    var seasonCache: [SeasonKey: [Episode]] = [:]
    private var movieCache: [Int: CachedMovie] = [:]
    var prefetchedResolved: [Int: ResolvedGroupItems] = [:]

    private static let maxPrefetchConcurrency = 6

    init(
        metadata: any MetadataProvider,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        opts: PlanOptions,
        existing: Set<String>,
        existingDirs: Set<String>?
    ) {
        self.metadata = metadata
        self.scan = scan
        self.decisions = decisions
        self.opts = opts
        self.existing = existing
        self.sortedExisting = existing.sorted()
        self.existingLower = Set(existing.map { $0.lowercased() })
        self.existingDirsLower = existingDirs.map { Set($0.map { p in p.lowercased() }) }
    }

    func run() async throws -> RenamePlan {
        buildStaticIndices()

        var selectedContexts: [SelectedGroupContext] = []
        var skipped: [MediaGroup] = []
        for (groupIdx, g) in scan.groups.enumerated() {
            let d = decisions[g.id] ?? GroupDecision()
            guard d.selected, let match = d.match ?? g.match else {
                skipped.append(g)
                continue
            }
            selectedContexts.append(SelectedGroupContext(
                group: g,
                groupIndex: groupIdx,
                decision: d,
                match: match
            ))
        }

        // Phase 1: Bounded concurrent prefetch of all unique metadata needed across selected groups.
        try await prefetchMetadata(for: selectedContexts)

        // Phase 2: Deterministic sequential CPU planning pass in scan.groups order.
        var processed: [MediaGroup] = []
        processed.reserveCapacity(selectedContexts.count)
        for ctx in selectedContexts {
            try await planGroup(ctx.group, groupIndex: ctx.groupIndex, decision: ctx.decision, match: ctx.match)
            processed.append(ctx.group)
        }

        if !opts.scrapeOnly {
            planJunk(processed: processed, skipped: skipped)
        }

        var mkdirOps = mkdirs.map { (path, group) in
            RenameOp(
                id: OpId("m-\(stableHash(path))"),
                kind: .mkdir,
                phase: .files,
                src: "",
                dst: path,
                group: group,
                selected: selectedMkdirs.contains(path)
            )
        }
        mkdirOps.sort { a, b in
            let da = slashCount(a.dst)
            let db = slashCount(b.dst)
            return da != db ? da < db : a.dst < b.dst
        }

        let ops = mkdirOps + fileOps + seasonOps + folderOps + deleteOps
        let conflicts = detectPlanConflicts(ops: ops, existing: existing)
        return RenamePlan(ops: ops, conflicts: conflicts, merges: merges)
    }

    // MARK: - Phase 1 Concurrent Metadata Prefetch & Cache Lookups

    private func prefetchMetadata(for selectedContexts: [SelectedGroupContext]) async throws {
        guard !selectedContexts.isEmpty else { return }

        let wantScrape = opts.scrape || opts.scrapeOnly

        // Sub-phase 1a: Collect all unique show / episodeGroups / movie requests across selected groups.
        var requests: [PrefetchRequest] = []
        var seenReqs: Set<PrefetchRequest> = []
        func enqueue(_ req: PrefetchRequest) {
            if seenReqs.insert(req).inserted {
                requests.append(req)
            }
        }

        for ctx in selectedContexts {
            let g = ctx.group
            let d = ctx.decision
            let match = ctx.match
            let isTv = (match.kind == .episode)

            if isTv {
                if !(g.show != nil && g.match?.tmdbId == match.tmdbId), showCache[match.tmdbId] == nil {
                    enqueue(.show(match.tmdbId))
                }
                if d.episodeGroupId != nil, episodeGroupsCache[match.tmdbId] == nil {
                    enqueue(.episodeGroups(match.tmdbId))
                }
            } else {
                let needsMovie = (!opts.scrapeOnly && !hasHan(match.title))
                    || (wantScrape && match.kind == .movie)
                if needsMovie, movieCache[match.tmdbId] == nil {
                    enqueue(.movie(match.tmdbId))
                }
                if wantScrape && match.kind != .movie,
                   !(g.show != nil && g.match?.tmdbId == match.tmdbId),
                   showCache[match.tmdbId] == nil {
                    enqueue(.show(match.tmdbId))
                }
            }
        }

        if !requests.isEmpty {
            let meta = metadata
            let maxConcurrency = Self.maxPrefetchConcurrency
            let results = try await withThrowingTaskGroup(of: PrefetchResult.self) { group in
                var nextIndex = 0
                var inFlight = 0
                var collected: [PrefetchResult] = []
                collected.reserveCapacity(requests.count)

                func scheduleMore() {
                    while inFlight < maxConcurrency && nextIndex < requests.count {
                        if Task.isCancelled { return }
                        let req = requests[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            switch req {
                            case .show(let id):
                                return .show(id, try await meta.show(id))
                            case .episodeGroups(let id):
                                return .episodeGroups(id, try await meta.episodeGroups(id))
                            case .movie(let id):
                                return .movie(id, try? await meta.movie(id))
                            }
                        }
                    }
                }

                scheduleMore()
                while inFlight > 0 {
                    guard let res = try await group.next() else { break }
                    inFlight -= 1
                    collected.append(res)
                    scheduleMore()
                }
                try Task.checkCancellation()
                return collected
            }

            for res in results {
                switch res {
                case .show(let id, let detail):
                    showCache[id] = detail
                case .episodeGroups(let id, let groups):
                    episodeGroupsCache[id] = groups
                case .movie(let id, let detail):
                    movieCache[id] = detail.map(CachedMovie.hit) ?? .miss
                }
            }
        }

        // Sub-phase 1b: Resolve needed TV seasons across selected groups and prefetch concurrently.
        var neededSeasons: [SeasonKey] = []
        var seenSeasons: Set<SeasonKey> = []
        func enqueueSeason(_ tmdbId: Int, _ season: Int) {
            let key = SeasonKey(tmdbId: tmdbId, season: season)
            if seasonCache[key] == nil && seenSeasons.insert(key).inserted {
                neededSeasons.append(key)
            }
        }

        for ctx in selectedContexts {
            let g = ctx.group
            let d = ctx.decision
            let match = ctx.match
            guard match.kind == .episode else { continue }

            let show: ShowDetail? = (g.show != nil && g.match?.tmdbId == match.tmdbId)
                ? g.show
                : showCache[match.tmdbId]
            let epGroup: EpisodeGroup? = d.episodeGroupId.flatMap { egId in
                episodeGroupsCache[match.tmdbId]?.first { $0.id == egId }
            }
            let tmdbCounts = seasonEpisodeCounts(show: show, episodeGroup: epGroup)
            let naming = opts.naming.tv
            let allVideos = g.files.filter { $0.role == .video }
            let videos = allVideos.filter { !(d.overrides[$0.path]?.ignore ?? false) }

            let needsAirDate = videos.contains(where: { $0.parsed?.airDate != nil })
            if needsAirDate, let show {
                for s in show.seasons where s.number > 0 {
                    enqueueSeason(match.tmdbId, s.number)
                }
            }

            let wantTitles = naming.episodeTitle
                || (naming.customTemplate?.contains("episode_title") ?? false)
                || (wantScrape && epGroup != nil)
            if wantTitles || wantScrape {
                let lowMatch = (d.match == nil && g.matchScore < opts.confidenceThreshold)
                let items = resolveVideoItems(
                    videos: videos,
                    decision: d,
                    isTv: true,
                    lowMatch: lowMatch,
                    tmdbCounts: tmdbCounts,
                    epGroup: epGroup,
                    byDate: [:]
                )
                let companions = resolveCompanions(
                    group: g,
                    decision: d,
                    isTv: true,
                    lowMatch: lowMatch,
                    tmdbCounts: tmdbCounts,
                    allVideos: allVideos,
                    items: items
                )
                if !needsAirDate {
                    prefetchedResolved[ctx.groupIndex] = ResolvedGroupItems(items: items, companions: companions)
                }

                if wantTitles {
                    let targetRefs = items.compactMap(\.ref) + companions.compactMap(\.ref)
                    let plan = seasonsNeededForRefs(
                        targetRefs,
                        strategy: d.strategy,
                        tmdbCounts: tmdbCounts,
                        epGroup: epGroup
                    )
                    for s in plan.seasons { enqueueSeason(match.tmdbId, s) }
                }
                if wantScrape {
                    let episodeRefs = items.compactMap { (!$0.extra ? $0.ref : nil) }
                    let plan = seasonsNeededForRefs(
                        episodeRefs,
                        strategy: d.strategy,
                        tmdbCounts: tmdbCounts,
                        epGroup: epGroup
                    )
                    for s in plan.seasons { enqueueSeason(match.tmdbId, s) }
                }
            }
        }

        if !neededSeasons.isEmpty {
            await prefetchSeasonKeys(neededSeasons)
        }
    }

    func fetchShow(_ tmdbId: Int) async throws -> ShowDetail {
        if let cached = showCache[tmdbId] { return cached }
        let fetched = try await metadata.show(tmdbId)
        showCache[tmdbId] = fetched
        return fetched
    }

    func fetchEpisodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
        if let cached = episodeGroupsCache[tmdbId] { return cached }
        let fetched = try await metadata.episodeGroups(tmdbId)
        episodeGroupsCache[tmdbId] = fetched
        return fetched
    }

    private func prefetchSeasonKeys(_ keys: [SeasonKey]) async {
        var missing: [SeasonKey] = []
        var seen: Set<SeasonKey> = []
        for key in keys {
            if seasonCache[key] == nil && seen.insert(key).inserted {
                missing.append(key)
            }
        }
        guard !missing.isEmpty else { return }

        let meta = metadata
        let maxConcurrency = Self.maxPrefetchConcurrency
        let fetched = await withTaskGroup(of: (SeasonKey, [Episode]).self) { group in
            var nextIndex = 0
            var inFlight = 0
            var pairs: [(SeasonKey, [Episode])] = []
            pairs.reserveCapacity(missing.count)

            func scheduleMore() {
                while inFlight < maxConcurrency && nextIndex < missing.count {
                    if Task.isCancelled { return }
                    let key = missing[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        let eps = (try? await meta.season(key.tmdbId, season: key.season)) ?? []
                        return (key, eps)
                    }
                }
            }

            scheduleMore()
            while inFlight > 0 {
                guard let pair = await group.next() else { break }
                inFlight -= 1
                pairs.append(pair)
                scheduleMore()
            }
            return pairs
        }

        for (key, eps) in fetched {
            seasonCache[key] = eps
        }
    }

    func allSeasonsCached(tmdbId: Int, seasons: [Int]) -> Bool {
        seasons.allSatisfy { seasonCache[SeasonKey(tmdbId: tmdbId, season: $0)] != nil }
    }

    func ensureSeasonsCached(tmdbId: Int, seasons: [Int]) async {
        guard !seasons.isEmpty else { return }
        await prefetchSeasonKeys(seasons.map { SeasonKey(tmdbId: tmdbId, season: $0) })
    }

    func fetchMovie(_ tmdbId: Int) async -> MovieDetail? {
        if let cached = movieCache[tmdbId] { return cached.value }
        let fetched = try? await metadata.movie(tmdbId)
        movieCache[tmdbId] = fetched.map(CachedMovie.hit) ?? .miss
        return fetched
    }
}

// MARK: - Private Path Utilities

private func slashCount(_ s: String) -> Int {
    var count = 0
    for ch in s where ch == "/" { count += 1 }
    return count
}
