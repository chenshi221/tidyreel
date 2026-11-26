import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

private struct DetailLoadKey: Equatable, Sendable {
    let taskId: TaskId
    let stage: TaskStage?
    let batch: BatchId?
    let reloadToken: Int
}

private struct WorkSection: Identifiable, Equatable, Sendable {
    let id: String
    let match: Candidate?
    let fallbackTitle: String?
    let records: [HistoryRecord]
    let failedCount: Int
}

private struct DetailSnapshotResult: Sendable {
    let review: TaskReview?
    let records: [HistoryRecord]
    let workSections: [WorkSection]
    let hasDoneRelocate: Bool
}

private struct EmptyDirsPayload: Identifiable {
    let id = UUID()
    let dirs: [String]
}

public struct TaskDetailPageView: View {
    public let store: AppStore
    public let taskId: TaskId

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var review: TaskReview? = nil
    @State private var records: [HistoryRecord] = []
    @State private var workSections: [WorkSection] = []
    @State private var hasDoneRelocate = false
    @State private var hasLoadedOnce = false
    @State private var loadError: String? = nil
    @State private var lastReviewTaskId: TaskId? = nil
    @State private var lastReviewStage: TaskStage? = nil
    @State private var lastReviewReloadToken: Int = -1
    @State private var reloadToken = 0

    @State private var isConfirmingDelete = false
    @State private var emptyDirsPayload: EmptyDirsPayload? = nil

    private let busyTracker = TasksBusyTracker.shared

    public init(store: AppStore, taskId: TaskId) {
        self.store = store
        self.taskId = taskId
    }

    private var summary: TaskSummary? {
        store.tasks.first { $0.id == taskId }
    }

    public var body: some View {
        let task = summary
        let isBusy = busyTracker.isBusy(taskId)
        let isCleanupBusy = busyTracker.isKeyBusy("cleanup:\(taskId.value)")
        let reduceMotion = store.settings.reduceMotion

        let running = task != nil && task!.stage.isActive && task!.stage != .awaitingReview
        let renaming = task != nil && (task!.stage == .renamingFiles || task!.stage == .renamingFolders)
        let undoable = task != nil && canUndo(task!)
        let canCleanupEmptyDirs = task != nil
            && !task!.scrapeOnly
            && (task!.stage == .done || task!.stage == .partiallyFailed)
            && (task!.mode == .moveToLibrary || hasDoneRelocate)
        let canSingleUndo = task != nil
            && canUndo(task!)
            && (task!.stage == .done || task!.stage == .partiallyFailed || task!.stage == .cancelled)

        let loadKey = DetailLoadKey(
            taskId: taskId,
            stage: task?.stage,
            batch: task?.batch,
            reloadToken: reloadToken
        )
        let activePollBatch: BatchId? = renaming ? task?.batch : nil

        PageScaffoldView(
            title: l10n.tr("任务详情", "Task Details"),
            subtitle: task.map { TasksFormatting.stageLabel($0.stage, l10n: l10n) }
        ) {
            QuietIconButton(
                systemImage: "chevron.left",
                tooltip: store.taskDetailOpenedFromSources
                    ? l10n.tr("返回来源", "Back to Sources")
                    : l10n.tr("返回任务", "Back to Tasks")
            ) {
                store.closeTasksSubroute()
            }
        } actions: {
            if running {
                SecondaryActionButton(l10n.cancel) {
                    Task { await store.taskManager.cancel(taskId) }
                }
            }

            if task?.stage == .partiallyFailed {
                PrimaryActionButton(
                    l10n.tr("重试失败项", "Retry Failed"),
                    systemImage: "arrow.clockwise",
                    isDisabled: isBusy
                ) {
                    performRetryFailed()
                }
            }

            if let task, canRetry(task) {
                SecondaryActionButton(
                    l10n.tr("重新识别", "Re-match"),
                    systemImage: "arrow.clockwise",
                    isDisabled: isBusy
                ) {
                    performRetry()
                }
            }

            if canCleanupEmptyDirs {
                SecondaryActionButton(
                    l10n.tr("清理空目录", "Clean Empty Folders"),
                    systemImage: "folder.badge.minus",
                    isDisabled: isBusy || isCleanupBusy
                ) {
                    scanAndPresentEmptyDirs()
                }
            }

            if undoable {
                SecondaryActionButton(
                    l10n.undo,
                    systemImage: "arrow.uturn.left",
                    isDisabled: isBusy
                ) {
                    performUndoAll()
                }
            }

            if let task, TasksFormatting.canDeleteTask(task) {
                QuietIconButton(
                    systemImage: "trash",
                    tooltip: l10n.tr("删除记录", "Delete Record"),
                    isDisabled: isBusy
                ) {
                    isConfirmingDelete = true
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let task {
                    summaryHeaderCard(task: task, running: running, reduceMotion: reduceMotion)
                        .padding(EdgeInsets(top: 0, leading: 48, bottom: 12, trailing: 40))
                }

                detailBody(
                    task: task,
                    isBusy: isBusy,
                    canSingleUndo: canSingleUndo
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.canvas)
        .environment(\.tidyreelReduceMotion, reduceMotion)
        .task(id: loadKey) {
            await loadDetailSnapshot(for: loadKey)
        }
        .task(id: activePollBatch) {
            guard let activePollBatch else { return }
            await pollRenamingRecords(batch: activePollBatch)
        }
        .onDisappear {
            clearRetainedDetailState()
        }
        .onChange(of: task?.stage) { prev, next in
            if let prev, prev != .awaitingReview, next == .awaitingReview {
                store.openTaskReview(taskId)
            }
        }
        .sheet(isPresented: $isConfirmingDelete) {
            let undoNote = undoable
                ? l10n.tr("删除后这些任务就不能再撤销了。", " Once deleted, these tasks can no longer be undone.")
                : ""
            TaskActionConfirmSheet(
                title: l10n.tr("删除任务记录", "Delete Task Record"),
                message: l10n.tr(
                    "只删除理片里的记录，不会动网盘或磁盘上的文件。\(undoNote)",
                    "Only records inside Tidyreel are removed; your files stay untouched.\(undoNote)"
                ),
                confirmLabel: l10n.delete,
                isDestructive: true
            ) {
                performDeleteAndClose()
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(item: $emptyDirsPayload) { payload in
            EmptyDirsCleanupSheet(
                store: store,
                taskId: taskId,
                dirs: payload.dirs
            ) { _ in
                reloadToken += 1
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - Top Summary Header Card (`_TaskSummaryHeader` in `task_detail_page.dart:200-355`)

    private func summaryHeaderCard(
        task: TaskSummary,
        running: Bool,
        reduceMotion: Bool
    ) -> some View {
        let connName = store.connections.first { $0.id == task.connection }?.name ?? task.connection.value
        let recognized = TaskCardMeta.isRecognizedStage(task.stage)
        let resolvedMeta: TaskCardMeta? = {
            if let cached = store.taskCardMeta[task.id] {
                return cached
            }
            if let review, review.id == task.id {
                return TaskCardMeta.from(scan: review.scan, decisions: review.decisions)
            }
            return nil
        }()
        let works = recognized ? (resolvedMeta?.works ?? []) : []
        let unassigned = recognized ? (resolvedMeta?.unassignedCount ?? 0) : 0
        let title = TasksFormatting.displayTitle(task: task, works: works, l10n: l10n)
        let metaLine = TasksFormatting.metadataLine(
            task: task,
            connectionName: connName,
            recognized: recognized,
            unassignedCount: unassigned,
            l10n: l10n
        )
        let showMessage = !task.message.isEmpty && task.stage != .failed && task.stage != .cancelled
        let isWarningMsg = task.stage == .partiallyFailed || task.message.hasPrefix("已撤销部分操作")
        let showStepper = task.stage.isActive && TasksFormatting.currentStep(task.stage) >= 0

        let statusLabel: String = {
            if running, let progress = task.progress {
                let pct = Int((min(max(progress, 0), 1) * 100).rounded())
                return "\(TasksFormatting.stageLabel(task.stage, l10n: l10n)) \(pct)%"
            }
            return TasksFormatting.stageLabel(task.stage, l10n: l10n)
        }()

        return PanelBox(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            HStack(alignment: .top, spacing: 16) {
                DownsampledArtworkView(
                    tmdbPath: works.first?.posterPath,
                    width: 56,
                    height: 84,
                    cornerRadius: TidyreelRadii.sm,
                    fallbackSystemImage: "folder"
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)

                        StatusDotLabel(
                            label: statusLabel,
                            color: TasksFormatting.stageColor(task.stage, palette: palette),
                            busy: running
                        )
                    }

                    Text(metaLine)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(task.paths.joined(separator: "\n"))
                        .padding(.top, 3)

                    if showMessage {
                        Text(TasksFormatting.localizedMessage(l10n, task.message))
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(isWarningMsg ? palette.warning : palette.textMuted)
                            .textSelection(.enabled)
                            .padding(.top, 4)
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
            }
        }
    }

    // MARK: - Detail Body (`_Body` in `task_detail_page.dart:357-516`)

    @ViewBuilder
    private func detailBody(
        task: TaskSummary?,
        isBusy: Bool,
        canSingleUndo: Bool
    ) -> some View {
        let isMatchingStage = task != nil && (task!.stage == .importing || task!.stage == .recognizing)

        if !hasLoadedOnce && !isMatchingStage && task?.stage != .awaitingReview {
            VStack {
                DashedSpinner(size: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, records.isEmpty {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: l10n.tr("无法读取任务详情", "Unable to Load Task Details"),
                subtitle: loadError
            )
        } else if isMatchingStage {
            EmptyStateCard(
                icon: "hourglass",
                title: l10n.tr("正在识别", "Matching"),
                subtitle: l10n.tr(
                    "识别完成后会自动打开识别结果",
                    "The review page will open automatically once matching finishes"
                )
            )
        } else if task?.stage == .awaitingReview {
            VStack {
                PrimaryActionButton(l10n.tr("查看识别结果", "Review Matches")) {
                    store.openTaskReview(taskId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if records.isEmpty {
            emptyRecordsView(task: task, isBusy: isBusy)
        } else {
            groupedRecordsList(canSingleUndo: canSingleUndo)
        }
    }

    @ViewBuilder
    private func emptyRecordsView(task: TaskSummary?, isBusy: Bool) -> some View {
        if let task, task.stage == .failed || task.stage == .cancelled {
            let isFailed = task.stage == .failed
            let needsKey = isFailed && TasksFormatting.isTmdbApiKeyError(task.message)
            let msg = !task.message.isEmpty
                ? TasksFormatting.localizedMessage(l10n, task.message)
                : (isFailed
                    ? l10n.tr("识别过程中出错，没有改动任何文件。", "An error occurred during matching; no files were modified.")
                    : l10n.tr("任务在修改文件前已取消。", "Task was cancelled before any files were modified."))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PanelBox(padding: EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: isFailed ? "exclamationmark.circle.fill" : "xmark.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isFailed ? palette.danger : palette.textMuted)
                                Text(
                                    isFailed
                                        ? l10n.tr("识别失败", "Matching Failed")
                                        : l10n.tr("任务已取消", "Task Cancelled")
                                )
                                .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                                .foregroundStyle(palette.text)
                            }

                            Text(msg)
                                .font(.system(size: TidyreelTypeScale.body))
                                .foregroundStyle(isFailed ? palette.danger : palette.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)

                            if needsKey || canRetry(task) {
                                HStack(spacing: 8) {
                                    if needsKey {
                                        PrimaryActionButton(l10n.tr("去设置", "Settings")) {
                                            store.navigateToTab(.settings)
                                        }
                                    }
                                    if canRetry(task) {
                                        if needsKey {
                                            SecondaryActionButton(
                                                l10n.tr("重新识别", "Re-match"),
                                                isDisabled: isBusy
                                            ) {
                                                performRetry()
                                            }
                                        } else {
                                            PrimaryActionButton(
                                                l10n.tr("重新识别", "Re-match"),
                                                isDisabled: isBusy
                                            ) {
                                                performRetry()
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 16)
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 48, bottom: 24, trailing: 40))
            }
        } else {
            EmptyStateCard(
                icon: "doc.text",
                title: l10n.tr("还没有整理记录", "No Operations Yet"),
                subtitle: l10n.tr(
                    "这个任务还没有改动任何文件",
                    "No files have been modified by this task yet"
                )
            )
        }
    }

    private func groupedRecordsList(canSingleUndo: Bool) -> some View {
        let firstSectionId = workSections.first?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(workSections) { section in
                    let isFirstSection = section.id == firstSectionId
                    let lastRecordId = section.records.last?.id
                    Section {
                        ForEach(section.records) { record in
                            let opBusy = busyTracker.isBusy(taskId)
                                || busyTracker.isKeyBusy("\(taskId.value):\(record.op.id.value)")
                            let isLastInSection = record.id == lastRecordId
                            OpRecordRow(
                                record: record,
                                canSingleUndo: canSingleUndo,
                                isBusy: opBusy,
                                onUndoOp: { opId in
                                    undoSingleOp(opId)
                                },
                                onCopyPath: { path in
                                    TasksFormatting.copyToPasteboard(path)
                                    store.showToast(l10n.tr("已复制路径", "Path copied"))
                                }
                            )
                            .padding(.horizontal, 14)
                            .padding(.bottom, isLastInSection ? 14 : 0)
                            .background(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 0,
                                    bottomLeadingRadius: isLastInSection ? TidyreelRadii.lg : 0,
                                    bottomTrailingRadius: isLastInSection ? TidyreelRadii.lg : 0,
                                    topTrailingRadius: 0,
                                    style: .continuous
                                )
                                .fill(palette.panel)
                            )
                        }
                    } header: {
                        WorkSectionHeaderRow(
                            match: section.match,
                            fallbackTitle: section.fallbackTitle ?? l10n.tr("文件夹和其他", "Folders & Other"),
                            recordCount: section.records.count,
                            failedCount: section.failedCount,
                            hasRecords: !section.records.isEmpty
                        )
                        .padding(.top, isFirstSection ? 0 : 12)
                    }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 48, bottom: 24, trailing: 40))
        }
    }

    // MARK: - Off-Main-Thread Data Loading & Actions

    private nonisolated static func buildWorkSections(
        records: [HistoryRecord],
        review: TaskReview?
    ) -> [WorkSection] {
        guard !records.isEmpty else { return [] }
        let scanGroups = review?.scan.groups ?? []
        let validGroupIds = Set(scanGroups.map(\.id))
        var byGroup: [GroupId?: [HistoryRecord]] = [:]
        for record in records {
            let gid: GroupId? = {
                guard let g = record.op.group, validGroupIds.contains(g) else { return nil }
                return g
            }()
            byGroup[gid, default: []].append(record)
        }

        var sections: [WorkSection] = []
        sections.reserveCapacity(scanGroups.count + 1)
        for g in scanGroups {
            guard let rs = byGroup[g.id], !rs.isEmpty else { continue }
            let match = review?.decisions[g.id]?.match ?? g.match
            let failedCount = rs.reduce(0) { $0 + ($1.status == .failed ? 1 : 0) }
            sections.append(
                WorkSection(
                    id: "group:\(g.id.value)",
                    match: match,
                    fallbackTitle: g.anchorTitle,
                    records: rs,
                    failedCount: failedCount
                )
            )
        }
        if let otherRecords = byGroup[nil], !otherRecords.isEmpty {
            let failedCount = otherRecords.reduce(0) { $0 + ($1.status == .failed ? 1 : 0) }
            sections.append(
                WorkSection(
                    id: "other",
                    match: nil,
                    fallbackTitle: nil,
                    records: otherRecords,
                    failedCount: failedCount
                )
            )
        }
        return sections
    }

    private nonisolated static func fetchOffMainThread(
        taskId: TaskId,
        batch: BatchId?,
        shouldLoadReview: Bool,
        existingReview: TaskReview?,
        taskManager: any TaskManager,
        historyStore: any HistoryStore
    ) async throws -> DetailSnapshotResult {
        let loadedReview: TaskReview?
        if shouldLoadReview {
            loadedReview = try? await taskManager.review(taskId)
        } else {
            loadedReview = nil
        }
        let loadedRecords: [HistoryRecord]
        if let batch {
            loadedRecords = try await historyStore.records(batch: batch)
        } else {
            loadedRecords = []
        }
        let effectiveReview = shouldLoadReview ? loadedReview : existingReview
        let sections = buildWorkSections(records: loadedRecords, review: effectiveReview)
        let doneRelocate = loadedRecords.contains { $0.status == .done && $0.op.kind == .relocate }
        return DetailSnapshotResult(
            review: loadedReview,
            records: loadedRecords,
            workSections: sections,
            hasDoneRelocate: doneRelocate
        )
    }

    private nonisolated static func fetchRecordsAndSectionsOffMainThread(
        batch: BatchId,
        reviewSnapshot: TaskReview?,
        historyStore: any HistoryStore
    ) async throws -> (records: [HistoryRecord], sections: [WorkSection], hasDoneRelocate: Bool) {
        let loadedRecords = try await historyStore.records(batch: batch)
        let sections = buildWorkSections(records: loadedRecords, review: reviewSnapshot)
        let doneRelocate = loadedRecords.contains { $0.status == .done && $0.op.kind == .relocate }
        return (loadedRecords, sections, doneRelocate)
    }

    private func loadDetailSnapshot(for key: DetailLoadKey) async {
        if lastReviewTaskId != key.taskId {
            review = nil
            records = []
            workSections = []
            hasDoneRelocate = false
            hasLoadedOnce = false
            loadError = nil
        }

        let needReview = review == nil
            || lastReviewTaskId != key.taskId
            || lastReviewStage != key.stage
            || lastReviewReloadToken != key.reloadToken

        let existingReview = needReview ? nil : review
        let tm = store.taskManager
        let hs = store.historyStore
        do {
            let result = try await Self.fetchOffMainThread(
                taskId: key.taskId,
                batch: key.batch,
                shouldLoadReview: needReview,
                existingReview: existingReview,
                taskManager: tm,
                historyStore: hs
            )
            guard !Task.isCancelled else { return }
            if needReview {
                review = result.review
                lastReviewTaskId = key.taskId
                lastReviewStage = key.stage
                lastReviewReloadToken = key.reloadToken
                workSections = result.workSections
            } else if review == existingReview {
                workSections = result.workSections
            } else {
                workSections = Self.buildWorkSections(records: result.records, review: review)
            }
            records = result.records
            hasDoneRelocate = result.hasDoneRelocate
            loadError = nil
            hasLoadedOnce = true
        } catch {
            guard !Task.isCancelled else { return }
            loadError = TasksFormatting.readableError(error, l10n: l10n)
            hasLoadedOnce = true
        }
    }

    private func pollRenamingRecords(batch: BatchId) async {
        let hs = store.historyStore
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                break
            }
            guard !Task.isCancelled, summary?.batch == batch else { break }
            let reviewSnapshot = review
            do {
                let result = try await Self.fetchRecordsAndSectionsOffMainThread(
                    batch: batch,
                    reviewSnapshot: reviewSnapshot,
                    historyStore: hs
                )
                guard !Task.isCancelled, summary?.batch == batch else { break }
                if result.records != records {
                    records = result.records
                    hasDoneRelocate = result.hasDoneRelocate
                    if review == reviewSnapshot {
                        workSections = result.sections
                    } else {
                        workSections = Self.buildWorkSections(records: result.records, review: review)
                    }
                }
            } catch {
                if Task.isCancelled { break }
            }
        }
    }

    private func clearRetainedDetailState() {
        review = nil
        records = []
        workSections = []
        hasDoneRelocate = false
        hasLoadedOnce = false
        lastReviewTaskId = nil
        lastReviewStage = nil
        lastReviewReloadToken = -1
    }

    private func performUndoAll() {
        guard busyTracker.tryAcquire(taskId) else { return }
        Task { @MainActor in
            defer { busyTracker.release(taskId) }
            do {
                try await store.taskManager.undo(taskId, only: nil)
                store.refreshTaskCardMeta(taskId)
                reloadToken += 1
                store.showToast(l10n.tr("已撤销", "Undone"))
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func undoSingleOp(_ opId: OpId) {
        let key = "\(taskId.value):\(opId.value)"
        guard busyTracker.tryAcquireKey(key) else { return }
        Task { @MainActor in
            defer { busyTracker.releaseKey(key) }
            do {
                try await store.taskManager.undo(taskId, only: [opId])
                let currentBatch = summary?.batch
                let fetched = try await Self.fetchOffMainThread(
                    taskId: taskId,
                    batch: currentBatch,
                    shouldLoadReview: true,
                    existingReview: nil,
                    taskManager: store.taskManager,
                    historyStore: store.historyStore
                )
                review = fetched.review
                records = fetched.records
                workSections = fetched.workSections
                hasDoneRelocate = fetched.hasDoneRelocate
                reloadToken += 1
                store.refreshTaskCardMeta(taskId)
                store.showToast(l10n.tr("已撤销该操作", "Operation undone"))
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func scanAndPresentEmptyDirs() {
        let key = "cleanup:\(taskId.value)"
        guard busyTracker.tryAcquireKey(key) else { return }
        Task { @MainActor in
            defer { busyTracker.releaseKey(key) }
            do {
                let dirs = try await store.taskManager.findEmptyDirs(taskId)
                if dirs.isEmpty {
                    store.showToast(
                        l10n.tr("没有可清理的空目录", "No empty folders to clean up")
                    )
                    return
                }
                emptyDirsPayload = EmptyDirsPayload(dirs: dirs)
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func performRetryFailed() {
        guard busyTracker.tryAcquire(taskId) else { return }
        Task { @MainActor in
            defer { busyTracker.release(taskId) }
            do {
                try await store.taskManager.retryFailed(taskId)
                reloadToken += 1
                store.showToast(
                    l10n.tr("已重试失败项", "Retrying failed operations")
                )
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func performRetry() {
        guard busyTracker.tryAcquire(taskId) else { return }
        Task { @MainActor in
            defer { busyTracker.release(taskId) }
            do {
                try await store.taskManager.retry(taskId)
                reloadToken += 1
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }

    private func performDeleteAndClose() {
        guard busyTracker.tryAcquire(taskId) else { return }
        Task { @MainActor in
            defer { busyTracker.release(taskId) }
            do {
                try await store.taskManager.delete(taskId)
                store.closeTasksSubroute()
            } catch {
                store.showToast(TasksFormatting.readableError(error, l10n: l10n))
            }
        }
    }
}

// MARK: - Work-Grouped Section Header (`_WorkSection` in `task_detail_page.dart:518-600`)

private struct WorkSectionHeaderRow: View {
    let match: Candidate?
    let fallbackTitle: String
    let recordCount: Int
    let failedCount: Int
    let hasRecords: Bool

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let headerTitle: String = {
            guard let match else { return fallbackTitle }
            guard let year = match.year else { return match.title }
            return l10n.isEn ? "\(match.title) (\(year))" : "\(match.title)（\(year)）"
        }()
        let countLine = l10n.tr(
            "\(recordCount) 项\(failedCount > 0 ? "，\(failedCount) 项失败" : "")",
            "\(l10n.plural(recordCount, "item"))\(failedCount > 0 ? ", \(failedCount) failed" : "")"
        )
        let fallbackIcon: String = {
            guard let match else { return "folder" }
            return match.kind == .movie ? "film" : "tv"
        }()

        HStack(alignment: .top, spacing: 14) {
            DownsampledArtworkView(
                tmdbPath: match?.posterPath,
                width: 44,
                height: 66,
                cornerRadius: 6,
                fallbackSystemImage: fallbackIcon
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                    .foregroundStyle(palette.text)

                Text(countLine)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)

                if let overview = match?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(
            top: 14,
            leading: 14,
            bottom: hasRecords ? 10 : 14,
            trailing: 14
        ))
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: TidyreelRadii.lg,
                bottomLeadingRadius: hasRecords ? 0 : TidyreelRadii.lg,
                bottomTrailingRadius: hasRecords ? 0 : TidyreelRadii.lg,
                topTrailingRadius: TidyreelRadii.lg,
                style: .continuous
            )
            .fill(palette.panel)
        )
    }
}

// MARK: - Per-Operation Diff Row (`_OpRow` in `task_detail_page.dart:641-750`)

private struct OpRecordRow: View {
    let record: HistoryRecord
    let canSingleUndo: Bool
    let isBusy: Bool
    let onUndoOp: (OpId) -> Void
    let onCopyPath: (String) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isUndoHovered = false

    var body: some View {
        let op = record.op
        let (statusLabel, statusColor) = statusVisual(record.status)
        let (fromText, toText, tooltipFrom, tooltipTo) = resolvedPaths(op)
        let canUndoRow = canSingleUndo && record.status == .done && op.kind != .delete
        let tooltip = buildTooltip(from: tooltipFrom, to: tooltipTo, error: record.error)

        HStack(alignment: .top, spacing: 8) {
            TagBadge(statusLabel, tint: statusColor)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(fromText)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("→ \(toText)")
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let error = record.error, !error.isEmpty {
                    Text(TasksFormatting.explainRecordError(error, l10n: l10n))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canUndoRow {
                Button {
                    onUndoOp(op.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 11, weight: .medium))
                        Text(l10n.undo)
                            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    }
                    .foregroundStyle(isBusy ? palette.textFaint : palette.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                            .fill(isUndoHovered && !isBusy ? palette.hover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isHovered ? 1.0 : 0.72)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .onHover { isUndoHovered = $0 }
            }
        }
        .padding(EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(isHovered ? palette.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        .onHover { isHovered = $0 }
        .help(tooltip)
        .contextMenu {
            if !op.src.isEmpty && !op.src.hasPrefix(writeTextPrefix) {
                Button {
                    onCopyPath(op.src)
                } label: {
                    Label(l10n.tr("复制原路径", "Copy Source Path"), systemImage: "doc.on.doc")
                }
            }
            if !op.dst.isEmpty {
                Button {
                    onCopyPath(op.dst)
                } label: {
                    Label(l10n.tr("复制目标路径", "Copy Destination Path"), systemImage: "doc.on.doc")
                }
            }
            if canUndoRow {
                Divider()
                Button {
                    onUndoOp(op.id)
                } label: {
                    Label(l10n.undo, systemImage: "arrow.uturn.left")
                }
                .disabled(isBusy)
            }
        }
    }

    private func statusVisual(_ status: OpStatus) -> (String, Color) {
        switch status {
        case .done:
            return (l10n.tr("完成", "Done"), palette.success)
        case .failed:
            return (l10n.tr("失败", "Failed"), palette.danger)
        case .undone:
            return (l10n.tr("已撤销", "Undone"), palette.textMuted)
        case .skipped:
            return (l10n.tr("跳过", "Skipped"), palette.textMuted)
        case .pending:
            return (l10n.tr("未处理", "Pending"), palette.textMuted)
        }
    }

    private func resolvedPaths(_ op: RenameOp) -> (String, String, String, String) {
        switch op.kind {
        case .mkdir:
            let newFolder = l10n.tr("新建文件夹", "New folder")
            return (newFolder, TasksFormatting.lastPathComponent(op.dst), newFolder, op.dst)
        case .delete:
            return (TasksFormatting.lastPathComponent(op.src), l10n.delete, op.src, l10n.delete)
        case .write:
            if op.src.hasPrefix(writeTextPrefix) {
                let nfoLabel = l10n.tr("写入元数据", "Write metadata")
                return (nfoLabel, TasksFormatting.lastPathComponent(op.dst), nfoLabel, op.dst)
            }
            return (
                TasksFormatting.lastPathComponent(op.src),
                TasksFormatting.lastPathComponent(op.dst),
                op.src,
                op.dst
            )
        case .relocate:
            return (
                TasksFormatting.lastPathComponent(op.src),
                TasksFormatting.lastPathComponent(op.dst),
                op.src,
                op.dst
            )
        }
    }

    private func buildTooltip(from: String, to: String, error: String?) -> String {
        var lines = ["\(from)\n→ \(to)"]
        if let error, !error.isEmpty {
            lines.append(TasksFormatting.localizedMessage(l10n, error))
        }
        return lines.joined(separator: "\n")
    }
}
