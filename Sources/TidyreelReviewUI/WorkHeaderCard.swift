import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels

// MARK: - Refined Frosted Artwork `WorkHeader` (`review_panes.dart:469-779`)

struct WorkHeaderCard: View {
    let group: MediaGroup
    let decision: GroupDecision
    let completeness: Completeness?
    let activeSeason: Int?
    let showInspector: Bool
    let onExpandInspector: () -> Void
    let onSearchTMDB: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let match = effectiveMatch(group, decision)
        let detailShow = (group.show?.info.tmdbId == match?.tmdbId) ? group.show : nil
        let detail = detailShow?.info
        let hasCustomTitleOverride: Bool = {
            guard let dm = decision.match, let base = detail?.title ?? group.match?.title, dm.tmdbId == (detail?.tmdbId ?? group.match?.tmdbId) else {
                return decision.match != nil
            }
            return dm.title != base
        }()
        let title = hasCustomTitleOverride
            ? (decision.match?.title ?? group.anchorTitle)
            : (detail?.title ?? match?.title ?? group.anchorTitle)

        let origTitle = match?.originalTitle ?? detail?.originalTitle
        let enTitle = match?.englishTitle ?? detail?.englishTitle
        let backdropPath = match?.backdropPath ?? detail?.backdropPath
        let seasonPoster = activeSeason.flatMap { sNum in
            detailShow?.seasons.first(where: { $0.number == sNum })?.posterPath
        }
        let posterPath = seasonPoster ?? match?.posterPath
        let genres = !(detail?.genres.isEmpty ?? true) ? (detail?.genres ?? []) : (match?.genres ?? [])
        let overview = match?.overview ?? detail?.overview
        let rating = match?.voteAverage ?? detail?.voteAverage
        let isTv = group.kind == .episode
        let comp = isTv ? completeness : nil
        let compLabel = comp?.localizedLabel(l10n)

        let metaChips: [(text: String, isWarning: Bool)] = {
            var arr: [(String, Bool)] = []
            if let y = match?.year { arr.append(("\(y)", false)) }
            let cLabel = countryLabel(match?.originCountry, l10n: l10n)
            if !cLabel.isEmpty { arr.append((cLabel, false)) }
            if !genres.isEmpty {
                arr.append((genres.prefix(3).joined(separator: " / "), false))
            }
            if isTv, let comp, let compLabel {
                arr.append((compLabel, comp.incomplete))
            } else {
                arr.append((
                    l10n.tr("电影，\(group.files.count) 个文件", "Movie, \(l10n.plural(group.files.count, "file"))"),
                    false
                ))
            }
            return arr
        }()

        ZStack {
            // Ambient backdrop (`w1280`, topTrailing) with dual Xuan-paper frosted gradients
            GeometryReader { geo in
                if let backdropPath, !backdropPath.isEmpty {
                    ZStack {
                        DownsampledArtworkView(
                            tmdbPath: backdropPath,
                            sizeBucket: "w1280",
                            width: max(1, geo.size.width),
                            height: max(1, geo.size.height),
                            cornerRadius: 0,
                            alignment: .topTrailing,
                            showsBorder: false
                        )
                        LinearGradient(
                            stops: [
                                .init(color: palette.panel.opacity(0.97), location: 0.0),
                                .init(color: palette.panel.opacity(0.86), location: 0.50),
                                .init(color: palette.panel.opacity(0.18), location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        LinearGradient(
                            colors: [
                                palette.panel.opacity(0.90),
                                palette.panel.opacity(0.0),
                            ],
                            startPoint: .bottom,
                            endPoint: .center
                        )
                    }
                } else {
                    LinearGradient(
                        colors: [palette.accentSoft, palette.panel],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }

            HStack(alignment: .top, spacing: 20) {
                DownsampledArtworkView(
                    tmdbPath: posterPath,
                    width: 112,
                    height: 168,
                    cornerRadius: 9,
                    fallbackSystemImage: isTv ? "tv" : "film"
                )

                VStack(alignment: .leading, spacing: 0) {
                    // Title (26pt semibold) + RatingBadge + optional collapsed inspector actions
                    HStack(alignment: .top, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title)
                                .font(.system(size: TidyreelTypeScale.title, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundStyle(palette.text)
                                .lineLimit(2)

                            if let rating, rating > 0 {
                                RatingBadgeView(value: rating)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !showInspector {
                            HStack(spacing: 6) {
                                SecondaryActionButton(
                                    l10n.tr("重新搜索 TMDB", "Search TMDB"),
                                    systemImage: "magnifyingglass",
                                    action: onSearchTMDB
                                )
                                SecondaryActionButton(
                                    l10n.tr("展开作品操作", "Show Inspector"),
                                    systemImage: "sidebar.right",
                                    action: onExpandInspector
                                )
                            }
                        }
                    }

                    // Original / English subtitle
                    if let origTitle, !origTitle.isEmpty, origTitle != title {
                        let subtitleParts: [String] = {
                            if let enTitle, !enTitle.isEmpty, enTitle != origTitle, enTitle != title {
                                return [origTitle, enTitle]
                            }
                            return [origTitle]
                        }()
                        Text(subtitleParts.joined(separator: "  ·  "))
                            .font(.system(size: TidyreelTypeScale.body))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }

                    // Framed metadata chips (`palette.panel.opacity(0.7)` + `0.5pt` `palette.line`)
                    HStack(spacing: 6) {
                        ForEach(Array(metaChips.enumerated()), id: \.offset) { _, chip in
                            Text(chip.text)
                                .font(.system(size: TidyreelTypeScale.small))
                                .monospacedDigit()
                                .foregroundStyle(chip.isWarning ? palette.warning : palette.text)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                        .fill(palette.panel.opacity(0.7))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                        .strokeBorder(palette.line, lineWidth: hairlineWidth)
                                )
                        }
                    }
                    .padding(.top, 8)

                    // 220pt TV completeness progress bar
                    if isTv, match != nil, let comp, let frac = comp.progressFraction {
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(palette.line)
                                Capsule()
                                    .fill(comp.incomplete ? palette.warning : palette.success)
                                    .frame(width: max(6, barGeo.size.width * frac))
                            }
                        }
                        .frame(width: 220, height: 5)
                        .padding(.top, 10)
                    }

                    // Expandable 3-line overview (`UnderlinedLinkText("展开" / "收起")`)
                    if let overview, !overview.isEmpty {
                        ExpandableOverviewText(text: overview)
                            .id(overview)
                            .padding(.top, 10)
                    }

                    // Unmatched prompt
                    if match == nil {
                        HStack(spacing: 8) {
                            Text(l10n.tr("还没有匹配到 TMDB 条目", "Not matched to a TMDB entry yet"))
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.danger)
                            if showInspector {
                                SecondaryActionButton(
                                    l10n.tr("重新搜索 TMDB", "Search TMDB"),
                                    systemImage: "magnifyingglass",
                                    action: onSearchTMDB
                                )
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 20, trailing: 20))
        }
        .clipShape(RoundedRectangle(cornerRadius: TidyreelRadii.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.xl, style: .continuous)
                .strokeBorder(palette.line, lineWidth: hairlineWidth)
        )
    }
}

/// 3-line truncated overview with accurate width-aware overflow detection and `UnderlinedLinkText`.
private struct ExpandableOverviewText: View {
    let text: String

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isExpanded = false
    @State private var containerWidth: CGFloat = 0

    private var overflowsThreeLines: Bool {
        guard containerWidth > 20 else {
            return text.count > 120 || text.filter({ $0 == "\n" }).count >= 3
        }
        let font = NSFont.systemFont(ofSize: TidyreelTypeScale.small)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style,
        ]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: containerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let singleLine = ceil(font.ascender - font.descender + font.leading)
        let threeLineMax = singleLine * 3 + 8 + 2
        return rect.height > threeLineMax
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: TidyreelTypeScale.small))
                .lineSpacing(4)
                .foregroundStyle(palette.textMuted)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { containerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in containerWidth = w }
                    }
                )

            if overflowsThreeLines {
                UnderlinedLinkText(
                    isExpanded ? l10n.tr("收起", "Show less") : l10n.tr("展开", "Show more")
                ) {
                    isExpanded.toggle()
                }
            }
        }
    }
}
