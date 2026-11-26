import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - Neutral Star Rating Badge (`RatingBadge` in `tmdb_search_dialog.dart:31-55`)

struct RatingBadgeView: View {
    let value: Double

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.textMuted)
            Text(String(format: "%.1f", value))
                .font(.system(size: TidyreelTypeScale.small, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.text)
        }
    }
}

// MARK: - Candidate Row (`CandidateTile` in `tmdb_search_dialog.dart:57-108`)

struct CandidateTileView: View {
    let candidate: Candidate
    let onTap: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let c = candidate
        let metaParts: [String] = [
            (c.originalTitle != nil && c.originalTitle != c.title) ? c.originalTitle : nil,
            c.year.map { "\($0)" },
            c.kind == .movie ? l10n.movie : l10n.tvShow,
            c.originCountry.map { countryLabel($0, l10n: l10n) },
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        InstantHoverRow(
            cornerRadius: TidyreelRadii.sm,
            padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8),
            action: onTap
        ) {
            HStack(alignment: .center, spacing: 10) {
                DownsampledArtworkView(
                    tmdbPath: c.posterPath,
                    width: 34,
                    height: 51,
                    cornerRadius: 4,
                    fallbackSystemImage: c.kind == .movie ? "film" : "tv"
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)

                    if !metaParts.isEmpty {
                        Text(metaParts.joined(separator: " · "))
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }

                    if let overview = c.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if let vote = c.voteAverage, vote > 0 {
                    RatingBadgeView(value: vote)
                }
            }
        }
    }
}

// MARK: - Shared TMDB Search Box (`TmdbSearchBox` in `tmdb_search_dialog.dart:111-318`)
// Used inline inside unmatched `_GroupCard`s AND inside `TMDBSearchSheet`.

struct TMDBSearchBoxView: View {
    let store: AppStore
    let initialQuery: String
    let autoSearch: Bool
    var compact: Bool = false
    let onPick: (Candidate) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var query: String = ""
    @State private var selectedKind: MediaKind = .unknown // .unknown == 全部
    @State private var yearInput: String = ""
    @State private var results: [Candidate]?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var searchSeq: Int = 0
    @State private var boundInitial: String?

    private var currentYearPlusOne: Int {
        Calendar.current.component(.year, from: Date()) + 1
    }

    private var parsedYear: Int? {
        let trimmed = yearInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let y = Int(trimmed), (1870...2100).contains(y) else { return nil }
        return y
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search input with right-arrow submit / spinner
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.textFaint)

                TextField(l10n.tr("搜索 TMDB", "Search TMDB"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: compact ? TidyreelTypeScale.small : TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
                    .onSubmit {
                        performSearch()
                    }

                if isBusy {
                    DashedSpinner(size: 13)
                } else {
                    Button {
                        performSearch()
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(
                                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? palette.textFaint.opacity(0.45)
                                    : palette.textMuted
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(l10n.tr("搜索", "Search"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )

            // Type segmented + Year filter
            HStack(spacing: 8) {
                SlidingSegmented(
                    options: [
                        (MediaKind.unknown, l10n.tr("全部", "All")),
                        (MediaKind.episode, l10n.tvShow),
                        (MediaKind.movie, l10n.movie),
                    ],
                    selection: selectedKind
                ) { nextKind in
                    selectedKind = nextKind
                    if results != nil || autoSearch {
                        performSearch()
                    }
                }

                HStack(spacing: 4) {
                    TextField(l10n.tr("年份", "Year"), text: $yearInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: TidyreelTypeScale.small).monospacedDigit())
                        .foregroundStyle(palette.text)
                        .frame(width: 44)
                        .onSubmit {
                            performSearch()
                        }

                    Menu {
                        Button(l10n.tr("不限", "Any")) {
                            yearInput = ""
                            if results != nil || autoSearch {
                                performSearch()
                            }
                        }
                        Divider()
                        ForEach((1950...currentYearPlusOne).reversed(), id: \.self) { y in
                            Button("\(y)") {
                                yearInput = "\(y)"
                                performSearch()
                            }
                        }
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textMuted)
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(l10n.tr("选择年份", "Choose year"))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                )

                Spacer(minLength: 0)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.danger)
            }

            if let results {
                if results.isEmpty {
                    Text(l10n.tr("没有找到结果", "No results found"))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(results, id: \.self) { candidate in
                            CandidateTileView(candidate: candidate) {
                                onPick(candidate)
                            }
                        }
                    }
                    .padding(compact ? 3 : 0)
                    .background(
                        Group {
                            if compact {
                                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                    .fill(palette.panel)
                            }
                        }
                    )
                    .overlay {
                        if compact {
                            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                .strokeBorder(palette.line, lineWidth: hairlineWidth)
                        }
                    }
                }
            }
        }
        .onAppear {
            syncInitialIfNeeded()
        }
        .onChange(of: initialQuery) { _, _ in
            syncInitialIfNeeded()
        }
    }

    private func syncInitialIfNeeded() {
        guard boundInitial != initialQuery else { return }
        boundInitial = initialQuery
        query = initialQuery
        yearInput = ""
        selectedKind = .unknown
        results = nil
        errorMessage = nil
        if autoSearch && !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performSearch()
        }
    }

    private func performSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchSeq += 1
        let currentSeq = searchSeq
        let kindParam: MediaKind? = (selectedKind == .unknown) ? nil : selectedKind
        let yearParam = parsedYear
        let provider = store.currentMetadataProvider()

        isBusy = true
        errorMessage = nil

        Task {
            defer {
                if currentSeq == searchSeq {
                    isBusy = false
                }
            }
            do {
                let found = try await provider.search(q, kind: kindParam, year: yearParam)
                guard currentSeq == searchSeq else { return }
                results = found
            } catch {
                guard currentSeq == searchSeq else { return }
                let msg = localizeCoreMessage(l10n, error.localizedDescription)
                errorMessage = l10n.tr("搜索失败：\(msg)", "Search failed: \(msg)")
            }
        }
    }
}

// MARK: - Modal TMDB Search Sheet (`showTmdbSearchDialog` in `tmdb_search_dialog.dart:322-402`)

struct TMDBSearchSheet: View {
    let store: AppStore
    let taskId: TaskId
    let group: MediaGroup
    let initialQuery: String
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var saveAsPin = false
    @State private var pinKeyword: String = ""
    @State private var didInit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("重新搜索 TMDB", "Search TMDB"))
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            ScrollView {
                TMDBSearchBoxView(
                    store: store,
                    initialQuery: initialQuery,
                    autoSearch: true,
                    compact: false,
                    onPick: { candidate in
                        pickCandidate(candidate)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // TitlePin rule (`以后文件夹名包含 … 时都匹配到选中的作品`)
            HStack(spacing: 6) {
                InkCheckbox(isChecked: saveAsPin) {
                    saveAsPin.toggle()
                }

                Text(l10n.tr("以后文件夹名包含", "Always match folders with"))
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
                    .onTapGesture { saveAsPin.toggle() }

                TextField(group.anchorTitle, text: $pinKeyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(saveAsPin ? palette.text : palette.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 140)
                    .background(
                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                            .fill(saveAsPin ? palette.panel : palette.sidebar)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                            .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                    )
                    .disabled(!saveAsPin)

                Text(l10n.tr("时都匹配到选中的作品", "to the selected title"))
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            HStack {
                Spacer()
                SecondaryActionButton(l10n.cancel) {
                    viewModel.activeSheet = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 520, height: 520)
        .background(palette.canvas)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            pinKeyword = group.anchorTitle
        }
    }

    private func pickCandidate(_ candidate: Candidate) {
        if saveAsPin {
            let kw = pinKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kw.isEmpty {
                store.pinTitleRule(keyword: kw, match: candidate)
            }
        }

        var next = viewModel.decision(for: group.id)
        if next.episodeGroupId != nil && next.match?.tmdbId != candidate.tmdbId {
            next.episodeGroupId = nil
        }
        next.match = candidate
        next.selected = true

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
