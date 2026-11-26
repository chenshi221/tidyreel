import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct EditRowSheet: View {
    let store: AppStore
    let taskId: TaskId
    let group: MediaGroup
    let row: ReviewRow
    let allRows: [ReviewRow]
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    private enum RowKindChoice: String, CaseIterable, Hashable {
        case main
        case special
        case extra
        case ignore
    }

    @State private var kindChoice: RowKindChoice = .main
    @State private var manualMode: Bool = false
    @State private var selectedSeason: Int = 1
    @State private var pickedEpisode: EpisodeRef?
    @State private var seasonInput: String = "1"
    @State private var episodeInput: String = ""
    @State private var shiftFollowing: Bool = true
    @State private var didInitialize = false

    private var isTv: Bool { group.kind == .episode }
    private var decision: GroupDecision { viewModel.decision(for: group.id) }
    private var match: Candidate? { effectiveMatch(group, decision) }

    private var groupWithFetchedShow: MediaGroup {
        effectiveGroup(group, decision, fetchedShows: viewModel.fetchedShows)
    }

    private var availableSeasons: [Int] {
        guard isTv else { return [] }
        let g = groupWithFetchedShow
        let sizes = seasonSizes(g, decision)
        switch kindChoice {
        case .main:
            return sizes.keys.sorted()
        case .special:
            let hasSpecials = g.show?.seasons.contains(where: { $0.number == 0 }) ?? false
            return (hasSpecials && !sizes.isEmpty) ? [0] : []
        case .extra, .ignore:
            return []
        }
    }

    private var useTMDBEpisodePicker: Bool {
        isTv
            && match != nil
            && !availableSeasons.isEmpty
            && !manualMode
            && (kindChoice == .main || kindChoice == .special)
    }

    private var showManualFields: Bool {
        isTv
            && !useTMDBEpisodePicker
            && kindChoice != .extra
            && kindChoice != .ignore
    }

    private var laterFollowCount: Int {
        guard isTv, row.file.role == .video, kindChoice == .main else { return 0 }
        return shiftFollowingCount(rows: allRows, from: row)
    }

    private var validationError: String? {
        guard showManualFields else { return nil }
        let sTrimmed = seasonInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = Int(sTrimmed), s >= 0 else {
            return l10n.tr("季号需为不小于 0 的整数", "Season must be an integer ≥ 0")
        }
        let eTrimmed = episodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = Int(eTrimmed), e >= 1 else {
            return l10n.tr("集号需为大于 0 的整数", "Episode must be an integer ≥ 1")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("修正这个文件", "Edit File Assignment"))
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)

                Text(row.file.name)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            // Kind Segmented Switcher (`SlidingSegmented`)
            HStack {
                Spacer()
                SlidingSegmented(
                    options: [
                        (RowKindChoice.main, l10n.tr("正片", "Main")),
                        (RowKindChoice.special, l10n.specials),
                        (RowKindChoice.extra, l10n.tr("花絮", "Extra")),
                        (RowKindChoice.ignore, l10n.tr("忽略", "Ignore")),
                    ],
                    selection: kindChoice
                ) { choice in
                    kindChoice = choice
                    pickedEpisode = nil
                    if choice == .special {
                        seasonInput = "0"
                        selectedSeason = 0
                        if let tmdbId = match?.tmdbId {
                            viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: 0)
                        }
                    } else if choice == .main && seasonInput == "0" {
                        let firstSeason = availableSeasons.first ?? 1
                        seasonInput = "\(firstSeason)"
                        selectedSeason = firstSeason
                        if let tmdbId = match?.tmdbId {
                            viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: firstSeason)
                        }
                    }
                }
                Spacer()
            }

            // TMDB Episode Browser OR Manual Season/Episode Fields
            if useTMDBEpisodePicker, let match {
                showHeader(match: match)
                tmdbEpisodePicker(match: match)
            } else if showManualFields {
                manualInputFields
            } else if kindChoice == .extra {
                PanelBox(framed: true) {
                    Text(l10n.tr("该文件将归类为花絮，放入作品目录下的 Extras 文件夹。", "This file will be placed into the Extras folder."))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if kindChoice == .ignore {
                PanelBox(framed: true) {
                    Text(l10n.tr("该文件将被忽略，整理时保持原样不变。", "This file will be ignored and left untouched when organizing."))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Shift following checkbox (`InkCheckbox`)
            if laterFollowCount > 0 {
                HStack(spacing: 8) {
                    InkCheckbox(isChecked: shiftFollowing) {
                        shiftFollowing.toggle()
                    }
                    Text(
                        l10n.tr(
                            "同时顺延本季后续集号（影响后续 \(laterFollowCount) 个文件）",
                            "Also shift following episodes in this season (\(l10n.plural(laterFollowCount, "file")) affected)"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .onTapGesture {
                        shiftFollowing.toggle()
                    }
                }
            }

            // Footer Actions
            HStack(spacing: 8) {
                if isTv, match != nil, !availableSeasons.isEmpty, kindChoice != .ignore, kindChoice != .extra {
                    QuietTextButton(
                        manualMode
                            ? l10n.tr("从 TMDB 剧集里选", "Pick from TMDB list")
                            : l10n.tr("手动填写季和集", "Enter manually"),
                        fontSize: TidyreelTypeScale.small
                    ) {
                        manualMode.toggle()
                    }
                }

                if row.override != nil {
                    QuietTextButton(
                        l10n.tr("恢复自动识别", "Reset"),
                        fontSize: TidyreelTypeScale.small
                    ) {
                        clearOverride()
                    }
                }

                Spacer()

                SecondaryActionButton(l10n.cancel) {
                    viewModel.activeSheet = nil
                }
                .keyboardShortcut(.cancelAction)

                if useTMDBEpisodePicker {
                    PrimaryActionButton(
                        l10n.tr("确认", "Confirm"),
                        isDisabled: pickedEpisode == nil
                    ) {
                        if let pickedEpisode {
                            saveWithEpisodeRef(pickedEpisode)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    PrimaryActionButton(
                        l10n.tr("保存", "Save"),
                        isDisabled: validationError != nil
                    ) {
                        saveManualOrKindOverride()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: useTMDBEpisodePicker ? 620 : 460)
        .background(palette.canvas)
        .onAppear {
            initializeFromRowIfNeeded()
        }
    }

    // MARK: - Show Header & TMDB Season / Episode Browser (`edit_row_sheet.dart:245-395`)

    private func showHeader(match: Candidate) -> some View {
        HStack(spacing: 10) {
            DownsampledArtworkView(
                tmdbPath: match.posterPath,
                width: 30,
                height: 45,
                cornerRadius: 4,
                fallbackSystemImage: "tv"
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(match.title)
                    .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text("TMDB \(match.tmdbId)\(match.year.map { " · \($0)" } ?? "")")
                    .font(.system(size: TidyreelTypeScale.small))
                    .monospacedDigit()
                    .foregroundStyle(palette.textMuted)
            }
            Spacer()
        }
    }

    private func tmdbEpisodePicker(match: Candidate) -> some View {
        let seasons = availableSeasons
        let activeSeason = seasons.contains(selectedSeason) ? selectedSeason : (seasons.first ?? 1)
        let cacheKey = SeasonEpisodesCacheKey(tmdbId: match.tmdbId, season: activeSeason)
        let episodesMap = viewModel.seasonEpisodesCache[cacheKey]
        let sortedEpisodes = episodesMap?.values.sorted { $0.number < $1.number }
        let takenMap = assignedFilesByEpisode()

        return PanelBox(padding: EdgeInsets(), framed: true) {
            HStack(spacing: 0) {
                // Season list column
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(seasons, id: \.self) { s in
                            let isSelected = (s == activeSeason)
                            InstantHoverRow(
                                isSelected: isSelected,
                                cornerRadius: TidyreelRadii.sm,
                                padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10),
                                action: {
                                    selectedSeason = s
                                    viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: match.tmdbId, season: s)
                                }
                            ) {
                                HStack {
                                    Text(seasonTabTitle(s, l10n: l10n))
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? palette.text : palette.textMuted)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(width: 112)

                Rectangle()
                    .fill(palette.line)
                    .frame(width: hairlineWidth)

                // Episode list column
                Group {
                    if let sortedEpisodes {
                        if sortedEpisodes.isEmpty {
                            EmptyStateCard(
                                icon: "tv",
                                title: l10n.tr("读不到这一季的剧集", "Unable to Load Episodes"),
                                subtitle: l10n.tr("可以用「手动填写季和集」", "Use \"Enter manually\" instead")
                            )
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(sortedEpisodes, id: \.number) { ep in
                                        let ref = EpisodeRef(activeSeason, ep.number)
                                        let isPicked = (pickedEpisode == ref)
                                        let isCurrent = (row.targetRef == ref)
                                        let otherFile = takenMap[ref]

                                        InstantHoverRow(
                                            isSelected: isPicked,
                                            cornerRadius: TidyreelRadii.sm,
                                            padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10),
                                            action: {
                                                if pickedEpisode == ref {
                                                    saveWithEpisodeRef(ref)
                                                } else {
                                                    pickedEpisode = ref
                                                }
                                            }
                                        ) {
                                            HStack(spacing: 10) {
                                                Text(String(format: "E%02d", ep.number))
                                                    .font(.system(size: TidyreelTypeScale.small, weight: .semibold).monospacedDigit())
                                                    .foregroundStyle(palette.textMuted)
                                                    .frame(width: 34, alignment: .leading)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    let headerParts = [
                                                        ep.title ?? l10n.tr("第 \(ep.number) 集", "Episode \(ep.number)"),
                                                        viewModel.seasonAirDatesCache[cacheKey]?[ep.number] ?? formatShortAirDate(ep.airDate),
                                                    ].compactMap { $0 }

                                                    Text(headerParts.joined(separator: "  ·  "))
                                                        .font(.system(size: TidyreelTypeScale.body))
                                                        .foregroundStyle(palette.text)
                                                        .lineLimit(1)

                                                    if let otherFile {
                                                        Text(l10n.tr("已对应：\(otherFile)", "Assigned: \(otherFile)"))
                                                            .font(.system(size: TidyreelTypeScale.small))
                                                            .foregroundStyle(palette.warning)
                                                            .lineLimit(1)
                                                    }
                                                }

                                                Spacer(minLength: 4)

                                                if isCurrent {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundStyle(palette.text)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(4)
                            }
                        }
                    } else {
                        VStack {
                            DashedSpinner(size: 18)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            viewModel.ensureSeasonEpisodesLoaded(
                                store: store,
                                tmdbId: match.tmdbId,
                                season: activeSeason
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 300)
        }
    }

    private func assignedFilesByEpisode() -> [EpisodeRef: String] {
        var map: [EpisodeRef: String] = [:]
        let startRaw = episodeOf(row.file, nil)
        let localSeason = row.file.parsed?.season ?? 1
        let willShift = shiftFollowing
            && kindChoice == .main
            && row.file.role == .video
            && startRaw != nil

        for r in allRows where r.file.path != row.file.path && r.file.role == .video && !r.ignored {
            if willShift,
               let startRaw,
               !isExtraFile(r.file, r.override),
               !isSpecialFile(r.file, r.override),
               (r.file.parsed?.season ?? 1) == localSeason,
               (episodeOf(r.file, nil) ?? 0) >= startRaw {
                continue
            }
            if let ref = r.targetRef {
                map[ref] = r.file.name
            }
        }
        return map
    }

    // MARK: - Manual Season & Episode Inputs

    private var manualInputFields: some View {
        PanelBox(framed: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(l10n.tr("季", "Season"))
                        .font(.system(size: TidyreelTypeScale.body))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 64, alignment: .leading)

                    TextField("1", text: $seasonInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: TidyreelTypeScale.body).monospacedDigit())
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
                }

                HStack(spacing: 12) {
                    Text(l10n.tr("集", "Episode"))
                        .font(.system(size: TidyreelTypeScale.body))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 64, alignment: .leading)

                    TextField("1", text: $episodeInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: TidyreelTypeScale.body).monospacedDigit())
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
                }

                if let validationError {
                    Text(validationError)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.danger)
                }
            }
        }
    }

    // MARK: - State Init & Save Actions

    private func initializeFromRowIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true

        if row.ignored {
            kindChoice = .ignore
        } else if isExtraFile(row.file, row.override) {
            kindChoice = .extra
        } else if isSpecialFile(row.file, row.override) {
            kindChoice = .special
        } else {
            kindChoice = .main
        }

        let initialSeason = row.targetRef?.season
            ?? row.override?.season
            ?? row.file.parsed?.season
            ?? (kindChoice == .special ? 0 : 1)
        let initialEp = row.targetRef?.episode ?? episodeOf(row.file, row.override)

        selectedSeason = initialSeason
        seasonInput = "\(max(0, initialSeason))"
        episodeInput = initialEp.map { "\($0)" } ?? ""
        pickedEpisode = row.targetRef

        if let tmdbId = match?.tmdbId, isTv {
            if group.show?.info.tmdbId != tmdbId {
                viewModel.ensureShowLoaded(store: store, tmdbId: tmdbId)
            }
            viewModel.ensureSeasonEpisodesLoaded(store: store, tmdbId: tmdbId, season: max(0, initialSeason))
        }
    }

    private func resolvedMediaKind() -> MediaKind? {
        switch kindChoice {
        case .main: return group.kind == .movie ? .movie : .episode
        case .special: return .special
        case .extra: return .extra
        case .ignore: return row.override?.kind
        }
    }

    private func saveWithEpisodeRef(_ ref: EpisodeRef) {
        let kind = resolvedMediaKind()
        let override = FileOverride(season: ref.season, episode: ref.episode, kind: kind, ignore: false)
        commitOverride(override, targetRef: ref)
    }

    private func saveManualOrKindOverride() {
        let kind = resolvedMediaKind()
        if kindChoice == .ignore {
            let override = FileOverride(
                season: row.override?.season,
                episode: row.override?.episode,
                kind: row.override?.kind,
                ignore: true
            )
            commitOverride(override, targetRef: nil)
            return
        }
        if kindChoice == .extra || !isTv {
            let override = FileOverride(season: nil, episode: nil, kind: kind, ignore: false)
            commitOverride(override, targetRef: nil)
            return
        }

        guard let s = Int(seasonInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              let e = Int(episodeInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let ref = EpisodeRef(s, e)
        let override = FileOverride(season: s, episode: e, kind: kind, ignore: false)
        commitOverride(override, targetRef: ref)
    }

    private func commitOverride(_ override: FileOverride, targetRef: EpisodeRef?) {
        viewModel.activeSheet = nil
        if shiftFollowing,
           isTv,
           row.file.role == .video,
           kindChoice == .main,
           let toRef = targetRef,
           toRef != row.targetRef {
            Task {
                await viewModel.applyEpisodeShift(
                    store: store,
                    taskId: taskId,
                    group: groupWithFetchedShow,
                    allRows: allRows,
                    fromRow: row,
                    toRef: toRef,
                    kind: override.kind
                )
            }
        } else {
            var next = decision
            next.overrides[row.file.path] = override
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

    private func clearOverride() {
        var next = decision
        next.overrides.removeValue(forKey: row.file.path)
        viewModel.activeSheet = nil
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
