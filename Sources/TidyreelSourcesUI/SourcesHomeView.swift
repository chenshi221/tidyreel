import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct SourcesHomeView: View {
    let store: AppStore
    let coordinator: SourcesCoordinator

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    private var isMissingTmdbKey: Bool {
        !store.isDemoMode
            && store.settings.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.builtInTmdbToken.isEmpty
    }

    private struct FavoriteFolderItem: Identifiable {
        let connection: ConnectionConfig
        let path: String
        var id: String { "\(connection.id.value)#\(path)" }
    }

    private var allFavorites: [FavoriteFolderItem] {
        store.connections.flatMap { conn in
            conn.favorites.map { FavoriteFolderItem(connection: conn, path: $0) }
        }
    }

    var body: some View {
        if store.connections.isEmpty {
            PageScaffoldView(title: l10n.tr("来源", "Sources")) {
                VStack(alignment: .leading, spacing: 0) {
                    if isMissingTmdbKey {
                        missingTmdbBanner
                            .padding(EdgeInsets(top: 0, leading: 48, bottom: 8, trailing: 32))
                    }

                    EmptyStateCard(
                        icon: "cloud",
                        title: l10n.tr("还没有连接", "No Connections Yet"),
                        subtitle: l10n.tr(
                            "添加一个 Alist、WebDAV、SMB 共享或本地文件夹，就可以开始整理了\n\n添加连接 → 浏览并识别 → 确认后整理（可随时撤销）",
                            "Add an Alist, WebDAV, SMB share, or local folder to get started.\n\nAdd source → Browse & match → Review & organize (always undoable)"
                        )
                    ) {
                        addConnectionButton
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            PageScaffoldView(title: l10n.tr("来源", "Sources")) {
                addConnectionButton
            } content: {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if isMissingTmdbKey {
                            missingTmdbBanner
                                .padding(.bottom, 8)
                        }

                        connectionsSection

                        favoritesSection

                        RecentlyOrganizedSection(store: store)
                    }
                    .padding(EdgeInsets(top: 0, leading: 48, bottom: 32, trailing: 32))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var addConnectionButton: some View {
        SecondaryActionButton(
            l10n.tr("添加连接", "Add Connection"),
            systemImage: "plus"
        ) {
            coordinator.presentAddConnection()
        }
    }

    // MARK: - Missing TMDB Key Banner

    private var missingTmdbBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(palette.warning)

            Text(
                l10n.tr(
                    "尚未配置 TMDB API key，无法自动识别影片信息",
                    "TMDB API key is not configured; automatic media matching is unavailable"
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.text)
            .lineLimit(2)

            Spacer(minLength: 8)

            SecondaryActionButton(l10n.tr("去设置", "Settings")) {
                store.navigateToTab(.settings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .fill(palette.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .strokeBorder(palette.warning.opacity(0.30), lineWidth: hairlineWidth)
        )
    }

    // MARK: - Connections Section (`sources_page.dart:92-104`)

    @ViewBuilder
    private var connectionsSection: some View {
        SectionHeaderLabel(l10n.tr("连接", "Connections"))

        PanelBox(padding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8)) {
            VStack(spacing: 0) {
                ForEach(Array(store.connections.enumerated()), id: \.element.id) { idx, conn in
                    if idx > 0 {
                        Rectangle()
                            .fill(palette.line)
                            .frame(height: hairlineWidth)
                    }
                    ConnectionRowView(
                        connection: conn,
                        status: store.connectionStatuses[conn.id] ?? .unknown,
                        onOpen: {
                            store.openBrowser(connection: conn)
                        },
                        onEdit: {
                            coordinator.presentEditConnection(conn, copy: false)
                        },
                        onDuplicate: {
                            coordinator.presentEditConnection(conn, copy: true)
                        },
                        onPing: {
                            Task { await store.pingConnection(conn.id) }
                        },
                        onDelete: {
                            store.removeConnectionWithUndo(conn)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Favorites Section (`sources_page.dart:105-123`)

    @ViewBuilder
    private var favoritesSection: some View {
        SectionHeaderLabel(l10n.tr("收藏", "Favorites"))

        let favs = allFavorites
        if favs.isEmpty {
            Text(
                l10n.tr(
                    "打开一个文件夹，点右上角的 ☆，常用目录就会出现在这里",
                    "Open a folder and click ☆ in the top right to pin frequent directories here"
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 4)
        } else {
            PanelBox(padding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8)) {
                VStack(spacing: 0) {
                    ForEach(Array(favs.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Rectangle()
                                .fill(palette.line)
                                .frame(height: hairlineWidth)
                        }
                        FavoriteFolderRowView(
                            connection: item.connection,
                            path: item.path,
                            onOpen: {
                                store.openBrowser(connection: item.connection, path: item.path)
                            },
                            onUnfavorite: {
                                store.toggleFavorite(connectionId: item.connection.id, path: item.path)
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Recently Organized Section (`sources_page.dart:124-137, 511-581`)

private struct RecentlyOrganizedSection: View {
    let store: AppStore

    @Environment(\.l10n) private var l10n

    private var recentDoneTasks: [TaskSummary] {
        Array(
            store.tasks
                .filter { $0.stage == .done || $0.stage == .partiallyFailed }
                .prefix(3)
        )
    }

    var body: some View {
        let tasks = recentDoneTasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeaderLabel(l10n.tr("最近整理", "Recently Organized"))

                HStack(alignment: .top, spacing: 20) {
                    ForEach(tasks) { task in
                        RecentOrganizedPosterCard(store: store, task: task)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Unified Panel Connection Row (`_ConnectionRow` in `sources_page.dart`)

private struct ConnectionRowView: View {
    let connection: ConnectionConfig
    let status: ConnectionPingState
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onPing: () -> Void
    let onDelete: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let diag = ConnectionDiagnostics.presentation(
            for: status,
            config: connection,
            palette: palette,
            l10n: l10n
        )
        let startNorm = normalizeDir(connection.startDir)

        HStack(alignment: .center, spacing: 0) {
            // Tap target covering icon + text + status
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 0) {
                    OutlinedIconTile(
                        SourcesConnectionIcon.systemName(for: connection.type),
                        size: 40,
                        outlined: true
                    )

                    Spacer().frame(width: 14)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(connection.name)
                            .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                            .foregroundStyle(palette.text)
                            .underline(isHovered, color: palette.textFaint)
                            .lineLimit(1)

                        HStack(alignment: .center, spacing: 0) {
                            FramedTypeTag(l10n.connectionTypeLabel(connection.type))

                            Spacer().frame(width: 10)

                            Text(connection.endpoint)
                                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                .foregroundStyle(palette.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if startNorm != "/" {
                                Spacer().frame(width: 14)
                                metaFactView(icon: "folder", text: startNorm)
                            }

                            if let libRoot = connection.libraryRoot, !libRoot.isEmpty {
                                Spacer().frame(width: 14)
                                metaFactView(
                                    icon: "tray.and.arrow.down",
                                    text: libRoot,
                                    tooltip: l10n.tr("媒体库", "Media Library")
                                )
                            }
                        }

                        if diag.isFailed, let detail = diag.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: TidyreelTypeScale.small))
                                .foregroundStyle(diag.color)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 12)

                    StatusDotLabel(label: diag.label, color: diag.color, busy: diag.isBusy)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if diag.isFailed {
                QuietIconButton(systemImage: "pencil", tooltip: l10n.edit, action: onEdit)
                QuietIconButton(
                    systemImage: "arrow.clockwise",
                    tooltip: l10n.tr("重新检测", "Recheck"),
                    action: onPing
                )
            }

            MoreMenuButton {
                connectionMenuItems
            }
            .opacity(isHovered || diag.isFailed ? 1.0 : 0.35)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            connectionMenuItems
        }
    }

    @ViewBuilder
    private var connectionMenuItems: some View {
        Button(action: onOpen) {
            Label(l10n.tr("打开", "Open"), systemImage: "folder")
        }

        Button(action: onEdit) {
            Label(l10n.edit, systemImage: "pencil")
        }

        Button(action: onDuplicate) {
            Label(l10n.tr("复制为新连接", "Duplicate"), systemImage: "doc.on.doc")
        }

        Button(action: onPing) {
            Label(l10n.tr("重新检测", "Recheck"), systemImage: "arrow.clockwise")
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label(l10n.delete, systemImage: "trash")
        }
    }

    private func metaFactView(icon: String, text: String, tooltip: String? = nil) -> some View {
        let row = HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(palette.textFaint)
            Text(text)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        return Group {
            if let tooltip {
                row.help(tooltip)
            } else {
                row
            }
        }
    }
}

// MARK: - Unified Panel Favorite Folder Row (`_FavoriteRow` in `sources_page.dart`)

private struct FavoriteFolderRowView: View {
    let connection: ConnectionConfig
    let path: String
    let onOpen: () -> Void
    let onUnfavorite: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered = false

    var body: some View {
        let folderName = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .last ?? l10n.rootDir

        HStack(alignment: .center, spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 0) {
                    OutlinedIconTile("star", size: 40, outlined: true)

                    Spacer().frame(width: 14)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(folderName)
                            .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                            .foregroundStyle(palette.text)
                            .underline(isHovered, color: palette.textFaint)
                            .lineLimit(1)

                        HStack(alignment: .center, spacing: 10) {
                            FramedTypeTag(connection.name)

                            Text(path)
                                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                .foregroundStyle(palette.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            MoreMenuButton {
                favoriteMenuItems
            }
            .opacity(isHovered ? 1.0 : 0.35)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            favoriteMenuItems
        }
    }

    @ViewBuilder
    private var favoriteMenuItems: some View {
        Button(action: onOpen) {
            Label(l10n.tr("打开", "Open"), systemImage: "folder")
        }

        Button(role: .destructive, action: onUnfavorite) {
            Label(l10n.tr("取消收藏", "Unfavorite"), systemImage: "star.slash")
        }
    }
}

// MARK: - Recently Organized Fixed-148pt Poster Card (`_RecentTask` in `sources_page.dart:511-581`)

private struct RecentOrganizedPosterCard: View {
    let store: AppStore
    let task: TaskSummary

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private static let posterWidth: CGFloat = 148
    private static let posterHeight: CGFloat = 222

    var body: some View {
        let works = store.taskCardMeta[task.id]?.works ?? []
        let firstWork = works.first
        let fallbackName = task.paths.first?
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .last ?? l10n.rootDir

        let title: String = {
            guard let w = firstWork else { return fallbackName }
            if works.count > 1 {
                return l10n.tr(
                    "\(w.title) 等 \(works.count) 部",
                    "\(w.title) + \(works.count - 1) more"
                )
            }
            return w.title
        }()

        let subtitle = [
            firstWork?.year.map(String.init),
            l10n.tr(
                "\(task.videoCount) 个视频",
                l10n.plural(task.videoCount, "video")
            ),
        ]
        .compactMap { $0 }
        .joined(separator: "  ")

        Button {
            store.openTaskDetail(task.id, fromSources: true)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                DownsampledArtworkView(
                    tmdbPath: firstWork?.posterPath,
                    width: Self.posterWidth,
                    height: Self.posterHeight,
                    cornerRadius: TidyreelRadii.lg,
                    fallbackSystemImage: "folder"
                )

                Spacer().frame(height: 10)

                Text(title)
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Spacer().frame(height: 2)

                Text(subtitle)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
            }
            .frame(width: Self.posterWidth, alignment: .leading)
            .offset(y: isHovered ? -3 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onAppear {
            if store.taskCardMeta[task.id] == nil {
                store.refreshTaskCardMeta(task.id)
            }
        }
    }
}
