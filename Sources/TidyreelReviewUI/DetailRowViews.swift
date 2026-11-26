import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels

// MARK: - Episode Number Badge (`_EpBadge` in `review_panes.dart:1394-1431`)

private struct EpisodeBadgeView: View {
    let text: String
    var dim: Bool = false
    var color: Color? = nil

    @Environment(\.palette) private var palette

    var body: some View {
        let fill: Color = dim
            ? .clear
            : (color?.opacity(0.13) ?? palette.sidebar)
        let stroke: Color = dim
            ? palette.lineStrong
            : (color?.opacity(0.30) ?? palette.line)
        let fg: Color = dim
            ? palette.textFaint
            : (color ?? palette.text)

        Text(text)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(fg)
            .frame(width: 34, height: 26)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(stroke, lineWidth: dim ? 1.0 : hairlineWidth)
            )
    }
}

// MARK: - Virtualized Episode / Movie Row (`_EpisodeRow` in `review_panes.dart:1600-1850`)

struct DetailEpisodeRowView: View {
    let row: ReviewRow
    let display: EpisodeRowDisplay
    let isTvMatched: Bool
    let isTvGroup: Bool
    let tmdbEpisode: Episode?
    let formattedAirDate: String?
    let isHighlighted: Bool
    let isMultiSelectMode: Bool
    let isMultiSelected: Bool
    let canSplitGroup: Bool
    let showsBottomDivider: Bool
    let onPrimaryClick: () -> Void
    let onToggleInclude: (Bool) -> Void
    let onToggleMultiSelect: () -> Void
    let onOpenEdit: () -> Void
    let onSplitSingle: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let target = row.targetRef
        let issueColor: Color? = row.conflict ? palette.danger : (display.hasWarning ? palette.warning : nil)
        let epColor: Color? = (target == nil || row.ignored)
            ? nil
            : seasonBadgeColor(target!.season, isDark: palette.isDark)
        let techBadges = row.techBadges(for: l10n)
        let sizeStr = row.sizeText

        let rowFill: Color = {
            if isHighlighted { return palette.danger.opacity(0.12) }
            if isMultiSelected { return palette.selected }
            if isHovered { return palette.hover }
            if let issueColor { return issueColor.opacity(0.05) }
            return .clear
        }()

        HStack(alignment: .top, spacing: 0) {
            InkCheckbox(isChecked: isMultiSelectMode ? isMultiSelected : row.selected) {
                if isMultiSelectMode {
                    onToggleMultiSelect()
                } else {
                    onToggleInclude(!row.selected)
                }
            }
            .frame(width: 28, alignment: .center)
            .padding(.top, 5)

            Spacer().frame(width: 2)

            Group {
                if row.bucket == .extras {
                    EpisodeBadgeView(text: "EX", color: palette.textMuted)
                } else if !isTvGroup && target == nil {
                    OutlinedIconTile(
                        row.file.isDiscDir ? "opticaldisc" : "film",
                        size: 26
                    )
                } else {
                    let badgeText = target.map { String(format: "%02d", $0.episode) } ?? "—"
                    EpisodeBadgeView(text: badgeText, color: epColor)
                }
            }
            .padding(.top, 1)

            Spacer().frame(width: 12)

            // Main content: Episode Title (TV) + 原文件名 → 新文件名 + Tech Badges
            VStack(alignment: .leading, spacing: 3) {
                if isTvMatched {
                    HStack(spacing: 8) {
                        Text(
                            tmdbEpisode?.title
                                ?? (target == nil
                                    ? l10n.tr("未识别集号", "Episode unknown")
                                    : l10n.tr("第 \(target!.episode) 集", "Episode \(target!.episode)"))
                        )
                        .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                        .foregroundStyle(row.ignored ? palette.textFaint : palette.text)
                        .lineLimit(1)

                        if let airStr = formattedAirDate {
                            Text(airStr)
                                .font(.system(size: TidyreelTypeScale.small))
                                .monospacedDigit()
                                .foregroundStyle(palette.textFaint)
                        }
                    }
                }

                // 原文件名
                Text(row.file.name)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(2)
                    .truncationMode(.middle)

                // → 新文件名
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(row.conflict ? palette.danger : palette.textFaint)
                        .padding(.top, 3)

                    Text(display.diffText)
                        .strikethrough(row.ignored, color: palette.textFaint)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                if !techBadges.isEmpty {
                    TechBadgeRowView(badges: techBadges)
                        .padding(.top, 1)
                }

                if row.conflict {
                    if row.conflictReason != nil {
                        Text(display.conflictDetail)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.danger)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        if !sizeStr.isEmpty {
                            Text(sizeStr)
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(palette.textMuted)
                        }

                        QuickInlineActionChip(
                            label: isTvGroup
                                ? l10n.tr("修改集号", "Edit episode")
                                : l10n.tr("修改对应关系", "Edit mapping"),
                            systemImage: "pencil",
                            tint: nil,
                            action: onOpenEdit
                        )

                        QuickInlineActionChip(
                            label: l10n.tr("忽略此文件", "Ignore"),
                            systemImage: "eye.slash",
                            tint: palette.danger
                        ) {
                            onToggleInclude(false)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPrimaryClick)

            Spacer().frame(width: 8)

            // Trailing status tags, decimal size, and hover edit icon
            HStack(spacing: 5) {
                if row.conflict {
                    TagBadge(l10n.tr("冲突", "Conflict"), tint: palette.danger)
                } else if display.missingEpNumber {
                    TagBadge(l10n.tr("未识别到集号", "No episode #"), tint: palette.warning)
                } else if let warning = row.op?.warning {
                    TagBadge(localizeCoreMessage(l10n, warning), tint: palette.warning)
                }

                if display.lowConfidence {
                    TagBadge(l10n.tr("不确定", "Uncertain"), tint: palette.warning)
                }

                if !sizeStr.isEmpty && !row.conflict {
                    Text(sizeStr)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(palette.textFaint)
                }

                Button(action: onOpenEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .opacity(isHovered ? 1 : 0)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 6, bottom: 9, trailing: 12))
        .background(rowFill)
        .overlay(alignment: .leading) {
            if let issueColor {
                Rectangle()
                    .fill(issueColor)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 52)
            }
        }
        .onHover { isHovered = $0 }
        .help(display.tooltipText)
        .contextMenu {
            Button(action: onOpenEdit) {
                Label(l10n.tr("修改对应关系…", "Edit mapping…"), systemImage: "pencil")
            }
            Button {
                onToggleInclude(!row.selected)
            } label: {
                Label(
                    row.selected
                        ? l10n.tr("忽略这个文件", "Ignore file")
                        : l10n.tr("参与整理", "Include file"),
                    systemImage: row.selected ? "eye.slash" : "arrow.uturn.backward"
                )
            }
            if canSplitGroup {
                Divider()
                Button(action: onToggleMultiSelect) {
                    Label(l10n.tr("加入多选拆分", "Select for split"), systemImage: "checkmark.circle")
                }
                Button(action: onSplitSingle) {
                    Label(l10n.tr("拆分为新作品", "Split into new group"), systemImage: "scissors")
                }
            }
        }
    }
}

// MARK: - Companion Fold Toggle (`_VideoBlock` in `review_panes.dart:1270-1305`)

struct CompanionFoldToggleRow: View {
    let summary: String
    let isOpen: Bool
    let showsBottomDivider: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))

                Text(summary)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(isHovered ? palette.text : palette.textMuted)

                Spacer()
            }
            .padding(EdgeInsets(top: 0, leading: 52, bottom: 7, trailing: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 52)
            }
        }
    }
}

// MARK: - Virtualized Companion / Sidecar Row (`_SidecarRow` in `review_panes.dart:1853-2058`)

struct DetailSidecarRowView: View {
    let row: ReviewRow
    let display: SidecarRowDisplay
    let isIndented: Bool
    let isHighlighted: Bool
    let isMultiSelectMode: Bool
    let isMultiSelected: Bool
    let showsBottomDivider: Bool
    let onPrimaryClick: () -> Void
    let onToggleInclude: (Bool) -> Void
    let onToggleMultiSelect: () -> Void
    let onOpenEdit: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let techBadges = row.techBadges(for: l10n)
        let sizeStr = row.sizeText

        let fill: Color = {
            if isHighlighted { return palette.danger.opacity(0.12) }
            if isMultiSelected { return palette.selected }
            if isHovered { return palette.hover }
            if row.conflict { return palette.danger.opacity(0.05) }
            return .clear
        }()

        HStack(alignment: .top, spacing: 0) {
            InkCheckbox(isChecked: isMultiSelectMode ? isMultiSelected : row.selected) {
                if isMultiSelectMode {
                    onToggleMultiSelect()
                } else {
                    onToggleInclude(!row.selected)
                }
            }
            .frame(width: 28, alignment: .center)
            .padding(.top, 2)

            Spacer().frame(width: 14)

            Image(systemName: display.roleIcon)
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)
                .padding(.top, 3)

            Spacer().frame(width: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.file.name)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(display.diffText)
                    .strikethrough(row.ignored, color: palette.textFaint)
                    .lineLimit(1)

                if !techBadges.isEmpty {
                    TechBadgeRowView(badges: techBadges)
                        .padding(.top, 1)
                }

                if row.conflict {
                    HStack(spacing: 6) {
                        QuickInlineActionChip(
                            label: l10n.tr("修改集号", "Edit episode"),
                            systemImage: "pencil",
                            tint: nil,
                            action: onOpenEdit
                        )
                        QuickInlineActionChip(
                            label: l10n.tr("忽略此文件", "Ignore"),
                            systemImage: "eye.slash",
                            tint: palette.danger
                        ) {
                            onToggleInclude(false)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPrimaryClick)

            Spacer().frame(width: 6)

            HStack(spacing: 5) {
                if row.conflict {
                    TagBadge(l10n.tr("冲突", "Conflict"), tint: palette.danger)
                } else if let w = row.op?.warning {
                    TagBadge(localizeCoreMessage(l10n, w), tint: palette.warning)
                }

                if !sizeStr.isEmpty {
                    Text(sizeStr)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(palette.textFaint)
                }

                Button(action: onOpenEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                        .opacity(isHovered ? 1 : 0)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 6, leading: isIndented ? 30 : 6, bottom: 6, trailing: 12))
        .background(fill)
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 52)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: onOpenEdit) {
                Label(l10n.tr("修改对应关系…", "Edit mapping…"), systemImage: "pencil")
            }
            Button {
                onToggleInclude(!row.selected)
            } label: {
                Label(
                    row.selected
                        ? l10n.tr("忽略这个文件", "Ignore file")
                        : l10n.tr("参与整理", "Include file"),
                    systemImage: row.selected ? "eye.slash" : "arrow.uturn.backward"
                )
            }
        }
    }
}

// MARK: - Missing Episode Placeholder Row (`_MissingRow` in `review_panes.dart:2061-2101`)

struct DetailMissingEpisodeRowView: View {
    let season: Int
    let episode: Int
    let tmdbEpisode: Episode?
    let formattedAirDate: String?
    let showsBottomDivider: Bool

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let titleParts: [String] = [
            tmdbEpisode?.title ?? l10n.tr("第 \(episode) 集", "Episode \(episode)"),
            formattedAirDate,
        ].compactMap { $0 }

        HStack(spacing: 12) {
            EpisodeBadgeView(text: String(format: "%02d", episode), dim: true)

            Text(titleParts.joined(separator: "  ·  "))
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textFaint)
                .lineLimit(1)

            Spacer()

            TagBadge(l10n.tr("本地缺失", "Missing"), tint: palette.warning)
        }
        .padding(EdgeInsets(top: 9, leading: 36, bottom: 9, trailing: 12))
        .background(palette.warning.opacity(0.04))
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 52)
            }
        }
    }
}

// MARK: - Shared Technical Badges & Quick Action Chip

private struct TechBadgeRowView: View {
    let badges: [TechBadgeItem]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges, id: \.self) { badge in
                let fg: Color = {
                    switch badge.tone {
                    case .accent: return palette.accent
                    case .success: return palette.success
                    case .neutral: return palette.textMuted
                    }
                }()
                let bg: Color = {
                    switch badge.tone {
                    case .accent: return palette.accent.opacity(0.12)
                    case .success: return palette.success.opacity(0.10)
                    case .neutral: return palette.selected
                    }
                }()
                Text(badge.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(bg)
                    )
            }
        }
    }
}

private struct QuickInlineActionChip: View {
    let label: String
    let systemImage: String
    let tint: Color?
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let c = tint ?? palette.text
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(c)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(isHovered ? c.opacity(0.12) : palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(tint?.opacity(0.35) ?? palette.lineStrong, lineWidth: hairlineWidth)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
