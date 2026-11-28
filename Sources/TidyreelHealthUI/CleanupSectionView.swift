import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct CleanupSectionView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @Bindable var controller: HealthSessionController
    let report: HealthReport

    var body: some View {
        let items = report.cleanupItems
        if items.isEmpty {
            EmptyStateCard(
                icon: "checkmark.circle",
                title: l10n.tr("没有待清理项目", "Nothing to Clean Up"),
                subtitle: l10n.tr(
                    "未发现广告垃圾文件或空目录",
                    "No ad/junk files or empty folders found"
                )
            )
            .padding(.top, 24)
        } else {
            let selectedCount = controller.selectedCleanupPaths.count
            let selectedBytes = controller.selectedCleanupBytes
            let summaryText = selectedBytes > 0
                ? l10n.tr(
                    "已选 \(selectedCount) 项 · \(formatBytes(selectedBytes))",
                    "\(selectedCount) selected · \(formatBytes(selectedBytes))"
                )
                : l10n.tr(
                    "已选 \(selectedCount) 项",
                    "\(selectedCount) selected"
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text(summaryText)
                        .font(.system(size: TidyreelTypeScale.small))
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    QuietTextButton(
                        l10n.tr("全选垃圾", "Select Junk"),
                        isDisabled: controller.isBusyAction || controller.junkCount == 0,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        controller.selectAllJunkFiles()
                    }

                    QuietTextButton(
                        l10n.tr("全选空目录", "Select Empty Folders"),
                        isDisabled: controller.isBusyAction || controller.emptyDirCount == 0,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        controller.selectAllEmptyDirs()
                    }

                    QuietTextButton(
                        l10n.tr("清空选择", "Clear Selection"),
                        isDisabled: controller.isBusyAction || selectedCount == 0,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        controller.clearCleanupSelection()
                    }

                    SecondaryActionButton(
                        l10n.tr("删除选中项", "Delete Selected"),
                        systemImage: "trash",
                        isDestructive: true,
                        isDisabled: controller.isBusyAction || selectedCount == 0
                    ) {
                        controller.requestCleanupSelected()
                    }
                    .padding(.leading, 2)
                }

                PanelBox(padding: EdgeInsets(), framed: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle()
                                    .fill(palette.line)
                                    .frame(height: hairlineWidth)
                                    .padding(.leading, 84)
                            }
                            CleanupIssueRowView(
                                item: item,
                                isChecked: controller.selectedCleanupPaths.contains(item.path),
                                isBusy: controller.isBusyAction
                            ) {
                                controller.toggleCleanupPath(item.path)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Single Cleanup Row (`health_page.dart:1120-1174`)

private struct CleanupIssueRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let item: CleanupIssue
    let isChecked: Bool
    let isBusy: Bool
    let onToggle: () -> Void

    var body: some View {
        let reasonLabel = HealthSessionController.localizedCleanupReason(item.reason, l10n: l10n)

        InstantHoverRow(
            isSelected: false,
            cornerRadius: 0,
            padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
            action: nil
        ) {
            HStack(alignment: .center, spacing: 10) {
                InkCheckbox(isChecked: isChecked, action: onToggle)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.45 : 1.0)

                Button(action: onToggle) {
                    HStack(alignment: .center, spacing: 12) {
                        OutlinedIconTile(
                            item.kind == .emptyDir ? "folder" : "doc.text",
                            size: 30,
                            outlined: true
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)

                            Text(item.path)
                                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                .foregroundStyle(palette.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.path)
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            TagBadge(
                                reasonLabel,
                                tint: item.kind == .junkFile ? palette.danger : palette.warning
                            )
                            if item.size > 0 {
                                Text(formatBytes(item.size))
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.textMuted)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }
}

// MARK: - Permanent Deletion Confirmation Sheet (`health_page.dart:1021-1044`)

struct CleanupConfirmSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    let payload: CleanupConfirmPayload
    let isBusy: Bool
    let onConfirm: () -> Void

    var body: some View {
        let fileCount = payload.junkFiles.count
        let dirCount = payload.emptyDirs.count
        let totalCount = payload.items.count
        let onlyEmptyDirs = fileCount == 0 && dirCount > 0
        let sizeText = formatBytesOrEmpty(payload.totalJunkBytes)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OutlinedIconTile(
                    onlyEmptyDirs ? "folder" : "trash",
                    size: 32,
                    outlined: true,
                    iconColor: palette.danger
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        onlyEmptyDirs
                            ? l10n.tr(
                                "删除 \(dirCount) 个空目录？",
                                "Delete \(l10n.plural(dirCount, "empty folder"))?"
                            )
                            : l10n.tr(
                                "永久删除 \(totalCount) 个项目？",
                                "Permanently delete \(l10n.plural(totalCount, "item"))?"
                            )
                    )
                    .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                    .foregroundStyle(palette.text)

                    Text(subtitleLine(fileCount: fileCount, dirCount: dirCount, sizeText: sizeText))
                        .font(.system(size: TidyreelTypeScale.small))
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                }
                Spacer()
            }

            Text(
                onlyEmptyDirs
                    ? l10n.tr(
                        "仅会删除确认为空（或仅含系统隐藏文件）的目录，删除前会再次实时校验。",
                        "Only folders verified to be empty (or containing only OS hidden files) will be removed after a live re-check."
                    )
                    : l10n.tr(
                        "此操作将直接从存储源永久删除所选项目（删除空目录前会实时复查确保不含正常文件），无法通过理片撤销。",
                        "This permanently removes the selected items from your storage source (empty folders are live-checked before removal) and cannot be undone in Tidyreel."
                    )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            PanelBox(padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10), framed: true) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(payload.items.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 {
                                Rectangle()
                                    .fill(palette.line)
                                    .frame(height: hairlineWidth)
                            }
                            HStack(spacing: 8) {
                                Image(systemName: item.kind == .emptyDir ? "folder" : "doc.text")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.textFaint)
                                Text(item.path)
                                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.path)
                                Spacer(minLength: 8)
                                TagBadge(
                                    HealthSessionController.localizedCleanupReason(item.reason, l10n: l10n),
                                    tint: item.kind == .junkFile ? palette.danger : palette.warning
                                )
                                if item.size > 0 {
                                    Text(formatBytes(item.size))
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
                    onlyEmptyDirs
                        ? l10n.tr("删除空目录", "Delete Empty Folders")
                        : l10n.tr("永久删除", "Delete Permanently"),
                    systemImage: "trash",
                    isDestructive: true,
                    isDisabled: isBusy
                ) {
                    onConfirm()
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 420)
        .background(palette.canvas)
    }

    private func subtitleLine(fileCount: Int, dirCount: Int, sizeText: String) -> String {
        let sizeSuffix = sizeText.isEmpty ? "" : "（\(sizeText)）"
        let enSizeSuffix = sizeText.isEmpty ? "" : " (\(sizeText))"
        if fileCount > 0 && dirCount > 0 {
            return l10n.tr(
                "垃圾文件 \(fileCount) 个\(sizeSuffix) · 空目录 \(dirCount) 个",
                "\(l10n.plural(fileCount, "junk file"))\(enSizeSuffix) · \(l10n.plural(dirCount, "empty folder"))"
            )
        } else if fileCount > 0 {
            return l10n.tr(
                "垃圾文件 \(fileCount) 个\(sizeSuffix)",
                "\(l10n.plural(fileCount, "junk file"))\(enSizeSuffix)"
            )
        } else {
            return l10n.tr(
                "空目录 \(dirCount) 个",
                l10n.plural(dirCount, "empty folder")
            )
        }
    }
}
