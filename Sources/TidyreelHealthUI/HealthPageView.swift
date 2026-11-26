import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

public struct HealthPageView: View {
    public let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion

    @State private var controller: HealthSessionController
    @State private var isSkippedDirsPopoverShown = false

    public init(store: AppStore) {
        self.store = store
        self._controller = State(initialValue: HealthSessionRegistry.shared.controller(for: store))
    }

    public var body: some View {
        Group {
            if store.connections.isEmpty {
                PageScaffoldView(title: l10n.tr("体检", "Health")) {
                    EmptyStateCard(
                        icon: "checkmark.shield",
                        title: l10n.tr("还没有连接", "No Connections Yet"),
                        subtitle: l10n.tr(
                            "先在「来源」添加你的 Alist、WebDAV、SMB 或本地媒体库，再开始体检",
                            "Add an Alist, WebDAV, SMB, or local library in Sources before running a health check"
                        )
                    ) {
                        SecondaryActionButton(l10n.tr("去「来源」添加连接", "Add Connection in Sources")) {
                            store.navigateToTab(.sources)
                        }
                    }
                }
            } else {
                let selectedConn = controller.selectedConnection(in: store)
                let controlsDisabled = controller.isScanning || controller.isBusyAction

                PageScaffoldView(
                    title: l10n.tr("体检", "Health"),
                    subtitle: selectedConn.map { conn in
                        l10n.tr(
                            "只读扫描 \(conn.name) · \(controller.targetPath)",
                            "Read-only scan of \(conn.name) · \(controller.targetPath)"
                        )
                    }
                ) {
                    connectionPickerMenu(selectedConn: selectedConn, isDisabled: controlsDisabled)
                    pathChipMenu(selectedConn: selectedConn, isDisabled: controlsDisabled)

                    if controller.report != nil && !controller.isScanning {
                        QuietIconButton(
                            systemImage: "arrow.clockwise",
                            tooltip: l10n.tr("忽略缓存重新扫描", "Rescan ignoring cache"),
                            iconSize: 14,
                            isDisabled: controller.isBusyAction
                        ) {
                            controller.startScan(fresh: true, store: store)
                        }
                    }

                    if controller.isScanning {
                        SecondaryActionButton(
                            l10n.tr("停止", "Stop"),
                            systemImage: "stop.fill"
                        ) {
                            controller.cancelScan()
                        }
                    } else {
                        PrimaryActionButton(
                            controller.report == nil
                                ? l10n.tr("开始体检", "Start Audit")
                                : l10n.tr("重新体检", "Scan Again"),
                            systemImage: "checkmark.shield",
                            isDisabled: selectedConn == nil || controller.isBusyAction
                        ) {
                            controller.startScan(fresh: false, store: store)
                        }
                    }
                } content: {
                    mainBody(selectedConn: selectedConn)
                }
            }
        }
        .background(palette.canvas)
        .onAppear {
            controller.syncConnectionsIfNeeded(store: store)
        }
        .onChange(of: store.connections) { _, _ in
            controller.syncConnectionsIfNeeded(store: store)
        }
        .sheet(isPresented: $controller.isFolderPickerPresented) {
            if let conn = controller.selectedConnection(in: store) {
                RemoteFolderPickerSheet(
                    store: store,
                    connection: conn,
                    initialPath: controller.targetPath
                ) { chosenPath in
                    controller.setTargetPath(chosenPath)
                }
                .environment(\.palette, palette)
                .environment(\.l10n, l10n)
                .environment(\.tidyreelReduceMotion, reduceMotion)
            }
        }
        .sheet(item: $controller.pendingDuplicateDelete) { payload in
            DuplicateDeleteConfirmSheet(
                payload: payload,
                isBusy: controller.isBusyAction
            ) {
                Task {
                    await controller.confirmDeleteDuplicates(payload, store: store)
                }
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(item: $controller.pendingCleanupDelete) { payload in
            CleanupConfirmSheet(
                payload: payload,
                isBusy: controller.isBusyAction
            ) {
                Task {
                    await controller.confirmCleanup(payload, store: store)
                }
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - Top Bar Controls (`health_page.dart:230-417`)

    private func connectionPickerMenu(selectedConn: ConnectionConfig?, isDisabled: Bool) -> some View {
        Menu {
            ForEach(store.connections) { conn in
                Button {
                    controller.selectConnection(conn.id, store: store)
                } label: {
                    Label(conn.name, systemImage: connectionSymbol(for: conn.type))
                }
            }
        } label: {
            HStack(spacing: 0) {
                if let selectedConn {
                    Image(systemName: connectionSymbol(for: selectedConn.type))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textMuted)
                        .padding(.trailing, 6)
                }
                Text(selectedConn?.name ?? l10n.tr("选择连接", "Select Connection"))
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                    .padding(.leading, 4)
            }
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
            .opacity(isDisabled ? 0.50 : 1.0)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(isDisabled)
        .help(l10n.tr("选择连接", "Select Connection"))
    }

    private func pathChipMenu(selectedConn: ConnectionConfig?, isDisabled: Bool) -> some View {
        let quickDirs = quickCandidateDirs(for: selectedConn)

        return Menu {
            ForEach(quickDirs, id: \.self) { dir in
                Button {
                    controller.setTargetPath(dir)
                } label: {
                    Label(
                        dir,
                        systemImage: dir == controller.targetPath ? "checkmark" : "folder"
                    )
                }
            }
            if !quickDirs.isEmpty {
                Divider()
            }
            Button {
                controller.isFolderPickerPresented = true
            } label: {
                Label(l10n.tr("浏览选择其他目录…", "Browse Another Folder…"), systemImage: "folder")
            }
        } label: {
            MaxWidthLayout(maxWidth: 240) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textFaint)
                    Text(controller.targetPath)
                        .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
                .opacity(isDisabled ? 0.50 : 1.0)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(isDisabled || selectedConn == nil)
        .help(l10n.tr("切换体检目录", "Change Audit Folder"))
    }

    private func quickCandidateDirs(for conn: ConnectionConfig?) -> [String] {
        guard let conn else { return ["/"] }
        var seen: Set<String> = []
        var out: [String] = []
        func appendDir(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let norm = normalizeDir(trimmed)
            if seen.insert(norm).inserted {
                out.append(norm)
            }
        }
        appendDir(conn.libraryRoot)
        appendDir(conn.startDir)
        for fav in conn.favorites {
            appendDir(fav)
        }
        return out
    }

    // MARK: - Main Body States (`health_page.dart:171-225`)

    @ViewBuilder
    private func mainBody(selectedConn: ConnectionConfig?) -> some View {
        if controller.isScanning {
            HealthScanningView(controller: controller)
        } else if let error = controller.errorMessage {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: l10n.tr("体检未能完成", "Audit Failed"),
                subtitle: l10n.coreMessage(error)
            ) {
                HStack(spacing: 8) {
                    SecondaryActionButton(l10n.tr("更换目录", "Change Folder")) {
                        controller.isFolderPickerPresented = true
                    }
                    PrimaryActionButton(l10n.retry) {
                        controller.startScan(fresh: true, store: store)
                    }
                }
            }
        } else if let report = controller.report {
            reportView(report)
        } else {
            EmptyStateCard(
                icon: "checkmark.shield",
                title: l10n.tr("媒体库体检", "Library Health Check"),
                subtitle: l10n.tr(
                    "本地只读扫描重复片源、缺失 NFO/海报以及垃圾文件与空目录，绝不擅自改动文件",
                    "Read-only scan for duplicate copies, missing NFO/posters, junk files, and empty folders — never modifies files without your confirmation"
                )
            ) {
                SecondaryActionButton(
                    l10n.tr("开始体检", "Start Audit"),
                    systemImage: "play.fill",
                    isDisabled: selectedConn == nil || controller.isBusyAction
                ) {
                    controller.startScan(fresh: false, store: store)
                }
            }
        }
    }

    // MARK: - Report View (`health_page.dart:494-590`)

    @ViewBuilder
    private func reportView(_ report: HealthReport) -> some View {
        if report.totalIssues == 0 {
            if report.skippedDirs.isEmpty {
                EmptyStateCard(
                    icon: "checkmark.seal",
                    title: l10n.tr("媒体库很整洁", "Library Looks Clean"),
                    subtitle: l10n.tr(
                        "已扫描 \(report.totalWorks) 部作品 · \(report.scannedFiles) 个文件，未发现重复片源、缺失元数据或垃圾文件",
                        "Scanned \(l10n.plural(report.totalWorks, "title")) · \(l10n.plural(report.scannedFiles, "file")). No duplicates, missing metadata, or junk files found."
                    )
                )
            } else {
                EmptyStateCard(
                    icon: "checkmark.seal",
                    title: l10n.tr("媒体库很整洁", "Library Looks Clean"),
                    subtitle: l10n.tr(
                        "已扫描 \(report.totalWorks) 部作品 · \(report.scannedFiles) 个文件，未发现重复片源、缺失元数据或垃圾文件",
                        "Scanned \(l10n.plural(report.totalWorks, "title")) · \(l10n.plural(report.scannedFiles, "file")). No duplicates, missing metadata, or junk files found."
                    )
                ) {
                    skippedFoldersLink(report.skippedDirs)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    reportTopBar(report)

                    switch controller.selectedCategory {
                    case .duplicates:
                        DuplicatesSectionView(
                            controller: controller,
                            issues: controller.sortedDuplicateIssues
                        )
                    case .missingAssets:
                        MissingAssetsSectionView(
                            store: store,
                            controller: controller,
                            items: report.missingAssets
                        )
                    case .cleanup:
                        CleanupSectionView(
                            controller: controller,
                            report: report
                        )
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 48, bottom: 32, trailing: 40))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reportTopBar(_ report: HealthReport) -> some View {
        let segmented = SlidingSegmented(
            options: [
                (
                    value: HealthCategory.duplicates,
                    label: l10n.tr("重复片源 \(report.duplicates.count)", "Duplicates \(report.duplicates.count)")
                ),
                (
                    value: HealthCategory.missingAssets,
                    label: l10n.tr("缺失元数据 \(report.missingAssets.count)", "Missing Metadata \(report.missingAssets.count)")
                ),
                (
                    value: HealthCategory.cleanup,
                    label: l10n.tr("垃圾与空目录 \(report.cleanupItems.count)", "Junk & Empty \(report.cleanupItems.count)")
                ),
            ],
            selection: controller.selectedCategory,
            onSelect: { controller.setCategory($0) }
        )

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                segmented
                Spacer(minLength: 16)
                reportSummaryLine(report)
            }
            VStack(alignment: .leading, spacing: 10) {
                segmented
                reportSummaryLine(report)
            }
        }
    }

    private func reportSummaryLine(_ report: HealthReport) -> some View {
        let reclaimable = controller.totalReclaimableBytes
        var parts: [String] = [
            l10n.tr("\(report.totalWorks) 部作品", l10n.plural(report.totalWorks, "title")),
            l10n.tr("\(report.scannedFiles) 个文件", l10n.plural(report.scannedFiles, "file")),
        ]
        if reclaimable > 0 {
            parts.append(
                l10n.tr(
                    "可释放 \(formatBytes(reclaimable))",
                    "\(formatBytes(reclaimable)) reclaimable"
                )
            )
        }
        let summaryText = parts.joined(separator: " · ")

        return HStack(spacing: 6) {
            Text(summaryText)
                .font(.system(size: TidyreelTypeScale.small))
                .monospacedDigit()
                .foregroundStyle(palette.textFaint)
                .lineLimit(1)

            if !report.skippedDirs.isEmpty {
                Text("·")
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                skippedFoldersLink(report.skippedDirs)
            }
        }
    }

    private func skippedFoldersLink(_ skipped: [String: String]) -> some View {
        UnderlinedLinkText(
            l10n.tr(
                "跳过 \(skipped.count) 个目录",
                l10n.plural(skipped.count, "skipped folder")
            )
        ) {
            isSkippedDirsPopoverShown.toggle()
        }
        .popover(isPresented: $isSkippedDirsPopoverShown, arrowEdge: .bottom) {
            skippedDirsPopover(skipped)
        }
    }

    private func skippedDirsPopover(_ skipped: [String: String]) -> some View {
        let sortedKeys = skipped.keys.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text(l10n.tr("扫描跳过的目录", "Skipped Folders"))
                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                .foregroundStyle(palette.text)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedKeys, id: \.self) { dir in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dir)
                                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                                .foregroundStyle(palette.text)
                            if let msg = skipped[dir] {
                                Text(l10n.coreMessage(msg))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.textMuted)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 380)
        .background(palette.panel)
    }
}

// MARK: - Isolated Scanning Progress Subview (Prevents Top-Bar Rebuilds on Every Scan Tick)

private struct HealthScanningView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion

    let controller: HealthSessionController

    var body: some View {
        let prog = controller.progress
        let fraction = min(max(prog?.fraction ?? 0.1, 0.02), 1.0)
        let phaseTitle = prog?.phase.localizedLabel(l10n)
            ?? l10n.tr("正在扫描媒体库", "Scanning media library")
        let detail = prog.map {
            HealthSessionController.localizedProgressDetail($0, targetPath: controller.targetPath, l10n: l10n)
        } ?? l10n.tr("正在扫描 \(controller.targetPath)…", "Scanning \(controller.targetPath)…")

        VStack {
            Spacer()
            PanelBox(
                padding: EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22),
                framed: true
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        AnimatedDashedSpinner(size: 16, color: palette.accent)
                        Text(phaseTitle)
                            .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(palette.selected)
                                .frame(height: 4)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [palette.accent.opacity(0.78), palette.accent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(6, geo.size.width * fraction), height: 4)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 12)

                    Text(detail)
                        .font(.system(size: TidyreelTypeScale.small))
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.top, 10)

                    HStack {
                        Spacer()
                        SecondaryActionButton(l10n.tr("停止", "Stop")) {
                            controller.cancelScan()
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
