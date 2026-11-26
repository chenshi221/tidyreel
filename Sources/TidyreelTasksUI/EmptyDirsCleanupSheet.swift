import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct EmptyDirsCleanupSheet: View {
    let store: AppStore
    let taskId: TaskId
    let dirs: [String]
    var onCompleted: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var selectedDirs: Set<String>
    @State private var isRemoving = false
    @State private var errorMessage: String? = nil

    init(
        store: AppStore,
        taskId: TaskId,
        dirs: [String],
        onCompleted: ((Int) -> Void)? = nil
    ) {
        self.store = store
        self.taskId = taskId
        self.dirs = dirs
        self.onCompleted = onCompleted
        self._selectedDirs = State(initialValue: Set(dirs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.tr("清理空目录", "Clean Empty Folders"))
                .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                .foregroundStyle(palette.text)

            Text(
                l10n.tr(
                    "仅删除完全为空或仅含系统残留文件（如 .DS_Store、Thumbs.db）的目录，不会删除包含媒体文件的目录。",
                    "Only removes folders that are completely empty or contain OS metadata files (.DS_Store, Thumbs.db). Folders with media files are never deleted."
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)

            PanelBox(padding: EdgeInsets(), framed: true) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dirs, id: \.self) { dir in
                            EmptyDirRow(
                                dir: dir,
                                isChecked: selectedDirs.contains(dir),
                                onToggle: { toggleDir(dir) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding(.top, 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.danger)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Text(
                    l10n.tr(
                        "共 \(dirs.count) 个空目录",
                        l10n.plural(dirs.count, "empty folder")
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)

                Spacer()

                SecondaryActionButton(l10n.cancel, isDisabled: isRemoving) {
                    dismiss()
                }

                PrimaryActionButton(
                    isRemoving
                        ? l10n.tr("正在清理…", "Cleaning…")
                        : l10n.tr(
                            "清理所选 (\(selectedDirs.count))",
                            "Clean Selected (\(selectedDirs.count))"
                        ),
                    isDisabled: selectedDirs.isEmpty || isRemoving
                ) {
                    Task { await confirmRemoveSelected() }
                }
            }
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 500)
        .background(palette.panel)
    }

    private func toggleDir(_ dir: String) {
        guard !isRemoving else { return }
        if selectedDirs.contains(dir) {
            selectedDirs.remove(dir)
        } else {
            selectedDirs.insert(dir)
        }
    }

    private func confirmRemoveSelected() async {
        let targets = dirs.filter { selectedDirs.contains($0) }
        guard !targets.isEmpty else { return }
        let key = "cleanup:\(taskId.value)"
        guard TasksBusyTracker.shared.tryAcquireKey(key) else { return }
        isRemoving = true
        errorMessage = nil
        defer {
            isRemoving = false
            TasksBusyTracker.shared.releaseKey(key)
        }

        do {
            let removed = try await store.taskManager.removeEmptyDirs(taskId, dirs: targets)
            store.showToast(
                l10n.tr(
                    "已清理 \(removed) 个空目录",
                    "Removed \(l10n.plural(removed, "empty folder"))"
                )
            )
            onCompleted?(removed)
            dismiss()
        } catch {
            errorMessage = TasksFormatting.readableError(error, l10n: l10n)
        }
    }
}

private struct EmptyDirRow: View {
    let dir: String
    let isChecked: Bool
    let onToggle: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            InkCheckbox(isChecked: isChecked, action: onToggle)
                .frame(width: 24, alignment: .leading)

            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(palette.textMuted)

            Text(dir)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(isHovered ? palette.hover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
    }
}
