import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct UnassignedPane: View {
    let store: AppStore
    let taskId: TaskId
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let files = viewModel.review?.scan.unassigned ?? []
        let deletedPaths = viewModel.index?.plannedUnassignedDeletes ?? []
        let deletedCount = deletedPaths.count
        let hasGroups = !viewModel.assignableGroupTargets.isEmpty
        let flatItems = viewModel.unassignedFlatItems

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                QuietTextButton(
                    l10n.tr("返回作品", "Back to titles"),
                    systemImage: "chevron.left"
                ) {
                    viewModel.returnToWorks(store: store)
                }

                Spacer()

                if viewModel.hasUndeletedUnassignedJunk {
                    QuietTextButton(
                        l10n.tr("标记全部垃圾文件删除", "Delete all junk"),
                        systemImage: "trash",
                        isDestructive: true,
                        fontSize: TidyreelTypeScale.small
                    ) {
                        var updates: [String: Bool] = [:]
                        for f in files where f.role == .junk && !deletedPaths.contains(f.path) {
                            updates[f.path] = true
                        }
                        Task {
                            await viewModel.setManyUnassignedDeletes(
                                store: store,
                                taskId: taskId,
                                updates: updates
                            )
                        }
                    }
                }

                if deletedCount > 0 {
                    QuietTextButton(
                        l10n.tr("全部保留", "Keep all"),
                        systemImage: "arrow.uturn.backward",
                        fontSize: TidyreelTypeScale.small
                    ) {
                        var updates: [String: Bool] = [:]
                        for f in files where deletedPaths.contains(f.path) {
                            updates[f.path] = false
                        }
                        Task {
                            await viewModel.setManyUnassignedDeletes(
                                store: store,
                                taskId: taskId,
                                updates: updates
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if files.isEmpty {
                EmptyStateCard(
                    icon: "checkmark.circle",
                    title: l10n.tr("所有文件均已归入作品", "All files assigned")
                )
                .padding(.bottom, 104)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(
                            l10n.tr(
                                "未归类 \(files.count) 个文件",
                                l10n.plural(files.count, "Unassigned file")
                            )
                        )
                        .font(.system(size: TidyreelTypeScale.headline, weight: .bold))
                        .foregroundStyle(palette.text)

                        Text(summaryText(totalCount: files.count, deletedCount: deletedCount))
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(deletedCount > 0 ? palette.danger : palette.textMuted)
                            .padding(.top, 4)

                        ForEach(flatItems) { item in
                            switch item {
                            case .header(let dir):
                                Text(dir)
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.top, 14)
                                    .padding(.bottom, 6)

                            case .file(let file, let isFirst, let isLast):
                                UnassignedFileRowView(
                                    file: file,
                                    willDelete: deletedPaths.contains(file.path),
                                    hasGroups: hasGroups,
                                    viewModel: viewModel,
                                    showsBottomDivider: !isLast,
                                    onToggleDelete: {
                                        let currentDelete = deletedPaths.contains(file.path)
                                        Task {
                                            await viewModel.setUnassignedDelete(
                                                store: store,
                                                taskId: taskId,
                                                filePath: file.path,
                                                delete: !currentDelete
                                            )
                                        }
                                    },
                                    onAssign: { targetGroupId in
                                        Task {
                                            await viewModel.assignUnassigned(
                                                store: store,
                                                taskId: taskId,
                                                filePath: file.path,
                                                targetGroup: targetGroupId
                                            )
                                        }
                                    }
                                )
                                .background(palette.panel)
                                .clipShape(
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: isFirst ? TidyreelRadii.lg : 0,
                                        bottomLeadingRadius: isLast ? TidyreelRadii.lg : 0,
                                        bottomTrailingRadius: isLast ? TidyreelRadii.lg : 0,
                                        topTrailingRadius: isFirst ? TidyreelRadii.lg : 0,
                                        style: .continuous
                                    )
                                )
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 104, trailing: 20))
                }
            }
        }
        .background(palette.canvas)
    }

    private func summaryText(totalCount: Int, deletedCount: Int) -> String {
        if deletedCount == 0 {
            return l10n.tr(
                "这些文件没归进任何作品，整理时原样保留。",
                "These files do not belong to any title and will be left untouched."
            )
        }
        if deletedCount == totalCount {
            return l10n.tr(
                "这些文件没归进任何作品，且已计划删除，确认整理后将被永久删除。",
                "These unassigned files are marked for deletion and will be permanently deleted when organizing."
            )
        }
        return l10n.tr(
            "共 \(totalCount) 个未归类文件：其中 \(deletedCount) 个已计划在整理时永久删除，其余原样保留。",
            "\(l10n.plural(totalCount, "unassigned file")): \(deletedCount) scheduled for permanent deletion; the rest will be kept."
        )
    }
}

private struct UnassignedFileRowView: View {
    let file: ScanFile
    let willDelete: Bool
    let hasGroups: Bool
    let viewModel: ReviewViewModel
    let showsBottomDivider: Bool
    let onToggleDelete: () -> Void
    let onAssign: (GroupId) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isDeleteHovered = false

    private var roleIcon: String {
        switch file.role {
        case .video: return "film"
        case .subtitle: return "captions.bubble"
        case .sidecar: return "doc.text"
        case .junk: return "trash"
        case .other: return "doc"
        }
    }

    var body: some View {
        let sizeStr = formatBytesOrEmpty(file.size)
        let meta = [
            sizeStr.isEmpty ? nil : sizeStr,
            unassignedReasonLabel(file, l10n: l10n),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")

        HStack(spacing: 10) {
            Image(systemName: roleIcon)
                .font(.system(size: 14))
                .foregroundStyle(willDelete ? palette.danger : palette.textMuted)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                    .foregroundStyle(willDelete ? palette.textMuted : palette.text)
                    .strikethrough(willDelete, color: palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(meta)
                    .font(.system(size: TidyreelTypeScale.small))
                    .monospacedDigit()
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Toggle Keep / Delete pill (`review_panes.dart:2775-2818`)
            Button(action: onToggleDelete) {
                HStack(spacing: 4) {
                    Image(systemName: willDelete ? "trash" : "checkmark.circle")
                        .font(.system(size: 11.5))
                    Text(willDelete ? l10n.delete : l10n.tr("保留", "Keep"))
                        .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                }
                .foregroundStyle(willDelete ? palette.danger : palette.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(
                            willDelete
                                ? palette.danger.opacity(0.10)
                                : (isDeleteHovered ? palette.hover : palette.panel)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(
                            willDelete ? palette.danger.opacity(0.35) : palette.lineStrong,
                            lineWidth: hairlineWidth
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovered = $0 }

            if hasGroups {
                AssignPopoverButton(viewModel: viewModel, onAssign: onAssign)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: hairlineWidth)
                    .padding(.leading, 40)
            }
        }
    }
}

private struct AssignPopoverButton: View {
    let viewModel: ReviewViewModel
    let onAssign: (GroupId) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textMuted)
                Text(l10n.tr("归入作品…", "Assign…"))
                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(isHovered ? palette.hover : palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(l10n.tr("归入已有作品", "Assign to existing title"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AssignGroupPopoverList(
                targets: viewModel.assignableGroupTargets,
                onSelect: { groupId in
                    isPresented = false
                    onAssign(groupId)
                }
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }
}

private struct AssignGroupPopoverList: View {
    let targets: [AssignGroupTarget]
    let onSelect: (GroupId) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        let rowHeight: CGFloat = 30
        let contentHeight = min(320, max(40, CGFloat(targets.count) * rowHeight + 12))

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(targets) { target in
                    InstantHoverRow(
                        cornerRadius: TidyreelRadii.sm,
                        padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
                        action: { onSelect(target.id) }
                    ) {
                        Text(target.label)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 280, height: contentHeight)
        .background(palette.panel)
    }
}
