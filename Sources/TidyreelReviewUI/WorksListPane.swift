import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct WorksListPane: View {
    let store: AppStore
    let taskId: TaskId
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let review = viewModel.review
        let index = viewModel.index
        let matchedBase = viewModel.matchedGroups
        let unmatchedBase = viewModel.unmatchedGroups
        let visible = viewModel.visibleGroups
        let canMerge = (review?.scan.groups.count ?? 0) >= 2
        let unassignedFiles = review?.scan.unassigned ?? []
        let unassignedDeletes = index?.plannedUnassignedDeletes.count ?? 0

        VStack(alignment: .leading, spacing: 0) {
            // 1. Search Field (`搜索作品  ⌘F`)
            searchField
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))

            // 2. Calm Monochrome SlidingSegmented (`可整理 N` | `需手动匹配 M`)
            SlidingSegmented(
                options: [
                    (
                        LeftPaneTab.matched,
                        l10n.tr("可整理 \(matchedBase.count)", "Matched \(matchedBase.count)")
                    ),
                    (
                        LeftPaneTab.unmatched,
                        l10n.tr("需手动匹配 \(unmatchedBase.count)", "Unmatched \(unmatchedBase.count)")
                    ),
                ],
                selection: viewModel.leftTab
            ) { nextTab in
                viewModel.selectLeftTab(nextTab, store: store)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))

            // 3. Quick Filter Chips + Bulk Selection Links (Matched tab)
            if viewModel.leftTab == .matched && !matchedBase.isEmpty, review != nil, index != nil {
                filterAndBulkToolbar(visible: visible)
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
            }

            // 4. Virtualized `_GroupCard` List
            if visible.isEmpty {
                emptyWorksState(
                    matchedCount: matchedBase.count,
                    unmatchedCount: unmatchedBase.count
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review, let index {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visible) { group in
                                GroupCardView(
                                    store: store,
                                    group: group,
                                    decision: review.decisions[group.id] ?? GroupDecision(),
                                    hasConflict: index.conflictGroups.contains(group.id),
                                    completeness: viewModel.completenessByGroup[group.id],
                                    canSplit: viewModel.hasMultipleVideosByGroup[group.id] ?? false,
                                    isSelected: !viewModel.showUnassigned && viewModel.selectedGroupId == group.id,
                                    canMerge: canMerge,
                                    onSelect: {
                                        viewModel.selectGroup(group.id, store: store)
                                    },
                                    onToggleCheck: { checked in
                                        var d = viewModel.decision(for: group.id)
                                        d.selected = checked
                                        Task {
                                            await viewModel.updateDecision(
                                                store: store,
                                                taskId: taskId,
                                                groupId: group.id,
                                                decision: d
                                            )
                                        }
                                    },
                                    onPickCandidate: { candidate in
                                        var d = viewModel.decision(for: group.id)
                                        if d.episodeGroupId != nil && d.match?.tmdbId != candidate.tmdbId {
                                            d.episodeGroupId = nil
                                        }
                                        d.match = candidate
                                        d.selected = true
                                        Task {
                                            await viewModel.updateDecision(
                                                store: store,
                                                taskId: taskId,
                                                groupId: group.id,
                                                decision: d
                                            )
                                        }
                                    },
                                    onCorrect: {
                                        let m = effectiveMatch(group, review.decisions[group.id])
                                        viewModel.activeSheet = .tmdbSearch(
                                            group: group,
                                            initialQuery: m?.title ?? group.anchorTitle
                                        )
                                    },
                                    onMergeGroup: {
                                        viewModel.activeSheet = .mergeGroup(source: group)
                                    },
                                    onSplitGroup: {
                                        viewModel.activeSheet = .splitGroup(source: group, initialSelection: [])
                                    }
                                )
                                .id(group.id)
                            }
                        }
                        .padding(EdgeInsets(
                            top: 4,
                            leading: 10,
                            bottom: unassignedFiles.isEmpty ? 104 : 12,
                            trailing: 10
                        ))
                    }
                    .onChange(of: viewModel.selectedGroupId) { _, newId in
                        guard let newId, !viewModel.showUnassigned else { return }
                        proxy.scrollTo(newId, anchor: nil)
                    }
                }
            }

            // 5. Pinned Bottom `未归类 N 个文件` Card + 104pt Floating Bar Clearance
            if !unassignedFiles.isEmpty {
                PinnedUnassignedCard(
                    count: unassignedFiles.count,
                    deleteCount: unassignedDeletes,
                    isSelected: viewModel.showUnassigned
                ) {
                    viewModel.showUnassigned = true
                }
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 104, trailing: 8))
            } else if visible.isEmpty {
                Spacer().frame(height: 104)
            }
        }
        .background(palette.sidebar.opacity(0.5))
        .onChange(of: viewModel.searchFocusTrigger) { _, _ in
            isSearchFocused = true
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)

            TextField(
                l10n.tr("搜索作品  ⌘F", "Search titles  ⌘F"),
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { newVal in
                        viewModel.updateSearchQuery(newVal, store: store)
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: TidyreelTypeScale.body))
            .foregroundStyle(palette.text)
            .focused($isSearchFocused)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.updateSearchQuery("", store: store)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textFaint)
                }
                .buttonStyle(.plain)
                .help(l10n.tr("清空搜索", "Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? palette.text.opacity(0.55) : palette.lineStrong,
                    lineWidth: isSearchFocused ? 1.0 : hairlineWidth
                )
        )
    }

    // MARK: - Quick Filter Chips & Bulk Selection (`review_page.dart:1104-1228`)

    private func filterAndBulkToolbar(visible: [MediaGroup]) -> some View {
        let conflictCount = viewModel.conflictCount
        let incompleteCount = viewModel.incompleteCount
        let lowConfCount = viewModel.lowConfidenceCount
        let selectedVisibleCount = viewModel.selectedVisibleCount

        return VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ReviewFilterChipView(
                        label: l10n.tr("全部", "All"),
                        tint: nil,
                        isDarkWarning: false,
                        isSelected: viewModel.filter == .all
                    ) {
                        viewModel.selectFilter(.all, store: store)
                    }

                    if conflictCount > 0 || viewModel.filter == .conflict {
                        ReviewFilterChipView(
                            label: l10n.tr("冲突 \(conflictCount)", "Conflicts \(conflictCount)"),
                            tint: palette.danger,
                            isDarkWarning: false,
                            isSelected: viewModel.filter == .conflict
                        ) {
                            viewModel.selectFilter(.conflict, store: store)
                        }
                    }

                    if incompleteCount > 0 || viewModel.filter == .incomplete {
                        ReviewFilterChipView(
                            label: l10n.tr("缺集 \(incompleteCount)", "Missing \(incompleteCount)"),
                            tint: palette.warning,
                            isDarkWarning: palette.isDark,
                            isSelected: viewModel.filter == .incomplete
                        ) {
                            viewModel.selectFilter(.incomplete, store: store)
                        }
                    }

                    if lowConfCount > 0 || viewModel.filter == .lowConfidence {
                        ReviewFilterChipView(
                            label: l10n.tr("低置信 \(lowConfCount)", "Low conf \(lowConfCount)"),
                            tint: palette.warning,
                            isDarkWarning: palette.isDark,
                            isSelected: viewModel.filter == .lowConfidence
                        ) {
                            viewModel.selectFilter(.lowConfidence, store: store)
                        }
                    }
                }
            }

            if !visible.isEmpty {
                HStack(spacing: 4) {
                    Text(
                        l10n.tr(
                            "已选 \(selectedVisibleCount)/\(visible.count)",
                            "Selected \(selectedVisibleCount)/\(visible.count)"
                        )
                    )
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.textFaint)

                    Spacer()

                    HoverLinkButton(title: l10n.tr("全选", "All")) {
                        var updates: [GroupId: GroupDecision] = [:]
                        for g in visible {
                            var d = viewModel.decision(for: g.id)
                            if !d.selected {
                                d.selected = true
                                updates[g.id] = d
                            }
                        }
                        Task {
                            await viewModel.updateManyDecisions(store: store, taskId: taskId, updates: updates)
                        }
                    }

                    HoverLinkButton(title: l10n.tr("反选", "Invert")) {
                        var updates: [GroupId: GroupDecision] = [:]
                        for g in visible {
                            var d = viewModel.decision(for: g.id)
                            d.selected.toggle()
                            updates[g.id] = d
                        }
                        Task {
                            await viewModel.updateManyDecisions(store: store, taskId: taskId, updates: updates)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private func emptyWorksState(matchedCount: Int, unmatchedCount: Int) -> some View {
        let hasQuery = !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title: String = {
            if hasQuery {
                return l10n.tr("没有符合搜索条件的作品", "No matching titles")
            }
            if viewModel.leftTab == .matched && viewModel.filter != .all {
                return l10n.tr("没有符合筛选条件的作品", "No titles match filter")
            }
            return viewModel.leftTab == .matched
                ? l10n.tr("没有可整理的作品", "No matched titles")
                : l10n.tr("没有需要手动匹配的作品", "No unmatched titles")
        }()

        let otherCount = viewModel.leftTab == .matched ? unmatchedCount : matchedCount

        return EmptyStateCard(icon: "tray", title: title) {
            if viewModel.leftTab == .matched && viewModel.filter != .all {
                QuietTextButton(l10n.tr("显示全部", "Show all")) {
                    viewModel.selectFilter(.all, store: store)
                }
            } else if otherCount > 0 {
                QuietTextButton(
                    viewModel.leftTab == .unmatched
                        ? l10n.tr("查看可整理的 \(otherCount) 个作品", "View \(l10n.plural(otherCount, "matched title"))")
                        : l10n.tr("查看需手动匹配的 \(otherCount) 个作品", "View \(l10n.plural(otherCount, "unmatched title"))")
                ) {
                    viewModel.selectLeftTab(viewModel.leftTab == .matched ? .unmatched : .matched, store: store)
                }
            }
        }
    }
}

// MARK: - Pinned Bottom Unassigned Card (`review_page.dart:1278-1345`)

private struct PinnedUnassignedCard: View {
    let count: Int
    let deleteCount: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let fill: Color = isSelected
            ? palette.selected
            : (isHovered ? palette.hover : .clear)

        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? palette.text : palette.textMuted)

                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        l10n.tr(
                            "未归类 \(count) 个文件",
                            l10n.plural(count, "unassigned file")
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                    Text(
                        deleteCount > 0
                            ? l10n.tr(
                                "其中 \(deleteCount) 个垃圾文件将被永久删除",
                                "\(l10n.plural(deleteCount, "junk file")) marked for permanent deletion"
                            )
                            : l10n.tr(
                                "没归进任何作品，不会被整理",
                                "Not in any title; left untouched"
                            )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(deleteCount > 0 ? palette.danger : palette.textMuted)
                    .lineLimit(2)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? palette.text.opacity(0.35) : .clear,
                        lineWidth: 1.0
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Filter Chip (`ReviewFilterChip` in `review_panes.dart:83-130`)

private struct ReviewFilterChipView: View {
    let label: String
    let tint: Color?
    let isDarkWarning: Bool
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let c = tint ?? palette.text
        let selectedFg: Color = {
            if tint == nil { return palette.canvas }
            if isDarkWarning { return palette.canvas }
            return .white
        }()
        let fill: Color = isSelected
            ? c
            : (isHovered ? c.opacity(0.09) : palette.panel)
        let borderColor: Color = isSelected
            ? c
            : (tint?.opacity(0.35) ?? palette.line)

        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? selectedFg : (tint ?? palette.textMuted))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: hairlineWidth)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct HoverLinkButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isHovered ? palette.text : palette.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Virtualized `_GroupCard` (`review_panes.dart:212-383`)

private struct GroupCardView: View {
    let store: AppStore
    let group: MediaGroup
    let decision: GroupDecision
    let hasConflict: Bool
    let completeness: Completeness?
    let canSplit: Bool
    let isSelected: Bool
    let canMerge: Bool
    let onSelect: () -> Void
    let onToggleCheck: (Bool) -> Void
    let onPickCandidate: (Candidate) -> Void
    let onCorrect: () -> Void
    let onMergeGroup: () -> Void
    let onSplitGroup: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let match = effectiveMatch(group, decision)
        let isTv = group.kind == .episode
        let title = match?.title ?? group.anchorTitle
        let orig = match?.originalTitle ?? match?.englishTitle
        let comp = isTv ? completeness : nil
        let cardFill: Color = isSelected
            ? palette.selected
            : (isHovered ? palette.hover : .clear)

        VStack(alignment: .leading, spacing: 0) {
            // Top row: InkCheckbox + 44x66 Poster + Title & Tags
            HStack(alignment: .top, spacing: 0) {
                InkCheckbox(isChecked: decision.selected) {
                    onToggleCheck(!decision.selected)
                }
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)

                HStack(alignment: .top, spacing: 10) {
                    DownsampledArtworkView(
                        tmdbPath: match?.posterPath,
                        width: 44,
                        height: 66,
                        cornerRadius: 5,
                        fallbackSystemImage: isTv ? "tv" : "film"
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let orig, !orig.isEmpty, orig != title {
                            Text(orig)
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.textMuted)
                                .lineLimit(1)
                        }

                        Spacer().frame(height: 1)

                        if let match {
                            HStack(spacing: 4) {
                                TagBadge(isTv ? l10n.tvShow : l10n.movie)
                                if hasConflict {
                                    TagBadge(l10n.tr("冲突", "Conflict"), tint: palette.danger)
                                }
                                let metaParts = [
                                    match.year.map { "\($0)" } ?? l10n.tr("年份未知", "Unknown year"),
                                    countryLabel(match.originCountry, l10n: l10n),
                                ].filter { !$0.isEmpty }
                                Text(metaParts.joined(separator: " · "))
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.textMuted)
                                    .lineLimit(1)
                                    .padding(.leading, 2)
                            }
                        } else {
                            HStack(spacing: 4) {
                                TagBadge(l10n.tr("未能识别", "Unmatched"), tint: palette.danger)
                                if hasConflict {
                                    TagBadge(l10n.tr("冲突", "Conflict"), tint: palette.danger)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
            }

            // Bottom section (indented 28pt to align with poster):
            // TV completeness bar, Movie file count, or Inline TMDB Search Box when unmatched!
            if match != nil {
                if isTv, let comp {
                    VStack(alignment: .leading, spacing: 4) {
                        if let frac = comp.progressFraction {
                            GeometryReader { barGeo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(palette.line)
                                    Capsule()
                                        .fill(comp.incomplete ? palette.warning : palette.success)
                                        .frame(width: max(4, barGeo.size.width * frac))
                                }
                            }
                            .frame(height: 4)
                        }
                        Text(comp.localizedLabel(l10n))
                            .font(.system(size: TidyreelTypeScale.small, weight: comp.incomplete ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(comp.incomplete ? palette.warning : palette.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.top, 8)
                    .padding(.leading, 28)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                } else {
                    Text(l10n.tr("\(group.files.count) 个文件", l10n.plural(group.files.count, "file")))
                        .font(.system(size: TidyreelTypeScale.small))
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 6)
                        .padding(.leading, 28)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onSelect)
                }
            } else {
                TMDBSearchBoxView(
                    store: store,
                    initialQuery: group.anchorTitle,
                    autoSearch: false,
                    compact: true,
                    onPick: onPickCandidate
                )
                .padding(.top, 8)
                .padding(.leading, 28)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .strokeBorder(
                    isSelected ? palette.text.opacity(0.35) : .clear,
                    lineWidth: 1.0
                )
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: onCorrect) {
                Label(l10n.tr("重新搜索 TMDB", "Search TMDB"), systemImage: "magnifyingglass")
            }
            if canMerge {
                Button(action: onMergeGroup) {
                    Label(l10n.tr("合并到其他作品…", "Merge into another title…"), systemImage: "arrow.triangle.merge")
                }
            }
            if canSplit {
                Button(action: onSplitGroup) {
                    Label(l10n.tr("拆分分组…", "Split group…"), systemImage: "scissors")
                }
            }
        }
    }
}
