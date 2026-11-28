import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - Constants

private let maxVisibleMapBlocks = 150

// MARK: - RepoMapView (`repo_map_view.dart`)

struct RepoMapView: View {
    let store: AppStore
    let connection: ConnectionConfig
    let dir: String
    let refreshTrigger: Int
    let selectedPaths: Set<String>
    let manualOrganizedMarks: [String: Bool]
    let onOpenDir: (String) -> Void
    let onSwitchToList: () -> Void
    let onToggleSelect: (String) -> Void
    let onSetSelection: (Set<String>) -> Void
    let onSubmitSingle: (String, OrganizeMode?, Bool, Bool) -> Void
    let onToggleFavorite: (String) -> Void
    let onMarkOrganized: (String, Bool) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var snapshot = SizeScanSnapshot(rootDir: "/")
    @State private var cachedMapBlocks: [MapBlockItem] = []
    @State private var cachedUnorganizedChildPaths: [String] = []
    @State private var hasHydratedCurrentDir: Bool = false
    @State private var wasManuallyStopped: Bool = false
    @State private var scanTask: Task<Void, Never>?
    @State private var activeScanner: SizeScannerActor?
    @State private var isShowingSkippedSheet: Bool = false

    private var allUnorganizedSelected: Bool {
        !cachedUnorganizedChildPaths.isEmpty && cachedUnorganizedChildPaths.allSatisfy { selectedPaths.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topSummaryBar
                .padding(EdgeInsets(top: 4, leading: 4, bottom: 18, trailing: 4))

            ZStack {
                if cachedMapBlocks.isEmpty {
                    emptyOrScanningState
                } else {
                    OrganicMapView(
                        store: store,
                        blocks: cachedMapBlocks,
                        selectedPaths: selectedPaths,
                        isScanning: snapshot.isRunning,
                        favorites: Set(connection.favorites),
                        manualOrganizedMarks: manualOrganizedMarks,
                        onToggleSelect: onToggleSelect,
                        onOpenDir: onOpenDir,
                        onSwitchToList: onSwitchToList,
                        onSubmitSingle: onSubmitSingle,
                        onToggleFavorite: onToggleFavorite,
                        onMarkOrganized: onMarkOrganized
                    )
                    .id(dir)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recomputeDerivedMapData()
            startOrAttachScan(fresh: false)
        }
        .onDisappear {
            let activeTask = scanTask
            scanTask = nil
            activeTask?.cancel()
            if let scanner = activeScanner {
                activeScanner = nil
                Task {
                    await scanner.cancel()
                    if let activeTask {
                        await activeTask.value
                    }
                    await scanner.releaseMemoryCache()
                }
            }
        }
        .onChange(of: manualOrganizedMarks) { _, _ in
            recomputeDerivedMapData()
        }
        .onChange(of: l10n) { _, _ in
            recomputeDerivedMapData()
        }
        .onChange(of: dir) { _, _ in
            wasManuallyStopped = false
            hasHydratedCurrentDir = false
            startOrAttachScan(fresh: false)
        }
        .onChange(of: connection.id) { _, _ in
            let prevTask = scanTask
            scanTask = nil
            prevTask?.cancel()
            if let prevScanner = activeScanner {
                activeScanner = nil
                Task {
                    await prevScanner.cancel()
                    if let prevTask {
                        await prevTask.value
                    }
                    await prevScanner.releaseMemoryCache()
                }
            }
            wasManuallyStopped = false
            hasHydratedCurrentDir = false
            startOrAttachScan(fresh: false)
        }
        .onChange(of: refreshTrigger) { oldVal, newVal in
            if newVal != oldVal {
                wasManuallyStopped = false
                startOrAttachScan(fresh: true)
            }
        }
        .sheet(isPresented: $isShowingSkippedSheet) {
            skippedFoldersSheet
                .environment(\.palette, palette)
                .environment(\.l10n, l10n)
        }
    }

    // MARK: - Top Summary Bar (`repo_map_view.dart:222-293, 454-608`)

    private var topSummaryBar: some View {
        let stats = snapshot.rootStats
        let sizeStr = formatBytesOrEmpty(stats.total)
        let sizeParts = sizeStr.split(separator: " ").map(String.init)
        let sizeValue = sizeParts.isEmpty ? "0" : sizeParts[0]
        let sizeUnit: String? = sizeParts.count > 1 ? sizeParts[1] : nil
        let unorgCount = cachedUnorganizedChildPaths.count
        let allUnorgSelected = allUnorganizedSelected

        return HStack(alignment: .bottom, spacing: 0) {
            BigHeroNumber(sizeValue, unit: sizeUnit) {
                summaryStatusCaption(stats: stats)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if unorgCount > 0 {
                Spacer().frame(width: 12)

                CompactSelectUnorganizedButton(
                    title: allUnorgSelected
                        ? l10n.tr("取消选中未整理", "Deselect Unorganized")
                        : l10n.tr(
                            "选中未整理 (\(unorgCount))",
                            "Select Unorganized (\(unorgCount))"
                        ),
                    systemImage: allUnorgSelected ? "checkmark.square.fill" : "checkmark.square"
                ) {
                    toggleAllUnorganized()
                }

                Spacer().frame(width: 14)
            }

            VStack(alignment: .trailing, spacing: 0) {
                MapLegendView()
                    .padding(.bottom, 6)

                Text(
                    l10n.tr(
                        "点击进入 · ⌘/⇧ 点选多选 · 右键更多",
                        "Click to open · ⌘/⇧ click to select · Right-click for more"
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textFaint)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func summaryStatusCaption(stats: FolderStats) -> some View {
        if snapshot.isRunning {
            HStack(spacing: 8) {
                DashedSpinner(size: 13)
                Text(
                    l10n.tr(
                        "正在统计，已读 \(snapshot.dirsListed) 个文件夹",
                        "Scanning, \(l10n.plural(snapshot.dirsListed, "folder")) read"
                    )
                )
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.text)

                UnderlinedLinkText(l10n.tr("停止", "Stop")) {
                    stopScan()
                }
            }
        } else if let err = snapshot.errorMessage, !err.isEmpty {
            HStack(spacing: 10) {
                Text(formatScanErrorText(err, l10n: l10n))
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.danger)
                    .lineLimit(2)
                    .help(l10n.coreMessage(err))

                UnderlinedLinkText(l10n.retry) {
                    wasManuallyStopped = false
                    startOrAttachScan(fresh: true)
                }
            }
        } else if snapshot.isComplete {
            let summaryText = [
                l10n.tr(
                    "\(stats.files) 个文件",
                    l10n.plural(stats.files, "file")
                ),
                stats.unorganized > 0
                    ? l10n.tr(
                        "未整理 \(formatBytes(stats.unorganized))",
                        "\(formatBytes(stats.unorganized)) unorganized"
                    )
                    : nil,
            ]
            .compactMap { $0 }
            .joined(separator: l10n.isEn ? ", " : "，")

            HStack(spacing: 8) {
                Text(summaryText)
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.textMuted)

                if !snapshot.skipped.isEmpty {
                    UnderlinedLinkText(
                        l10n.tr(
                            "跳过 \(snapshot.skipped.count) 个读不了的文件夹",
                            "Skipped \(l10n.plural(snapshot.skipped.count, "unreadable folder"))"
                        )
                    ) {
                        isShowingSkippedSheet = true
                    }
                }
            }
        } else if !hasHydratedCurrentDir {
            HStack(spacing: 8) {
                DashedSpinner(size: 13)
            }
        } else {
            HStack(spacing: 10) {
                Text(l10n.tr("已停止，结果不完整", "Stopped; results are incomplete"))
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.textMuted)

                UnderlinedLinkText(l10n.tr("继续统计", "Resume")) {
                    wasManuallyStopped = false
                    startOrAttachScan(fresh: false)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOrScanningState: some View {
        if !snapshot.isRunning, snapshot.errorMessage != nil {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: l10n.tr("这里统计不了", "Unable to Scan Folder")
            ) {
                SecondaryActionButton(l10n.retry) {
                    wasManuallyStopped = false
                    startOrAttachScan(fresh: true)
                }
            }
        } else if snapshot.isRunning || (!hasHydratedCurrentDir && !wasManuallyStopped) {
            DashedSpinner(size: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateCard(
                icon: "folder",
                title: l10n.tr("这里没有文件", "No Files Here")
            ) {
                SecondaryActionButton(l10n.tr("切回列表视图", "Switch to List View")) {
                    onSwitchToList()
                }
            }
        }
    }

    private var skippedFoldersSheet: some View {
        let items = snapshot.skipped.keys.sorted().map { ($0, snapshot.skipped[$0] ?? "") }
        return VStack(alignment: .leading, spacing: 12) {
            Text(
                l10n.tr(
                    "跳过 \(items.count) 个读不了的文件夹",
                    "Skipped \(l10n.plural(items.count, "unreadable folder"))"
                )
            )
            .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
            .foregroundStyle(palette.text)

            PanelBox(padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8), framed: true) {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.0) { idx, pair in
                            if idx > 0 {
                                Rectangle()
                                    .fill(palette.line)
                                    .frame(height: hairlineWidth)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.0)
                                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                                    .foregroundStyle(palette.text)
                                    .textSelection(.enabled)
                                Text(localizeCoreMessage(l10n, pair.1))
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.textMuted)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                QuietTextButton(l10n.close) {
                    isShowingSkippedSheet = false
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: 22))
        .frame(width: 520, height: 400)
        .background(palette.canvas)
    }

    // MARK: - Derived Map Data & Scanner Lifecycle

    private func applySnapshot(_ next: SizeScanSnapshot) {
        snapshot = next
        recomputeDerivedMapData()
    }

    private func recomputeDerivedMapData() {
        let adjusted: [MapChildNode]
        if manualOrganizedMarks.isEmpty {
            adjusted = snapshot.children
        } else {
            adjusted = snapshot.children.map { node in
                guard let explicit = manualOrganizedMarks[node.entry.path] else { return node }
                let total = node.stats.total
                let files = node.stats.files
                let nextStats = explicit
                    ? FolderStats(organized: total, unorganized: 0, other: 0, files: files)
                    : FolderStats(organized: 0, unorganized: total, other: 0, files: files)
                return MapChildNode(entry: node.entry, stats: nextStats)
            }
        }
        cachedMapBlocks = buildMapBlockItems(from: adjusted, l10n: l10n)
        cachedUnorganizedChildPaths = adjusted
            .filter { $0.state == .unorganized || $0.state == .mixed }
            .map(\.entry.path)
    }

    private func toggleAllUnorganized() {
        var next = selectedPaths
        if allUnorganizedSelected {
            for p in cachedUnorganizedChildPaths { next.remove(p) }
        } else {
            for p in cachedUnorganizedChildPaths { next.insert(p) }
        }
        onSetSelection(next)
    }

    private func stopScan() {
        wasManuallyStopped = true
        scanTask?.cancel()
        let scanner = activeScanner ?? (try? store.sizeScanner(for: connection.id))
        let targetDir = dir
        let naming = store.namingProfile
        Task {
            if let scanner {
                await scanner.cancel()
                let latest = await scanner.snapshot(for: targetDir, naming: naming)
                await MainActor.run {
                    var updated = latest
                    updated.isRunning = false
                    applySnapshot(updated)
                    hasHydratedCurrentDir = true
                }
            }
        }
    }

    private func startOrAttachScan(fresh: Bool) {
        scanTask?.cancel()
        let targetDir = normalizeDir(dir)
        let naming = store.namingProfile
        let connId = connection.id
        guard let scanner = try? store.sizeScanner(for: connId) else { return }
        activeScanner = scanner

        scanTask = Task {
            if !fresh {
                let cached = await scanner.snapshot(for: targetDir, naming: naming)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    applySnapshot(cached)
                    hasHydratedCurrentDir = true
                }
                if cached.isComplete || wasManuallyStopped {
                    return
                }
            }

            let throttleActor = SnapshotEmitThrottle()
            await scanner.scan(root: targetDir, fresh: fresh, naming: naming) { snap in
                guard !Task.isCancelled else { return }
                let shouldDeliver = await throttleActor.shouldDeliver(
                    isComplete: snap.isComplete,
                    isRunning: snap.isRunning
                )
                guard shouldDeliver else { return }
                await MainActor.run {
                    if !Task.isCancelled {
                        applySnapshot(snap)
                        hasHydratedCurrentDir = true
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar, Legend & Map Controls

private struct CompactSelectUnorganizedButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(isHovered ? palette.hover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .strokeBorder(palette.text.opacity(0.78), lineWidth: 1.0)
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MapLegendView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        HStack(spacing: 14) {
            swatchItem(state: .unorganized, label: l10n.tr("未整理", "Unorganized"))
            swatchItem(state: .mixed, label: l10n.tr("部分整理", "Partial"))
            swatchItem(state: .organized, label: l10n.tr("已整理", "Organized"))
            swatchItem(state: .other, label: l10n.tr("非视频", "Other"))
        }
    }

    private func swatchItem(state: MapBlockState, label: String) -> some View {
        let fill = mapBlockFill(state: state, palette: palette, id: nil)
        return HStack(spacing: 6) {
            ZStack {
                if let fill {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fill)
                        .frame(width: 12, height: 12)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(palette.text.opacity(0.60), lineWidth: 1.0)
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .strokeBorder(palette.text.opacity(0.60), lineWidth: 0.8)
                        .frame(width: 5, height: 5)
                }
            }
            Text(label)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
        }
    }
}

/// Bottom-right zoom mode switcher and zoom pill buttons (`organic_map.dart:1524-1575`).
struct OrganicMapControlsView: View {
    let zoomStyle: MapZoomStyle
    let onSelectZoomStyle: (MapZoomStyle) -> Void
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onFitAll: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        HStack(spacing: 8) {
            SlidingSegmented(
                options: [
                    (value: MapZoomStyle.camera, label: l10n.tr("缩放", "Zoom")),
                    (value: MapZoomStyle.semantic, label: l10n.tr("展开", "Expand")),
                ],
                selection: zoomStyle,
                onSelect: onSelectZoomStyle
            )
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm + 2, style: .continuous)
                    .fill(palette.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm + 2, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: hairlineWidth)
            )
            .help(
                l10n.tr(
                    "缩放：几何放大并裁剪边缘  ·  展开：重排视野内的区块填满画面",
                    "Zoom: geometric zoom with rounded frame edges · Expand: reflow visible blocks to fill the view"
                )
            )

            HStack(spacing: 0) {
                MapZoomPillButton(
                    systemImage: "minus",
                    tooltip: l10n.tr("缩小", "Zoom out"),
                    action: onZoomOut
                )

                MapZoomPillButton(
                    systemImage: "plus",
                    tooltip: l10n.tr("放大，显示更多名字", "Zoom in to see more labels"),
                    action: onZoomIn
                )

                MapZoomPillButton(
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    tooltip: l10n.tr("显示全部", "Fit all"),
                    action: onFitAll
                )
            }
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(palette.panel)
            )
            .clipShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: hairlineWidth)
            )
        }
    }
}

private struct MapZoomPillButton: View {
    let systemImage: String
    let tooltip: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(palette.textMuted)
                .frame(width: 30, height: 28)
                .background(isHovered ? palette.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

// MARK: - Selection & Context Menu Actions (`repo_map_view.dart:322-343`)

@MainActor
func presentMapEntryContextMenu(
    for entry: RemoteEntry,
    at pt: CGPoint,
    in view: NSView,
    store: AppStore,
    l10n: AppL10n,
    selectedPaths: Set<String>,
    favorites: Set<String>,
    manualOrganizedMarks: [String: Bool],
    onOpenDir: @escaping (String) -> Void,
    onSubmitSingle: @escaping (String, OrganizeMode?, Bool, Bool) -> Void,
    onToggleSelect: @escaping (String) -> Void,
    onToggleFavorite: @escaping (String) -> Void,
    onMarkOrganized: @escaping (String, Bool) -> Void
) {
    let menu = NSMenu()
    let isSel = selectedPaths.contains(entry.path)
    let isFav = entry.isDir && favorites.contains(normalizeDir(entry.path))
    let explicitMark = manualOrganizedMarks[entry.path]

    func addItem(_ title: String, action: @escaping () -> Void) {
        let wrapper = ClosureMenuItemTarget(action)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItemTarget.invoke), keyEquivalent: "")
        item.target = wrapper
        item.representedObject = wrapper
        menu.addItem(item)
    }

    if entry.isDir {
        addItem(l10n.tr("打开", "Open")) {
            onOpenDir(entry.path)
        }
    }

    addItem(l10n.tr("整理（原地）", "Organize (In-place)")) {
        onSubmitSingle(entry.path, .inPlace, false, false)
    }
    addItem(l10n.tr("整理（移动到媒体库）", "Organize (Move to Library)")) {
        onSubmitSingle(entry.path, .moveToLibrary, false, false)
    }
    addItem(l10n.tr("刮削", "Scrape")) {
        onSubmitSingle(entry.path, nil, true, false)
    }
    addItem(l10n.tr("仅刮削（不改文件名）", "Scrape Only (Keep Filenames)")) {
        onSubmitSingle(entry.path, nil, true, true)
    }

    menu.addItem(.separator())

    addItem(isSel ? l10n.tr("取消选中", "Deselect") : l10n.tr("选中", "Select")) {
        onToggleSelect(entry.path)
    }

    if entry.isDir {
        addItem(isFav ? l10n.tr("取消收藏", "Unfavorite") : l10n.tr("收藏", "Favorite")) {
            onToggleFavorite(entry.path)
        }
    }

    if explicitMark != true {
        addItem(l10n.tr("标记为已整理", "Mark as Organized")) {
            onMarkOrganized(entry.path, true)
        }
    }
    if explicitMark != false {
        addItem(l10n.tr("标记为未整理", "Mark as Unorganized")) {
            onMarkOrganized(entry.path, false)
        }
    }

    addItem(l10n.tr("复制路径", "Copy Path")) {
        copyStringToPasteboard(entry.path)
        store.showToast(l10n.tr("已复制路径", "Path copied"))
    }

    menu.popUp(positioning: nil, at: pt, in: view)
}

private final class ClosureMenuItemTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

// MARK: - Map Block Aggregation, Error Formatting & Tooltip Builders

private func formatScanErrorText(_ rawError: String, l10n: AppL10n) -> String {
    if rawError.contains("notFound") || rawError.contains("不存在") || rawError.contains("找不到") {
        return l10n.tr(
            "统计出错：找不到这个文件夹，可能已被移动或删除",
            "Scan failed: folder not found (it may have been moved or deleted)"
        )
    }
    let localized = localizeCoreMessage(l10n, rawError)
    return l10n.tr("统计出错：\(localized)", "Scan failed: \(localized)")
}

private func buildMapBlockItems(from children: [MapChildNode], l10n: AppL10n) -> [MapBlockItem] {
    let positive = children
        .filter { $0.stats.total > 0 }
        .sorted { $0.stats.total > $1.stats.total }
    guard !positive.isEmpty else { return [] }

    var out: [MapBlockItem] = []
    out.reserveCapacity(min(positive.count, maxVisibleMapBlocks + 1))

    var restStats = FolderStats.zero
    var restCount = 0

    for node in positive {
        if out.count < maxVisibleMapBlocks {
            let sz = formatBytesOrEmpty(node.stats.total)
            out.append(
                MapBlockItem(
                    id: node.entry.path,
                    entry: node.entry,
                    label: node.entry.name,
                    shortLabel: OrganicGeometry.shortMapLabel(node.entry.name),
                    bytes: node.stats.total,
                    caption: sz.isEmpty ? nil : sz,
                    state: node.state,
                    stats: node.stats,
                    tooltipLines: buildBlockTooltipLines(name: node.entry.name, stats: node.stats, l10n: l10n)
                )
            )
        } else {
            restStats = restStats + node.stats
            restCount += 1
        }
    }

    if restCount > 0 {
        let restLabel = l10n.tr("其余 \(restCount) 项", "\(restCount) more")
        let sz = formatBytesOrEmpty(restStats.total)
        out.append(
            MapBlockItem(
                id: mapRestBlockId,
                entry: nil,
                label: restLabel,
                shortLabel: restLabel,
                bytes: restStats.total,
                caption: sz.isEmpty ? nil : sz,
                state: MapBlockState.of(restStats),
                stats: restStats,
                tooltipLines: buildBlockTooltipLines(name: restLabel, stats: restStats, l10n: l10n)
            )
        )
    }

    return out
}

private func buildBlockTooltipLines(name: String, stats: FolderStats, l10n: AppL10n) -> [String] {
    let sz = formatBytesOrEmpty(stats.total)
    let line1 = sz.isEmpty ? name : "\(name) · \(sz)"
    let line2: String
    if stats.video == 0 {
        line2 = l10n.tr("非视频文件", "Non-video files")
    } else if stats.unorganized == 0 {
        line2 = l10n.tr("全部已整理", "All organized")
    } else if stats.organized == 0 {
        line2 = l10n.tr("全部未整理", "All unorganized")
    } else {
        let pct = min(99, max(1, Int((Double(stats.organized) * 100.0 / Double(stats.video)).rounded())))
        line2 = l10n.tr(
            "已整理 \(pct)% · 未整理 \(formatBytes(stats.unorganized))",
            "\(pct)% organized · \(formatBytes(stats.unorganized)) unorganized"
        )
    }
    let line3 = l10n.tr("共 \(stats.files) 个文件", l10n.plural(stats.files, "file"))
    return [line1, line2, line3]
}
