import AppKit
import Foundation
import Observation
import SwiftUI
import TidyreelDesign
import TidyreelModels

// MARK: - Mutual-Exclusion Busy Task Tracker

@Observable
@MainActor
final class TasksBusyTracker {
    static let shared = TasksBusyTracker()

    private(set) var busyIds: Set<TaskId> = []
    private(set) var busyKeys: Set<String> = []

    private init() {}

    func isBusy(_ id: TaskId) -> Bool {
        busyIds.contains(id)
    }

    func isAnyBusy<S: Sequence>(_ ids: S) -> Bool where S.Element == TaskId {
        ids.contains { busyIds.contains($0) }
    }

    func tryAcquire(_ id: TaskId) -> Bool {
        guard !busyIds.contains(id) else { return false }
        busyIds.insert(id)
        return true
    }

    func tryAcquireAll(_ ids: [TaskId]) -> Bool {
        guard !ids.isEmpty, !ids.contains(where: { busyIds.contains($0) }) else { return false }
        busyIds.formUnion(ids)
        return true
    }

    func release(_ id: TaskId) {
        busyIds.remove(id)
    }

    func releaseAll(_ ids: [TaskId]) {
        busyIds.subtract(ids)
    }

    func isKeyBusy(_ key: String) -> Bool {
        busyKeys.contains(key)
    }

    func tryAcquireKey(_ key: String) -> Bool {
        guard !busyKeys.contains(key) else { return false }
        busyKeys.insert(key)
        return true
    }

    func releaseKey(_ key: String) {
        busyKeys.remove(key)
    }
}

// MARK: - Task Formatting & Stage Helpers (`tasks_page.dart` & `task_detail_page.dart`)

enum TasksFormatting {
    static func stepsFor(_ l10n: AppL10n) -> [String] {
        [
            l10n.tr("导入", "Import"),
            l10n.tr("识别", "Match"),
            l10n.tr("确认", "Review"),
            l10n.tr("重命名", "Rename"),
            l10n.tr("整理文件夹", "Folders"),
        ]
    }

    /// Index of the step currently running; 5 = all complete; -1 = stopped early.
    static func currentStep(_ stage: TaskStage) -> Int {
        switch stage {
        case .importing: return 0
        case .recognizing: return 1
        case .awaitingReview: return 2
        case .renamingFiles: return 3
        case .renamingFolders: return 4
        case .done, .partiallyFailed: return 5
        case .cancelled, .undone, .failed: return -1
        }
    }

    static func stageLabel(_ stage: TaskStage, l10n: AppL10n) -> String {
        switch stage {
        case .done:
            return l10n.tr("已完成", "Done")
        case .partiallyFailed:
            return l10n.tr("部分失败", "Partial")
        case .cancelled:
            return l10n.tr("已取消", "Cancelled")
        case .undone:
            return l10n.tr("已撤销", "Undone")
        case .failed:
            return l10n.tr("失败", "Failed")
        case .awaitingReview:
            return l10n.tr("待确认", "Review")
        case .renamingFiles:
            return l10n.tr("正在重命名文件", "Renaming files")
        case .renamingFolders:
            return l10n.tr("正在整理文件夹", "Organizing folders")
        case .importing:
            return l10n.tr("导入", "Import")
        case .recognizing:
            return l10n.tr("识别", "Match")
        }
    }

    static func runningLabel(_ stage: TaskStage, progress: Double?, l10n: AppL10n) -> String {
        let what: String
        switch stage {
        case .importing:
            what = l10n.tr("正在导入", "Importing")
        case .recognizing:
            what = l10n.tr("正在识别", "Matching")
        case .renamingFiles:
            what = l10n.tr("正在重命名文件", "Renaming files")
        case .renamingFolders:
            what = l10n.tr("正在整理文件夹", "Organizing folders")
        default:
            what = stageLabel(stage, l10n: l10n)
        }
        if let progress {
            let pct = Int((min(max(progress, 0), 1) * 100).rounded())
            return "\(what) \(pct)%"
        }
        return what
    }

    static func stageColor(_ stage: TaskStage, palette: TidyreelPalette) -> Color {
        switch stage {
        case .awaitingReview:
            return palette.accent
        case .done:
            return palette.success
        case .partiallyFailed:
            return palette.warning
        case .failed:
            return palette.danger
        case .cancelled, .undone:
            return palette.textFaint
        case .importing, .recognizing, .renamingFiles, .renamingFolders:
            return palette.textMuted
        }
    }

    static func canDeleteTask(_ task: TaskSummary) -> Bool {
        !task.stage.isActive || task.stage == .awaitingReview
    }

    static func isTmdbApiKeyError(_ message: String) -> Bool {
        if isTmdbKeyError(message) { return true }
        let low = message.lowercased()
        return low.contains("tmdb") && (low.contains("api") || low.contains("key") || low.contains("密钥"))
    }

    static func displayTitle(task: TaskSummary, works: [Candidate], l10n: AppL10n) -> String {
        let folder = task.paths.first?
            .split(separator: "/")
            .map(String.init)
            .last { !$0.isEmpty }
            ?? l10n.rootDir
        if works.isEmpty {
            if task.paths.count > 1 {
                return l10n.tr(
                    "\(folder) 等 \(task.paths.count) 项",
                    "\(folder) + \(task.paths.count - 1) more"
                )
            }
            return folder
        }
        if works.count == 1 {
            return works[0].title
        }
        return l10n.tr(
            "\(works[0].title) 等 \(works.count) 部",
            "\(works[0].title) + \(works.count - 1) more"
        )
    }

    static func metadataLine(
        task: TaskSummary,
        connectionName: String,
        recognized: Bool,
        unassignedCount: Int,
        l10n: AppL10n
    ) -> String {
        let whereText: String
        if task.paths.count == 1 {
            whereText = task.paths[0]
        } else if task.paths.isEmpty {
            whereText = "/"
        } else {
            whereText = l10n.tr(
                "\(task.paths.count) 个文件夹",
                l10n.plural(task.paths.count, "folder")
            )
        }

        var countParts: [String] = [
            l10n.tr("\(task.videoCount) 个视频", l10n.plural(task.videoCount, "video")),
        ]
        if task.subtitleCount > 0 {
            countParts.append(
                l10n.tr("\(task.subtitleCount) 个字幕", l10n.plural(task.subtitleCount, "subtitle"))
            )
        }
        if task.folderCount > 0 {
            countParts.append(
                l10n.tr("\(task.folderCount) 个文件夹", l10n.plural(task.folderCount, "folder"))
            )
        }
        if unassignedCount > 0 {
            countParts.append(
                l10n.tr("\(unassignedCount) 个未归类", "\(unassignedCount) unassigned")
            )
        }
        let counts = countParts.joined(separator: l10n.isEn ? ", " : "，")

        let parts: [String?] = [
            connectionName,
            !task.scrapeOnly ? l10n.organizeModeLabel(task.mode) : nil,
            (task.scrape && !task.scrapeOnly) ? l10n.tr("刮削", "Scrape") : nil,
            recognized ? counts : whereText,
        ]
        return parts.compactMap { $0 }.joined(separator: l10n.isEn ? " · " : "，")
    }

    /// Translates core runtime messages using `TidyreelModels.localizeCoreMessage` plus extended execution patterns.
    static func localizedMessage(_ l10n: AppL10n, _ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let base = localizeCoreMessage(l10n, raw)
        guard l10n.isEn, base == raw else { return base }

        let extraExact: [String: String] = [
            "正在整理文件夹": "Organizing folders",
            "正在刮削（写入元数据和海报）": "Scraping metadata and artwork",
            "正在清理": "Cleaning up",
            "正在重试失败的操作": "Retrying failed operations",
            "整理完成": "Organization complete",
            "已撤销部分操作": "Partially undone",
            "识别完成，请确认结果后继续执行": "Matching complete; review results to continue",
            "锚点识别完成，正在进行后续处理": "Anchor match done; finishing up",
            "上次执行未开始，请重新确认": "Previous run did not start; please review again",
            "任务正在处理中": "Task is currently busy",
            "任务尚未识别完成": "Task has not finished matching yet",
            "正在更新整理计划，请稍后再试": "Updating plan; please try again shortly",
            "存在冲突，无法执行": "Resolve naming conflicts before running",
            "没有可执行的操作：请先勾选要整理的作品": "Nothing to run: select at least one work first",
            "任务没有失败的操作": "Task has no failed operations",
            "这个任务不能重试": "This task cannot be retried",
            "任务正在进行，先取消再删除": "Task is active; cancel it before deleting",
            "任务没有可撤销的操作": "Task has no operations to undo",
            "任务正在撤销中": "Task is already being undone",
            "删除无法撤销": "Deleted files cannot be restored",
            "覆盖写入无法撤销": "Overwrite write cannot be undone",
            "文件夹非空，已保留": "Folder is not empty; kept",
            "文件或目录不存在": "File or folder not found",
            "目标位置已存在同名文件或目录": "Destination already exists",
            "文件或目录正被占用": "File or folder is in use",
            "网络连接失败": "Network connection failed",
            "连接超时": "Connection timed out",
        ]
        if let hit = extraExact[raw] { return hit }

        if raw.hasPrefix("正在撤销（"), raw.hasSuffix("）") {
            let inner = raw.dropFirst("正在撤销（".count).dropLast()
            return "Undoing (\(inner))"
        }
        for (zhPhase, enPhase) in [
            ("正在重命名文件", "Renaming files"),
            ("正在整理文件夹", "Organizing folders"),
            ("正在刮削（写入元数据和海报）", "Scraping"),
            ("正在清理", "Cleaning up"),
        ] {
            let prefix = "\(zhPhase)（"
            if raw.hasPrefix(prefix), raw.hasSuffix("）") {
                let inner = raw.dropFirst(prefix.count).dropLast()
                return "\(enPhase) (\(inner))"
            }
        }
        if raw.hasPrefix("部分操作失败（"), raw.hasSuffix(" 项），其余已完成") {
            let numStr = raw
                .replacingOccurrences(of: "部分操作失败（", with: "")
                .replacingOccurrences(of: " 项），其余已完成", with: "")
            let n = Int(numStr) ?? 0
            return "\(l10n.plural(n, "operation")) failed; the rest completed"
        }
        for (zhStep, enStep) in [
            ("导入失败：", "Import failed: "),
            ("识别失败：", "Matching failed: "),
            ("生成计划失败：", "Planning failed: "),
            ("执行失败：", "Execution failed: "),
            ("执行出错：", "Execution failed: "),
            ("原位置已被占用：", "Original path is occupied: "),
            ("目标已不存在：", "Destination no longer exists: "),
            ("依赖的操作失败：", "Prerequisite operation failed: "),
            ("所选路径不存在：", "Selected path not found: "),
            ("连接不存在：", "Connection not found: "),
        ] {
            if raw.hasPrefix(zhStep) {
                let tail = String(raw.dropFirst(zhStep.count))
                return enStep + localizedMessage(l10n, tail)
            }
        }
        if raw.hasPrefix("已撤销部分操作") {
            return "Partially undone"
        }
        return base
    }

    static func readableError(_ error: any Error, l10n: AppL10n) -> String {
        if let se = error as? StorageError {
            return localizedMessage(l10n, se.message.isEmpty ? se.code.rawValue : se.message)
        }
        if let te = error as? TmdbError {
            return localizedMessage(l10n, te.message)
        }
        if let le = error as? any LocalizedError, let desc = le.errorDescription, !desc.isEmpty {
            return localizedMessage(l10n, desc)
        }
        return localizedMessage(l10n, String(describing: error))
    }

    static func explainRecordError(_ error: String, l10n: AppL10n) -> String {
        let low = error.lowercased()
        if error.contains("StorageErrorCode.busy") || error.contains("正被占用") || low.contains("access is denied") {
            return l10n.tr(
                "文件夹被占用：服务器上有程序正打开里面的文件（如下载软件正在做种、播放器或资源管理器开着）。关掉后点右上角「重试失败项」。\n\(error)",
                "Folder is in use: another app on the server has a file open (e.g. torrent client, player, or Explorer). Close it and click \"Retry Failed\" above.\n\(localizedMessage(l10n, error))"
            )
        }
        return localizedMessage(l10n, error)
    }

    static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").map(String.init).last { !$0.isEmpty } ?? path
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - 5-Step Monochrome Ink Stepper (`TaskStepper` in `tasks_page.dart:642-704`)

struct TaskStepper: View {
    let stage: TaskStage
    let progress: Double?
    let running: Bool
    let reduceMotion: Bool

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    init(
        stage: TaskStage,
        progress: Double? = nil,
        running: Bool = true,
        reduceMotion: Bool = false
    ) {
        self.stage = stage
        self.progress = progress
        self.running = running
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        let steps = TasksFormatting.stepsFor(l10n)
        let cur = TasksFormatting.currentStep(stage)

        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                VStack(alignment: .leading, spacing: 4) {
                    stepBar(index: idx, currentIndex: cur)
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

                    Text(label)
                        .font(.system(
                            size: TidyreelTypeScale.small,
                            weight: idx == cur ? .semibold : .regular
                        ))
                        .foregroundStyle(
                            idx == cur
                                ? palette.text
                                : (idx < cur ? palette.textMuted : palette.textFaint)
                        )
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func stepBar(index: Int, currentIndex: Int) -> some View {
        if index == currentIndex && !running {
            Rectangle().fill(palette.text)
        } else if index == currentIndex, let progress {
            GeometryReader { geo in
                let clamped = min(max(progress, 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(palette.selected)
                    LinearGradient(
                        colors: [palette.text.opacity(0.68), palette.text],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(3, geo.size.width * clamped))
                }
            }
        } else if index == currentIndex {
            IndeterminateInkBar(
                trackColor: palette.text.opacity(0.12),
                barColor: palette.text,
                reduceMotion: reduceMotion
            )
        } else if index < currentIndex {
            Rectangle().fill(palette.text.opacity(0.7))
        } else {
            Rectangle().fill(palette.selected)
        }
    }
}

private struct IndeterminateInkBar: View {
    let trackColor: Color
    let barColor: Color
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let segWidth = max(14, width * 0.36)
            let travel = max(0, width - segWidth)
            ZStack(alignment: .leading) {
                Rectangle().fill(trackColor)
                Rectangle()
                    .fill(barColor.opacity(reduceMotion ? 0.65 : 0.90))
                    .frame(width: reduceMotion ? width * 0.45 : segWidth)
                    .offset(x: reduceMotion ? 0 : travel * phase)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
}

// MARK: - Clean Xuan-Paper Confirmation Sheet (`confirmDialog` / `confirmPermanentDelete`)

struct TaskActionConfirmSheet: View {
    let title: String
    let message: String
    let confirmLabel: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            Text(message)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.textMuted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                SecondaryActionButton(l10n.cancel) {
                    dismiss()
                }
                if isDestructive {
                    SecondaryActionButton(confirmLabel, isDestructive: true) {
                        dismiss()
                        onConfirm()
                    }
                } else {
                    PrimaryActionButton(confirmLabel) {
                        dismiss()
                        onConfirm()
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 440)
        .background(palette.panel)
    }
}
