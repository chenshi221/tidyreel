import SwiftUI
import TidyreelDesign
import TidyreelModels

/// Strictly synchronous O(1) task card rendered from `TaskSummary` + pre-decoded `TaskCardMeta?`
/// (`tasks_page.dart:288-637`). Never touches SQLite or `review()` during scroll.
struct TaskCardView: View {
    let task: TaskSummary
    let meta: TaskCardMeta?
    let connectionName: String
    let reduceMotion: Bool
    let isBusy: Bool

    let onOpenReview: () -> Void
    let onRunConfident: () -> Void
    let onCancel: () -> Void
    let onRetryFailed: () -> Void
    let onUndo: () -> Void
    let onRetry: () -> Void
    let onOpenDetail: () -> Void
    let onRequestDelete: () -> Void
    let onOpenSettings: () -> Void
    let onCopyTaskId: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false
    @State private var isMoreHovered = false

    var body: some View {
        let recognized = TaskCardMeta.isRecognizedStage(task.stage)
        let works = recognized ? (meta?.works ?? []) : []
        let unassigned = recognized ? (meta?.unassignedCount ?? 0) : 0
        let title = TasksFormatting.displayTitle(task: task, works: works, l10n: l10n)
        let metaLine = TasksFormatting.metadataLine(
            task: task,
            connectionName: connectionName,
            recognized: recognized,
            unassignedCount: unassigned,
            l10n: l10n
        )
        let running = task.stage.isActive && task.stage != .awaitingReview
        let statusColor = TasksFormatting.stageColor(task.stage, palette: palette)
        let problem = problemMessage
        let needsTmdbKey = task.stage == .failed && TasksFormatting.isTmdbApiKeyError(task.message)
        let showStepper = task.stage.isActive && TasksFormatting.currentStep(task.stage) >= 0

        HStack(alignment: .center, spacing: 0) {
            Button(action: handleCardTap) {
                HStack(alignment: .center, spacing: 0) {
                    DownsampledArtworkView(
                        tmdbPath: works.first?.posterPath,
                        width: 64,
                        height: 96,
                        cornerRadius: TidyreelRadii.sm,
                        fallbackSystemImage: "folder"
                    )

                    Spacer().frame(width: 18)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if task.scrapeOnly {
                                TagBadge(l10n.tr("仅刮削", "Scrape Only"), tint: palette.accent)
                            }
                        }

                        Text(metaLine)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.paths.joined(separator: "\n"))
                            .padding(.top, 3)

                        if let problem {
                            Text(problem)
                                .font(.system(size: 12))
                                .foregroundStyle(task.stage == .failed ? palette.danger : palette.warning)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(problem)
                                .padding(.top, 3)
                        }

                        if works.count > 1 {
                            Text(works.map(\.title).joined(separator: l10n.isEn ? ", " : "、"))
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textFaint)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.top, 3)
                        }

                        if showStepper {
                            TaskStepper(
                                stage: task.stage,
                                progress: task.progress,
                                running: running,
                                reduceMotion: reduceMotion
                            )
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(width: 16)

                    StatusDotLabel(
                        label: running
                            ? TasksFormatting.runningLabel(task.stage, progress: task.progress, l10n: l10n)
                            : TasksFormatting.stageLabel(task.stage, l10n: l10n),
                        color: statusColor,
                        busy: running
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer().frame(width: 12)

            trailingActions(running: running, needsTmdbKey: needsTmdbKey)

            Spacer().frame(width: 2)

            moreMenuButton
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 8))
        .background {
            Rectangle()
                .fill(isHovered ? palette.hover : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleCardTap)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            menuItems
        }
    }

    private var problemMessage: String? {
        guard !task.message.isEmpty else { return nil }
        let isProblem = task.stage == .failed
            || task.stage == .cancelled
            || task.stage == .partiallyFailed
            || task.message.hasPrefix("已撤销部分操作")
        guard isProblem else { return nil }
        return TasksFormatting.localizedMessage(l10n, task.message)
    }

    private func handleCardTap() {
        if task.stage == .awaitingReview {
            onOpenReview()
        } else {
            onOpenDetail()
        }
    }

    @ViewBuilder
    private func trailingActions(running: Bool, needsTmdbKey: Bool) -> some View {
        HStack(spacing: 4) {
            if task.stage == .awaitingReview {
                QuietTextButton(
                    l10n.tr("只整理有把握的", "Confident Only"),
                    isDisabled: isBusy
                ) {
                    onRunConfident()
                }

                PrimaryActionButton(
                    l10n.tr("去确认", "Review"),
                    isDisabled: isBusy
                ) {
                    onOpenReview()
                }
            }

            if running {
                QuietTextButton(l10n.cancel) {
                    onCancel()
                }
            }

            if task.stage == .partiallyFailed {
                QuietTextButton(
                    l10n.tr("重试失败项", "Retry Failed"),
                    isDisabled: isBusy
                ) {
                    onRetryFailed()
                }
            }

            if canUndo(task) {
                QuietTextButton(
                    l10n.undo,
                    isDisabled: isBusy
                ) {
                    onUndo()
                }
            }

            if needsTmdbKey {
                QuietTextButton(l10n.tr("去设置", "Settings")) {
                    onOpenSettings()
                }
            }

            if (task.stage == .cancelled || task.stage == .failed) && canRetry(task) {
                QuietTextButton(
                    l10n.tr("重新识别", "Re-match"),
                    isDisabled: isBusy
                ) {
                    onRetry()
                }
            }
        }
    }

    private var moreMenuButton: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.textMuted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isMoreHovered ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.more)
        .onHover { isMoreHovered = $0 }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            onOpenDetail()
        } label: {
            Label(l10n.tr("打开详情", "Open Details"), systemImage: "doc.text")
        }

        if task.stage == .awaitingReview {
            Button {
                onOpenReview()
            } label: {
                Label(l10n.tr("去确认", "Review"), systemImage: "eye")
            }

            Button {
                onRunConfident()
            } label: {
                Label(l10n.tr("只整理有把握的", "Organize Confident Only"), systemImage: "play")
            }
            .disabled(isBusy)
        }

        if task.stage == .partiallyFailed {
            Button {
                onRetryFailed()
            } label: {
                Label(l10n.tr("重试失败项", "Retry Failed"), systemImage: "arrow.clockwise")
            }
            .disabled(isBusy)
        }

        if canUndo(task) {
            Button {
                onUndo()
            } label: {
                Label(l10n.undo, systemImage: "arrow.uturn.left")
            }
            .disabled(isBusy)
        }

        if canRetry(task) {
            Button {
                onRetry()
            } label: {
                Label(l10n.tr("重新识别", "Re-match"), systemImage: "arrow.clockwise")
            }
            .disabled(isBusy)
        }

        if task.stage.isActive {
            Button {
                onCancel()
            } label: {
                Label(l10n.cancel, systemImage: "stop")
            }
        }

        Divider()

        Button {
            onCopyTaskId()
        } label: {
            Label(l10n.tr("复制任务 ID", "Copy Task ID"), systemImage: "doc.on.doc")
        }

        if TasksFormatting.canDeleteTask(task) {
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label(l10n.tr("删除记录", "Delete Record"), systemImage: "trash")
            }
            .disabled(isBusy)
        }
    }
}
