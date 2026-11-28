import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

private enum TasksFilter: String, CaseIterable, Hashable {
    case all
    case active
    case finished
}

private struct DeleteConfirmContext: Identifiable {
    let id = UUID()
    let tasks: [TaskSummary]
}

private struct PermanentDeleteContext: Identifiable {
    let id = UUID()
    let taskId: TaskId
    let paths: Set<String>
    var deleteCount: Int { paths.count }
}

public struct TasksPageView: View {
    public let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var filter: TasksFilter = .all
    @State private var deleteConfirmContext: DeleteConfirmContext? = nil
    @State private var permanentDeleteContext: PermanentDeleteContext? = nil

    private let busyTracker = TasksBusyTracker.shared

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        let all = store.tasks
        let active = all.filter { $0.stage.isActive }
        let finished = all.filter { !$0.stage.isActive }
        let waiting = active.filter { $0.stage == .awaitingReview }.count
        let showActive = filter != .finished && !active.isEmpty
        let showFinished = filter != .active && !finished.isEmpty
        let connectionNames = Dictionary(
            uniqueKeysWithValues: store.connections.map { ($0.id, $0.name) }
        )
        let reduceMotion = store.settings.reduceMotion

        PageScaffoldView(
            title: l10n.tr("任务", "Tasks")
        ) {
            if showFinished {
                QuietTextButton(
                    l10n.tr("清空已完成", "Clear Finished"),
                    systemImage: "trash",
                    isDisabled: busyTracker.isAnyBusy(finished.map(\.id)),
                    fontSize: TidyreelTypeScale.body
                ) {
                    deleteConfirmContext = DeleteConfirmContext(tasks: finished)
                }
            }

            SlidingSegmented(
                options: [
                    (.all, l10n.tr("全部 \(all.count)", "All \(all.count)")),
                    (.active, l10n.tr("进行中 \(active.count)", "Active \(active.count)")),
                    (.finished, l10n.tr("已完成 \(finished.count)", "Done \(finished.count)")),
                ],
                selection: filter,
                onSelect: { filter = $0 }
            )
        } content: {
            if !showActive && !showFinished {
                emptyStateView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if waiting > 0 && filter != .finished {
                            BigHeroNumber("\(waiting)") {
                                Text(l10n.tr("个待确认", "awaiting review"))
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                        }

                        if showActive {
                            if showFinished {
                                SectionHeaderLabel(l10n.tr("进行中", "Active"))
                            }
                            taskSection(
                                list: active,
                                connectionNames: connectionNames,
                                reduceMotion: reduceMotion
                            )
                        }

                        if showFinished {
                            if showActive {
                                SectionHeaderLabel(l10n.tr("已完成", "Completed"))
                            }
                            taskSection(
                                list: finished,
                                connectionNames: connectionNames,
                                reduceMotion: reduceMotion
                            )
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 48, bottom: 28, trailing: 40))
                }
            }
        }
        .background(palette.canvas)
        .environment(\.tidyreelReduceMotion, reduceMotion)
        .sheet(item: $deleteConfirmContext) { ctx in
            let tasks = ctx.tasks
            let undoable = tasks.contains { canUndo($0) }
            let title = tasks.count == 1
                ? l10n.tr("删除任务记录", "Delete Task Record")
                : l10n.tr(
                    "清空 \(tasks.count) 条任务记录",
                    "Clear \(l10n.plural(tasks.count, "Task Record"))"
                )
            let message = l10n.tr(
                "只删除理片里的记录，不会动网盘或磁盘上的文件。\(undoable ? "删除后这些任务就不能再撤销了。" : "")",
                "Only records inside Tidyreel are removed; your files stay untouched.\(undoable ? " Once deleted, these tasks can no longer be undone." : "")"
            )
            TaskActionConfirmSheet(
                title: title,
                message: message,
                confirmLabel: l10n.delete,
                isDestructive: true
            ) {
                performDeleteTasks(tasks)
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(item: $permanentDeleteContext) { ctx in
            TaskActionConfirmSheet(
                title: l10n.tr(
                    "永久删除 \(ctx.deleteCount) 个文件？",
                    "Permanently Delete \(l10n.plural(ctx.deleteCount, "File"))?"
                ),
                message: l10n.tr(
                    "整理过程中将直接删除 \(ctx.deleteCount) 个垃圾或附属文件，删除后无法通过「撤销」找回。",
                    "This run will permanently delete \(l10n.plural(ctx.deleteCount, "file")), which cannot be restored by Undo."
                ),
                confirmLabel: l10n.delete,
                isDestructive: true
            ) {
                executeRunConfident(ctx)
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - Empty State & Section Panel

    @ViewBuilder
    private var emptyStateView: some View {
        let title: String = {
            switch filter {
            case .all:
                return l10n.tr("还没有任务", "No Tasks Yet")
            case .active:
                return l10n.tr("没有进行中的任务", "No Active Tasks")
            case .finished:
                return l10n.tr("还没有已完成的任务", "No Completed Tasks")
            }
        }()

        if filter == .finished {
            EmptyStateCard(
                icon: "checkmark.seal",
                title: title
            )
        } else {
            EmptyStateCard(
                icon: "tray",
                title: title,
                subtitle: l10n.tr(
                    "去「来源」选一个文件夹开始整理",
                    "Pick a folder in Sources to start organizing"
                )
            ) {
                SecondaryActionButton(
                    l10n.tr("去「来源」选择文件夹", "Choose Folder in Sources")
                ) {
                    store.navigateToTab(.sources)
                }
            }
        }
    }

    private func taskSection(
        list: [TaskSummary],
        connectionNames: [ConnectionId: String],
        reduceMotion: Bool
    ) -> some View {
        PanelBox(padding: EdgeInsets()) {
            LazyVStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, task in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.line)
                            .frame(height: hairlineWidth)
                            .padding(.leading, 70)
                    }

                    TaskCardView(
                        task: task,
                        meta: store.taskCardMeta[task.id],
                        connectionName: connectionNames[task.connection] ?? task.connection.value,
                        reduceMotion: reduceMotion,
                        isBusy: busyTracker.isBusy(task.id),
                        onOpenReview: { store.openTaskReview(task.id) },
                        onRunConfident: { requestRunConfident(task.id) },
                        onCancel: { cancelTask(task.id) },
                        onRetryFailed: { retryFailed(task.id) },
                        onUndo: { performUndo(task.id) },
                        onRetry: { retryTask(task.id) },
                        onOpenDetail: { store.openTaskDetail(task.id) },
                        onRequestDelete: { deleteConfirmContext = DeleteConfirmContext(tasks: [task]) },
                        onOpenSettings: { store.navigateToTab(.settings) },
                        onCopyTaskId: {
                            TasksFormatting.copyToPasteboard(task.id.value)
                            store.showToast(l10n.tr("已复制任务 ID", "Task ID copied"))
                        }
                    )
                }
            }
        }
    }

    // MARK: - Task Actions

    private func requestRunConfident(_ id: TaskId) {
        guard busyTracker.tryAcquire(id) else { return }
        Task { @MainActor in
            var shouldRelease = true
            defer {
                if shouldRelease {
                    busyTracker.release(id)
                }
            }
            do {
                let review = try await store.taskManager.review(id)
                let deletes = review.preview.ops.filter {
                    $0.selected && $0.kind == .delete && $0.warning == nil
                }.map(\.src)
                if !deletes.isEmpty {
                    busyTracker.release(id)
                    shouldRelease = false
                    permanentDeleteContext = PermanentDeleteContext(taskId: id, paths: Set(deletes))
                    return
                }
                try await store.taskManager.run(id, onlyConfident: true)
                store.showToast(
                    l10n.tr("已开始整理有把握的项目", "Started organizing confident matches")
                )
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func executeRunConfident(_ context: PermanentDeleteContext) {
        let id = context.taskId
        guard busyTracker.tryAcquire(id) else { return }
        Task { @MainActor in
            defer { busyTracker.release(id) }
            do {
                try await store.taskManager.run(id, onlyConfident: true, confirmedDeletePaths: context.paths)
                store.showToast(
                    l10n.tr("已开始整理有把握的项目", "Started organizing confident matches")
                )
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func cancelTask(_ id: TaskId) {
        Task { @MainActor in
            await store.taskManager.cancel(id)
        }
    }

    private func retryFailed(_ id: TaskId) {
        guard busyTracker.tryAcquire(id) else { return }
        Task { @MainActor in
            defer { busyTracker.release(id) }
            do {
                try await store.taskManager.retryFailed(id)
                store.showToast(
                    l10n.tr("已重试失败项", "Retrying failed operations")
                )
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func retryTask(_ id: TaskId) {
        guard busyTracker.tryAcquire(id) else { return }
        Task { @MainActor in
            defer { busyTracker.release(id) }
            do {
                try await store.taskManager.retry(id)
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func performUndo(_ id: TaskId) {
        guard busyTracker.tryAcquire(id) else { return }
        Task { @MainActor in
            defer { busyTracker.release(id) }
            do {
                try await store.taskManager.undo(id, only: nil)
                store.refreshTaskCardMeta(id)
                store.showToast(l10n.tr("已撤销", "Undone"))
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func performDeleteTasks(_ tasks: [TaskSummary]) {
        let ids = tasks.map(\.id)
        guard busyTracker.tryAcquireAll(ids) else { return }
        Task { @MainActor in
            defer { busyTracker.releaseAll(ids) }
            do {
                for id in ids {
                    try await store.taskManager.delete(id)
                }
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }
}
