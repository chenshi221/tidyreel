import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

private final class KeyMonitorBridge {
    private var token: Any?
    private var handler: (@MainActor (NSEvent) -> NSEvent?)?

    @MainActor
    func install(viewModel: ReviewViewModel, store: AppStore, taskId: TaskId) {
        remove()
        handler = { [weak viewModel, weak store] event in
            guard let viewModel, let store else { return event }
            return Self.handleKeyEvent(event, viewModel: viewModel, store: store, taskId: taskId)
        }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let handler = self?.handler else { return event }
            return handler(event)
        }
    }

    @MainActor
    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
        handler = nil
    }

    deinit {
        if let token {
            NSEvent.removeMonitor(token)
        }
    }

    @MainActor
    private static func handleKeyEvent(
        _ event: NSEvent,
        viewModel: ReviewViewModel,
        store: AppStore,
        taskId: TaskId
    ) -> NSEvent? {
        guard viewModel.activeSheet == nil,
              viewModel.review != nil else {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)
        let hasOpt = flags.contains(.option)

        // ⌘F -> focus left-pane search field
        if (hasCmd || hasCtrl) && !hasOpt,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            viewModel.searchFocusTrigger += 1
            return nil
        }

        // ⌘↩ -> execute
        if (hasCmd || hasCtrl) && !hasOpt && (event.keyCode == 36 || event.keyCode == 76) {
            let scrapeOnly = store.tasks.first(where: { $0.id == taskId })?.scrapeOnly ?? false
            Task { @MainActor [weak viewModel, weak store] in
                guard let viewModel, let store else { return }
                await viewModel.triggerExecute(store: store, taskId: taskId, scrapeOnly: scrapeOnly)
            }
            return nil
        }

        // Do not intercept arrows or space while typing inside any text editor
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
            return event
        }
        guard !hasCmd && !hasCtrl && !hasOpt && !flags.contains(.shift) else {
            return event
        }

        switch event.keyCode {
        case 126: // Up arrow
            viewModel.moveGroupSelection(delta: -1, store: store)
            return nil
        case 125: // Down arrow
            viewModel.moveGroupSelection(delta: 1, store: store)
            return nil
        case 123: // Left arrow
            viewModel.moveDetailTab(delta: -1, store: store)
            return nil
        case 124: // Right arrow
            viewModel.moveDetailTab(delta: 1, store: store)
            return nil
        case 49: // Space
            Task { @MainActor [weak viewModel, weak store] in
                guard let viewModel, let store else { return }
                await viewModel.toggleSelectedGroupChecked(store: store, taskId: taskId)
            }
            return nil
        default:
            return event
        }
    }
}

public struct ReviewPageView: View {
    public let store: AppStore
    public let taskId: TaskId

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var viewModel: ReviewViewModel
    @State private var leftWidth: CGFloat = 312
    @State private var rightWidth: CGFloat = 276
    @State private var widthPersistTask: Task<Void, Never>?
    @State private var keyMonitor: KeyMonitorBridge

    public init(store: AppStore, taskId: TaskId) {
        self.store = store
        self.taskId = taskId
        _viewModel = State(initialValue: ReviewViewModel())
        _keyMonitor = State(initialValue: KeyMonitorBridge())
    }

    private var taskSummary: TaskSummary? {
        store.tasks.first(where: { $0.id == taskId })
    }

    private var resolvedPaths: [String] {
        taskSummary?.paths ?? viewModel.review?.scan.roots ?? []
    }

    private var headerSubtitle: String? {
        let paths = resolvedPaths
        if paths.count == 1 {
            return paths[0]
        }
        if paths.count > 1 {
            return l10n.tr("\(paths.count) 个文件夹", l10n.plural(paths.count, "folder"))
        }
        return nil
    }

    public var body: some View {
        let summary = taskSummary
        let scrapeOnly = summary?.scrapeOnly ?? false
        let paths = resolvedPaths

        PageScaffoldView(
            title: l10n.tr("识别结果", "Review Matches"),
            subtitle: headerSubtitle,
            leading: {
                QuietIconButton(
                    systemImage: "chevron.left",
                    tooltip: l10n.tr("返回任务", "Back to Tasks")
                ) {
                    store.closeTasksSubroute()
                }
            },
            actions: {
                if scrapeOnly {
                    TagBadge(
                        l10n.tr("仅刮削", "Scrape only"),
                        tint: palette.accent
                    )
                }

                if paths.count > 1 {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 28, height: 28)
                        .help(paths.joined(separator: "\n"))
                }

                QuietIconButton(
                    systemImage: "keyboard",
                    tooltip: l10n.tr(
                        "快捷键（点击查看）\n↑ ↓  切换作品\n← →  切换季 / 文件夹\n空格  勾选或取消作品\n⌘F  搜索\n⌘↩  开始整理",
                        "Keyboard shortcuts (click to view)\n↑ ↓  Switch title\n← →  Switch season / folder\nSpace  Toggle title\n⌘F  Search\n⌘↩  Start organizing"
                    )
                ) {
                    viewModel.activeSheet = .shortcuts
                }

                QuietIconButton(
                    systemImage: "sidebar.right",
                    tooltip: viewModel.showInspector
                        ? l10n.tr("隐藏作品操作", "Hide inspector")
                        : l10n.tr("显示作品操作", "Show inspector"),
                    tint: viewModel.showInspector ? palette.text : palette.textMuted
                ) {
                    viewModel.showInspector.toggle()
                }
            }
        ) {
            pageBody(summary: summary, scrapeOnly: scrapeOnly)
        }
        .background(palette.canvas)
        .onAppear {
            viewModel.syncContext(confidenceThreshold: store.settings.confidenceThreshold, l10n: l10n)
            dismissStaleReviewToastIfNeeded()
            syncWidthsFromSettings()
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
            flushWidthsToSettingsIfNeeded()
            viewModel.cleanupOnDisappear()
        }
        .task(id: taskId) {
            viewModel.syncContext(confidenceThreshold: store.settings.confidenceThreshold, l10n: l10n)
            dismissStaleReviewToastIfNeeded()
            syncWidthsFromSettings()
            installKeyboardMonitor()
            await viewModel.load(store: store, taskId: taskId)
        }
        .onChange(of: taskSummary?.stage) { oldStage, newStage in
            if (oldStage == .importing || oldStage == .recognizing) && newStage == .awaitingReview {
                Task { await viewModel.load(store: store, taskId: taskId) }
            } else if oldStage == .awaitingReview,
                      let newStage,
                      newStage != .awaitingReview {
                store.openTaskDetail(taskId)
            }
        }
        .onChange(of: l10n) { _, newL10n in
            viewModel.syncContext(confidenceThreshold: store.settings.confidenceThreshold, l10n: newL10n)
        }
        .onChange(of: store.namingProfile) { _, _ in
            reloadIfAwaitingReview()
        }
        .onChange(of: store.settings.autoDeleteJunk) { _, _ in
            reloadIfAwaitingReview()
        }
        .onChange(of: store.settings.confidenceThreshold) { _, newThreshold in
            viewModel.syncContext(confidenceThreshold: newThreshold, l10n: l10n)
            reloadIfAwaitingReview()
        }
        .onChange(of: store.connections) { _, _ in
            reloadIfAwaitingReview()
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
                .environment(\.palette, palette)
                .environment(\.l10n, l10n)
        }
    }

    // MARK: - Main Content & Floating Bottom Bar (`review_page.dart:920-946`)

    @ViewBuilder
    private func pageBody(summary: TaskSummary?, scrapeOnly: Bool) -> some View {
        if let summary, (summary.stage == .importing || summary.stage == .recognizing) {
            VStack(spacing: 12) {
                DashedSpinner(size: 20)
                Text(localizeCoreMessage(l10n, summary.message.isEmpty ? "正在识别" : summary.message))
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = viewModel.errorMessage, viewModel.review == nil {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: l10n.tr("无法读取识别结果", "Could not load review"),
                subtitle: localizeCoreMessage(l10n, err)
            ) {
                SecondaryActionButton(l10n.retry, systemImage: "arrow.clockwise") {
                    Task { await viewModel.load(store: store, taskId: taskId) }
                }
            }
        } else if let review = viewModel.review {
            ZStack(alignment: .bottom) {
                splitThreePaneBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(palette.line)
                            .frame(height: hairlineWidth)
                    }

                floatingBottomBar(review: review, summary: summary, scrapeOnly: scrapeOnly)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                DashedSpinner(size: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 3-Pane Resizable Split Body (`review_page.dart:988-1572`)

    private var splitThreePaneBody: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let showRight = viewModel.showInspector
                && !viewModel.showUnassigned
                && viewModel.selectedGroup != nil
            let effectiveWidths = clampedPaneWidths(
                totalWidth: totalW,
                desiredLeft: leftWidth,
                desiredRight: rightWidth,
                showRight: showRight
            )

            HStack(spacing: 0) {
                WorksListPane(
                    store: store,
                    taskId: taskId,
                    viewModel: viewModel
                )
                .frame(width: effectiveWidths.left)

                ResizableVerticalDivider { delta in
                    guard abs(delta) < 120 else { return }
                    let dividerTotal: CGFloat = showRight ? 12 : 6
                    let maxLeft = min(
                        460,
                        max(240, totalW - dividerTotal - 320 - effectiveWidths.right)
                    )
                    let next = min(maxLeft, max(240, effectiveWidths.left + delta))
                    if abs(next - leftWidth) > 0.2 {
                        leftWidth = next
                        scheduleSaveWidths()
                    }
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        leftWidth = 312
                        scheduleSaveWidths()
                    }
                )

                centerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showRight, let selectedGroup = viewModel.selectedGroup {
                    ResizableVerticalDivider { delta in
                        guard abs(delta) < 120 else { return }
                        let maxRight = min(
                            420,
                            max(220, totalW - 12 - 320 - effectiveWidths.left)
                        )
                        let next = min(maxRight, max(220, effectiveWidths.right - delta))
                        if abs(next - rightWidth) > 0.2 {
                            rightWidth = next
                            scheduleSaveWidths()
                        }
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            rightWidth = 276
                            scheduleSaveWidths()
                        }
                    )

                    InspectorPane(
                        store: store,
                        taskId: taskId,
                        group: selectedGroup,
                        viewModel: viewModel
                    )
                    .frame(width: effectiveWidths.right)
                }
            }
        }
    }

    @ViewBuilder
    private var centerPane: some View {
        if viewModel.showUnassigned {
            UnassignedPane(
                store: store,
                taskId: taskId,
                viewModel: viewModel
            )
        } else if let group = viewModel.selectedGroup {
            DetailPane(
                store: store,
                taskId: taskId,
                group: group,
                viewModel: viewModel
            )
        } else {
            EmptyStateCard(
                icon: "film",
                title: l10n.tr("选择一个作品查看详情", "Select a title to view details")
            )
            .padding(.bottom, 104)
        }
    }

    // MARK: - Centered Floating Bottom Bar (`review_page.dart:1575-1783`)

    private func floatingBottomBar(
        review: TaskReview,
        summary: TaskSummary?,
        scrapeOnly: Bool
    ) -> some View {
        let conflicts = review.preview.conflicts.count
        let merges = viewModel.selectedMerges
        let currentMode = summary?.mode ?? store.settings.defaultMode
        let opsCount = viewModel.index?.selectedOpsCount ?? 0
        let blockedReason = viewModel.blockedExecuteReason(scrapeOnly: scrapeOnly, l10n: l10n)
        let canStart = (blockedReason == nil)

        let conflictLabel: String = {
            if conflicts == 0 {
                return l10n.tr("没有冲突", "No conflicts")
            }
            if !merges.isEmpty {
                return l10n.tr(
                    "\(conflicts) 处冲突，点「开始整理」可分开保留",
                    "\(l10n.plural(conflicts, "conflict")) — click Organize to keep separate"
                )
            }
            return l10n.tr(
                "\(conflicts) 处冲突，处理后才能整理",
                "\(l10n.plural(conflicts, "conflict")) to resolve first"
            )
        }()

        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                if scrapeOnly {
                    TagBadge(
                        l10n.tr("仅刮削 · 保留原文件名", "Scrape only · Keep filenames"),
                        tint: palette.accent
                    )
                } else {
                    SlidingSegmented(
                        options: [
                            (.inPlace, l10n.organizeModeLabel(.inPlace)),
                            (.moveToLibrary, l10n.organizeModeLabel(.moveToLibrary)),
                        ],
                        selection: currentMode
                    ) { newMode in
                        guard !viewModel.isBusy else { return }
                        Task {
                            await viewModel.setOrganizeMode(store: store, taskId: taskId, mode: newMode)
                        }
                    }
                }

                Spacer().frame(width: 16)

                if conflicts > 0 {
                    ConflictJumpButton(
                        label: conflictLabel,
                        helpText: l10n.tr("点击定位到冲突文件", "Jump to first conflict")
                    ) {
                        viewModel.jumpToFirstConflict(store: store)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textFaint)
                        Text(conflictLabel)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer().frame(width: 12)

                Text(l10n.tr("\(opsCount) 处改动", l10n.plural(opsCount, "change")))
                    .font(.system(size: TidyreelTypeScale.small))
                    .monospacedDigit()
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)

                Spacer().frame(width: 18)

                PrimaryActionButton(
                    scrapeOnly
                        ? l10n.tr("开始刮削", "Start Scraping")
                        : l10n.tr("开始整理", "Start Organizing"),
                    isDisabled: !canStart
                ) {
                    Task {
                        await viewModel.triggerExecute(
                            store: store,
                            taskId: taskId,
                            scrapeOnly: scrapeOnly
                        )
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help(blockedReason ?? "⌘↩")
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.bar, style: .continuous)
                    .fill(palette.panel)
                    .shadow(
                        color: .black.opacity(palette.isDark ? 0.36 : 0.08),
                        radius: 14,
                        x: 0,
                        y: 6
                    )
                    .shadow(
                        color: .black.opacity(palette.isDark ? 0.20 : 0.04),
                        radius: 3,
                        x: 0,
                        y: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.bar, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: hairlineWidth)
            )

            if let blockedReason {
                Text(blockedReason)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Sheet Builder

    @ViewBuilder
    private func sheetContent(for sheet: ActiveReviewSheet) -> some View {
        switch sheet {
        case .editRow(let group, let row, let allRows):
            EditRowSheet(
                store: store,
                taskId: taskId,
                group: group,
                row: row,
                allRows: allRows,
                viewModel: viewModel
            )
        case .tmdbSearch(let group, let initialQuery):
            TMDBSearchSheet(
                store: store,
                taskId: taskId,
                group: group,
                initialQuery: initialQuery,
                viewModel: viewModel
            )
        case .mergeConfirm(let merges):
            MergeConfirmSheet(
                store: store,
                taskId: taskId,
                merges: merges,
                mode: taskSummary?.mode ?? store.settings.defaultMode,
                viewModel: viewModel
            )
        case .confirmPermanentDelete(let paths):
            PermanentDeleteConfirmSheet(
                paths: paths,
                onCancel: {
                    viewModel.activeSheet = nil
                },
                onConfirm: {
                    Task {
                        await viewModel.confirmPermanentDeleteAndRun(store: store, taskId: taskId, paths: paths)
                    }
                }
            )
        case .mergeGroup(let source):
            MergeGroupSheet(
                store: store,
                taskId: taskId,
                source: source,
                viewModel: viewModel
            )
        case .splitGroup(let source, let initialSelection):
            SplitGroupSheet(
                store: store,
                taskId: taskId,
                source: source,
                initialSelection: initialSelection,
                viewModel: viewModel
            )
        case .shortcuts:
            ShortcutsHelpSheet {
                viewModel.activeSheet = nil
            }
        }
    }

    // MARK: - Width Clamping & Persistence (`review_page.dart:991-1046`)

    private func syncWidthsFromSettings() {
        leftWidth = CGFloat(min(460, max(240, store.settings.reviewLeftWidth)))
        rightWidth = CGFloat(min(420, max(220, store.settings.reviewRightWidth)))
    }

    private func clampedPaneWidths(
        totalWidth: CGFloat,
        desiredLeft: CGFloat,
        desiredRight: CGFloat,
        showRight: Bool
    ) -> (left: CGFloat, right: CGFloat) {
        let minCenter: CGFloat = 320
        let dividerTotal: CGFloat = showRight ? 12 : 6
        var effectiveLeft = min(460, max(240, desiredLeft))
        var effectiveRight = showRight ? min(420, max(220, desiredRight)) : 0

        guard totalWidth > 0 else { return (effectiveLeft, effectiveRight) }
        let availableForSides = max(0, totalWidth - dividerTotal - minCenter)
        if effectiveLeft + effectiveRight > availableForSides {
            if !showRight {
                effectiveLeft = min(effectiveLeft, availableForSides)
                if effectiveLeft < 180 && totalWidth > dividerTotal + 180 {
                    effectiveLeft = min(180, totalWidth - dividerTotal - 160)
                }
            } else {
                let excess = effectiveLeft + effectiveRight - availableForSides
                let leftRoom = max(0, effectiveLeft - 240)
                let rightRoom = max(0, effectiveRight - 220)
                if leftRoom + rightRoom >= excess && leftRoom + rightRoom > 0 {
                    let takeRight = min(rightRoom, excess * (rightRoom / (leftRoom + rightRoom)))
                    let takeLeft = min(leftRoom, excess - takeRight)
                    effectiveRight -= takeRight
                    effectiveLeft -= takeLeft
                } else {
                    let maxSides = max(0, totalWidth - dividerTotal - 200)
                    let sum = effectiveLeft + effectiveRight
                    if sum > 0 && sum > maxSides {
                        let scale = maxSides / sum
                        effectiveLeft *= scale
                        effectiveRight *= scale
                    }
                }
            }
        }
        return (effectiveLeft, effectiveRight)
    }

    private func scheduleSaveWidths() {
        widthPersistTask?.cancel()
        let l = Double(min(460, max(240, leftWidth)))
        let r = Double(min(420, max(220, rightWidth)))
        widthPersistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            persistWidthsNow(left: l, right: r)
        }
    }

    private func flushWidthsToSettingsIfNeeded() {
        widthPersistTask?.cancel()
        widthPersistTask = nil
        persistWidthsNow(
            left: Double(min(460, max(240, leftWidth))),
            right: Double(min(420, max(220, rightWidth)))
        )
    }

    private func persistWidthsNow(left: Double, right: Double) {
        let curL = store.settings.reviewLeftWidth
        let curR = store.settings.reviewRightWidth
        guard abs(curL - left) > 0.5 || abs(curR - right) > 0.5 else { return }
        store.updateSettings { s in
            s.reviewLeftWidth = left
            s.reviewRightWidth = right
        }
    }

    private func dismissStaleReviewToastIfNeeded() {
        if store.activeToast?.tasksRoute == .review(taskId) {
            store.activeToast = nil
        }
    }

    private func reloadIfAwaitingReview() {
        let stage = taskSummary?.stage
        if stage == nil || stage == .awaitingReview {
            Task { await viewModel.load(store: store, taskId: taskId) }
        }
    }

    // MARK: - Keyboard Navigation Monitor

    private func installKeyboardMonitor() {
        keyMonitor.install(viewModel: viewModel, store: store, taskId: taskId)
    }

    private func removeKeyboardMonitor() {
        keyMonitor.remove()
    }
}

private struct ConflictJumpButton: View {
    let label: String
    let helpText: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.danger)
                Text(label)
                    .font(.system(size: TidyreelTypeScale.small, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.danger)
                    .underline(true, color: palette.danger)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(isHovered ? palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}
