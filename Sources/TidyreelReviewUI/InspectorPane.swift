import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct InspectorPane: View {
    let store: AppStore
    let taskId: TaskId
    let group: MediaGroup
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var customTitleText: String = ""
    @State private var offsetText: String = "0"

    private var rawGroup: MediaGroup? {
        viewModel.rawGroup(for: group.id)
    }

    var body: some View {
        let decision = viewModel.decision(for: group.id)
        let match = effectiveMatch(group, decision)
        let isTv = group.kind == .episode
        let canMerge = (viewModel.review?.scan.groups.count ?? 0) >= 2
        let canSplit = viewModel.selectedHasMultipleVideos
        let hasMergePlan = viewModel.index?.mergesByGroup[group.id] != nil

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 匹配 (`Match` + Custom Title Override)
                matchSection(decision: decision, match: match, isTv: isTv)

                // 2. 季集策略 (`SeasonStrategy`)
                if isTv {
                    seasonStrategySection(decision: decision)

                    // 3. 剧集组 (`EpisodeGroup`)
                    episodeGroupSection(decision: decision, match: match)

                    // 4. 集数偏移 (`episodeOffset`)
                    episodeOffsetSection(decision: decision)
                }

                // 5. 目录合并 (`PlanMerge` / `separate`)
                if hasMergePlan || decision.separate {
                    folderMergeSection(decision: decision)
                }

                // 6. 分组 (`Group`: Merge / Split)
                if canMerge || canSplit {
                    groupActionsSection(canMerge: canMerge, canSplit: canSplit)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 104, trailing: 18))
        }
        .background(palette.canvas)
        .onAppear {
            syncFields(decision: decision, match: match)
        }
        .onChange(of: group.id) { _, newId in
            let nextDecision = viewModel.decision(for: newId)
            syncFields(decision: nextDecision, match: effectiveMatch(group, nextDecision))
        }
        .onChange(of: decision.episodeOffset) { _, newOffset in
            syncOffsetField(newOffset)
        }
        .onChange(of: match?.title) { _, newTitle in
            customTitleText = newTitle ?? ""
        }
    }

    // MARK: - 1. Match & Custom Title Override (`review_panes.dart:2405-2445`)

    private func matchSection(decision: GroupDecision, match: Candidate?, isTv: Bool) -> some View {
        let baseTitle: String? = {
            if let showInfo = group.show?.info, showInfo.tmdbId == match?.tmdbId {
                return showInfo.title
            }
            if let rawMatch = rawGroup?.match, rawMatch.tmdbId == match?.tmdbId {
                return rawMatch.title
            }
            return nil
        }()
        let hasCustomTitle: Bool = {
            guard let dm = decision.match, let baseTitle else { return false }
            return dm.title != baseTitle
        }()

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("匹配", "Match")) {
                if hasCustomTitle, let baseTitle {
                    UnderlinedLinkText(l10n.tr("恢复默认片名", "Reset title")) {
                        applyCustomTitle(baseTitle, decision: decision, match: match)
                    }
                }
            }

            PanelBox(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        DownsampledArtworkView(
                            tmdbPath: match?.posterPath,
                            width: 30,
                            height: 45,
                            cornerRadius: 4,
                            fallbackSystemImage: isTv ? "tv" : "film"
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(match?.title ?? l10n.tr("尚未匹配", "Unmatched"))
                                .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)

                            Text(
                                match == nil
                                    ? l10n.tr("在 TMDB 里搜索并选择", "Search and pick on TMDB")
                                    : "TMDB \(match!.tmdbId)\(match!.year.map { " · \($0)" } ?? "")"
                            )
                            .font(.system(size: TidyreelTypeScale.small))
                            .monospacedDigit()
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }

                    SecondaryActionButton(
                        l10n.tr("重新搜索 TMDB", "Search TMDB"),
                        systemImage: "magnifyingglass"
                    ) {
                        viewModel.activeSheet = .tmdbSearch(
                            group: group,
                            initialQuery: match?.title ?? group.anchorTitle
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let match {
                        Rectangle()
                            .fill(palette.line)
                            .frame(height: hairlineWidth)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("自定义片名", "Custom Title"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(palette.textMuted)

                            HStack(spacing: 6) {
                                TextField(match.title, text: $customTitleText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.text)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                            .fill(palette.canvas)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                            .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                                    )
                                    .onSubmit {
                                        commitCustomTitle(decision: decision, match: match)
                                    }

                                let trimmed = customTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty && trimmed != match.title {
                                    QuietTextButton(
                                        l10n.tr("应用", "Apply"),
                                        fontSize: TidyreelTypeScale.small
                                    ) {
                                        commitCustomTitle(decision: decision, match: match)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func commitCustomTitle(decision: GroupDecision, match: Candidate) {
        let trimmed = customTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customTitleText = match.title
            return
        }
        guard trimmed != match.title else { return }
        applyCustomTitle(trimmed, decision: decision, match: match)
    }

    private func applyCustomTitle(_ newTitle: String, decision: GroupDecision, match: Candidate?) {
        guard var updatedMatch = match else { return }
        updatedMatch.title = newTitle
        customTitleText = newTitle
        var next = decision
        next.match = updatedMatch
        Task {
            await viewModel.updateDecision(
                store: store,
                taskId: taskId,
                groupId: group.id,
                decision: next
            )
        }
    }

    // MARK: - 2. Season Strategy (`review_panes.dart:2447-2465`)

    private func seasonStrategySection(decision: GroupDecision) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("季集策略", "Season Strategy")) {
                if decision.strategy != .asParsed {
                    TagBadge(l10n.tr("已自定义", "Custom"), tint: palette.warning)
                }
            }

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    let cases = SeasonStrategy.allCases
                    ForEach(Array(cases.enumerated()), id: \.element) { idx, strategy in
                        let info = localizedStrategyInfo(strategy, l10n: l10n)
                        let isSelected = (decision.strategy == strategy)
                        let isSuggested = (group.suggestedStrategy == strategy)

                        MonochromeOptionRow(
                            title: info.title,
                            caption: info.caption,
                            badge: isSuggested ? l10n.tr("推荐", "Recommended") : nil,
                            isSelected: isSelected,
                            showsBottomDivider: idx < cases.count - 1
                        ) {
                            guard decision.strategy != strategy else { return }
                            var next = decision
                            next.strategy = strategy
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
                }
            }
        }
    }

    // MARK: - 3. Episode Group (`review_panes.dart:2466-2510`)

    private func episodeGroupSection(decision: GroupDecision, match: Candidate?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("剧集组", "Episode Group")) {
                if decision.episodeGroupId != nil {
                    TagBadge(l10n.tr("已启用", "Active"), tint: palette.warning)
                }
            }

            PanelBox(padding: EdgeInsets()) {
                if let match {
                    switch viewModel.episodeGroupsCache[match.tmdbId] ?? .loading {
                    case .loading:
                        HStack(spacing: 8) {
                            DashedSpinner(size: 13)
                            Text(l10n.tr("读取中…", "Loading…"))
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.textMuted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onAppear {
                            viewModel.ensureEpisodeGroupsLoaded(store: store, tmdbId: match.tmdbId)
                        }

                    case .failed(let msg):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l10n.tr("读取失败：\(localizeCoreMessage(l10n, msg))", "Failed to load: \(localizeCoreMessage(l10n, msg))"))
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.danger)
                            QuietTextButton(l10n.retry, systemImage: "arrow.clockwise", fontSize: TidyreelTypeScale.small) {
                                viewModel.ensureEpisodeGroupsLoaded(store: store, tmdbId: match.tmdbId)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    case .loaded(let groups):
                        if groups.isEmpty {
                            Text(l10n.tr("TMDB 上没有剧集组", "No episode groups on TMDB"))
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.textMuted)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(spacing: 0) {
                                MonochromeOptionRow(
                                    title: l10n.tr("默认季划分", "Default seasons"),
                                    caption: nil,
                                    badge: nil,
                                    isSelected: decision.episodeGroupId == nil,
                                    showsBottomDivider: true
                                ) {
                                    guard decision.episodeGroupId != nil else { return }
                                    var next = decision
                                    next.episodeGroupId = nil
                                    Task {
                                        await viewModel.updateDecision(
                                            store: store,
                                            taskId: taskId,
                                            groupId: group.id,
                                            decision: next
                                        )
                                    }
                                }

                                ForEach(Array(groups.enumerated()), id: \.element.id) { idx, eg in
                                    MonochromeOptionRow(
                                        title: eg.name,
                                        caption: l10n.tr("\(eg.seasons.count) 季", l10n.plural(eg.seasons.count, "season")),
                                        badge: nil,
                                        isSelected: decision.episodeGroupId == eg.id,
                                        showsBottomDivider: idx < groups.count - 1
                                    ) {
                                        guard decision.episodeGroupId != eg.id else { return }
                                        var next = decision
                                        next.episodeGroupId = eg.id
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
                            }
                        }
                    }
                } else {
                    Text(l10n.tr("匹配作品后可选", "Available after matching"))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 4. Episode Offset (`review_panes.dart:2512-2560`)

    private func episodeOffsetSection(decision: GroupDecision) -> some View {
        let offset = decision.episodeOffset
        let example: String = {
            if offset == 0 {
                return l10n.tr("例如 +1 时 E01 → E02", "e.g. +1 maps E01 → E02")
            }
            let from = offset < 0 ? (1 - offset) : 1
            let to = from + offset
            return String(
                format: l10n.tr("当前：E%02d → E%02d", "Now: E%02d → E%02d"),
                from,
                to
            )
        }()

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("集数偏移", "Episode Offset")) {
                if offset != 0 {
                    UnderlinedLinkText(l10n.tr("归零", "Reset")) {
                        applyOffset(0, decision: decision)
                    }
                }
            }

            PanelBox(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("偏移", "Offset"))
                            .font(.system(size: TidyreelTypeScale.body))
                            .foregroundStyle(palette.text)

                        Text(
                            l10n.tr(
                                "应用策略前给集号加上偏移（\(example)）",
                                "Shift episode numbers before applying strategy (\(example))"
                            )
                        )
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 0) {
                        QuietIconButton(
                            systemImage: "minus",
                            tooltip: l10n.tr("减 1", "Decrease by 1"),
                            iconSize: 11
                        ) {
                            applyOffset(offset - 1, decision: decision)
                        }

                        TextField("0", text: $offsetText)
                            .textFieldStyle(.plain)
                            .font(.system(size: TidyreelTypeScale.body, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.center)
                            .frame(width: 34)
                            .onSubmit {
                                commitTypedOffset(decision: decision)
                            }

                        QuietIconButton(
                            systemImage: "plus",
                            tooltip: l10n.tr("加 1", "Increase by 1"),
                            iconSize: 11
                        ) {
                            applyOffset(offset + 1, decision: decision)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                            .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                    )
                }
            }
        }
    }

    // MARK: - 5. Folder Merge Toggle

    private func folderMergeSection(decision: GroupDecision) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("目录合并", "Folder Merge"))

            PanelBox(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                VStack(alignment: .leading, spacing: 8) {
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

                    Text(
                        l10n.tr(
                            "分开保留时不与目标位置同名文件夹合并",
                            "Keeps a separate folder instead of merging into an existing show folder"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                }
            }
        }
    }

    // MARK: - 6. Group Actions (`review_panes.dart:2562-2590`)

    private func groupActionsSection(canMerge: Bool, canSplit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("分组", "Group"))

            PanelBox(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
                VStack(alignment: .leading, spacing: 8) {
                    if canMerge {
                        SecondaryActionButton(
                            l10n.tr("合并到其他作品…", "Merge into another title…"),
                            systemImage: "arrow.triangle.merge"
                        ) {
                            viewModel.activeSheet = .mergeGroup(source: group)
                        }
                    }
                    if canSplit {
                        SecondaryActionButton(
                            l10n.tr("拆分分组…", "Split group…"),
                            systemImage: "scissors"
                        ) {
                            viewModel.activeSheet = .splitGroup(
                                source: group,
                                initialSelection: viewModel.multiSelectedPaths
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func syncFields(decision: GroupDecision, match: Candidate?) {
        customTitleText = match?.title ?? ""
        syncOffsetField(decision.episodeOffset)
    }

    private func syncOffsetField(_ value: Int) {
        offsetText = "\(value)"
    }

    private func commitTypedOffset(decision: GroupDecision) {
        let cleaned = offsetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "+", with: "")
        guard let parsed = Int(cleaned) else {
            syncOffsetField(decision.episodeOffset)
            return
        }
        let clamped = min(5000, max(-5000, parsed))
        applyOffset(clamped, decision: decision)
    }

    private func applyOffset(_ newOffset: Int, decision: GroupDecision) {
        syncOffsetField(newOffset)
        guard decision.episodeOffset != newOffset else { return }
        var next = decision
        next.episodeOffset = newOffset
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

// MARK: - Monochrome Radio Option Row (`_OptionRow` in `review_panes.dart:2350-2388`)

private struct MonochromeOptionRow: View {
    let title: String
    let caption: String?
    let badge: String?
    let isSelected: Bool
    let showsBottomDivider: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? palette.text : palette.lineStrong)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: TidyreelTypeScale.body, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(palette.text)
                            .lineLimit(2)

                        if let badge {
                            TagBadge(badge, tint: palette.accent)
                        }
                    }

                    if let caption {
                        Text(caption)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(isHovered ? palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 36)
            }
        }
    }
}
