import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelParser
import TidyreelServices

enum BrowserViewMode: String, CaseIterable, Hashable {
    case list
    case map
}

enum BrowserSort: String, CaseIterable, Hashable {
    case name
    case time
    case size
}

struct FileBrowserView: View {
    let store: AppStore
    let connection: ConnectionConfig
    let coordinator: SourcesCoordinator

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    // Navigation & View Mode
    @State private var currentDir: String
    @State private var viewMode: BrowserViewMode = .list
    @State private var searchText: String = ""
    @State private var sortMode: BrowserSort = .name
    @State private var onlyUnorganized: Bool = false

    // Directory Listing & Background Organized State
    @State private var rawEntries: [RemoteEntry] = []
    @State private var entriesRevision: Int = 0
    @State private var simplifiedLowerNames: [String: String] = [:]
    @State private var displayedEntries: [RemoteEntry] = []
    @State private var isLoadingEntries: Bool = false
    @State private var showLoadingSpinner: Bool = false
    @State private var listingError: Error?
    @State private var refreshNonce: Int = 0
    @State private var mapRefreshTrigger: Int = 0
    @State private var autoOrganizedPaths: Set<String> = []
    @State private var manualOrganizedMarks: [String: Bool] = [:]

    // Selection & Task Submission Controls
    @State private var selectedPaths: Set<String> = []
    @State private var lastClickedPath: String?
    @State private var isShowingSelectedSheet: Bool = false
    @State private var organizeMode: OrganizeMode
    @State private var isSubmittingTask: Bool = false
    @State private var activeScanPreview: ScanPreviewRequest?

    init(
        store: AppStore,
        connection: ConnectionConfig,
        coordinator: SourcesCoordinator
    ) {
        self.store = store
        self.connection = connection
        self.coordinator = coordinator
        let root = normalizeDir(connection.startDir)
        let initialDir: String
        if let req = store.browserJumpRequest, req.connectionId == connection.id {
            let norm = normalizeDir(req.path)
            initialDir = isWithinDir(norm, root: root) ? norm : root
        } else {
            initialDir = root
        }
        self._currentDir = State(initialValue: initialDir)
        self._organizeMode = State(initialValue: store.settings.defaultMode)
    }

    private var rootDir: String {
        normalizeDir(connection.startDir)
    }

    private var liveConnection: ConnectionConfig {
        store.connections.first(where: { $0.id == connection.id }) ?? connection
    }

    private var isCurrentDirFavorite: Bool {
        liveConnection.favorites.contains(normalizeDir(currentDir))
    }

    private func isEntryOrganized(_ entry: RemoteEntry) -> Bool {
        if let manual = manualOrganizedMarks[entry.path] {
            return manual
        }
        return autoOrganizedPaths.contains(entry.path)
    }

    private func recomputeDisplayedEntries() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let simplifiedQuery = trimmedQuery.isEmpty ? "" : toSimplified(trimmedQuery.lowercased())
        var list = rawEntries
        if !simplifiedQuery.isEmpty {
            list = list.filter { entry in
                let target = simplifiedLowerNames[entry.path] ?? toSimplified(entry.name.lowercased())
                return fuzzyMatch(simplifiedLowerQuery: simplifiedQuery, simplifiedLowerTarget: target)
            }
        }
        if onlyUnorganized {
            list = list.filter { !isEntryOrganized($0) }
        }
        list.sort { a, b in
            if a.isDir != b.isDir {
                return a.isDir && !b.isDir
            }
            switch sortMode {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .time:
                let da = a.modified ?? .distantPast
                let db = b.modified ?? .distantPast
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                if a.size != b.size { return a.size > b.size }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        displayedEntries = list
    }

    private var allDisplayedSelected: Bool {
        let shown = displayedEntries
        guard !shown.isEmpty else { return false }
        return shown.allSatisfy { selectedPaths.contains($0.path) }
    }

    var body: some View {
        let conn = liveConnection

        PageScaffoldView(
            title: conn.name,
            subtitle: "\(l10n.connectionTypeLabel(conn.type))  ·  \(conn.endpoint)",
            leading: {
                QuietIconButton(
                    systemImage: "chevron.left",
                    tooltip: l10n.tr("返回连接列表", "Back to Connections")
                ) {
                    store.openConnectionId = nil
                }
            },
            actions: {
                QuietIconButton(
                    systemImage: "arrow.clockwise",
                    tooltip: l10n.refresh
                ) {
                    triggerRefresh()
                }
                QuietIconButton(
                    systemImage: isCurrentDirFavorite ? "star.fill" : "star",
                    tooltip: isCurrentDirFavorite
                        ? l10n.tr("取消收藏此文件夹", "Unfavorite Folder")
                        : l10n.tr("收藏此文件夹", "Favorite Folder"),
                    tint: isCurrentDirFavorite ? palette.accent : nil
                ) {
                    store.toggleFavorite(connectionId: conn.id, path: currentDir)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                breadcrumbBar
                toolbarView

                ZStack(alignment: .bottom) {
                    Group {
                        switch viewMode {
                        case .list:
                            listModeContainer
                                .padding(EdgeInsets(top: 0, leading: 48, bottom: 20, trailing: 40))
                        case .map:
                            RepoMapView(
                                store: store,
                                connection: conn,
                                dir: currentDir,
                                refreshTrigger: mapRefreshTrigger,
                                selectedPaths: selectedPaths,
                                manualOrganizedMarks: manualOrganizedMarks,
                                onOpenDir: { targetDir in
                                    navigateToDirectory(targetDir)
                                },
                                onSwitchToList: {
                                    viewMode = .list
                                },
                                onToggleSelect: { path in
                                    toggleSelection(for: path)
                                },
                                onSetSelection: { nextSet in
                                    selectedPaths = nextSet
                                },
                                onSubmitSingle: { path, modeOverride, scrape, scrapeOnly in
                                    initiateSubmit(
                                        paths: [path],
                                        modeOverride: modeOverride,
                                        scrape: scrape,
                                        scrapeOnly: scrapeOnly,
                                        clearSelectionOnSubmit: false
                                    )
                                },
                                onToggleFavorite: { path in
                                    store.toggleFavorite(connectionId: conn.id, path: path)
                                },
                                onMarkOrganized: { path, isOrg in
                                    manualOrganizedMarks[path] = isOrg
                                }
                            )
                            .padding(EdgeInsets(top: 4, leading: 48, bottom: 20, trailing: 40))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !selectedPaths.isEmpty {
                        SelectionFloatingBar(
                            count: selectedPaths.count,
                            mode: organizeMode,
                            hint: store.settings.mediaHint,
                            isSubmitting: isSubmittingTask,
                            onShowSelected: {
                                isShowingSelectedSheet = true
                            },
                            onHintChange: { nextHint in
                                store.updateSettings { $0.mediaHint = nextHint }
                            },
                            onModeChange: { nextMode in
                                if nextMode == .moveToLibrary && (conn.libraryRoot ?? "").isEmpty {
                                    warnMissingLibraryRoot()
                                    return
                                }
                                organizeMode = nextMode
                            },
                            onCancel: {
                                selectedPaths.removeAll()
                            },
                            onOrganize: {
                                initiateSubmit(
                                    paths: selectedPaths.sorted(),
                                    modeOverride: nil,
                                    scrape: false,
                                    scrapeOnly: false,
                                    clearSelectionOnSubmit: true
                                )
                            },
                            onScrape: {
                                initiateSubmit(
                                    paths: selectedPaths.sorted(),
                                    modeOverride: nil,
                                    scrape: true,
                                    scrapeOnly: false,
                                    clearSelectionOnSubmit: true
                                )
                            },
                            onScrapeOnly: {
                                initiateSubmit(
                                    paths: selectedPaths.sorted(),
                                    modeOverride: nil,
                                    scrape: true,
                                    scrapeOnly: true,
                                    clearSelectionOnSubmit: true
                                )
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            consumePendingJumpRequestIfNeeded()
        }
        .onChange(of: store.browserJumpRequest) { _, _ in
            consumePendingJumpRequestIfNeeded()
        }
        .onChange(of: conn.startDir) { _, newStart in
            let clamped = normalizeDir(newStart)
            if !isWithinDir(currentDir, root: clamped) {
                currentDir = clamped
            }
        }
        .onChange(of: searchText) { _, _ in
            recomputeDisplayedEntries()
        }
        .onChange(of: sortMode) { _, _ in
            recomputeDisplayedEntries()
        }
        .onChange(of: onlyUnorganized) { _, _ in
            recomputeDisplayedEntries()
        }
        .onChange(of: autoOrganizedPaths) { _, _ in
            if onlyUnorganized {
                recomputeDisplayedEntries()
            }
        }
        .onChange(of: manualOrganizedMarks) { _, _ in
            if onlyUnorganized {
                recomputeDisplayedEntries()
            }
        }
        .task(id: "\(conn.id.value)#\(currentDir)#\(refreshNonce)") {
            await loadDirectoryEntries(forceRefresh: refreshNonce > 0)
        }
        .task(id: "\(conn.id.value)#\(entriesRevision)#\(store.namingProfile.hashValue)") {
            await computeOrganizedPathsInBackground()
        }
        .sheet(isPresented: $isShowingSelectedSheet) {
            SelectedItemsSheet(
                selectedPaths: $selectedPaths,
                onNavigateToFolder: { parentDir in
                    isShowingSelectedSheet = false
                    navigateToDirectory(parentDir)
                }
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(item: $activeScanPreview) { previewReq in
            ScanPreviewSheet(
                store: store,
                request: previewReq,
                onConfirm: {
                    executeSubmitTask(request: previewReq)
                }
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - Breadcrumb Bar (`padding: .leading 40, .trailing 40`)

    private var breadcrumbBar: some View {
        let rootSegs = rootDir.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let allSegs = currentDir.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let subSegs = Array(allSegs.dropFirst(min(rootSegs.count, allSegs.count)))
        let rootTitle = rootSegs.last ?? l10n.rootDir

        return HStack(alignment: .center, spacing: 0) {
            QuietIconButton(
                systemImage: "house",
                tooltip: l10n.tr("回到主页", "Home Folder"),
                iconSize: 15,
                isDisabled: currentDir == rootDir
            ) {
                navigateToDirectory(rootDir)
            }

            QuietIconButton(
                systemImage: "arrow.up",
                tooltip: l10n.tr("上一级", "Up One Level"),
                iconSize: 15,
                isDisabled: currentDir == rootDir
            ) {
                guard currentDir != rootDir else { return }
                let parent = dirOf(currentDir)
                navigateToDirectory(isWithinDir(parent, root: rootDir) ? parent : rootDir)
            }

            Spacer().frame(width: 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 2) {
                    BreadcrumbItemButton(
                        label: rootTitle,
                        isLast: subSegs.isEmpty
                    ) {
                        navigateToDirectory(rootDir)
                    }

                    ForEach(Array(subSegs.enumerated()), id: \.offset) { idx, seg in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textFaint)

                        let prefixPath = (rootDir == "/" ? "" : rootDir) + "/" + subSegs.prefix(idx + 1).joined(separator: "/")
                        BreadcrumbItemButton(
                            label: seg,
                            isLast: idx == subSegs.count - 1
                        ) {
                            navigateToDirectory(normalizeDir(prefixPath))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 40)
        .padding(.trailing, 40)
    }

    // MARK: - Toolbar (`padding: .leading 48, .trailing 40, .top 6, .bottom 12`)

    private var toolbarView: some View {
        FlowHStack(spacing: 8, runSpacing: 8) {
            SlidingSegmented(
                options: [
                    (value: BrowserViewMode.list, label: l10n.tr("列表", "List")),
                    (value: BrowserViewMode.map, label: l10n.tr("地图", "Map")),
                ],
                selection: viewMode,
                onSelect: { viewMode = $0 }
            )

            SecondaryActionButton(
                l10n.tr("整理当前文件夹", "Organize Current Folder"),
                systemImage: "wand.and.stars"
            ) {
                initiateSubmit(
                    paths: [currentDir],
                    modeOverride: nil,
                    scrape: false,
                    scrapeOnly: false,
                    clearSelectionOnSubmit: false
                )
            }

            if viewMode == .list {
                searchInputField
                sortMenuButton
                unorganizedFilterChip

                QuietTextButton(
                    allDisplayedSelected
                        ? l10n.tr("取消全选", "Deselect All")
                        : l10n.tr("全选", "Select All")
                ) {
                    toggleSelectAllDisplayed()
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 48, bottom: 12, trailing: 40))
    }

    private var searchInputField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)

            TextField(
                l10n.tr("在当前文件夹内搜索", "Search in this folder"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: TidyreelTypeScale.body))
            .foregroundStyle(palette.text)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
        )
    }

    private var sortMenuButton: some View {
        let sortLabel: String = {
            switch sortMode {
            case .name: return l10n.tr("按名称", "Name")
            case .time: return l10n.tr("按时间", "Modified")
            case .size: return l10n.tr("按大小", "Size")
            }
        }()

        return Menu {
            Button {
                sortMode = .name
            } label: {
                HStack {
                    Text(l10n.tr("按名称", "Name"))
                    if sortMode == .name { Image(systemName: "checkmark") }
                }
            }
            Button {
                sortMode = .time
            } label: {
                HStack {
                    Text(l10n.tr("按时间", "Modified"))
                    if sortMode == .time { Image(systemName: "checkmark") }
                }
            }
            Button {
                sortMode = .size
            } label: {
                HStack {
                    Text(l10n.tr("按大小", "Size"))
                    if sortMode == .size { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textMuted)
                Text(sortLabel)
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.tr("排序", "Sort"))
    }

    private var unorganizedFilterChip: some View {
        Button {
            onlyUnorganized.toggle()
        } label: {
            HStack(spacing: 5) {
                if onlyUnorganized {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(l10n.tr("只看未整理的", "Unorganized Only"))
                    .font(.system(size: TidyreelTypeScale.body, weight: onlyUnorganized ? .medium : .regular))
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(onlyUnorganized ? palette.selected : palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(
                        onlyUnorganized ? palette.text.opacity(0.65) : palette.lineStrong,
                        lineWidth: hairlineWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List View (`file_browser.dart:1164-1282`)

    private var listModeContainer: some View {
        let conn = liveConnection
        let shown = displayedEntries
        let hasActiveFilter = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || onlyUnorganized

        return PanelBox(padding: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
            Group {
                if isLoadingEntries && rawEntries.isEmpty {
                    if showLoadingSpinner {
                        DashedSpinner(size: 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let listingError {
                    let isAuthError: Bool = {
                        if let se = listingError as? StorageError, se.code == .unauthorized {
                            return true
                        }
                        return false
                    }()
                    let rawMsg = (listingError as? StorageError)?.message ?? listingError.localizedDescription
                    let detail = isAuthError
                        ? l10n.tr(
                            "用户名或密码错误（区分大小写）：\(localizeCoreMessage(l10n, rawMsg))",
                            "Incorrect username or password (case-sensitive): \(localizeCoreMessage(l10n, rawMsg))"
                        )
                        : ConnectionDiagnostics.enrichOfflineMessage(rawMsg, config: conn, l10n: l10n)

                    EmptyStateCard(
                        icon: "exclamationmark.triangle",
                        title: isAuthError
                            ? l10n.tr("认证失败", "Authentication Failed")
                            : l10n.tr("无法读取文件夹", "Unable to Read Folder"),
                        subtitle: detail
                    ) {
                        HStack(spacing: 8) {
                            SecondaryActionButton(l10n.retry) {
                                triggerRefresh()
                            }
                            SecondaryActionButton(l10n.tr("编辑连接", "Edit Connection")) {
                                coordinator.presentEditConnection(conn)
                            }
                        }
                    }
                } else if shown.isEmpty {
                    if hasActiveFilter {
                        EmptyStateCard(
                            icon: "magnifyingglass",
                            title: l10n.tr("没有符合筛选条件的项目", "No Matching Items")
                        ) {
                            SecondaryActionButton(l10n.tr("清除筛选", "Clear Filters")) {
                                searchText = ""
                                onlyUnorganized = false
                            }
                        }
                    } else {
                        EmptyStateCard(
                            icon: "folder",
                            title: l10n.tr("这个文件夹是空的", "This Folder Is Empty")
                        )
                    }
                } else {
                    let favoritesSet = Set(conn.favorites)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, entry in
                                if idx > 0 {
                                    Rectangle()
                                        .fill(palette.line)
                                        .frame(height: hairlineWidth)
                                        .padding(.horizontal, 16)
                                }
                                FileBrowserEntryRow(
                                    entry: entry,
                                    isSelected: selectedPaths.contains(entry.path),
                                    anySelected: !selectedPaths.isEmpty,
                                    isFavorite: entry.isDir && favoritesSet.contains(normalizeDir(entry.path)),
                                    explicitMark: manualOrganizedMarks[entry.path],
                                    onRowClick: {
                                        handleEntryRowClick(entry, in: shown)
                                    },
                                    onToggleCheckbox: {
                                        toggleSelection(for: entry.path)
                                        lastClickedPath = entry.path
                                    },
                                    onOpenFolder: {
                                        if entry.isDir {
                                            navigateToDirectory(entry.path)
                                        }
                                    },
                                    onQuickOrganize: {
                                        initiateSubmit(
                                            paths: [entry.path],
                                            modeOverride: nil,
                                            scrape: false,
                                            scrapeOnly: false,
                                            clearSelectionOnSubmit: false
                                        )
                                    },
                                    onSubmitVariant: { mode, scrape, scrapeOnly in
                                        initiateSubmit(
                                            paths: [entry.path],
                                            modeOverride: mode,
                                            scrape: scrape,
                                            scrapeOnly: scrapeOnly,
                                            clearSelectionOnSubmit: false
                                        )
                                    },
                                    onToggleFavorite: {
                                        store.toggleFavorite(connectionId: conn.id, path: entry.path)
                                    },
                                    onMarkOrganized: { flag in
                                        manualOrganizedMarks[entry.path] = flag
                                    },
                                    onCopyPath: {
                                        copyStringToPasteboard(entry.path)
                                        store.showToast(l10n.tr("已复制路径", "Path copied"))
                                    }
                                )
                            }
                        }
                        .padding(
                            EdgeInsets(
                                top: 6,
                                leading: 6,
                                bottom: selectedPaths.isEmpty ? 6 : 96,
                                trailing: 6
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contextMenu {
            folderContextMenuItems(conn: conn)
        }
    }

    @ViewBuilder
    private func folderContextMenuItems(conn: ConnectionConfig) -> some View {
        Button {
            triggerRefresh()
        } label: {
            Label(l10n.refresh, systemImage: "arrow.clockwise")
        }

        Button {
            toggleSelectAllDisplayed()
        } label: {
            Label(l10n.tr("全选 / 取消全选", "Select / Deselect All"), systemImage: "checkmark.square")
        }

        Divider()

        Button {
            initiateSubmit(
                paths: [currentDir],
                modeOverride: .inPlace,
                scrape: false,
                scrapeOnly: false,
                clearSelectionOnSubmit: false
            )
        } label: {
            Label(l10n.tr("整理（原地）", "Organize (In-place)"), systemImage: "wand.and.stars")
        }

        Button {
            initiateSubmit(
                paths: [currentDir],
                modeOverride: .moveToLibrary,
                scrape: false,
                scrapeOnly: false,
                clearSelectionOnSubmit: false
            )
        } label: {
            Label(l10n.tr("整理（移动到媒体库）", "Organize (Move to Library)"), systemImage: "tray.and.arrow.down")
        }

        Button {
            initiateSubmit(
                paths: [currentDir],
                modeOverride: nil,
                scrape: true,
                scrapeOnly: false,
                clearSelectionOnSubmit: false
            )
        } label: {
            Label(l10n.tr("刮削", "Scrape"), systemImage: "photo.on.rectangle")
        }

        Button {
            initiateSubmit(
                paths: [currentDir],
                modeOverride: nil,
                scrape: true,
                scrapeOnly: true,
                clearSelectionOnSubmit: false
            )
        } label: {
            Label(l10n.tr("仅刮削（不改文件名）", "Scrape Only (Keep Filenames)"), systemImage: "sparkles")
        }

        Button {
            store.toggleFavorite(connectionId: conn.id, path: currentDir)
        } label: {
            Label(
                isCurrentDirFavorite
                    ? l10n.tr("取消收藏当前文件夹", "Unfavorite Current Folder")
                    : l10n.tr("收藏当前文件夹", "Favorite Current Folder"),
                systemImage: isCurrentDirFavorite ? "star.slash" : "star"
            )
        }

        Button {
            copyStringToPasteboard(currentDir)
            store.showToast(l10n.tr("已复制路径", "Path copied"))
        } label: {
            Label(l10n.tr("复制当前路径", "Copy Current Path"), systemImage: "doc.on.clipboard")
        }
    }

    // MARK: - Actions & Async Operations

    private func consumePendingJumpRequestIfNeeded() {
        guard let req = store.browserJumpRequest, req.connectionId == connection.id else { return }
        let norm = normalizeDir(req.path)
        let target = isWithinDir(norm, root: rootDir) ? norm : rootDir
        searchText = ""
        selectedPaths.removeAll()
        lastClickedPath = nil
        currentDir = target
        store.browserJumpRequest = nil
    }

    private func navigateToDirectory(_ target: String) {
        let norm = normalizeDir(target)
        searchText = ""
        lastClickedPath = nil
        currentDir = isWithinDir(norm, root: rootDir) ? norm : rootDir
    }

    private func triggerRefresh() {
        refreshNonce &+= 1
        if viewMode == .map {
            mapRefreshTrigger &+= 1
        }
    }

    private func toggleSelection(for path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func toggleSelectAllDisplayed() {
        let paths = Set(displayedEntries.map(\.path))
        guard !paths.isEmpty else { return }
        if paths.isSubset(of: selectedPaths) {
            selectedPaths.subtract(paths)
        } else {
            selectedPaths.formUnion(paths)
        }
    }

    private func handleEntryRowClick(_ entry: RemoteEntry, in shown: [RemoteEntry]) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let isRangeSelect = modifiers.contains(.shift)
        let isCmdSelect = modifiers.contains(.command) || modifiers.contains(.control)

        if isRangeSelect,
           let anchor = lastClickedPath,
           let i1 = shown.firstIndex(where: { $0.path == anchor }),
           let i2 = shown.firstIndex(where: { $0.path == entry.path }) {
            let lower = min(i1, i2)
            let upper = max(i1, i2)
            for idx in lower...upper {
                selectedPaths.insert(shown[idx].path)
            }
            return
        }

        if entry.isDir && !isCmdSelect && !isRangeSelect {
            navigateToDirectory(entry.path)
            return
        }

        toggleSelection(for: entry.path)
        lastClickedPath = entry.path
    }

    private func warnMissingLibraryRoot() {
        let conn = liveConnection
        store.showToast(
            l10n.tr(
                "此连接尚未设置媒体库，请先编辑连接设置媒体库路径",
                "No media library folder is set for this connection. Edit the connection first."
            ),
            actionLabel: l10n.tr("编辑连接", "Edit Connection")
        ) { [weak coordinator] in
            coordinator?.presentEditConnection(conn)
        }
    }

    private func initiateSubmit(
        paths: [String],
        modeOverride: OrganizeMode?,
        scrape: Bool,
        scrapeOnly: Bool,
        clearSelectionOnSubmit: Bool
    ) {
        guard !paths.isEmpty, !isSubmittingTask else { return }
        let conn = liveConnection
        let chosenMode: OrganizeMode = scrapeOnly
            ? .inPlace
            : (modeOverride ?? organizeMode)
        let effectiveScrape = scrape || scrapeOnly

        if !scrapeOnly && chosenMode == .moveToLibrary && (conn.libraryRoot ?? "").isEmpty {
            warnMissingLibraryRoot()
            return
        }

        var fileSizes: [String: Int64] = [:]
        for entry in rawEntries where !entry.isDir {
            fileSizes[entry.path] = entry.size
        }

        let req = ScanPreviewRequest(
            connectionId: conn.id,
            paths: paths,
            fileSizes: fileSizes,
            mode: chosenMode,
            scrape: effectiveScrape,
            scrapeOnly: scrapeOnly,
            mediaHint: store.settings.mediaHint,
            clearSelectionOnSubmit: clearSelectionOnSubmit
        )

        if store.settings.scanPreview {
            activeScanPreview = req
        } else {
            executeSubmitTask(request: req)
        }
    }

    private func executeSubmitTask(request: ScanPreviewRequest) {
        guard !isSubmittingTask else { return }
        isSubmittingTask = true
        Task {
            defer { isSubmittingTask = false }
            do {
                let taskId = try await store.submitTask(
                    connection: request.connectionId,
                    paths: request.paths,
                    mode: request.mode,
                    scrape: request.scrape,
                    scrapeOnly: request.scrapeOnly
                )
                if request.clearSelectionOnSubmit {
                    selectedPaths.removeAll()
                }
                store.openTaskDetail(taskId)
            } catch {
                let msg = localizeCoreMessage(l10n, error.localizedDescription)
                store.showToast(
                    l10n.tr("提交任务失败：\(msg)", "Failed to submit task: \(msg)")
                )
            }
        }
    }

    private func loadDirectoryEntries(forceRefresh: Bool) async {
        isLoadingEntries = true
        listingError = nil
        showLoadingSpinner = false

        let spinnerTask = Task {
            try? await Task.sleep(for: .milliseconds(110))
            if !Task.isCancelled && isLoadingEntries {
                showLoadingSpinner = true
            }
        }
        defer { spinnerTask.cancel() }

        do {
            let backend = try store.backend(for: connection.id)
            let fetched = try await backend.list(currentDir, refresh: forceRefresh)
            guard !Task.isCancelled else { return }

            let namesWorker = Task.detached(priority: .userInitiated) { () -> [String: String] in
                var map: [String: String] = [:]
                map.reserveCapacity(fetched.count)
                for entry in fetched {
                    if Task.isCancelled { return [:] }
                    map[entry.path] = toSimplified(entry.name.lowercased())
                }
                return map
            }
            let namesMap = await withTaskCancellationHandler {
                await namesWorker.value
            } onCancel: {
                namesWorker.cancel()
            }
            guard !Task.isCancelled else { return }

            simplifiedLowerNames = namesMap
            rawEntries = fetched
            entriesRevision &+= 1
            recomputeDisplayedEntries()
            isLoadingEntries = false
            showLoadingSpinner = false
        } catch {
            guard !Task.isCancelled else { return }
            simplifiedLowerNames = [:]
            rawEntries = []
            entriesRevision &+= 1
            recomputeDisplayedEntries()
            listingError = error
            isLoadingEntries = false
            showLoadingSpinner = false
        }
    }

    private func computeOrganizedPathsInBackground() async {
        let snapshotEntries = rawEntries
        guard !snapshotEntries.isEmpty else {
            autoOrganizedPaths = []
            return
        }
        let connId = connection.id
        let naming = store.namingProfile
        let allPaths = snapshotEntries.map(\.path)

        let historyOrganized = await store.arePathsOrganized(connection: connId, paths: allPaths)
        guard !Task.isCancelled else { return }

        let worker = Task.detached(priority: .userInitiated) { () -> Set<String> in
            var result = historyOrganized
            for entry in snapshotEntries {
                if Task.isCancelled { return result }
                if !result.contains(entry.path) && looksOrganized(entry, naming: naming) {
                    result.insert(entry.path)
                }
            }
            return result
        }
        let combined = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled else { return }
        autoOrganizedPaths = combined
    }
}

// MARK: - Breadcrumb Item (`_Breadcrumbs` in `file_browser.dart:1531-1545`)

private struct BreadcrumbItemButton: View {
    let label: String
    let isLast: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button {
            if !isLast { action() }
        } label: {
            Text(label)
                .font(.system(size: TidyreelTypeScale.body, weight: isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? palette.text : palette.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(!isLast && isHovered ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Virtualized Entry Row (`_EntryTile` in `file_browser.dart:1583-1688`)

private struct FileBrowserEntryRow: View {
    let entry: RemoteEntry
    let isSelected: Bool
    let anySelected: Bool
    let isFavorite: Bool
    let explicitMark: Bool?
    let onRowClick: () -> Void
    let onToggleCheckbox: () -> Void
    let onOpenFolder: () -> Void
    let onQuickOrganize: () -> Void
    let onSubmitVariant: (OrganizeMode?, Bool, Bool) -> Void
    let onToggleFavorite: () -> Void
    let onMarkOrganized: (Bool) -> Void
    let onCopyPath: () -> Void

    private let iconName: String
    private let isVideoFile: Bool
    private let metaText: String

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isHovered: Bool = false

    init(
        entry: RemoteEntry,
        isSelected: Bool,
        anySelected: Bool,
        isFavorite: Bool,
        explicitMark: Bool?,
        onRowClick: @escaping () -> Void,
        onToggleCheckbox: @escaping () -> Void,
        onOpenFolder: @escaping () -> Void,
        onQuickOrganize: @escaping () -> Void,
        onSubmitVariant: @escaping (OrganizeMode?, Bool, Bool) -> Void,
        onToggleFavorite: @escaping () -> Void,
        onMarkOrganized: @escaping (Bool) -> Void,
        onCopyPath: @escaping () -> Void
    ) {
        self.entry = entry
        self.isSelected = isSelected
        self.anySelected = anySelected
        self.isFavorite = isFavorite
        self.explicitMark = explicitMark
        self.onRowClick = onRowClick
        self.onToggleCheckbox = onToggleCheckbox
        self.onOpenFolder = onOpenFolder
        self.onQuickOrganize = onQuickOrganize
        self.onSubmitVariant = onSubmitVariant
        self.onToggleFavorite = onToggleFavorite
        self.onMarkOrganized = onMarkOrganized
        self.onCopyPath = onCopyPath

        if entry.isDir {
            self.iconName = "folder.fill"
            self.isVideoFile = false
        } else {
            let ext = extOf(entry.name).lowercased()
            if videoExtensions.contains(ext) {
                self.iconName = "film"
                self.isVideoFile = true
            } else if subtitleExtensions.contains(ext) {
                self.iconName = "captions.bubble"
                self.isVideoFile = false
            } else {
                self.iconName = "doc"
                self.isVideoFile = false
            }
        }

        let sizeStr = formatBytesOrEmpty(entry.size)
        let dateStr = formatEntryDate(entry.modified)
        if !sizeStr.isEmpty && !dateStr.isEmpty {
            self.metaText = "\(sizeStr)  ·  \(dateStr)"
        } else if !sizeStr.isEmpty {
            self.metaText = sizeStr
        } else {
            self.metaText = dateStr
        }
    }

    var body: some View {
        let rowFill: Color = isSelected
            ? palette.selected
            : (isHovered ? palette.hover : .clear)
        let iconColor: Color = entry.isDir
            ? palette.textMuted
            : (isVideoFile ? palette.text : palette.textFaint)

        HStack(alignment: .center, spacing: 0) {
            InkCheckbox(isChecked: isSelected, action: onToggleCheckbox)
                .frame(width: 30)
                .opacity(isSelected || isHovered || anySelected ? 1.0 : 0.35)

            Spacer().frame(width: 4)

            HStack(alignment: .center, spacing: 0) {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20)

                Spacer().frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)

                    if !metaText.isEmpty {
                        Text(metaText)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onRowClick()
            }

            QuietTextButton(
                l10n.tr("整理", "Organize"),
                systemImage: "wand.and.stars",
                action: onQuickOrganize
            )
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)

            Group {
                if entry.isDir {
                    Button(action: onOpenFolder) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textFaint)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 24)
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 4, bottom: 7, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .fill(rowFill)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            if entry.isDir {
                Button(action: onOpenFolder) {
                    Label(l10n.tr("打开", "Open"), systemImage: "folder")
                }
            }

            Button {
                onSubmitVariant(.inPlace, false, false)
            } label: {
                Label(l10n.tr("整理（原地）", "Organize (In-place)"), systemImage: "wand.and.stars")
            }

            Button {
                onSubmitVariant(.moveToLibrary, false, false)
            } label: {
                Label(l10n.tr("整理（移动到媒体库）", "Organize (Move to Library)"), systemImage: "tray.and.arrow.down")
            }

            Button {
                onSubmitVariant(nil, true, false)
            } label: {
                Label(l10n.tr("刮削", "Scrape"), systemImage: "photo.on.rectangle")
            }

            Button {
                onSubmitVariant(nil, true, true)
            } label: {
                Label(l10n.tr("仅刮削（不改文件名）", "Scrape Only (Keep Filenames)"), systemImage: "sparkles")
            }

            Divider()

            Button(action: onToggleCheckbox) {
                Label(
                    isSelected ? l10n.tr("取消选中", "Deselect") : l10n.tr("选中", "Select"),
                    systemImage: "checkmark.square"
                )
            }

            if entry.isDir {
                Button(action: onToggleFavorite) {
                    Label(
                        isFavorite ? l10n.tr("取消收藏", "Unfavorite") : l10n.tr("收藏", "Favorite"),
                        systemImage: isFavorite ? "star.slash" : "star"
                    )
                }
            }

            if explicitMark != true {
                Button {
                    onMarkOrganized(true)
                } label: {
                    Label(l10n.tr("标记为已整理", "Mark as Organized"), systemImage: "checkmark.seal")
                }
            }

            if explicitMark != false {
                Button {
                    onMarkOrganized(false)
                } label: {
                    Label(l10n.tr("标记为未整理", "Mark as Unorganized"), systemImage: "circle")
                }
            }

            Button(action: onCopyPath) {
                Label(l10n.tr("复制路径", "Copy Path"), systemImage: "doc.on.clipboard")
            }
        }
    }
}

// MARK: - Floating Selection Action Bar (`_SelectionBar` in `file_browser.dart:1328-1462`)

private struct SelectionFloatingBar: View {
    let count: Int
    let mode: OrganizeMode
    let hint: MediaHint
    let isSubmitting: Bool
    let onShowSelected: () -> Void
    let onHintChange: (MediaHint) -> Void
    let onModeChange: (OrganizeMode) -> Void
    let onCancel: () -> Void
    let onOrganize: () -> Void
    let onScrape: () -> Void
    let onScrapeOnly: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var isCountHovered = false
    @State private var isHintHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onShowSelected) {
                HStack(spacing: 5) {
                    Text(l10n.tr("已选 \(count) 项", "\(count) selected"))
                        .font(.system(size: TidyreelTypeScale.body, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.text)

                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                        .fill(isCountHovered ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isCountHovered = $0 }

            Menu {
                ForEach(MediaHint.allCases, id: \.self) { option in
                    Button {
                        onHintChange(option)
                    } label: {
                        HStack {
                            Text(l10n.mediaHintLabel(option))
                            if option == hint { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(
                        l10n.tr(
                            "类型：\(l10n.mediaHintLabel(hint))",
                            "Type: \(l10n.mediaHintLabel(hint))"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                        .fill(isHintHovered ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHintHovered = $0 }
            .help(l10n.tr("切换后作为识别类型提示", "Hint used for media matching"))

            SlidingSegmented(
                options: [
                    (value: OrganizeMode.inPlace, label: l10n.organizeModeLabel(.inPlace)),
                    (value: OrganizeMode.moveToLibrary, label: l10n.organizeModeLabel(.moveToLibrary)),
                ],
                selection: mode,
                onSelect: onModeChange
            )

            Spacer().frame(width: 6)

            QuietTextButton(l10n.cancel, action: onCancel)

            PrimaryActionButton(
                l10n.tr("整理", "Organize"),
                isDisabled: isSubmitting,
                action: onOrganize
            )
            .help(l10n.tr("重命名并整理文件（不写 NFO 和海报）", "Rename and organize files (without NFO or artwork)"))

            SecondaryActionButton(
                l10n.tr("刮削", "Scrape"),
                isDisabled: isSubmitting,
                action: onScrape
            )
            .help(l10n.tr("整理，并写入 NFO 和海报", "Organize and write NFO metadata and artwork"))

            SecondaryActionButton(
                l10n.tr("仅刮削", "Scrape Only"),
                isDisabled: isSubmitting,
                action: onScrapeOnly
            )
            .help(
                l10n.tr(
                    "不移动、不重命名文件，仅在原位补全 NFO 与海报",
                    "Write NFO and artwork in place without moving or renaming files"
                )
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.bar, style: .continuous)
                .fill(palette.panel)
                .shadow(color: .black.opacity(palette.isDark ? 0.32 : 0.10), radius: 14, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.bar, style: .continuous)
                .strokeBorder(palette.line, lineWidth: hairlineWidth)
        )
    }
}

// MARK: - Selected Items Sheet (`_showSelected` in `file_browser.dart:713-796`)

private struct SelectedItemsSheet: View {
    @Binding var selectedPaths: Set<String>
    let onNavigateToFolder: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let sorted = selectedPaths.sorted()

        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("已选 \(sorted.count) 项", "\(sorted.count) Selected"))
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            PanelBox(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6), framed: true) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element) { idx, path in
                            if idx > 0 {
                                Rectangle()
                                    .fill(palette.line)
                                    .frame(height: hairlineWidth)
                                    .padding(.horizontal, 10)
                            }
                            InstantHoverRow(
                                cornerRadius: TidyreelRadii.sm,
                                padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 6),
                                action: {
                                    onNavigateToFolder(dirOf(path))
                                }
                            ) {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(baseOf(path))
                                            .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                            .foregroundStyle(palette.text)
                                            .lineLimit(1)
                                        Text(path)
                                            .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                            .foregroundStyle(palette.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    QuietIconButton(
                                        systemImage: "xmark",
                                        tooltip: l10n.tr("移出选择", "Remove"),
                                        iconSize: 12
                                    ) {
                                        selectedPaths.remove(path)
                                        if selectedPaths.isEmpty {
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                QuietTextButton(l10n.tr("完成", "Done")) {
                    dismiss()
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: 22))
        .frame(width: 520, height: 440)
        .background(palette.canvas)
    }
}
