import Foundation
import Observation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct SeasonEpisodesCacheKey: Hashable, Sendable {
    let tmdbId: Int
    let season: Int
}

enum EpisodeGroupsLoadState: Equatable, Sendable {
    case loading
    case loaded([EpisodeGroup])
    case failed(String)
}

enum ActiveReviewSheet: Identifiable {
    case editRow(group: MediaGroup, row: ReviewRow, allRows: [ReviewRow])
    case tmdbSearch(group: MediaGroup, initialQuery: String)
    case mergeConfirm(merges: [PlanMerge])
    case confirmPermanentDelete(paths: [String])
    case mergeGroup(source: MediaGroup)
    case splitGroup(source: MediaGroup, initialSelection: Set<String>)
    case shortcuts

    var id: String {
        switch self {
        case .editRow(_, let row, _): return "edit:\(row.id)"
        case .tmdbSearch(let g, _): return "tmdb:\(g.id.value)"
        case .mergeConfirm: return "merge-confirm"
        case .confirmPermanentDelete: return "confirm-delete"
        case .mergeGroup(let g): return "merge-group:\(g.id.value)"
        case .splitGroup(let g, _): return "split-group:\(g.id.value)"
        case .shortcuts: return "shortcuts"
        }
    }
}

struct EpisodeRowDisplay {
    let missingEpNumber: Bool
    let lowConfidence: Bool
    let hasWarning: Bool
    let diffText: AttributedString
    let conflictDetail: String
    let tooltipText: String
}

struct SidecarRowDisplay {
    let diffText: AttributedString
    let roleIcon: String
}

@Observable
@MainActor
final class ReviewViewModel {
    private(set) var review: TaskReview?
    private(set) var index: ReviewIndex?
    private(set) var isLoading = false
    private(set) var pendingMutations = 0
    private(set) var isExecuting = false
    private(set) var errorMessage: String?

    // Navigation & selection state
    var leftTab: LeftPaneTab = .matched {
        didSet {
            guard oldValue != leftTab, !suppressProjectionRecompute else { return }
            recomputeGroupListProjections()
        }
    }
    var showUnassigned: Bool = false {
        didSet {
            guard oldValue != showUnassigned, !suppressProjectionRecompute else { return }
            recomputeSelectedGroupProjections()
        }
    }
    var filter: ReviewFilter = .all {
        didSet {
            guard oldValue != filter, !suppressProjectionRecompute else { return }
            recomputeGroupListProjections()
        }
    }
    var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery, !suppressProjectionRecompute else { return }
            recomputeGroupListProjections()
        }
    }
    var searchFocusTrigger: Int = 0
    var selectedGroupId: GroupId? {
        didSet {
            guard oldValue != selectedGroupId else { return }
            withSuppressedRecompute {
                detailTab = nil
                isMultiSelectMode = false
                multiSelectedPaths.removeAll()
                highlightedConflictPath = nil
            }
            if !suppressProjectionRecompute {
                recomputeSelectedGroupProjections()
            }
        }
    }
    var detailTab: DetailTab? {
        didSet {
            guard oldValue != detailTab, !suppressProjectionRecompute else { return }
            recomputeSelectedTabProjections()
        }
    }
    var showInspector: Bool = true
    var isMultiSelectMode: Bool = false
    var multiSelectedPaths: Set<String> = []
    var expandedVideoPaths: Set<String> = [] {
        didSet {
            guard oldValue != expandedVideoPaths, !suppressProjectionRecompute else { return }
            recomputeSelectedDetailItems()
        }
    }
    var highlightedConflictPath: String? {
        didSet {
            guard oldValue != highlightedConflictPath, !suppressProjectionRecompute else { return }
            recomputeSelectedDetailItems()
        }
    }
    var activeSheet: ActiveReviewSheet?

    // Metadata caches
    private(set) var fetchedShows: [Int: ShowDetail] = [:]
    private(set) var seasonEpisodesCache: [SeasonEpisodesCacheKey: [Int: Episode]] = [:]
    private(set) var seasonAirDatesCache: [SeasonEpisodesCacheKey: [Int: String]] = [:]
    private(set) var episodeGroupsCache: [Int: EpisodeGroupsLoadState] = [:]

    // Cached group-list projections (recomputed only when review/index/searchQuery/leftTab/filter/fetchedShows/threshold change)
    private(set) var matchedGroups: [MediaGroup] = []
    private(set) var unmatchedGroups: [MediaGroup] = []
    private(set) var visibleGroups: [MediaGroup] = []
    private(set) var conflictCount: Int = 0
    private(set) var incompleteCount: Int = 0
    private(set) var lowConfidenceCount: Int = 0
    private(set) var selectedVisibleCount: Int = 0
    private(set) var completenessByGroup: [GroupId: Completeness] = [:]
    private(set) var hasMultipleVideosByGroup: [GroupId: Bool] = [:]
    private(set) var selectedMerges: [PlanMerge] = []
    private(set) var assignableGroupTargets: [AssignGroupTarget] = []
    private(set) var unassignedFlatItems: [UnassignedListItem] = []
    private(set) var hasUndeletedUnassignedJunk: Bool = false

    // Cached selected-group detail projections (recomputed only when review/index/selectedGroupId/detailTab/fetchedShows/seasonEpisodesCache/expandedVideoPaths change)
    private(set) var selectedGroup: MediaGroup?
    private(set) var selectedGroupRows: [ReviewRow] = []
    private(set) var selectedAvailableDetailTabs: [DetailTab] = [.allFiles, .folders]
    private(set) var selectedResolvedDetailTab: DetailTab = .allFiles
    private(set) var selectedDetailItems: [DetailListItem] = []
    private(set) var selectedDuplicateConflicts: [GroupDuplicateConflict] = []
    private(set) var selectedConflictedRowCount: Int = 0
    private(set) var selectedSeasonOverflow: SeasonOverflowHint?
    private(set) var selectedMissingEpisodes: [Int] = []
    private(set) var selectedHasMultipleVideos: Bool = false
    private(set) var selectedMovieRowCount: Int = 0
    private(set) var selectedExtrasRowCount: Int = 0
    private(set) var selectedSeasonCountLabels: [Int: String] = [:]

    // Internal non-observed task tracking & memoization caches
    @ObservationIgnored private var showFetchTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var seasonFetchTasks: [SeasonEpisodesCacheKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var episodeGroupFetchTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetchGeneration: Int = 0
    @ObservationIgnored private var updateSeq: Int = 0
    @ObservationIgnored private var boundTaskId: TaskId?
    @ObservationIgnored private var suppressProjectionRecompute: Bool = false
    @ObservationIgnored private var cachedConfidenceThreshold: Double = 0.7
    @ObservationIgnored private var cachedL10n: AppL10n = .zh
    @ObservationIgnored private var rawGroupById: [GroupId: MediaGroup] = [:]
    @ObservationIgnored private var effectiveGroupById: [GroupId: MediaGroup] = [:]
    @ObservationIgnored private var allEffectiveGroups: [MediaGroup] = []
    @ObservationIgnored private var episodeRowDisplayCache: [String: EpisodeRowDisplay] = [:]
    @ObservationIgnored private var sidecarRowDisplayCache: [String: SidecarRowDisplay] = [:]
    @ObservationIgnored private var rowDisplayCachePalette: TidyreelPalette?
    @ObservationIgnored private var rowDisplayCacheL10n: AppL10n?
    @ObservationIgnored private var rowDisplayCacheThreshold: Double = -1

    var isBusy: Bool {
        isLoading || pendingMutations > 0 || isExecuting
    }

    // MARK: - Lifecycle & Environment Sync

    func syncContext(confidenceThreshold: Double, l10n: AppL10n) {
        let thresholdChanged = cachedConfidenceThreshold != confidenceThreshold
        let l10nChanged = cachedL10n != l10n
        cachedConfidenceThreshold = confidenceThreshold
        cachedL10n = l10n
        if thresholdChanged || l10nChanged {
            invalidateRowDisplayCache()
        }
        if thresholdChanged {
            recomputeGroupListProjections()
        }
        if l10nChanged {
            recomputeSelectedDetailItems()
        }
    }

    func resetIfNeeded(for taskId: TaskId) {
        guard boundTaskId != taskId else { return }
        boundTaskId = taskId
        cancelAndClearMetadataCaches()
        withSuppressedRecompute {
            review = nil
            index = nil
            errorMessage = nil
            leftTab = .matched
            showUnassigned = false
            filter = .all
            searchQuery = ""
            selectedGroupId = nil
            detailTab = nil
            isMultiSelectMode = false
            multiSelectedPaths = []
            expandedVideoPaths = []
            highlightedConflictPath = nil
            activeSheet = nil
        }
        clearAllProjections()
        updateSeq += 1
        pendingMutations = 0
        isExecuting = false
    }

    func cleanupOnDisappear() {
        cancelAndClearMetadataCaches()
    }

    private func cancelAndClearMetadataCaches() {
        fetchGeneration &+= 1
        for task in showFetchTasks.values { task.cancel() }
        showFetchTasks.removeAll()
        for task in seasonFetchTasks.values { task.cancel() }
        seasonFetchTasks.removeAll()
        for task in episodeGroupFetchTasks.values { task.cancel() }
        episodeGroupFetchTasks.removeAll()
        fetchedShows.removeAll()
        seasonEpisodesCache.removeAll()
        seasonAirDatesCache.removeAll()
        episodeGroupsCache.removeAll()
        invalidateRowDisplayCache()
    }

    private func withSuppressedRecompute(_ body: () -> Void) {
        let prev = suppressProjectionRecompute
        suppressProjectionRecompute = true
        body()
        suppressProjectionRecompute = prev
    }

    private func invalidateRowDisplayCache() {
        episodeRowDisplayCache.removeAll(keepingCapacity: true)
        sidecarRowDisplayCache.removeAll(keepingCapacity: true)
    }

    private func clearAllProjections() {
        rawGroupById.removeAll()
        effectiveGroupById.removeAll()
        allEffectiveGroups = []
        completenessByGroup = [:]
        hasMultipleVideosByGroup = [:]
        selectedMerges = []
        assignableGroupTargets = []
        unassignedFlatItems = []
        hasUndeletedUnassignedJunk = false

        matchedGroups = []
        unmatchedGroups = []
        visibleGroups = []
        conflictCount = 0
        incompleteCount = 0
        lowConfidenceCount = 0
        selectedVisibleCount = 0

        clearSelectedGroupProjections()
        invalidateRowDisplayCache()
    }

    private func clearSelectedGroupProjections() {
        selectedGroup = nil
        selectedGroupRows = []
        selectedAvailableDetailTabs = [.allFiles, .folders]
        selectedResolvedDetailTab = .allFiles
        selectedDetailItems = []
        selectedDuplicateConflicts = []
        selectedConflictedRowCount = 0
        selectedSeasonOverflow = nil
        selectedMissingEpisodes = []
        selectedHasMultipleVideos = false
        selectedMovieRowCount = 0
        selectedExtrasRowCount = 0
        selectedSeasonCountLabels = [:]
    }

    // MARK: - Derived Projections

    private func recomputeReviewDerivedData() {
        guard let review else {
            rawGroupById.removeAll()
            effectiveGroupById.removeAll()
            allEffectiveGroups = []
            completenessByGroup = [:]
            hasMultipleVideosByGroup = [:]
            selectedMerges = []
            assignableGroupTargets = []
            unassignedFlatItems = []
            hasUndeletedUnassignedJunk = false
            return
        }

        let opsBySrc = index?.opsBySrc
        var rawById: [GroupId: MediaGroup] = [:]
        rawById.reserveCapacity(review.scan.groups.count)
        var effById: [GroupId: MediaGroup] = [:]
        effById.reserveCapacity(review.scan.groups.count)
        var effList: [MediaGroup] = []
        effList.reserveCapacity(review.scan.groups.count)
        var compMap: [GroupId: Completeness] = [:]
        var multiVideoMap: [GroupId: Bool] = [:]
        multiVideoMap.reserveCapacity(review.scan.groups.count)
        var targets: [AssignGroupTarget] = []
        targets.reserveCapacity(review.scan.groups.count)

        for raw in review.scan.groups {
            rawById[raw.id] = raw
            let d = review.decisions[raw.id]
            let eg = effectiveGroup(raw, d, fetchedShows: fetchedShows)
            effById[eg.id] = eg
            effList.append(eg)

            if eg.kind == .episode {
                compMap[eg.id] = completeness(eg, d, opsBySrc: opsBySrc)
            }
            multiVideoMap[eg.id] = hasMultipleVideos(eg)

            let m = effectiveMatch(eg, d)
            let title = m?.title ?? eg.anchorTitle
            let label = m?.year.map { "\(title) (\($0))" } ?? title
            targets.append(AssignGroupTarget(id: eg.id, label: label))
        }

        rawGroupById = rawById
        effectiveGroupById = effById
        allEffectiveGroups = effList
        completenessByGroup = compMap
        hasMultipleVideosByGroup = multiVideoMap
        selectedMerges = review.preview.merges.filter { m in
            review.decisions[m.group]?.selected ?? true
        }
        assignableGroupTargets = targets

        let unassigned = review.scan.unassigned
        if unassigned.isEmpty {
            unassignedFlatItems = []
            hasUndeletedUnassignedJunk = false
        } else {
            let deletedPaths = index?.plannedUnassignedDeletes ?? []
            var hasJunk = false
            var byDir: [String: [ScanFile]] = [:]
            for f in unassigned {
                if !hasJunk && f.role == .junk && !deletedPaths.contains(f.path) {
                    hasJunk = true
                }
                byDir[dirOf(f.path), default: []].append(f)
            }
            hasUndeletedUnassignedJunk = hasJunk

            var flat: [UnassignedListItem] = []
            flat.reserveCapacity(unassigned.count + byDir.count)
            for dir in byDir.keys.sorted() {
                guard let dirFiles = byDir[dir], !dirFiles.isEmpty else { continue }
                flat.append(.header(dir: dir))
                let lastIdx = dirFiles.count - 1
                for (idx, file) in dirFiles.enumerated() {
                    flat.append(.file(
                        file: file,
                        isFirstInSection: idx == 0,
                        isLastInSection: idx == lastIdx
                    ))
                }
            }
            unassignedFlatItems = flat
        }
    }

    private func recomputeGroupListProjections() {
        guard let review else {
            matchedGroups = []
            unmatchedGroups = []
            visibleGroups = []
            conflictCount = 0
            incompleteCount = 0
            lowConfidenceCount = 0
            selectedVisibleCount = 0
            return
        }

        let hasQuery = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var matched: [MediaGroup] = []
        var unmatched: [MediaGroup] = []
        matched.reserveCapacity(allEffectiveGroups.count)

        for g in allEffectiveGroups {
            let d = review.decisions[g.id]
            if hasQuery && !matchesSearchQuery(searchQuery, group: g, decision: d) {
                continue
            }
            if isGroupMatched(g, d) {
                matched.append(g)
            } else {
                unmatched.append(g)
            }
        }

        var conflicts = 0
        var incomplete = 0
        var lowConf = 0
        var lowConfIds: Set<GroupId> = []

        if let index {
            for g in matched {
                if index.conflictGroups.contains(g.id) {
                    conflicts += 1
                }
                if completenessByGroup[g.id]?.incomplete == true {
                    incomplete += 1
                }
                if isGroupLowConfidence(g, review.decisions[g.id], index: index, threshold: cachedConfidenceThreshold) {
                    lowConf += 1
                    lowConfIds.insert(g.id)
                }
            }
        }

        let visible: [MediaGroup]
        if leftTab == .unmatched {
            visible = unmatched
        } else if filter == .all || index == nil {
            visible = matched
        } else if let index {
            switch filter {
            case .all:
                visible = matched
            case .conflict:
                visible = matched.filter { index.conflictGroups.contains($0.id) }
            case .incomplete:
                visible = matched.filter { completenessByGroup[$0.id]?.incomplete == true }
            case .lowConfidence:
                visible = matched.filter { lowConfIds.contains($0.id) }
            }
        } else {
            visible = matched
        }

        var selCount = 0
        for g in visible {
            if review.decisions[g.id]?.selected ?? true {
                selCount += 1
            }
        }

        matchedGroups = matched
        unmatchedGroups = unmatched
        conflictCount = conflicts
        incompleteCount = incomplete
        lowConfidenceCount = lowConf
        visibleGroups = visible
        selectedVisibleCount = selCount
    }

    private func recomputeSelectedGroupProjections() {
        invalidateRowDisplayCache()

        guard !showUnassigned,
              let review,
              let index,
              let selectedGroupId,
              let group = effectiveGroupById[selectedGroupId] else {
            clearSelectedGroupProjections()
            return
        }

        selectedGroup = group
        let d = review.decisions[group.id]
        let rows = buildRows(for: group, decision: d, index: index)

        var seasons: Set<Int> = []
        var hasExtras = false
        var movieCount = 0
        var extrasCount = 0
        var conflictedCount = 0
        var localEpsBySeason: [Int: Set<Int>] = [:]

        for r in rows {
            if r.conflict {
                conflictedCount += 1
            }
            switch r.bucket {
            case .season(let s):
                seasons.insert(s)
                if r.file.role == .video && !r.ignored,
                   let ep = r.targetRef?.episode ?? episodeOf(r.file, r.override) {
                    localEpsBySeason[s, default: []].insert(ep)
                }
            case .extras:
                hasExtras = true
                extrasCount += 1
            case .movie:
                movieCount += 1
            }
        }

        var tabs: [DetailTab] = []
        if group.kind == .episode {
            for s in seasons.sorted() where s >= 0 {
                tabs.append(.season(s))
            }
            if hasExtras {
                tabs.append(.extras)
            }
            if tabs.isEmpty {
                tabs.append(.season(1))
            }
        } else {
            tabs.append(.allFiles)
            if hasExtras {
                tabs.append(.extras)
            }
        }
        tabs.append(.folders)

        var seasonLabels: [Int: String] = [:]
        var tmdbCountsBySeason: [Int: Int] = [:]
        if let showSeasons = group.show?.seasons {
            for s in showSeasons where s.episodeCount > 0 {
                tmdbCountsBySeason[s.number] = s.episodeCount
            }
        }
        for tab in tabs {
            if case .season(let s) = tab {
                let localCount = localEpsBySeason[s]?.count ?? 0
                if let total = tmdbCountsBySeason[s], total > 0 {
                    seasonLabels[s] = "\(localCount)/\(total)"
                } else {
                    seasonLabels[s] = "\(localCount)"
                }
            }
        }

        selectedGroupRows = rows
        selectedAvailableDetailTabs = tabs
        selectedDuplicateConflicts = groupDuplicateConflicts(rows: rows, conflicts: review.preview.conflicts)
        selectedConflictedRowCount = conflictedCount
        selectedSeasonOverflow = detectSeasonOverflow(group: group, decision: d, rows: rows)
        selectedHasMultipleVideos = hasMultipleVideosByGroup[group.id] ?? hasMultipleVideos(group)
        selectedMovieRowCount = movieCount
        selectedExtrasRowCount = extrasCount
        selectedSeasonCountLabels = seasonLabels

        recomputeSelectedTabProjections()
    }

    private func recomputeSelectedTabProjections() {
        guard let group = selectedGroup, let review else {
            selectedResolvedDetailTab = .allFiles
            selectedMissingEpisodes = []
            selectedDetailItems = []
            return
        }

        let activeTab: DetailTab
        if let current = detailTab, selectedAvailableDetailTabs.contains(current) {
            activeTab = current
        } else {
            activeTab = selectedAvailableDetailTabs.first ?? .allFiles
        }
        selectedResolvedDetailTab = activeTab

        if case .season(let s) = activeTab {
            selectedMissingEpisodes = missingEpisodes(
                group: group,
                decision: review.decisions[group.id],
                rows: selectedGroupRows,
                season: s
            )
        } else {
            selectedMissingEpisodes = []
        }

        recomputeSelectedDetailItems()
    }

    private func recomputeSelectedDetailItems() {
        guard selectedGroup != nil else {
            selectedDetailItems = []
            return
        }

        switch selectedResolvedDetailTab {
        case .allFiles:
            selectedDetailItems = buildDetailItems(
                rows: selectedGroupRows,
                bucket: .movie,
                missing: [],
                expandedVideoPaths: expandedVideoPaths,
                highlightedPath: highlightedConflictPath,
                l10n: cachedL10n
            )
        case .season(let s):
            selectedDetailItems = buildDetailItems(
                rows: selectedGroupRows,
                bucket: .season(s),
                missing: selectedMissingEpisodes,
                expandedVideoPaths: expandedVideoPaths,
                highlightedPath: highlightedConflictPath,
                l10n: cachedL10n
            )
        case .extras:
            selectedDetailItems = buildDetailItems(
                rows: selectedGroupRows,
                bucket: .extras,
                missing: [],
                expandedVideoPaths: expandedVideoPaths,
                highlightedPath: highlightedConflictPath,
                l10n: cachedL10n
            )
        case .folders:
            selectedDetailItems = []
        }
    }

    // MARK: - Memoized Per-Row Display Cache

    private func ensureRowDisplayCacheMatches(
        palette: TidyreelPalette,
        l10n: AppL10n,
        confidenceThreshold: Double
    ) {
        if rowDisplayCachePalette != palette
            || rowDisplayCacheL10n != l10n
            || rowDisplayCacheThreshold != confidenceThreshold {
            invalidateRowDisplayCache()
            rowDisplayCachePalette = palette
            rowDisplayCacheL10n = l10n
            rowDisplayCacheThreshold = confidenceThreshold
        }
    }

    func episodeRowDisplay(
        for row: ReviewRow,
        isTvMatched: Bool,
        manuallyMatched: Bool,
        confidenceThreshold: Double,
        palette: TidyreelPalette,
        l10n: AppL10n
    ) -> EpisodeRowDisplay {
        ensureRowDisplayCacheMatches(
            palette: palette,
            l10n: l10n,
            confidenceThreshold: confidenceThreshold
        )
        if let cached = episodeRowDisplayCache[row.file.path] {
            return cached
        }

        let target = row.targetRef
        let missingEpNumber = !row.ignored
            && isTvMatched
            && target == nil
            && row.bucket != .extras
        let lowConfidence = !manuallyMatched
            && !missingEpNumber
            && row.op == nil
            && (row.file.parsed.map { $0.confidence < confidenceThreshold } ?? false)
        let hasWarning = (row.op?.warning != nil) || missingEpNumber || lowConfidence
        let epColor: Color? = (target == nil || row.ignored)
            ? nil
            : seasonBadgeColor(target!.season, isDark: palette.isDark)
        let baseFontSize: CGFloat = isTvMatched ? 12.5 : TidyreelTypeScale.body
        let baseFg: Color = row.ignored
            ? palette.textFaint
            : (isTvMatched ? palette.textMuted : palette.text)
        let diffText = diffFilenameAttributedString(
            oldName: row.file.name,
            newName: row.localizedNewLabel(l10n),
            baseFontSize: baseFontSize,
            baseColor: baseFg,
            ignored: row.ignored,
            conflict: row.conflict,
            hasWarning: hasWarning,
            episodeColor: epColor,
            palette: palette
        )
        let conflictDetail = row.conflictReason.map { localizeCoreMessage(l10n, $0) }
            ?? l10n.tr("目标路径冲突", "Target path conflict")

        var tooltipLines = [l10n.tr("原：\(row.file.path)", "From: \(row.file.path)")]
        if let dst = row.op?.dst, !dst.isEmpty {
            tooltipLines.append(l10n.tr("新：\(dst)", "To: \(dst)"))
        }
        if row.conflict {
            tooltipLines.append(l10n.tr("冲突：\(conflictDetail)", "Conflict: \(conflictDetail)"))
        }

        let built = EpisodeRowDisplay(
            missingEpNumber: missingEpNumber,
            lowConfidence: lowConfidence,
            hasWarning: hasWarning,
            diffText: diffText,
            conflictDetail: conflictDetail,
            tooltipText: tooltipLines.joined(separator: "\n")
        )
        episodeRowDisplayCache[row.file.path] = built
        return built
    }

    func sidecarRowDisplay(
        for row: ReviewRow,
        confidenceThreshold: Double,
        palette: TidyreelPalette,
        l10n: AppL10n
    ) -> SidecarRowDisplay {
        ensureRowDisplayCacheMatches(
            palette: palette,
            l10n: l10n,
            confidenceThreshold: confidenceThreshold
        )
        if let cached = sidecarRowDisplayCache[row.file.path] {
            return cached
        }

        let hasWarning = row.op?.warning != nil
        let diffText = diffFilenameAttributedString(
            oldName: row.file.name,
            newName: row.localizedNewLabel(l10n),
            prefix: "→ ",
            baseFontSize: TidyreelTypeScale.small,
            baseColor: row.ignored ? palette.textFaint : palette.textMuted,
            ignored: row.ignored,
            conflict: row.conflict,
            hasWarning: hasWarning,
            palette: palette
        )
        let roleIcon: String = {
            switch row.file.role {
            case .subtitle: return "captions.bubble"
            case .junk: return "trash"
            default:
                return isAudioCompanion(row.file) ? "music.note" : "doc"
            }
        }()

        let built = SidecarRowDisplay(diffText: diffText, roleIcon: roleIcon)
        sidecarRowDisplayCache[row.file.path] = built
        return built
    }

    // MARK: - Review Application & Lookups

    private func applyReview(_ next: TaskReview, store: AppStore, taskId: TaskId) {
        cachedConfidenceThreshold = store.settings.confidenceThreshold
        cachedL10n = store.l10n
        withSuppressedRecompute {
            review = next
            index = ReviewIndex.build(from: next)
            recomputeReviewDerivedData()
            store.updateTaskCardMeta(id: taskId, review: next)
            if next.scan.unassigned.isEmpty && showUnassigned {
                showUnassigned = false
            }
            recomputeGroupListProjections()
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: store.settings.confidenceThreshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        recomputeSelectedGroupProjections()
    }

    private func applyOptimisticReview(
        _ optimistic: TaskReview,
        store: AppStore,
        taskId: TaskId,
        promoteMatchedGroupId: GroupId? = nil
    ) {
        cachedConfidenceThreshold = store.settings.confidenceThreshold
        cachedL10n = store.l10n
        withSuppressedRecompute {
            review = optimistic
            recomputeReviewDerivedData()
            store.updateTaskCardMeta(id: taskId, review: optimistic)
            recomputeGroupListProjections()
            if let promoteId = promoteMatchedGroupId,
               leftTab == .unmatched && unmatchedGroups.isEmpty {
                leftTab = .matched
                showUnassigned = false
                selectedGroupId = promoteId
                recomputeGroupListProjections()
            }
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: store.settings.confidenceThreshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        recomputeSelectedGroupProjections()
    }

    func decision(for groupId: GroupId) -> GroupDecision {
        review?.decisions[groupId] ?? GroupDecision()
    }

    func rawGroup(for groupId: GroupId) -> MediaGroup? {
        rawGroupById[groupId]
    }

    func ensureValidSelection(confidenceThreshold: Double = 0.7) {
        if cachedConfidenceThreshold != confidenceThreshold {
            cachedConfidenceThreshold = confidenceThreshold
            invalidateRowDisplayCache()
            recomputeGroupListProjections()
        }
        guard let review else {
            selectedGroupId = nil
            return
        }
        if showUnassigned { return }
        let visible = visibleGroups
        if let current = selectedGroupId, visible.contains(where: { $0.id == current }) {
            return
        }
        if let first = visible.first {
            selectedGroupId = first.id
        } else if searchQuery.isEmpty && filter == .all {
            let otherMatched = (leftTab != .matched)
            let other = otherMatched ? matchedGroups : unmatchedGroups
            if let firstOther = other.first {
                leftTab = otherMatched ? .matched : .unmatched
                selectedGroupId = firstOther.id
            } else if !review.scan.unassigned.isEmpty {
                showUnassigned = true
                selectedGroupId = nil
            } else {
                selectedGroupId = nil
            }
        } else {
            selectedGroupId = nil
        }
    }

    func selectLeftTab(_ tab: LeftPaneTab, store: AppStore) {
        let threshold = store.settings.confidenceThreshold
        withSuppressedRecompute {
            cachedConfidenceThreshold = threshold
            leftTab = tab
            filter = .all
            showUnassigned = false
            recomputeGroupListProjections()
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: threshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        recomputeSelectedGroupProjections()
        prefetchSelectedGroupMetadata(store: store)
    }

    func selectFilter(_ nextFilter: ReviewFilter, store: AppStore) {
        let threshold = store.settings.confidenceThreshold
        withSuppressedRecompute {
            cachedConfidenceThreshold = threshold
            filter = nextFilter
            showUnassigned = false
            recomputeGroupListProjections()
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: threshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        recomputeSelectedGroupProjections()
        prefetchSelectedGroupMetadata(store: store)
    }

    func updateSearchQuery(_ nextQuery: String, store: AppStore) {
        guard searchQuery != nextQuery else { return }
        let threshold = store.settings.confidenceThreshold
        let prevSelected = selectedGroupId
        let prevShowUnassigned = showUnassigned
        withSuppressedRecompute {
            cachedConfidenceThreshold = threshold
            searchQuery = nextQuery
            recomputeGroupListProjections()
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: threshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        if selectedGroupId != prevSelected || showUnassigned != prevShowUnassigned {
            recomputeSelectedGroupProjections()
        }
    }

    func selectGroup(_ groupId: GroupId, store: AppStore) {
        let needsRecompute = showUnassigned || selectedGroupId != groupId
        withSuppressedRecompute {
            showUnassigned = false
            selectedGroupId = groupId
        }
        if needsRecompute {
            recomputeSelectedGroupProjections()
        }
        prefetchSelectedGroupMetadata(store: store)
    }

    private func navigateToGroup(_ groupId: GroupId, tab: LeftPaneTab, store: AppStore) {
        withSuppressedRecompute {
            showUnassigned = false
            leftTab = tab
            filter = .all
            selectedGroupId = groupId
        }
        recomputeGroupListProjections()
        recomputeSelectedGroupProjections()
        prefetchSelectedGroupMetadata(store: store)
    }

    func returnToWorks(store: AppStore) {
        let threshold = store.settings.confidenceThreshold
        withSuppressedRecompute {
            cachedConfidenceThreshold = threshold
            showUnassigned = false
            recomputeGroupListProjections()
            if visibleGroups.isEmpty {
                let otherMatched = (leftTab != .matched)
                let other = otherMatched ? matchedGroups : unmatchedGroups
                if !other.isEmpty {
                    leftTab = otherMatched ? .matched : .unmatched
                    filter = .all
                    recomputeGroupListProjections()
                }
            }
            let tabBefore = leftTab
            ensureValidSelection(confidenceThreshold: threshold)
            if leftTab != tabBefore {
                recomputeGroupListProjections()
            }
        }
        recomputeSelectedGroupProjections()
        prefetchSelectedGroupMetadata(store: store)
    }

    // MARK: - Loading & Metadata Prefetch

    func load(store: AppStore, taskId: TaskId) async {
        resetIfNeeded(for: taskId)
        cachedConfidenceThreshold = store.settings.confidenceThreshold
        cachedL10n = store.l10n
        let seq = nextSequence()
        isLoading = true
        defer {
            if boundTaskId == taskId {
                isLoading = false
            }
        }
        do {
            let loaded = try await store.taskManager.review(taskId)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            errorMessage = nil
            applyReview(loaded, store: store, taskId: taskId)
            prefetchSelectedGroupMetadata(store: store)
        } catch {
            guard boundTaskId == taskId, seq == updateSeq else { return }
            errorMessage = error.localizedDescription
        }
    }

    func prefetchSelectedGroupMetadata(store: AppStore) {
        guard let g = selectedGroup else { return }
        let d = decision(for: g.id)
        guard g.kind == .episode, let match = effectiveMatch(g, d) else { return }
        let tmdbId = match.tmdbId

        if g.show?.info.tmdbId != tmdbId, fetchedShows[tmdbId] == nil {
            ensureShowLoaded(store: store, tmdbId: tmdbId)
        }
        ensureEpisodeGroupsLoaded(store: store, tmdbId: tmdbId)

        if case .season(let s) = selectedResolvedDetailTab {
            ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: s)
        }
    }

    func ensureShowLoaded(store: AppStore, tmdbId: Int) {
        guard fetchedShows[tmdbId] == nil, showFetchTasks[tmdbId] == nil else { return }
        let gen = fetchGeneration
        let provider = store.currentMetadataProvider()
        showFetchTasks[tmdbId] = Task { [weak self] in
            defer {
                if let self, self.fetchGeneration == gen {
                    self.showFetchTasks.removeValue(forKey: tmdbId)
                }
            }
            guard let show = try? await provider.show(tmdbId), !Task.isCancelled else { return }
            guard let self, self.fetchGeneration == gen else { return }
            self.fetchedShows[tmdbId] = show
            self.handleFetchedShowUpdated(tmdbId: tmdbId)
        }
    }

    private func handleFetchedShowUpdated(tmdbId: Int) {
        invalidateRowDisplayCache()
        recomputeReviewDerivedData()
        recomputeGroupListProjections()
        if !showUnassigned,
           let gid = selectedGroupId,
           let raw = rawGroupById[gid],
           effectiveMatch(raw, review?.decisions[gid])?.tmdbId == tmdbId {
            recomputeSelectedGroupProjections()
        }
    }

    func ensureSeasonEpisodesLoaded(store: AppStore, tmdbId: Int, season: Int) {
        let key = SeasonEpisodesCacheKey(tmdbId: tmdbId, season: season)
        guard seasonEpisodesCache[key] == nil, seasonFetchTasks[key] == nil else { return }
        let gen = fetchGeneration
        let provider = store.currentMetadataProvider()
        seasonFetchTasks[key] = Task { [weak self] in
            defer {
                if let self, self.fetchGeneration == gen {
                    self.seasonFetchTasks.removeValue(forKey: key)
                }
            }
            guard let eps = try? await provider.season(tmdbId, season: season), !Task.isCancelled else { return }
            guard let self, self.fetchGeneration == gen else { return }
            var byNum: [Int: Episode] = [:]
            byNum.reserveCapacity(eps.count)
            var datesByNum: [Int: String] = [:]
            datesByNum.reserveCapacity(eps.count)
            for ep in eps {
                byNum[ep.number] = ep
                if let formatted = formatShortAirDate(ep.airDate) {
                    datesByNum[ep.number] = formatted
                }
            }
            self.seasonEpisodesCache[key] = byNum
            self.seasonAirDatesCache[key] = datesByNum
        }
    }

    func ensureEpisodeGroupsLoaded(store: AppStore, tmdbId: Int) {
        if let existing = episodeGroupsCache[tmdbId] {
            if case .failed = existing {} else { return }
        }
        guard episodeGroupFetchTasks[tmdbId] == nil else { return }
        let gen = fetchGeneration
        episodeGroupsCache[tmdbId] = .loading
        let provider = store.currentMetadataProvider()
        episodeGroupFetchTasks[tmdbId] = Task { [weak self] in
            defer {
                if let self, self.fetchGeneration == gen {
                    self.episodeGroupFetchTasks.removeValue(forKey: tmdbId)
                }
            }
            do {
                let groups = try await provider.episodeGroups(tmdbId)
                guard !Task.isCancelled, let self, self.fetchGeneration == gen else { return }
                self.episodeGroupsCache[tmdbId] = .loaded(groups)
            } catch {
                guard !Task.isCancelled, let self, self.fetchGeneration == gen else { return }
                self.episodeGroupsCache[tmdbId] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - TaskManager Mutations

    private func nextSequence() -> Int {
        updateSeq += 1
        return updateSeq
    }

    @discardableResult
    func updateDecision(
        store: AppStore,
        taskId: TaskId,
        groupId: GroupId,
        decision nextDecision: GroupDecision
    ) async -> Bool {
        let seq = nextSequence()
        pendingMutations += 1
        if let cur = review {
            var nextDecisions = cur.decisions
            nextDecisions[groupId] = nextDecision
            let optimistic = TaskReview(
                id: cur.id,
                scan: cur.scan,
                decisions: nextDecisions,
                preview: cur.preview
            )
            applyOptimisticReview(optimistic, store: store, taskId: taskId, promoteMatchedGroupId: groupId)
        }

        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }

        do {
            let updated = try await store.taskManager.updateDecision(taskId, group: groupId, decision: nextDecision)
            guard boundTaskId == taskId else { return false }
            store.updateTaskCardMeta(id: taskId, review: updated)
            if seq == updateSeq {
                applyReview(updated, store: store, taskId: taskId)
                prefetchSelectedGroupMetadata(store: store)
            }
            return true
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
                if seq == updateSeq {
                    await load(store: store, taskId: taskId)
                }
            }
            return false
        }
    }

    @discardableResult
    func updateManyDecisions(
        store: AppStore,
        taskId: TaskId,
        updates: [GroupId: GroupDecision]
    ) async -> Bool {
        guard !updates.isEmpty else { return true }
        let seq = nextSequence()
        pendingMutations += 1

        if let cur = review {
            var merged = cur.decisions
            for (gid, dec) in updates { merged[gid] = dec }
            let optimistic = TaskReview(id: cur.id, scan: cur.scan, decisions: merged, preview: cur.preview)
            applyOptimisticReview(optimistic, store: store, taskId: taskId)
        }

        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }

        do {
            let batchUpdates = updates.map { (group: $0.key, decision: $0.value) }
            let latest = try await store.taskManager.updateDecisions(taskId, updates: batchUpdates)
            guard boundTaskId == taskId else { return false }
            store.updateTaskCardMeta(id: taskId, review: latest)
            if seq == updateSeq {
                applyReview(latest, store: store, taskId: taskId)
                prefetchSelectedGroupMetadata(store: store)
            }
            return true
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
                if seq == updateSeq {
                    await load(store: store, taskId: taskId)
                }
            }
            return false
        }
    }

    func applyEpisodeShift(
        store: AppStore,
        taskId: TaskId,
        group: MediaGroup,
        allRows: [ReviewRow],
        fromRow: ReviewRow,
        toRef: EpisodeRef,
        kind: MediaKind?
    ) async {
        let groupId = group.id
        let before = decision(for: groupId)
        let shifted = shiftFrom(
            group: group,
            decision: before,
            rows: allRows,
            from: fromRow,
            to: toRef,
            kind: kind ?? fromRow.override?.kind
        )
        var next = before
        for (path, ov) in shifted {
            next.overrides[path] = ov
        }
        let ok = await updateDecision(store: store, taskId: taskId, groupId: groupId, decision: next)
        guard ok, boundTaskId == taskId, shifted.count >= 2 else { return }
        let count = shifted.count - 1
        let l10n = store.l10n
        store.showToast(
            l10n.tr(
                "后面 \(count) 个文件已依次顺延",
                "Shifted \(l10n.plural(count, "following file"))"
            ),
            actionLabel: l10n.undo,
            durationSeconds: 6.0
        ) { [weak self, weak store] in
            guard let self, let store else { return }
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                await self.updateDecision(
                    store: store,
                    taskId: taskId,
                    groupId: groupId,
                    decision: before
                )
            }
        }
    }

    func setOrganizeMode(store: AppStore, taskId: TaskId, mode: OrganizeMode) async {
        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.setMode(taskId, mode: mode)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            applyReview(updated, store: store, taskId: taskId)
        } catch {
            guard boundTaskId == taskId else { return }
            let raw = error.localizedDescription
            let l10n = store.l10n
            if raw.contains("libraryRoot") {
                store.showToast(
                    l10n.tr(
                        "这个连接还没设置媒体库，去「来源」编辑连接后再选",
                        "No library path set for this connection. Edit it in Sources first."
                    ),
                    actionLabel: l10n.tr("去来源", "Sources"),
                    tab: .sources
                )
            } else {
                store.showToast(
                    l10n.tr("没能切换整理方式，请重试", "Could not switch organize mode. Please try again.")
                )
            }
        }
    }

    func setUnassignedDelete(store: AppStore, taskId: TaskId, filePath: String, delete: Bool) async {
        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.setUnassignedDelete(taskId, filePath: filePath, delete: delete)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            applyReview(updated, store: store, taskId: taskId)
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    func setManyUnassignedDeletes(
        store: AppStore,
        taskId: TaskId,
        updates: [String: Bool]
    ) async {
        guard !updates.isEmpty else { return }
        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.setUnassignedDeletes(taskId, updates: updates)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            applyReview(updated, store: store, taskId: taskId)
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    func assignUnassigned(store: AppStore, taskId: TaskId, filePath: String, targetGroup: GroupId) async {
        let targetTitle: String = {
            guard let cur = review,
                  let g = rawGroupById[targetGroup] else {
                return ""
            }
            return effectiveMatch(g, cur.decisions[g.id])?.title ?? g.anchorTitle
        }()

        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.assignUnassigned(taskId, filePath: filePath, targetGroup: targetGroup)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            if updated.scan.unassigned.isEmpty,
               let g = updated.scan.groups.first(where: { $0.id == targetGroup }) {
                withSuppressedRecompute {
                    showUnassigned = false
                    leftTab = isGroupMatched(g, updated.decisions[g.id]) ? .matched : .unmatched
                    filter = .all
                    selectedGroupId = targetGroup
                }
            }
            applyReview(updated, store: store, taskId: taskId)
            prefetchSelectedGroupMetadata(store: store)
            if !targetTitle.isEmpty {
                let l10n = store.l10n
                store.showToast(l10n.tr("已归入「\(targetTitle)」", "Assigned to \"\(targetTitle)\""))
            }
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    func mergeGroups(store: AppStore, taskId: TaskId, keep: GroupId, absorb: GroupId) async {
        let targetTitle: String = {
            guard let cur = review,
                  let g = rawGroupById[keep] else {
                return ""
            }
            return effectiveMatch(g, cur.decisions[g.id])?.title ?? g.anchorTitle
        }()

        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.mergeGroups(taskId, keep: keep, absorb: absorb)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            if let kept = updated.scan.groups.first(where: { $0.id == keep }) {
                withSuppressedRecompute {
                    showUnassigned = false
                    leftTab = isGroupMatched(kept, updated.decisions[kept.id]) ? .matched : .unmatched
                    filter = .all
                    selectedGroupId = keep
                }
            }
            applyReview(updated, store: store, taskId: taskId)
            prefetchSelectedGroupMetadata(store: store)
            if !targetTitle.isEmpty {
                let l10n = store.l10n
                store.showToast(l10n.tr("已合并到「\(targetTitle)」", "Merged into \"\(targetTitle)\""))
            }
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    func splitGroup(store: AppStore, taskId: TaskId, group: GroupId, filePaths: Set<String>) async {
        guard !filePaths.isEmpty, let cur = review else { return }
        let existingIds = Set(cur.scan.groups.map(\.id))

        let seq = nextSequence()
        pendingMutations += 1
        defer {
            if boundTaskId == taskId {
                pendingMutations = max(0, pendingMutations - 1)
            }
        }
        do {
            let updated = try await store.taskManager.splitGroup(taskId, group: group, filePaths: filePaths)
            guard boundTaskId == taskId, seq == updateSeq else { return }
            isMultiSelectMode = false
            multiSelectedPaths.removeAll()
            let created = updated.scan.groups.first(where: { !existingIds.contains($0.id) })
            let createdId = created?.id
            let createdTab: LeftPaneTab? = created.map {
                isGroupMatched($0, updated.decisions[$0.id]) ? .matched : .unmatched
            }
            if let createdId, let createdTab {
                withSuppressedRecompute {
                    showUnassigned = false
                    leftTab = createdTab
                    filter = .all
                    selectedGroupId = createdId
                }
            }
            applyReview(updated, store: store, taskId: taskId)
            if createdId != nil {
                prefetchSelectedGroupMetadata(store: store)
            }
            let l10n = store.l10n
            store.showToast(
                l10n.tr("已拆分为新作品", "Split into a new group"),
                actionLabel: createdId != nil ? l10n.tr("去查看", "View") : nil
            ) { [weak self, weak store] in
                guard let self, let store, let createdId else { return }
                let resolvedTab: LeftPaneTab = {
                    if let curReview = self.review,
                       let g = self.rawGroupById[createdId] {
                        return isGroupMatched(g, curReview.decisions[createdId]) ? .matched : .unmatched
                    }
                    return createdTab ?? .unmatched
                }()
                self.navigateToGroup(createdId, tab: resolvedTab, store: store)
            }
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    // MARK: - Execution, Merge & Permanent Delete Flow (`review_page.dart:702-795`)

    func blockedExecuteReason(scrapeOnly: Bool, l10n: AppL10n) -> String? {
        if isExecuting {
            return scrapeOnly
                ? l10n.tr("正在刮削，请稍候", "Scraping, please wait")
                : l10n.tr("正在整理，请稍候", "Organizing, please wait")
        }
        if pendingMutations > 0 {
            return l10n.tr("正在更新整理计划，请稍候", "Updating plan, please wait")
        }
        guard let review, let index else {
            return l10n.tr("正在读取识别结果…", "Loading review…")
        }
        let conflicts = review.preview.conflicts.count
        let merges = selectedMerges
        if conflicts > 0 && merges.isEmpty {
            return l10n.tr("存在冲突，请先处理", "Resolve conflicts first")
        }
        if index.selectedOpsCount == 0 {
            let matched = review.scan.groups.filter { isGroupMatched($0, review.decisions[$0.id]) }
            let selected = matched.filter { review.decisions[$0.id]?.selected ?? true }
            if matched.isEmpty {
                return l10n.tr("没有可整理的作品，请先手动匹配", "No matched titles; match manually first")
            }
            if selected.isEmpty {
                return l10n.tr("未勾选作品，请在左侧勾选", "No titles selected; check titles on the left")
            }
            if review.preview.ops.contains(where: { $0.warning != nil }) {
                return l10n.tr("有文件需要确认，请勾选文件或修正对应关系", "Some files need review; check files or adjust episodes")
            }
            let hasActiveVideo = selected.contains { g in
                g.files.contains { f in
                    f.role == .video && !(review.decisions[g.id]?.overrides[f.path]?.ignore ?? false)
                }
            }
            if hasActiveVideo {
                return l10n.tr("没有可执行的改动，请检查文件对应关系", "No executable changes; check file mappings")
            }
            return l10n.tr("未选择可整理的文件，请勾选文件", "No files selected; check files to organize")
        }
        return nil
    }

    func triggerExecute(store: AppStore, taskId: TaskId, scrapeOnly: Bool) async {
        guard !isExecuting, pendingMutations == 0, let r = review else { return }
        guard blockedExecuteReason(scrapeOnly: scrapeOnly, l10n: store.l10n) == nil else {
            return
        }
        let merges = selectedMerges
        if !r.preview.conflicts.isEmpty && merges.isEmpty {
            let c = r.preview.conflicts.count
            store.showToast(
                store.l10n.tr(
                    "仍有 \(c) 处冲突，请先处理",
                    "Resolve \(store.l10n.plural(c, "remaining conflict")) first"
                )
            )
            return
        }
        if !merges.isEmpty {
            activeSheet = .mergeConfirm(merges: merges)
            return
        }
        await checkDeletesAndRun(store: store, taskId: taskId)
    }

    func confirmMergesAndContinue(
        store: AppStore,
        taskId: TaskId,
        merges: [PlanMerge],
        separateGroupIds: Set<GroupId>
    ) async {
        activeSheet = nil
        var updates: [GroupId: GroupDecision] = [:]
        for m in merges {
            let wantSeparate = separateGroupIds.contains(m.group)
            let cur = decision(for: m.group)
            if cur.separate != wantSeparate {
                var next = cur
                next.separate = wantSeparate
                updates[m.group] = next
            }
        }
        if !updates.isEmpty {
            let ok = await updateManyDecisions(store: store, taskId: taskId, updates: updates)
            guard ok else { return }
        }
        guard let latest = review else { return }
        if !latest.preview.conflicts.isEmpty {
            let c = latest.preview.conflicts.count
            store.showToast(
                store.l10n.tr(
                    "仍有 \(c) 处冲突，可在弹窗中选择「分开保留」或先修改集号",
                    "\(store.l10n.plural(c, "conflict")) remaining — choose \"Keep separate\" in the dialog or adjust episode numbers"
                )
            )
            return
        }
        await checkDeletesAndRun(store: store, taskId: taskId)
    }

    private func checkDeletesAndRun(store: AppStore, taskId: TaskId) async {
        guard let index, index.selectedOpsCount > 0 else { return }
        let deletePaths = index.deleteOpsPaths
        if !deletePaths.isEmpty {
            activeSheet = .confirmPermanentDelete(paths: deletePaths)
            return
        }
        await performRun(store: store, taskId: taskId)
    }

    func confirmPermanentDeleteAndRun(store: AppStore, taskId: TaskId) async {
        activeSheet = nil
        await performRun(store: store, taskId: taskId)
    }

    private func performRun(store: AppStore, taskId: TaskId) async {
        guard !isExecuting, pendingMutations == 0 else { return }
        isExecuting = true
        defer {
            if boundTaskId == taskId {
                isExecuting = false
            }
        }
        do {
            try await store.taskManager.run(taskId, onlyConfident: false)
            if boundTaskId == taskId {
                store.openTaskDetail(taskId)
            }
        } catch {
            if boundTaskId == taskId {
                store.showToast(localizeCoreMessage(store.l10n, error.localizedDescription))
            }
        }
    }

    // MARK: - Conflict Jump & Keyboard Navigation

    func jumpToFirstConflict(store: AppStore) {
        guard let review, let index,
              let loc = firstConflictLocation(in: review, index: index, fetchedShows: fetchedShows),
              let g = rawGroupById[loc.groupId] else {
            return
        }
        withSuppressedRecompute {
            if !searchQuery.isEmpty { searchQuery = "" }
            showUnassigned = false
            leftTab = isGroupMatched(g, review.decisions[g.id]) ? .matched : .unmatched
            if filter != .all && filter != .conflict {
                filter = .all
            }
            selectedGroupId = loc.groupId
            detailTab = loc.tab
            highlightedConflictPath = loc.filePath
        }
        recomputeGroupListProjections()
        recomputeSelectedGroupProjections()
        prefetchSelectedGroupMetadata(store: store)
    }

    func moveGroupSelection(delta: Int, store: AppStore) {
        let threshold = store.settings.confidenceThreshold
        if cachedConfidenceThreshold != threshold {
            cachedConfidenceThreshold = threshold
            invalidateRowDisplayCache()
            recomputeGroupListProjections()
        }
        let visible = visibleGroups
        guard !visible.isEmpty else { return }
        let currentIdx = showUnassigned ? nil : visible.firstIndex(where: { $0.id == selectedGroupId })
        let nextIdx: Int
        if let currentIdx {
            nextIdx = currentIdx + delta
        } else {
            nextIdx = delta > 0 ? 0 : visible.count - 1
        }
        guard nextIdx >= 0 && nextIdx < visible.count else { return }
        selectGroup(visible[nextIdx].id, store: store)
    }

    func moveDetailTab(delta: Int, store: AppStore) {
        guard !showUnassigned, selectedGroup != nil else { return }
        let tabs = selectedAvailableDetailTabs
        guard !tabs.isEmpty else { return }
        let currentIdx = tabs.firstIndex(of: selectedResolvedDetailTab) ?? 0
        let nextIdx = currentIdx + delta
        guard nextIdx >= 0 && nextIdx < tabs.count else { return }
        detailTab = tabs[nextIdx]
        prefetchSelectedGroupMetadata(store: store)
    }

    func toggleSelectedGroupChecked(store: AppStore, taskId: TaskId) async {
        guard !showUnassigned, let gid = selectedGroupId else { return }
        var d = decision(for: gid)
        d.selected.toggle()
        await updateDecision(store: store, taskId: taskId, groupId: gid, decision: d)
    }
}
