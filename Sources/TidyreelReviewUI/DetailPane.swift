import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct DetailPane: View {
    let store: AppStore
    let taskId: TaskId
    let group: MediaGroup
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        if let review = viewModel.review, let index = viewModel.index {
            detailContent(review: review, index: index)
        }
    }

    private func detailContent(review: TaskReview, index: ReviewIndex) -> some View {
        let decision = review.decisions[group.id] ?? GroupDecision()
        let match = effectiveMatch(group, decision)
        let allRows = viewModel.selectedGroupRows
        let availableTabs = viewModel.selectedAvailableDetailTabs
        let activeTab = viewModel.selectedResolvedDetailTab
        let mergePlan = index.mergesByGroup[group.id]
        let dupConflicts = viewModel.selectedDuplicateConflicts
        let conflictedRowCount = viewModel.selectedConflictedRowCount
        let overflowHint = viewModel.selectedSeasonOverflow
        let folderTabOps = index.folderTabOpsByGroup[group.id] ?? []
        let detailItems = viewModel.selectedDetailItems
        let canSplit = viewModel.selectedHasMultipleVideos
        let comp = viewModel.completenessByGroup[group.id]

        let activeSeasonNumber: Int? = {
            if case .season(let s) = activeTab { return s }
            return nil
        }()

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 1. WorkHeader + Contextual Banners + Season/Folder Tabs
                    VStack(alignment: .leading, spacing: 10) {
                        WorkHeaderCard(
                            group: group,
                            decision: decision,
                            completeness: comp,
                            activeSeason: activeSeasonNumber,
                            showInspector: viewModel.showInspector,
                            onExpandInspector: {
                                viewModel.showInspector = true
                            },
                            onSearchTMDB: {
                                viewModel.activeSheet = .tmdbSearch(
                                    group: group,
                                    initialQuery: match?.title ?? group.anchorTitle
                                )
                            }
                        )

                        if mergePlan != nil || decision.separate {
                            planMergeBanner(merge: mergePlan, decision: decision)
                        }

                        if !decision.selected {
                            uncheckedBanner(decision: decision, match: match)
                        }

                        if let suggested = group.suggestedStrategy, decision.strategy != suggested {
                            suggestedStrategyBanner(suggested: suggested, decision: decision)
                        }

                        if conflictedRowCount > 0 {
                            conflictBanner(
                                conflictedRowCount: conflictedRowCount,
                                dupConflicts: dupConflicts,
                                decision: decision
                            )
                        }

                        if let overflowHint {
                            overflowBanner(hint: overflowHint, allRows: allRows)
                        }

                        tabsAndSplitToolbar(
                            tabs: availableTabs,
                            activeTab: activeTab,
                            canSplit: canSplit,
                            detailItems: detailItems,
                            folderOpsCount: folderTabOps.count
                        )
                        .padding(.top, 4)
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    // 2. Virtualized Rows inside PanelBox surface
                    switch activeTab {
                    case .allFiles, .season, .extras:
                        if detailItems.isEmpty {
                            PanelBox {
                                EmptyStateCard(
                                    icon: "film",
                                    title: l10n.tr("当前标签页没有文件", "No files in this tab")
                                )
                                .frame(minHeight: 180)
                            }
                        } else {
                            let totalCount = detailItems.count
                            ForEach(Array(detailItems.enumerated()), id: \.element.id) { idx, item in
                                let isFirst = (idx == 0)
                                let isLast = (idx == totalCount - 1)
                                detailItemView(
                                    item: item,
                                    match: match,
                                    decision: decision,
                                    allRows: allRows,
                                    canSplit: canSplit
                                )
                                .background(palette.panel)
                                .clipShape(
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: isFirst ? TidyreelRadii.lg : 0,
                                        bottomLeadingRadius: isLast ? TidyreelRadii.lg : 0,
                                        bottomTrailingRadius: isLast ? TidyreelRadii.lg : 0,
                                        topTrailingRadius: isFirst ? TidyreelRadii.lg : 0,
                                        style: .continuous
                                    )
                                )
                            }
                        }

                    case .folders:
                        folderOperationsList(ops: folderTabOps)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 104)
            }
            .background(palette.canvas)
            .onAppear {
                if let season = activeSeasonNumber, let tmdbId = match?.tmdbId, group.kind == .episode {
                    viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: season)
                }
            }
            .onChange(of: activeSeasonNumber) { _, newSeason in
                if let s = newSeason, let tmdbId = match?.tmdbId, group.kind == .episode {
                    viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: s)
                }
            }
            .onChange(of: viewModel.highlightedConflictPath) { _, targetPath in
                guard let targetPath else { return }
                proxy.scrollTo("path:\(targetPath)", anchor: .center)
            }
        }
    }

    // MARK: - Contextual Banners (`review_panes.dart:895-1065`)

    private func planMergeBanner(
        merge: PlanMerge?,
        decision: GroupDecision
    ) -> some View {
        let otherGroup = merge?.withGroup.flatMap { gid in
            viewModel.rawGroup(for: gid)
        }
        let desc: String = {
            if decision.separate {
                return l10n.tr(
                    "已设为分开保留独立文件夹，不与已有同名目录合并。",
                    "Set to keep a separate folder instead of merging into an existing directory."
                )
            }
            if let merge {
                if merge.exists {
                    return l10n.tr(
                        "目标位置已有同名目录「\(merge.into)」，默认合并放入该目录。",
                        "Folder \"\(merge.into)\" already exists; episodes merge into it by default."
                    )
                }
                if let otherGroup {
                    return l10n.tr(
                        "将与本次的「\(otherGroup.rootDir)」合并放入「\(merge.into)」。",
                        "Will merge with \"\(otherGroup.rootDir)\" from this batch into \"\(merge.into)\"."
                    )
                }
                return l10n.tr(
                    "将合并放入「\(merge.into)」。",
                    "Will merge into \"\(merge.into)\"."
                )
            }
            return ""
        }()

        return HStack(spacing: 10) {
            Image(systemName: decision.separate ? "folder" : "arrow.triangle.merge")
                .font(.system(size: 13))
                .foregroundStyle(palette.textMuted)

            Text(desc)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.text)
                .lineLimit(2)

            Spacer(minLength: 8)

            SlidingSegmented(
                options: [
                    (false, l10n.tr("合并", "Merge")),
                    (true, l10n.tr("分开保留", "Keep Separate")),
                ],
                selection: decision.separate
            ) { wantSeparate in
                var next = decision
                next.separate = wantSeparate
                Task {
                    await viewModel.updateDecision(
                        store: store,
                        taskId: taskId,
                        groupId: group.id,
                        decision: next
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.line, lineWidth: hairlineWidth)
        )
    }

    private func uncheckedBanner(decision: GroupDecision, match: Candidate?) -> some View {
        HStack(spacing: 8) {
            Text(
                match == nil
                    ? l10n.tr(
                        "还没有匹配作品，整理时会跳过。请搜索并选定 TMDB 作品。",
                        "Not matched yet and will be skipped. Search and select a TMDB title."
                    )
                    : l10n.tr(
                        "这个作品没有勾选，整理时会跳过。在左侧列表勾选它即可。",
                        "This title is unchecked and will be skipped. Check it in the left sidebar to include it."
                    )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.text)

            Spacer(minLength: 8)

            if match == nil {
                QuietTextButton(l10n.tr("重新搜索 TMDB", "Search TMDB"), fontSize: TidyreelTypeScale.small) {
                    viewModel.activeSheet = .tmdbSearch(group: group, initialQuery: group.anchorTitle)
                }
            } else {
                QuietTextButton(l10n.tr("勾选作品", "Include title"), fontSize: TidyreelTypeScale.small) {
                    var next = decision
                    next.selected = true
                    Task {
                        await viewModel.updateDecision(store: store, taskId: taskId, groupId: group.id, decision: next)
                    }
                }
            }

            if !viewModel.showInspector {
                QuietTextButton(l10n.tr("展开作品操作", "Show Inspector"), fontSize: TidyreelTypeScale.small) {
                    viewModel.showInspector = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.warning.opacity(0.10))
        )
    }

    private func suggestedStrategyBanner(suggested: SeasonStrategy, decision: GroupDecision) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(palette.accent)

            Text(
                group.suggestedStrategyReason.map { localizeCoreMessage(l10n, $0) }
                    ?? l10n.tr(
                        "建议使用「\(localizedStrategyInfo(suggested, l10n: l10n).title)」",
                        "Recommended: \"\(localizedStrategyInfo(suggested, l10n: l10n).title)\""
                    )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.text)
            .lineLimit(2)

            Spacer(minLength: 8)

            PrimaryActionButton(l10n.tr("一键应用", "Apply")) {
                var next = decision
                next.strategy = suggested
                Task {
                    await viewModel.updateDecision(store: store, taskId: taskId, groupId: group.id, decision: next)
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.25), lineWidth: hairlineWidth)
        )
    }

    private func conflictBanner(
        conflictedRowCount: Int,
        dupConflicts: [GroupDuplicateConflict],
        decision: GroupDecision
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(palette.danger)

            Text(
                !dupConflicts.isEmpty
                    ? l10n.tr(
                        "本作品存在 \(dupConflicts.count) 处同名冲突，可保留体积较大者或逐个修改集号/忽略",
                        "\(l10n.plural(dupConflicts.count, "duplicate name conflict")) in this title — keep the largest file or edit/ignore individual rows"
                    )
                    : l10n.tr(
                        "本作品有 \(conflictedRowCount) 个文件存在目标路径冲突，请修改集号或忽略",
                        "\(l10n.plural(conflictedRowCount, "file")) in this title have target path conflicts — adjust episode numbers or ignore"
                    )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.danger)
            .lineLimit(2)

            Spacer(minLength: 8)

            if !dupConflicts.isEmpty {
                PrimaryActionButton(l10n.tr("保留体积较大者", "Keep Largest")) {
                    var next = decision
                    next.overrides = resolveKeepLargestOverrides(current: decision, conflicts: dupConflicts)
                    Task {
                        await viewModel.updateDecision(store: store, taskId: taskId, groupId: group.id, decision: next)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.danger.opacity(0.25), lineWidth: hairlineWidth)
        )
    }

    private func overflowBanner(hint: SeasonOverflowHint, allRows: [ReviewRow]) -> some View {
        let targetTag = String(format: "S%02dE%02d", hint.target.season, hint.target.episode)
        let nextSeasonTag = String(format: "S%02dE01", hint.target.season + 1)

        return HStack(spacing: 8) {
            Text(
                l10n.tr(
                    "「\(hint.row.file.name)」排到了 \(targetTag)，但 TMDB 第 \(hint.target.season) 季只有 \(hint.seasonMax) 集。要改成 \(nextSeasonTag)，后面的文件依次顺延吗？",
                    "\"\(hint.row.file.name)\" maps to \(targetTag), but TMDB Season \(hint.target.season) only has \(hint.seasonMax) episodes. Move to \(nextSeasonTag) and shift following files?"
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.text)
            .lineLimit(2)

            Spacer(minLength: 8)

            PrimaryActionButton(l10n.tr("改成并顺延", "Move & Shift")) {
                Task {
                    await viewModel.applyEpisodeShift(
                        store: store,
                        taskId: taskId,
                        group: group,
                        allRows: allRows,
                        fromRow: hint.row,
                        toRef: EpisodeRef(hint.target.season + 1, 1),
                        kind: hint.row.override?.kind
                    )
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.warning.opacity(0.10))
        )
    }

    // MARK: - Season / Folder Tabs & Multi-Select Split Bar (`review_panes.dart:1067-1092`)

    private func tabsAndSplitToolbar(
        tabs: [DetailTab],
        activeTab: DetailTab,
        canSplit: Bool,
        detailItems: [DetailListItem],
        folderOpsCount: Int
    ) -> some View {
        let isSelecting = viewModel.isMultiSelectMode || !viewModel.multiSelectedPaths.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs, id: \.self) { tab in
                            seasonTabChip(
                                tab: tab,
                                isSelected: activeTab == tab,
                                folderOpsCount: folderOpsCount
                            )
                        }
                    }
                }

                Spacer(minLength: 4)

                if canSplit && !isSelecting && activeTab != .folders {
                    QuietTextButton(
                        l10n.tr("多选拆分", "Select to split"),
                        systemImage: "scissors",
                        fontSize: TidyreelTypeScale.small
                    ) {
                        viewModel.isMultiSelectMode = true
                    }
                    .help(l10n.tr("勾选多个文件拆分出新作品（也可按住 ⌘ 点击文件行）", "Select multiple files to split into a new group (or ⌘-click rows)"))
                }
            }

            if isSelecting && canSplit {
                multiSelectSplitBar(detailItems: detailItems)
            }
        }
    }

    private func seasonTabChip(
        tab: DetailTab,
        isSelected: Bool,
        folderOpsCount: Int
    ) -> some View {
        let match = effectiveMatch(group, viewModel.decision(for: group.id))
        let detailShow = (group.show?.info.tmdbId == match?.tmdbId) ? group.show : nil

        let label: String
        let posterPath: String?
        let systemImage: String?
        let chipColor: Color?

        switch tab {
        case .allFiles:
            let count = viewModel.selectedMovieRowCount
            label = l10n.tr("全部 \(count)", "All \(count)")
            posterPath = nil
            systemImage = nil
            chipColor = nil

        case .season(let s):
            let countStr = viewModel.selectedSeasonCountLabels[s] ?? "0"
            label = "\(seasonTabTitle(s, l10n: l10n)) (\(countStr))"
            posterPath = detailShow?.seasons.first(where: { $0.number == s })?.posterPath
            systemImage = nil
            chipColor = seasonBadgeColor(s, isDark: palette.isDark)

        case .extras:
            let count = viewModel.selectedExtrasRowCount
            label = "\(l10n.tr("花絮", "Extras")) (\(count))"
            posterPath = nil
            systemImage = "sparkles.tv"
            chipColor = nil

        case .folders:
            let suffix = folderOpsCount > 0 ? " (\(folderOpsCount))" : ""
            label = "\(l10n.tr("文件夹", "Folders"))\(suffix)"
            posterPath = nil
            systemImage = "folder"
            chipColor = nil
        }

        return SeasonTabChipView(
            label: label,
            posterPath: posterPath,
            systemImage: systemImage,
            color: chipColor,
            isSelected: isSelected
        ) {
            viewModel.detailTab = tab
            viewModel.prefetchSelectedGroupMetadata(store: store)
        }
    }

    private func multiSelectSplitBar(detailItems: [DetailListItem]) -> some View {
        let effectiveSplitPaths = expandedSplitPaths(from: viewModel.multiSelectedPaths, detailItems: detailItems)
        let validSplit = !effectiveSplitPaths.isEmpty && effectiveSplitPaths.count < group.files.count

        let visibleFilePaths: [String] = detailItems.compactMap { item in
            switch item {
            case .video(let r, _, _): return r.file.path
            case .companion(let r, _, _): return r.file.path
            case .looseSidecar(let r, _): return r.file.path
            case .companionToggle, .missingEpisode: return nil
            }
        }

        return HStack(spacing: 8) {
            Text(
                l10n.tr(
                    "已选 \(effectiveSplitPaths.count) / \(group.files.count) 个文件",
                    "Selected \(effectiveSplitPaths.count) / \(group.files.count) files"
                )
            )
            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(palette.text)

            if effectiveSplitPaths.count >= group.files.count {
                Text(l10n.tr("（原分组至少保留 1 个文件）", "(Keep at least 1 file in original group)"))
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.warning)
            }

            Spacer()

            if !visibleFilePaths.isEmpty {
                QuietTextButton(l10n.tr("全选本页", "Select tab"), fontSize: TidyreelTypeScale.small) {
                    for p in visibleFilePaths {
                        viewModel.multiSelectedPaths.insert(p)
                    }
                }
            }

            SecondaryActionButton(l10n.cancel) {
                viewModel.isMultiSelectMode = false
                viewModel.multiSelectedPaths.removeAll()
            }

            PrimaryActionButton(
                l10n.tr("拆分 (\(effectiveSplitPaths.count))", "Split (\(effectiveSplitPaths.count))"),
                systemImage: "scissors",
                isDisabled: !validSplit
            ) {
                Task {
                    await viewModel.splitGroup(
                        store: store,
                        taskId: taskId,
                        group: group.id,
                        filePaths: effectiveSplitPaths
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
        )
    }

    private func expandedSplitPaths(from selected: Set<String>, detailItems: [DetailListItem]) -> Set<String> {
        var out = selected
        for item in detailItems {
            if case .video(let v, let comps, _) = item, selected.contains(v.file.path) {
                for c in comps {
                    out.insert(c.file.path)
                }
            }
        }
        return out
    }

    // MARK: - Virtualized Row Dispatch

    @ViewBuilder
    private func detailItemView(
        item: DetailListItem,
        match: Candidate?,
        decision: GroupDecision,
        allRows: [ReviewRow],
        canSplit: Bool
    ) -> some View {
        let isSelecting = viewModel.isMultiSelectMode || !viewModel.multiSelectedPaths.isEmpty
        let confidenceThreshold = store.settings.confidenceThreshold
        switch item {
        case .video(let row, let companions, let showsBottomDivider):
            let cacheKey: SeasonEpisodesCacheKey? = (group.kind == .episode && match != nil && row.targetRef != nil)
                ? SeasonEpisodesCacheKey(tmdbId: match!.tmdbId, season: row.targetRef!.season)
                : nil
            let tmdbEp: Episode? = cacheKey.flatMap { key in
                row.targetRef.flatMap { viewModel.seasonEpisodesCache[key]?[$0.episode] }
            }
            let formattedAirDate: String? = cacheKey.flatMap { key in
                row.targetRef.flatMap { viewModel.seasonAirDatesCache[key]?[$0.episode] }
            }
            let isTvMatched = group.kind == .episode && match != nil
            let display = viewModel.episodeRowDisplay(
                for: row,
                isTvMatched: isTvMatched,
                manuallyMatched: decision.match != nil,
                confidenceThreshold: confidenceThreshold,
                palette: palette,
                l10n: l10n
            )

            DetailEpisodeRowView(
                row: row,
                display: display,
                isTvMatched: isTvMatched,
                isTvGroup: group.kind == .episode,
                tmdbEpisode: tmdbEp,
                formattedAirDate: formattedAirDate,
                isHighlighted: viewModel.highlightedConflictPath == row.file.path,
                isMultiSelectMode: isSelecting,
                isMultiSelected: viewModel.multiSelectedPaths.contains(row.file.path),
                canSplitGroup: canSplit,
                showsBottomDivider: showsBottomDivider,
                onPrimaryClick: {
                    if isSelecting || NSEvent.modifierFlags.contains(.command) {
                        toggleMultiSelect(path: row.file.path)
                    } else {
                        viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                    }
                },
                onToggleInclude: { include in
                    toggleRowIncluded(row: row, include: include, decision: decision)
                },
                onToggleMultiSelect: {
                    toggleMultiSelect(path: row.file.path)
                },
                onOpenEdit: {
                    viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                },
                onSplitSingle: {
                    var paths: Set<String> = [row.file.path]
                    for c in companions { paths.insert(c.file.path) }
                    if paths.count < group.files.count {
                        Task {
                            await viewModel.splitGroup(
                                store: store,
                                taskId: taskId,
                                group: group.id,
                                filePaths: paths
                            )
                        }
                    } else {
                        viewModel.activeSheet = .splitGroup(source: group, initialSelection: [row.file.path])
                    }
                }
            )
            .id("path:\(row.file.path)")

        case .companionToggle(let videoPath, let summary, let isOpen, let showsBottomDivider):
            CompanionFoldToggleRow(
                summary: summary,
                isOpen: isOpen,
                showsBottomDivider: showsBottomDivider
            ) {
                if viewModel.expandedVideoPaths.contains(videoPath) {
                    viewModel.expandedVideoPaths.remove(videoPath)
                } else {
                    viewModel.expandedVideoPaths.insert(videoPath)
                }
            }

        case .companion(let row, _, let showsBottomDivider):
            let display = viewModel.sidecarRowDisplay(
                for: row,
                confidenceThreshold: confidenceThreshold,
                palette: palette,
                l10n: l10n
            )
            DetailSidecarRowView(
                row: row,
                display: display,
                isIndented: true,
                isHighlighted: viewModel.highlightedConflictPath == row.file.path,
                isMultiSelectMode: isSelecting,
                isMultiSelected: viewModel.multiSelectedPaths.contains(row.file.path),
                showsBottomDivider: showsBottomDivider,
                onPrimaryClick: {
                    if isSelecting || NSEvent.modifierFlags.contains(.command) {
                        toggleMultiSelect(path: row.file.path)
                    } else {
                        viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                    }
                },
                onToggleInclude: { include in
                    toggleRowIncluded(row: row, include: include, decision: decision)
                },
                onToggleMultiSelect: {
                    toggleMultiSelect(path: row.file.path)
                },
                onOpenEdit: {
                    viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                }
            )
            .id("path:\(row.file.path)")

        case .looseSidecar(let row, let showsBottomDivider):
            let display = viewModel.sidecarRowDisplay(
                for: row,
                confidenceThreshold: confidenceThreshold,
                palette: palette,
                l10n: l10n
            )
            DetailSidecarRowView(
                row: row,
                display: display,
                isIndented: false,
                isHighlighted: viewModel.highlightedConflictPath == row.file.path,
                isMultiSelectMode: isSelecting,
                isMultiSelected: viewModel.multiSelectedPaths.contains(row.file.path),
                showsBottomDivider: showsBottomDivider,
                onPrimaryClick: {
                    if isSelecting || NSEvent.modifierFlags.contains(.command) {
                        toggleMultiSelect(path: row.file.path)
                    } else {
                        viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                    }
                },
                onToggleInclude: { include in
                    toggleRowIncluded(row: row, include: include, decision: decision)
                },
                onToggleMultiSelect: {
                    toggleMultiSelect(path: row.file.path)
                },
                onOpenEdit: {
                    viewModel.activeSheet = .editRow(group: group, row: row, allRows: allRows)
                }
            )
            .id("path:\(row.file.path)")

        case .missingEpisode(let season, let epNum, let showsBottomDivider):
            let cacheKey = match.map { SeasonEpisodesCacheKey(tmdbId: $0.tmdbId, season: season) }
            let tmdbEp: Episode? = cacheKey.flatMap { viewModel.seasonEpisodesCache[$0]?[epNum] }
            let formattedAirDate: String? = cacheKey.flatMap { viewModel.seasonAirDatesCache[$0]?[epNum] }
            DetailMissingEpisodeRowView(
                season: season,
                episode: epNum,
                tmdbEpisode: tmdbEp,
                formattedAirDate: formattedAirDate,
                showsBottomDivider: showsBottomDivider
            )
        }
    }

    private func toggleMultiSelect(path: String) {
        if viewModel.multiSelectedPaths.contains(path) {
            viewModel.multiSelectedPaths.remove(path)
        } else {
            viewModel.multiSelectedPaths.insert(path)
        }
    }

    private func toggleRowIncluded(row: ReviewRow, include: Bool, decision: GroupDecision) {
        var next = decision
        let old = row.override
        next.overrides[row.file.path] = FileOverride(
            season: old?.season,
            episode: old?.episode,
            kind: old?.kind,
            ignore: !include
        )
        Task {
            await viewModel.updateDecision(
                store: store,
                taskId: taskId,
                groupId: group.id,
                decision: next
            )
        }
    }

    // MARK: - Folders Tab (`_FolderOps` in `review_panes.dart:2103-2190`)

    @ViewBuilder
    private func folderOperationsList(ops: [RenameOp]) -> some View {
        if ops.isEmpty {
            PanelBox {
                EmptyStateCard(
                    icon: "folder",
                    title: l10n.tr("没有文件夹操作", "No folder operations")
                )
                .frame(minHeight: 180)
            }
        } else {
            PanelBox(padding: EdgeInsets()) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ops.enumerated()), id: \.element.id) { idx, op in
                        folderOpRow(op: op, showsBottomDivider: idx < ops.count - 1)
                    }
                }
            }
        }
    }

    private func folderOpRow(op: RenameOp, showsBottomDivider: Bool) -> some View {
        let isConflict = viewModel.index?.conflictByOp[op.id] != nil
        let iconName: String = {
            switch op.kind {
            case .mkdir: return "folder.badge.plus"
            case .delete, .healthDeleteFile, .healthDeleteEmptyDirectory: return "trash"
            case .relocate: return "arrow.right.square"
            case .write: return op.dst.lowercased().hasSuffix(".nfo") ? "doc.text" : "photo"
            }
        }()

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(
                    isConflict ? palette.danger : (op.kind == .delete ? palette.danger : palette.textMuted)
                )
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                switch op.kind {
                case .mkdir:
                    Text(l10n.tr("新建 \(op.dst)", "Create \(op.dst)"))
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                case .delete, .healthDeleteFile, .healthDeleteEmptyDirectory:
                    Text(l10n.tr("删除 \(op.src)", "Delete \(op.src)"))
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                case .relocate:
                    Text(op.src)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textFaint)
                    Text("→ \(op.dst)")
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                case .write:
                    Text(l10n.tr("写入 \(op.dst)", "Write \(op.dst)"))
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                    if let warning = op.warning {
                        Text(localizeCoreMessage(l10n, warning))
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.warning)
                    }
                }
            }

            Spacer(minLength: 8)

            if isConflict {
                TagBadge(l10n.tr("冲突", "Conflict"), tint: palette.danger)
            } else if let warning = op.warning, op.kind != .write {
                TagBadge(localizeCoreMessage(l10n, warning), tint: palette.warning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 44)
            }
        }
    }
}

// MARK: - Season Tab Chip (`_SeasonChip` in `review_panes.dart:1307-1391`)

private struct SeasonTabChipView: View {
    let label: String
    let posterPath: String?
    let systemImage: String?
    let color: Color?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let baseColor = color ?? palette.text
        let selectedFg: Color = (color == nil) ? palette.canvas : .white
        let fill: Color = isSelected
            ? baseColor
            : (isHovered ? baseColor.opacity(0.07) : palette.panel)
        let borderColor: Color = isSelected
            ? baseColor
            : (color?.opacity(0.35) ?? palette.line)

        Button(action: action) {
            HStack(spacing: 0) {
                if let posterPath, !posterPath.isEmpty {
                    DownsampledArtworkView(
                        tmdbPath: posterPath,
                        sizeBucket: "w92",
                        width: 16,
                        height: 24,
                        cornerRadius: 3,
                        showsBorder: false
                    )
                    .padding(.trailing, 7)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isSelected ? selectedFg : palette.textMuted)
                        .padding(.trailing, 5)
                } else if let color {
                    Circle()
                        .fill(isSelected ? selectedFg : color)
                        .frame(width: 7, height: 7)
                        .padding(.trailing, 6)
                }

                Text(label)
                    .font(.system(size: TidyreelTypeScale.small, weight: isSelected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? selectedFg : palette.text)
                    .lineLimit(1)
            }
            .padding(.leading, posterPath != nil ? 4 : 10)
            .padding(.trailing, 11)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? hairlineWidth : 1.0)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
