import SwiftUI
import TidyreelDesign
import TidyreelModels

struct RemoteFolderPickerSheet: View {
    let title: String
    let initialPath: String
    let backend: any StorageBackend
    let shouldCloseBackendOnDisappear: Bool
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var currentDir: String
    @State private var subdirectories: [RemoteEntry] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var refreshNonce: Int = 0
    @State private var isCreatingFolder: Bool = false
    @State private var newFolderName: String = ""

    init(
        title: String,
        initialPath: String = "/",
        backend: any StorageBackend,
        shouldCloseBackendOnDisappear: Bool = false,
        onSelect: @escaping (String) -> Void
    ) {
        self.title = title
        let norm = normalizeDir(initialPath)
        self.initialPath = norm
        self.backend = backend
        self.shouldCloseBackendOnDisappear = shouldCloseBackendOnDisappear
        self.onSelect = onSelect
        self._currentDir = State(initialValue: norm)
    }

    private var pathSegments: [String] {
        currentDir.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)

                Spacer()

                Button {
                    isCreatingFolder.toggle()
                    newFolderName = ""
                } label: {
                    Label(l10n.tr("新建文件夹", "New Folder"), systemImage: "folder.badge.plus")
                        .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                }
                .buttonStyle(.plain)

                Button {
                    refreshNonce &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.tr("刷新", "Refresh"))
            }

            // Breadcrumbs
            breadcrumbBar

            if isCreatingFolder {
                createFolderBar
            }

            // Directory list
            PanelBox(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6), framed: true) {
                Group {
                    if isLoading {
                        DashedSpinner(size: 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        VStack(spacing: 10) {
                            EmptyStateCard(
                                icon: "exclamationmark.triangle",
                                title: l10n.tr("无法读取文件夹", "Unable to Read Folder"),
                                subtitle: localizeCoreMessage(l10n, errorMessage)
                            )
                            SecondaryActionButton(l10n.tr("重试", "Retry"), systemImage: "arrow.clockwise") {
                                refreshNonce &+= 1
                            }
                            .padding(.bottom, 16)
                        }
                    } else if subdirectories.isEmpty {
                        EmptyStateCard(
                            icon: "folder",
                            title: l10n.tr("没有子文件夹", "No Subfolders"),
                            subtitle: l10n.tr("可以直接选择当前文件夹", "You can select the current folder directly")
                        )
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 1) {
                                ForEach(subdirectories) { entry in
                                    InstantHoverRow(
                                        cornerRadius: TidyreelRadii.sm,
                                        padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10),
                                        action: {
                                            navigate(to: entry.path)
                                        }
                                    ) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(palette.textMuted)
                                            Text(entry.name)
                                                .font(.system(size: TidyreelTypeScale.body))
                                                .foregroundStyle(palette.text)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(palette.textFaint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Footer
            HStack(spacing: 10) {
                Text(currentDir)
                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                SecondaryActionButton(l10n.tr("取消", "Cancel")) {
                    dismiss()
                }

                PrimaryActionButton(
                    l10n.tr("选择这个文件夹", "Select Folder"),
                    systemImage: "checkmark"
                ) {
                    onSelect(currentDir)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 470)
        .background(palette.canvas)
        .task(id: "\(currentDir)#\(refreshNonce)") {
            await loadCurrentDirectory(refresh: refreshNonce > 0)
        }
        .onDisappear {
            if shouldCloseBackendOnDisappear {
                let be = backend
                Task { await be.close() }
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    guard currentDir != "/" else { return }
                    navigate(to: dirOf(currentDir))
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(currentDir == "/" ? palette.textFaint.opacity(0.4) : palette.textMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(currentDir == "/")

                crumbButton(
                    label: l10n.rootDir,
                    path: "/",
                    isCurrent: pathSegments.isEmpty
                )

                ForEach(Array(pathSegments.enumerated()), id: \.offset) { idx, seg in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textFaint)

                    let targetPath = "/" + pathSegments.prefix(idx + 1).joined(separator: "/")
                    crumbButton(
                        label: seg,
                        path: targetPath,
                        isCurrent: idx == pathSegments.count - 1
                    )
                }
            }
        }
    }

    private func crumbButton(label: String, path: String, isCurrent: Bool) -> some View {
        Button {
            if !isCurrent { navigate(to: path) }
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? palette.text : palette.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isCurrent ? palette.selected : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private var createFolderBar: some View {
        HStack(spacing: 8) {
            TextField(
                l10n.tr("输入新文件夹名称", "New folder name"),
                text: $newFolderName
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: TidyreelTypeScale.body))
            .onSubmit {
                Task { await createNewFolder() }
            }

            PrimaryActionButton(
                l10n.tr("创建", "Create"),
                isDisabled: newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                Task { await createNewFolder() }
            }
        }
    }

    private func navigate(to dir: String) {
        currentDir = normalizeDir(dir)
        isCreatingFolder = false
    }

    private func loadCurrentDirectory(refresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            let entries = try await backend.list(currentDir, refresh: refresh)
            guard !Task.isCancelled else { return }
            subdirectories = entries
                .filter(\.isDir)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            subdirectories = []
            isLoading = false
        }
    }

    private func createNewFolder() async {
        let trimmed = newFolderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
        guard !trimmed.isEmpty else { return }
        let target = joinPath(currentDir, trimmed)
        do {
            try await backend.mkdirs(target)
            isCreatingFolder = false
            newFolderName = ""
            currentDir = normalizeDir(target)
            refreshNonce &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
