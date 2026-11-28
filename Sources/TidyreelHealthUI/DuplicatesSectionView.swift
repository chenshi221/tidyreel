import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct DuplicatesSectionView: View {
    @Environment(\.l10n) private var l10n

    @Bindable var controller: HealthSessionController
    let issues: [DuplicateMediaIssue]

    var body: some View {
        if issues.isEmpty {
            EmptyStateCard(
                icon: "checkmark.circle",
                title: l10n.tr("没有发现重复片源", "No Duplicates Found"),
                subtitle: l10n.tr(
                    "每部电影与每集剧集都只保存了一份副本",
                    "Every movie and episode has only a single copy"
                )
            )
            .padding(.top, 24)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(issues) { issue in
                    DuplicateIssueCard(
                        issue: issue,
                        controller: controller
                    )
                }
            }
        }
    }
}

// MARK: - Single Duplicate Issue Card (`health_page.dart:672-740`)

private struct DuplicateIssueCard: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let issue: DuplicateMediaIssue
    @Bindable var controller: HealthSessionController

    var body: some View {
        let isMovie = issue.kind == .movie
        let summaryText = l10n.tr(
            "共 \(issue.copies.count) 份副本\(issue.reclaimableBytes > 0 ? " · 删除冗余可释放 \(formatBytes(issue.reclaimableBytes))" : "")",
            "\(issue.copies.count) copies\(issue.reclaimableBytes > 0 ? " · \(formatBytes(issue.reclaimableBytes)) reclaimable" : "")"
        )

        PanelBox(padding: EdgeInsets(), framed: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    OutlinedIconTile(isMovie ? "film" : "tv", size: 32, outlined: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)

                        Text(summaryText)
                            .font(.system(size: TidyreelTypeScale.small))
                            .monospacedDigit()
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    SecondaryActionButton(
                        l10n.tr("删除冗余副本", "Delete Redundant"),
                        systemImage: "trash",
                        isDestructive: true,
                        isDisabled: controller.isBusyAction || issue.redundantCopies.isEmpty
                    ) {
                        controller.requestDeleteIssueRedundant(issue)
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 12))

                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(issue.copies.enumerated()), id: \.element.id) { index, copy in
                        if index > 0 {
                            Rectangle()
                                .fill(palette.line)
                                .frame(height: hairlineWidth)
                                .padding(.leading, 16)
                        }
                        DuplicateCopyRowView(
                            copy: copy,
                            recommended: copy.path == issue.recommendedKeepPath,
                            isBusy: controller.isBusyAction
                        ) {
                            controller.requestDeleteSingleCopy(copy)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Single Copy Row (`health_page.dart:748-820`)

private struct DuplicateCopyRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let copy: DuplicateMediaCopy
    let recommended: Bool
    let isBusy: Bool
    let onDelete: () -> Void

    var body: some View {
        let badges = copy.localizedQualityBadges(l10n)

        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FlowHStack(horizontalSpacing: 6, verticalSpacing: 4) {
                    if recommended {
                        TagBadge(l10n.tr("推荐保留", "Recommended"), tint: palette.success)
                    }
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                        TagBadge(badge)
                    }
                    if copy.fileSize > 0 {
                        Text(formatBytes(copy.fileSize))
                            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(palette.text)
                    }
                }

                Text(copy.path)
                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(copy.path)
            }

            Spacer(minLength: 8)

            QuietIconButton(
                systemImage: "trash",
                tooltip: copy.isDiscDir
                    ? l10n.tr("原盘目录请前往「来源」手动处理", "Manage disc folders manually in Sources")
                    : l10n.tr("删除此副本", "Delete This Copy"),
                iconSize: 14,
                tint: palette.danger,
                isDisabled: isBusy || copy.isDiscDir,
                action: onDelete
            )
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 10))
        .background(recommended ? palette.success.opacity(palette.isDark ? 0.08 : 0.05) : Color.clear)
    }
}

// MARK: - Permanent Deletion Confirmation Sheet (`confirmPermanentDelete` in `common.dart`)

struct DuplicateDeleteConfirmSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    let payload: DuplicateDeletePayload
    let isBusy: Bool
    let onConfirm: () -> Void

    var body: some View {
        let count = payload.copies.count
        let sizeSummary = formatBytesOrEmpty(payload.totalBytes)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OutlinedIconTile("trash", size: 32, outlined: true, iconColor: palette.danger)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        l10n.tr(
                            "永久删除 \(count) 个副本？",
                            "Permanently delete \(l10n.plural(count, "copy", "copies"))?"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                    .foregroundStyle(palette.text)

                    if !sizeSummary.isEmpty {
                        Text(
                            l10n.tr(
                                "共 \(count) 个文件 · 可释放 \(sizeSummary)",
                                "\(l10n.plural(count, "file")) · \(sizeSummary) reclaimable"
                            )
                        )
                        .font(.system(size: TidyreelTypeScale.small))
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                    }
                }
                Spacer()
            }

            Text(
                l10n.tr(
                    "此操作将直接从存储源永久删除以下文件，无法通过理片撤销。请确认路径无误。",
                    "This permanently deletes the files below from your storage source and cannot be undone in Tidyreel."
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            PanelBox(padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10), framed: true) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(payload.copies.enumerated()), id: \.element.id) { idx, copy in
                            if idx > 0 {
                                Rectangle()
                                    .fill(palette.line)
                                    .frame(height: hairlineWidth)
                            }
                            HStack(spacing: 8) {
                                Text(copy.path)
                                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(copy.path)
                                Spacer(minLength: 8)
                                if copy.fileSize > 0 {
                                    Text(formatBytes(copy.fileSize))
                                        .font(.system(size: TidyreelTypeScale.small))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.textMuted)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                Spacer()
                SecondaryActionButton(l10n.cancel, isDisabled: isBusy) {
                    dismiss()
                }
                SecondaryActionButton(
                    l10n.tr("永久删除", "Delete Permanently"),
                    systemImage: "trash",
                    isDestructive: true,
                    isDisabled: isBusy
                ) {
                    onConfirm()
                }
            }
        }
        .padding(22)
        .frame(width: 540, height: 400)
        .background(palette.canvas)
    }
}
