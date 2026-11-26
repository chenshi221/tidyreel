import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelPlanner
import TidyreelServices

private struct SampleEvalKey: Equatable {
    let input: String
    let rules: TitleRules
}

/// Shared Title Rules section at the bottom of the left column of `NamingPageView` (`_TitleRulesSection` in `naming_page.dart:1476`).
struct TitleRulesSectionView: View {
    let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var sampleFolderInput: String
    @State private var cachedEvaluation: SampleFolderEvaluation
    @State private var isAddPinSheetPresented: Bool = false
    @State private var editingPin: TitlePin? = nil

    init(store: AppStore) {
        self.store = store
        let initialInput = "R人生复本 Dark Matter"
        self._sampleFolderInput = State(initialValue: initialInput)
        self._cachedEvaluation = State(
            initialValue: Self.evaluateSampleFolder(
                initialInput,
                rules: store.titleRules,
                parser: store.parser
            )
        )
    }

    private var rules: TitleRules {
        store.titleRules
    }

    private var sampleEvalKey: SampleEvalKey {
        SampleEvalKey(input: sampleFolderInput, rules: store.titleRules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cleanupsSection
            pinnedMatchesSection
        }
        .onAppear {
            recomputeSampleEvaluation()
        }
        .onChange(of: sampleEvalKey) { _, _ in
            recomputeSampleEvaluation()
        }
        .sheet(isPresented: $isAddPinSheetPresented) {
            TitlePinSearchSheet(
                store: store,
                initialKeyword: "",
                initialCandidate: nil
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(item: $editingPin) { pin in
            TitlePinSearchSheet(
                store: store,
                initialKeyword: pin.keyword,
                initialCandidate: pin.match
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - 1. Cleanups + Live Folder Name Tester

    private var cleanupsSection: some View {
        let evaluation = cachedEvaluation

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(
                l10n.tr("片名规则（电影与剧集共用）", "Title Rules (Shared by Movies & TV)")
            ) {
                QuietTextButton(
                    l10n.tr("添加", "Add"),
                    systemImage: "plus",
                    fontSize: TidyreelTypeScale.small
                ) {
                    var next = store.titleRules
                    next.cleanups.append(NameRewrite("", ""))
                    store.setTitleRules(next)
                }
            }

            PanelBox(padding: EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14)) {
                VStack(alignment: .leading, spacing: 10) {
                    if rules.cleanups.isEmpty {
                        Text(
                            l10n.tr(
                                "识别前先按正则清洗文件夹名，再去 TMDB 搜索。比如把 ^【.*?】 换成空，去掉「【日剧】」这类前缀。内置规则已经会去掉排序字母、分隔点和括号，搜不到时再只用中文名或英文名搜。",
                                "Clean folder names with regex before searching TMDB (e.g. replace ^\\[.*?\\] with empty to strip release prefixes). Built-in rules already strip sort letters, dots, and brackets, and fall back to Chinese or English titles when needed."
                            )
                        )
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        RegexRewriteEditorList(
                            items: rules.cleanups,
                            onUpdate: { idx, updated in
                                var next = store.titleRules
                                guard idx < next.cleanups.count else { return }
                                next.cleanups[idx] = updated
                                store.setTitleRules(next)
                            },
                            onRemove: { idx in
                                var next = store.titleRules
                                guard idx < next.cleanups.count else { return }
                                next.cleanups.remove(at: idx)
                                store.setTitleRules(next)
                            }
                        )
                    }

                    InkTextField(
                        placeholder: l10n.tr("输入一个文件夹名试试", "Type a folder name to test"),
                        text: $sampleFolderInput,
                        icon: "magnifyingglass"
                    )

                    Text(searchOrderDescription(for: evaluation))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func searchOrderDescription(for evaluation: SampleFolderEvaluation) -> String {
        if let pinned = evaluation.matchedPin {
            return l10n.tr(
                "指定匹配 →《\(pinned.match.title)》，不搜索",
                "Pinned match → \"\(pinned.match.title)\" (skips search)"
            )
        }
        if evaluation.searchQueries.isEmpty {
            return l10n.tr("没有可搜索的片名", "No searchable title")
        }
        let joined = evaluation.searchQueries.joined(separator: "  →  ")
        return l10n.tr(
            "依次搜索：\(joined)",
            "Search order: \(joined)"
        )
    }

    // MARK: - 2. Pinned Matches (`TitlePin`)

    private var pinnedMatchesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("指定匹配", "Pinned Matches")) {
                QuietTextButton(
                    l10n.tr("添加", "Add"),
                    systemImage: "plus",
                    fontSize: TidyreelTypeScale.small
                ) {
                    isAddPinSheetPresented = true
                }
            }

            PanelBox(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                if rules.pins.isEmpty {
                    Text(
                        l10n.tr(
                            "总是搜不准的片名，在识别结果里点「重新搜索 TMDB」并勾选「以后文件夹名包含 … 时都匹配到选中的作品」，就会记在这里：文件夹名包含关键词时直接用这部作品。",
                            "For titles that often mismatch, click \"Search TMDB\" in Review and check \"Always match folders containing …\" to pin them here."
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rules.pins.enumerated()), id: \.element.id) { idx, pin in
                            if idx > 0 {
                                SettingsDivider()
                                    .padding(.vertical, 4)
                            }
                            pinnedMatchRow(pin)
                        }
                    }
                }
            }
        }
    }

    private func pinnedMatchRow(_ pin: TitlePin) -> some View {
        let yearSuffixZh = pin.match.year.map { " \($0)" } ?? ""
        let yearSuffixEn = pin.match.year.map { " (\($0))" } ?? ""
        let summary = l10n.tr(
            "包含「\(pin.keyword)」→《\(pin.match.title)》\(yearSuffixZh)",
            "Contains \"\(pin.keyword)\" → \(pin.match.title)\(yearSuffixEn)"
        )

        return HStack(spacing: 10) {
            Button {
                editingPin = pin
            } label: {
                HStack(spacing: 10) {
                    DownsampledArtworkView(
                        tmdbPath: pin.match.posterPath,
                        sizeBucket: "w92",
                        width: 24,
                        height: 36,
                        cornerRadius: 3
                    )

                    Text(summary)
                        .font(.system(size: TidyreelTypeScale.body))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("点击修改此指定匹配", "Click to edit pinned match"))

            QuietIconButton(
                systemImage: "xmark",
                tooltip: l10n.delete,
                iconSize: 12
            ) {
                var next = store.titleRules
                next.pins.removeAll { $0 == pin }
                store.setTitleRules(next)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Live Folder Evaluation

    private struct SampleFolderEvaluation {
        let matchedPin: TitlePin?
        let searchQueries: [String]
    }

    private func recomputeSampleEvaluation() {
        cachedEvaluation = Self.evaluateSampleFolder(
            sampleFolderInput,
            rules: store.titleRules,
            parser: store.parser
        )
    }

    private static func evaluateSampleFolder(
        _ raw: String,
        rules: TitleRules,
        parser: any FilenameParser
    ) -> SampleFolderEvaluation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SampleFolderEvaluation(matchedPin: nil, searchQueries: [])
        }
        if let pin = rules.pins.first(where: { p in
            let kw = p.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !kw.isEmpty && trimmed.localizedCaseInsensitiveContains(kw)
        }) {
            return SampleFolderEvaluation(matchedPin: pin, searchQueries: [])
        }

        let parsedTitle = parser.parse("S01E01.mkv", parentDirs: [trimmed]).title ?? ""
        let cleaned = applyRewrites(parsedTitle, rewrites: rules.cleanups)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var queries: [String] = []
        if !cleaned.isEmpty {
            queries.append(cleaned)
        }
        let fallbacks = relaxedQueries(cleaned, rawName: trimmed)
        for q in fallbacks where !queries.contains(q) {
            queries.append(q)
        }
        return SampleFolderEvaluation(matchedPin: nil, searchQueries: queries)
    }
}

extension TitlePin: Identifiable {
    public var id: String { "\(keyword)#\(match.kind.rawValue)#\(match.tmdbId)" }
}

// MARK: - Modal TMDB Search Sheet for Pinning Keyword -> Candidate

private enum PinSearchKindFilter: String, CaseIterable, Hashable {
    case all
    case tv
    case movie

    var mediaKind: MediaKind? {
        switch self {
        case .all: return nil
        case .tv: return .episode
        case .movie: return .movie
        }
    }
}

private struct TitlePinSearchSheet: View {
    let store: AppStore
    let initialKeyword: String
    let initialCandidate: Candidate?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var keyword: String = ""
    @State private var searchQuery: String = ""
    @State private var yearFilterText: String = ""
    @State private var kindFilter: PinSearchKindFilter = .all
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @State private var results: [Candidate] = []
    @State private var selectedCandidate: Candidate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    initialKeyword.isEmpty
                        ? l10n.tr("添加指定匹配", "Add Pinned Match")
                        : l10n.tr("编辑指定匹配", "Edit Pinned Match")
                )
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

                Text(
                    l10n.tr(
                        "当文件夹名包含该关键词时，直接匹配到选中的 TMDB 作品，不再搜索。",
                        "Folders containing this keyword will match the selected TMDB entry directly."
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.tr("触发关键词（不区分大小写）", "Keyword (case-insensitive)"))
                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    .foregroundStyle(palette.textMuted)

                InkTextField(
                    placeholder: l10n.tr("例如：凡人修仙传 或 Dark.Matter", "e.g. Frieren or Dark.Matter"),
                    text: $keyword,
                    icon: "tag",
                    onSubmit: {
                        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchQuery = keyword
                        }
                        performSearch()
                    }
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.tr("搜索 TMDB 作品", "Search TMDB"))
                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    .foregroundStyle(palette.textMuted)

                HStack(spacing: 8) {
                    InkTextField(
                        placeholder: l10n.tr("输入片名搜索…", "Search by title…"),
                        text: $searchQuery,
                        icon: "magnifyingglass",
                        onSubmit: performSearch
                    )

                    InkTextField(
                        placeholder: l10n.tr("年份", "Year"),
                        text: $yearFilterText,
                        monospaced: true,
                        onSubmit: performSearch
                    )
                    .frame(width: 68)

                    SlidingSegmented(
                        options: [
                            (PinSearchKindFilter.all, l10n.tr("全部", "All")),
                            (PinSearchKindFilter.tv, l10n.tvShow),
                            (PinSearchKindFilter.movie, l10n.movie),
                        ],
                        selection: kindFilter
                    ) { next in
                        kindFilter = next
                        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            performSearch()
                        }
                    }

                    SecondaryActionButton(
                        isSearching ? l10n.tr("搜索中…", "Searching…") : l10n.tr("搜索", "Search"),
                        isDisabled: isSearching || (searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ) {
                        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchQuery = keyword
                        }
                        performSearch()
                    }
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(palette.canvas)
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: hairlineWidth)

                if isSearching {
                    HStack(spacing: 8) {
                        DashedSpinner(size: 14)
                        Text(l10n.tr("正在搜索 TMDB…", "Searching TMDB…"))
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                    }
                } else if let searchError {
                    Text(searchError)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                } else if results.isEmpty {
                    Text(
                        l10n.tr(
                            "输入片名并点击「搜索」以选择作品",
                            "Search for a movie or TV show above"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(results, id: \.self) { cand in
                                candidateRow(cand)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: 240)

            HStack(spacing: 8) {
                if let sel = selectedCandidate {
                    Text(
                        l10n.tr(
                            "已选：《\(sel.title)》(#\(sel.tmdbId))",
                            "Selected: \(sel.title) (#\(sel.tmdbId))"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                }

                Spacer()

                QuietTextButton(l10n.cancel) {
                    dismiss()
                }

                PrimaryActionButton(
                    l10n.tr("保存", "Save"),
                    isDisabled: keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCandidate == nil
                ) {
                    guard let chosen = selectedCandidate else { return }
                    let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKeyword.isEmpty else { return }

                    if !initialKeyword.isEmpty && initialKeyword != trimmedKeyword {
                        var cleanedPins = store.titleRules.pins.filter { $0.keyword != initialKeyword && $0.keyword != trimmedKeyword }
                        cleanedPins.append(TitlePin(trimmedKeyword, chosen))
                        store.setTitleRules(TitleRules(cleanups: store.titleRules.cleanups, pins: cleanedPins))
                    } else {
                        store.pinTitleRule(keyword: trimmedKeyword, match: chosen)
                    }
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 560)
        .background(palette.panel)
        .onAppear {
            keyword = initialKeyword
            searchQuery = initialCandidate?.title ?? initialKeyword
            if let initialCandidate {
                selectedCandidate = initialCandidate
                results = [initialCandidate]
            }
        }
    }

    private func candidateRow(_ cand: Candidate) -> some View {
        let isSelected = selectedCandidate?.tmdbId == cand.tmdbId && selectedCandidate?.kind == cand.kind
        return InstantHoverRow(
            isSelected: isSelected,
            cornerRadius: TidyreelRadii.sm,
            padding: EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
        ) {
            selectedCandidate = cand
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keyword = cand.title
            }
        } content: {
            HStack(alignment: .top, spacing: 10) {
                DownsampledArtworkView(
                    tmdbPath: cand.posterPath,
                    sizeBucket: "w92",
                    width: 34,
                    height: 51,
                    cornerRadius: 4
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(cand.title)
                            .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)

                        if let year = cand.year {
                            Text(String(year))
                                .font(.system(size: TidyreelTypeScale.small))
                                .monospacedDigit()
                                .foregroundStyle(palette.textMuted)
                        }

                        TagBadge(cand.kind == .movie ? l10n.movie : l10n.tvShow)

                        Spacer()

                        Text("#\(cand.tmdbId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.textFaint)
                    }

                    if let orig = cand.originalTitle, !orig.isEmpty, orig != cand.title {
                        Text(orig)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }

                    if let overview = cand.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textFaint)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        let parsedYear = Int(yearFilterText.trimmingCharacters(in: .whitespacesAndNewlines))
        let kind = kindFilter.mediaKind

        isSearching = true
        searchError = nil

        Task { @MainActor in
            defer { isSearching = false }
            do {
                let provider = store.currentMetadataProvider()
                let hits = try await provider.search(query, kind: kind, year: parsedYear)
                results = hits
                if selectedCandidate == nil, let first = hits.first {
                    selectedCandidate = first
                }
                if hits.isEmpty {
                    searchError = l10n.tr("没有搜到匹配的 TMDB 作品", "No matching TMDB entries found")
                }
            } catch {
                let rawMsg = (error as? TmdbError)?.message ?? error.localizedDescription
                searchError = l10n.coreMessage(rawMsg)
            }
        }
    }
}
