import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelHealthUI
import TidyreelModels
import TidyreelReviewUI
import TidyreelServices
import TidyreelSettingsUI
import TidyreelSourcesUI
import TidyreelTasksUI

struct AppShellView: View {
    @Bindable var store: AppStore
    @Environment(\.colorScheme) private var systemColorScheme

    private var preferredScheme: ColorScheme? {
        switch store.settings.themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    private var hasFloatingBottomBar: Bool {
        if store.selectedTab == .tasks, case .review = store.tasksRoute {
            return true
        }
        if store.selectedTab == .sources && store.openConnectionId != nil {
            return true
        }
        return false
    }

    var body: some View {
        let effectiveDark: Bool = {
            switch store.settings.themeMode {
            case .light: return false
            case .dark: return true
            case .system: return systemColorScheme == .dark
            }
        }()
        let p = store.settings.palette(systemIsDark: effectiveDark)
        let l10n = store.l10n

        HStack(spacing: 0) {
            SidebarView(store: store)
            Rectangle()
                .fill(p.line)
                .frame(width: hairlineWidth)
            ZStack(alignment: .bottom) {
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(p.canvas)

                if let toast = store.activeToast {
                    toastView(toast, palette: p)
                        .padding(.bottom, hasFloatingBottomBar ? 104 : 28)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(p.canvas)
        .environment(\.palette, p)
        .environment(\.l10n, l10n)
        .environment(\.tidyreelReduceMotion, store.settings.reduceMotion)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $store.isCommandPalettePresented) {
            CommandPaletteSheet(store: store)
                .environment(\.palette, p)
                .environment(\.l10n, l10n)
                .environment(\.tidyreelReduceMotion, store.settings.reduceMotion)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch store.selectedTab {
        case .sources:
            SourcesRootView(store: store)
        case .tasks:
            switch store.tasksRoute {
            case .none:
                TasksPageView(store: store)
            case .detail(let id):
                TaskDetailPageView(store: store, taskId: id)
            case .review(let id):
                ReviewPageView(store: store, taskId: id)
            }
        case .health:
            HealthPageView(store: store)
        case .naming:
            NamingPageView(store: store)
        case .settings:
            SettingsPageView(store: store)
        }
    }

    /// Ink-bar floating toast (`snackBarTheme` in `theme.dart`: `p.text` background, `p.canvas` text, `p.accentSoft` action).
    private func toastView(_ toast: ToastNotice, palette p: TidyreelPalette) -> some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(p.canvas)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let label = toast.actionLabel {
                Button {
                    let callback = toast.onAction
                    let tab = toast.destinationTab
                    let route = toast.tasksRoute
                    store.activeToast = nil
                    if let callback {
                        callback()
                    } else {
                        if let tab {
                            store.selectedTab = tab
                        }
                        if let route {
                            store.taskDetailOpenedFromSources = false
                            store.tasksRoute = route
                        }
                    }
                } label: {
                    Text(label)
                        .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                        .foregroundStyle(p.accentSoft)
                }
                .buttonStyle(.plain)
            }
            Button {
                store.activeToast = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.canvas.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                .fill(p.text)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        )
    }
}

// MARK: - Sidebar (`HEAD:app/lib/shell/sidebar.dart`)

struct SidebarView: View {
    let store: AppStore
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    private static let expandedWidth: CGFloat = 224
    private static let collapsedWidth: CGFloat = 78

    private var isCollapsed: Bool { store.isSidebarCollapsed }

    private struct SidebarFavoriteItem: Identifiable {
        let conn: ConnectionConfig
        let path: String
        var id: String { "\(conn.id.value)#\(path)" }
    }

    private var favorites: [SidebarFavoriteItem] {
        var out: [SidebarFavoriteItem] = []
        var seen: Set<String> = []
        for conn in store.connections {
            for path in conn.favorites {
                let item = SidebarFavoriteItem(conn: conn, path: path)
                if seen.insert(item.id).inserted {
                    out.append(item)
                }
            }
        }
        return out
    }

    var body: some View {
        let width: CGFloat = isCollapsed ? Self.collapsedWidth : Self.expandedWidth

        VStack(alignment: .leading, spacing: 0) {
            // Top bar aligned directly on the macOS traffic-lights row (y = 0..28) when expanded,
            // or directly beneath the traffic lights when collapsed.
            if isCollapsed {
                WindowDragRegion()
                    .frame(height: 28)
                HStack {
                    Spacer(minLength: 0)
                    sidebarToggleButton
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
            } else {
                ZStack(alignment: .trailing) {
                    WindowDragRegion()
                    sidebarToggleButton
                }
                .frame(height: 28)
            }

            if !isCollapsed {
                brandHeader
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            Spacer()
                .frame(height: isCollapsed ? 10 : 18)

            VStack(spacing: 2) {
                navRow(tab: .sources, icon: "folder", label: l10n.tr("来源", "Sources"))
                navRow(
                    tab: .tasks,
                    icon: "list.bullet.rectangle",
                    label: l10n.tr("任务", "Tasks"),
                    badge: store.pendingReviewCount,
                    running: store.hasRunningTasks
                )
                navRow(tab: .health, icon: "checkmark.shield", label: l10n.tr("体检", "Health"))
                navRow(tab: .naming, icon: "tag", label: l10n.tr("命名规则", "Naming"))
            }

            if isCollapsed {
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !favorites.isEmpty {
                            sectionTitle(l10n.tr("收藏", "Favorites"))
                            ForEach(Array(favorites.prefix(6))) { fav in
                                favoriteRow(conn: fav.conn, path: fav.path)
                            }
                            if favorites.count > 6 {
                                InstantHoverRow(
                                    isSelected: false,
                                    cornerRadius: TidyreelRadii.lg,
                                    padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
                                ) {
                                    store.navigateToTab(.sources)
                                } content: {
                                    Text(
                                        l10n.tr(
                                            "还有 \(favorites.count - 6) 个收藏…",
                                            "\(favorites.count - 6) more favorites…"
                                        )
                                    )
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.textFaint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        SidebarActiveTasksSection(store: store)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Rectangle()
                .fill(palette.line)
                .frame(height: hairlineWidth)

            navRow(tab: .settings, icon: "gearshape", label: l10n.tr("设置", "Settings"))
                .padding(.vertical, 8)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 0)
        .padding(.bottom, 0)
        .frame(width: width)
        .background(palette.sidebar)
    }

    private var sidebarToggleButton: some View {
        QuietIconButton(
            systemImage: "sidebar.left",
            tooltip: isCollapsed
                ? l10n.tr("展开侧栏", "Expand sidebar")
                : l10n.tr("收起侧栏", "Collapse sidebar"),
            iconSize: 15
        ) {
            if store.settings.reduceMotion {
                store.isSidebarCollapsed.toggle()
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    store.isSidebarCollapsed.toggle()
                }
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            AppLogoView(size: 22)
            if l10n.isEn {
                Text("Tidyreel")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("理片")
                        .font(.system(size: 15, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(palette.text)
                    Text("Tidyreel")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .allowsHitTesting(false)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
            .foregroundStyle(palette.textFaint)
            .padding(.top, 22)
            .padding(.bottom, 6)
            .padding(.leading, 12)
            .padding(.trailing, 10)
    }

    private func navRow(
        tab: AppTab,
        icon: String,
        label: String,
        badge: Int = 0,
        running: Bool = false
    ) -> some View {
        let selected = store.selectedTab == tab
        return InstantHoverRow(
            isSelected: selected,
            cornerRadius: TidyreelRadii.sm + 2,
            padding: EdgeInsets(
                top: 8,
                leading: isCollapsed ? 9 : 10,
                bottom: 8,
                trailing: isCollapsed ? 9 : 10
            )
        ) {
            store.navigateToTab(tab)
        } content: {
            if isCollapsed {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? palette.text : palette.textMuted)
                        .frame(maxWidth: .infinity)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.canvas)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.text))
                            .offset(x: -4, y: -5)
                    } else if running {
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: -6, y: -2)
                    }
                }
                .frame(height: 18)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? palette.text : palette.textMuted)
                        .frame(width: 18)
                    Text(label)
                        .font(.system(size: TidyreelTypeScale.body, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? palette.text : palette.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Quiet count in the accent: the one thing asking for you (`sidebar.dart:470`).
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(palette.accent)
                    }
                }
                .frame(height: 18)
            }
        }
        .help(isCollapsed ? label : "")
    }

    private func favoriteRow(conn: ConnectionConfig, path: String) -> some View {
        let name = path.split(separator: "/").last.map(String.init) ?? l10n.rootDir
        let tip = l10n.isEn ? "\(conn.name): \(path)" : "\(conn.name)：\(path)"
        return InstantHoverRow(
            isSelected: false,
            cornerRadius: TidyreelRadii.lg,
            padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        ) {
            store.openBrowser(connection: conn, path: path)
        } content: {
            HStack(spacing: 10) {
                Image(systemName: "star")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
                Text(name)
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .help(tip)
    }
}

/// Isolated subscriber for active background tasks so progress updates only rebuild this section.
private struct SidebarActiveTasksSection: View {
    let store: AppStore
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let active = store.tasks.filter { $0.stage.isActive }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.tr("后台任务", "Active Tasks"))
                    .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                    .foregroundStyle(palette.textFaint)
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                    .padding(.leading, 12)
                    .padding(.trailing, 10)

                ForEach(active) { task in
                    activeTaskRow(task)
                }
            }
        }
    }

    private func activeTaskRow(_ t: TaskSummary) -> some View {
        let review = t.stage == .awaitingReview
        let first = t.paths.first?.split(separator: "/").last.map(String.init)
            ?? (t.paths.isEmpty ? t.id.value : l10n.rootDir)
        let name = t.paths.count > 1
            ? l10n.tr("\(first) 等 \(t.paths.count) 项", "\(first) + \(t.paths.count - 1) more")
            : first
        let status: String = {
            switch t.stage {
            case .importing:
                return l10n.tr("已导入 \(t.importedCount) 个文件", "Imported \(l10n.plural(t.importedCount, "file"))")
            case .recognizing:
                return l10n.tr("识别中…", "Matching…")
            case .awaitingReview:
                return l10n.tr("识别完成，待确认", "Ready to review")
            default:
                return l10n.stageLabel(t.stage)
            }
        }()

        return InstantHoverRow(
            isSelected: false,
            cornerRadius: TidyreelRadii.lg,
            padding: EdgeInsets(top: 6, leading: 9, bottom: 7, trailing: 9)
        ) {
            if review {
                store.openTaskReview(t.id)
            } else {
                store.openTaskDetail(t.id)
            }
        } content: {
            HStack(alignment: .top, spacing: 9) {
                Group {
                    if review {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.accent)
                    } else if let progress = t.progress {
                        ZStack {
                            Circle()
                                .stroke(palette.selected, lineWidth: 1.4)
                            Circle()
                                .trim(from: 0, to: min(max(progress, 0), 1))
                                .stroke(palette.text, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 11, height: 11)
                        .padding(1.5)
                    } else {
                        DashedSpinner(size: 14)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(review ? palette.accent : palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
