import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct RemoteFolderPickerSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    let store: AppStore
    let connection: ConnectionConfig
    let initialPath: String
    let onSelect: (String) -> Void

    @State private var currentDir: String = "/"
    @State private var directories: [RemoteEntry] = []
    @State private var isLoading: Bool = true
    @State private var errorText: String?
    @State private var loadGeneration: Int = 0

    private var pathSegments: [String] {
        currentDir.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                OutlinedIconTile(connectionSymbol(for: connection.type), size: 30, outlined: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.tr("选择体检目录", "Choose Folder to Audit"))
                        .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                        .foregroundStyle(palette.text)
                    Text(connection.name)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                }
                Spacer()
                QuietIconButton(
                    systemImage: "arrow.clockwise",
                    tooltip: l10n.refresh,
                    iconSize: 14,
                    isDisabled: isLoading
                ) {
                    loadDirectory(currentDir, refresh: true)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    breadcrumbButton(
                        title: l10n.rootDir,
                        path: "/",
                        isCurrent: pathSegments.isEmpty
                    )
                    ForEach(Array(pathSegments.enumerated()), id: \.offset) { idx, seg in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(palette.textFaint)
                        let subPath = "/" + pathSegments.prefix(idx + 1).joined(separator: "/")
                        breadcrumbButton(
                            title: seg,
                            path: subPath,
                            isCurrent: idx == pathSegments.count - 1
                        )
                    }
                }
                .padding(.vertical, 2)
            }

            PanelBox(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6), framed: true) {
                Group {
                    if isLoading {
                        VStack(spacing: 10) {
                            AnimatedDashedSpinner(size: 16, color: palette.textMuted)
                            Text(l10n.tr("正在读取目录…", "Loading folders…"))
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(palette.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorText {
                        EmptyStateCard(
                            icon: "exclamationmark.triangle",
                            title: l10n.tr("无法读取文件夹", "Unable to Read Folder"),
                            subtitle: l10n.coreMessage(errorText)
                        )
                    } else if directories.isEmpty {
                        EmptyStateCard(
                            icon: "folder",
                            title: l10n.tr("没有子文件夹", "No Subfolders"),
                            subtitle: l10n.tr(
                                "可以直接点击下方按钮选择当前文件夹",
                                "You can select the current folder directly below"
                            )
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                if currentDir != "/" {
                                    InstantHoverRow(
                                        cornerRadius: TidyreelRadii.sm,
                                        padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
                                    ) {
                                        loadDirectory(normalizeDir(dirOf(currentDir)), refresh: false)
                                    } content: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "arrow.turn.left.up")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(palette.textMuted)
                                                .frame(width: 18)
                                            Text(l10n.tr("返回上级目录", "Parent Folder"))
                                                .font(.system(size: TidyreelTypeScale.body))
                                                .foregroundStyle(palette.textMuted)
                                            Spacer()
                                        }
                                    }
                                }
                                ForEach(directories) { entry in
                                    InstantHoverRow(
                                        cornerRadius: TidyreelRadii.sm,
                                        padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
                                    ) {
                                        loadDirectory(entry.path, refresh: false)
                                    } content: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 13))
                                                .foregroundStyle(palette.textMuted)
                                                .frame(width: 18)
                                            Text(entry.name)
                                                .font(.system(size: TidyreelTypeScale.body))
                                                .foregroundStyle(palette.text)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10.5, weight: .medium))
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

            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
                Text(currentDir)
                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                SecondaryActionButton(l10n.cancel) {
                    dismiss()
                }
                PrimaryActionButton(
                    l10n.tr("选择当前目录", "Select Folder"),
                    systemImage: "checkmark",
                    isDisabled: isLoading || errorText != nil
                ) {
                    onSelect(currentDir)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .background(palette.canvas)
        .task {
            await resolveAndLoadInitial()
        }
    }

    private func breadcrumbButton(title: String, path: String, isCurrent: Bool) -> some View {
        Button {
            if !isCurrent {
                loadDirectory(path, refresh: false)
            }
        } label: {
            Text(title)
                .font(.system(size: TidyreelTypeScale.small, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? palette.text : palette.textMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isCurrent ? palette.selected : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func resolveAndLoadInitial() async {
        let candidate = normalizeDir(initialPath)
        var start = candidate
        if candidate != "/" {
            if let backend = try? store.backend(for: connection.id) {
                let exists = (try? await backend.exists(candidate)) ?? false
                if !exists { start = "/" }
            }
        }
        loadDirectory(start, refresh: false)
    }

    private func loadDirectory(_ rawDir: String, refresh: Bool) {
        let dir = normalizeDir(rawDir)
        currentDir = dir
        isLoading = true
        errorText = nil
        loadGeneration += 1
        let gen = loadGeneration

        Task { @MainActor in
            do {
                let backend = try store.backend(for: connection.id)
                let entries = try await backend.list(dir, refresh: refresh)
                guard gen == loadGeneration else { return }
                directories = entries
                    .filter(\.isDir)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                isLoading = false
            } catch {
                guard gen == loadGeneration else { return }
                directories = []
                errorText = HealthSessionController.friendlyError(error)
                isLoading = false
            }
        }
    }
}
