import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct MissingAssetsSectionView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let store: AppStore
    @Bindable var controller: HealthSessionController
    let items: [MissingAssetIssue]

    var body: some View {
        if items.isEmpty {
            EmptyStateCard(
                icon: "checkmark.circle",
                title: l10n.tr("NFO 与海报齐全", "All Metadata Present"),
                subtitle: l10n.tr(
                    "所有扫描到的作品都已有 NFO 与海报文件",
                    "All scanned titles already have NFO files and posters"
                )
            )
            .padding(.top, 24)
        } else {
            let selectedCount = controller.selectedMissingFolders.count
            let allSelected = selectedCount == items.count

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text(
                        l10n.tr(
                            "已选 \(selectedCount) / \(items.count) 个目录",
                            "\(selectedCount) / \(items.count) folders selected"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .monospacedDigit()
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    QuietTextButton(
                        l10n.tr("全选", "Select All"),
                        isDisabled: controller.isBusyAction || allSelected,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        controller.selectAllMissingFolders()
                    }

                    QuietTextButton(
                        l10n.tr("取消全选", "Deselect All"),
                        isDisabled: controller.isBusyAction || selectedCount == 0,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        controller.clearMissingFolders()
                    }

                    PrimaryActionButton(
                        l10n.tr("一键刮削补全", "Scrape Missing"),
                        systemImage: "sparkles",
                        isDisabled: controller.isBusyAction || selectedCount == 0
                    ) {
                        Task {
                            await controller.scrapeSelectedMissing(store: store)
                        }
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
                            MissingAssetRowView(
                                item: item,
                                isChecked: controller.selectedMissingFolders.contains(item.folderPath),
                                isBusy: controller.isBusyAction,
                                onToggle: {
                                    controller.toggleMissingFolder(item.folderPath)
                                },
                                onScrapeOne: {
                                    Task {
                                        await controller.scrapeSingleMissing(item, store: store)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Single Missing Asset Row (`health_page.dart:921-965`)

private struct MissingAssetRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let item: MissingAssetIssue
    let isChecked: Bool
    let isBusy: Bool
    let onToggle: () -> Void
    let onScrapeOne: () -> Void

    var body: some View {
        InstantHoverRow(
            isSelected: false,
            cornerRadius: 0,
            padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10),
            action: nil
        ) {
            HStack(alignment: .center, spacing: 10) {
                InkCheckbox(isChecked: isChecked, action: onToggle)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.45 : 1.0)

                Button(action: onToggle) {
                    HStack(alignment: .center, spacing: 12) {
                        OutlinedIconTile(
                            item.kind == .movie ? "film" : "tv",
                            size: 30,
                            outlined: true
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.workTitle)
                                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)

                            Text(item.folderPath)
                                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                .foregroundStyle(palette.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.folderPath)
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 6) {
                            if item.missingNfo {
                                TagBadge(l10n.tr("缺 NFO", "No NFO"), tint: palette.danger)
                            }
                            if item.missingPoster {
                                TagBadge(l10n.tr("缺海报", "No Poster"), tint: palette.warning)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                QuietTextButton(
                    l10n.tr("补全", "Scrape"),
                    systemImage: "sparkles",
                    isDisabled: isBusy,
                    fontSize: TidyreelTypeScale.small,
                    action: onScrapeOne
                )
            }
        }
    }
}
