import AppKit
import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

private struct PaletteSourceKey: Equatable {
    let connectionCount: Int
    let favoriteCount: Int
    let taskCount: Int
    let isEn: Bool
    let isDark: Bool
}

private struct PaletteDisplayRow: Identifiable {
    var id: String { item.id }
    let index: Int
    let item: PaletteActionItem
    let showGroupHeader: Bool
}

public struct CommandPaletteSheet: View {
    public let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var allItems: [PaletteActionItem] = []
    @State private var filteredItems: [PaletteActionItem] = []
    @State private var displayRows: [PaletteDisplayRow] = []
    @State private var groupHeaderCount: Int = 0
    @State private var hasBuiltItems: Bool = false

    public init(store: AppStore) {
        self.store = store
    }

    private var sourceKey: PaletteSourceKey {
        PaletteSourceKey(
            connectionCount: store.connections.count,
            favoriteCount: store.connections.reduce(0) { $0 + $1.favorites.count },
            taskCount: store.tasks.count,
            isEn: l10n.isEn,
            isDark: palette.isDark
        )
    }

    private var clampedListHeight: CGFloat {
        guard !filteredItems.isEmpty else { return 0 }
        let rowHeight: CGFloat = 52
        let firstHeaderHeight: CGFloat = groupHeaderCount > 0 ? 28 : 0
        let otherHeadersHeight: CGFloat = CGFloat(max(0, groupHeaderCount - 1)) * 32
        let bottomPadding: CGFloat = 8
        let contentHeight = firstHeaderHeight + otherHeadersHeight + CGFloat(filteredItems.count) * rowHeight + bottomPadding
        return min(400, contentHeight)
    }

    public var body: some View {
        let items = filteredItems
        let activeIndex = items.isEmpty ? 0 : min(max(0, selectedIndex), items.count - 1)

        VStack(spacing: 0) {
            // Top Spotlight Input Bar (`command_palette.dart:404-478`)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.textMuted)

                PaletteSearchField(
                    text: $query,
                    placeholder: l10n.tr(
                        "搜索页面、连接、收藏目录或任务…",
                        "Search pages, connections, favorites, or tasks…"
                    ),
                    textColor: palette.text,
                    placeholderColor: palette.textFaint,
                    onMoveUp: {
                        moveSelection(delta: -1, count: items.count)
                    },
                    onMoveDown: {
                        moveSelection(delta: 1, count: items.count)
                    },
                    onSubmit: {
                        executeItem(at: activeIndex, in: items)
                    },
                    onEscape: {
                        dismissPalette()
                    }
                )
                .frame(height: 24)

                if !query.isEmpty {
                    Button {
                        query = ""
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textFaint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.clear)
                } else {
                    Text("Esc")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(palette.sidebar)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(palette.line, lineWidth: hairlineWidth)
                        )
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 10)

            SettingsDivider()

            // Grouped Results List (`command_palette.dart:480-500`)
            if !hasBuiltItems {
                Color.clear
                    .frame(height: 360)
            } else if items.isEmpty {
                Text(l10n.tr("没有匹配的结果", "No matching results"))
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        paletteRowsStack(rows: displayRows, items: items, activeIndex: activeIndex)
                    }
                    .frame(height: clampedListHeight)
                    .onChange(of: activeIndex) { _, nextIdx in
                        guard nextIdx >= 0, nextIdx < items.count else { return }
                        proxy.scrollTo(items[nextIdx].id)
                    }
                }
            }

            // Footer Bar (`command_palette.dart:501-537`)
            HStack {
                Text(
                    l10n.tr(
                        "↑↓ 选择  ·  ↵ 打开  ·  Esc 关闭",
                        "↑↓ Select  ·  ↵ Open  ·  Esc Close"
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textFaint)

                Spacer()

                Text(
                    l10n.tr(
                        "\(items.count) 项",
                        l10n.plural(items.count, "item")
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .monospacedDigit()
                .foregroundStyle(palette.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.sidebar)
            .overlay(alignment: .top) {
                SettingsDivider()
            }
        }
        .frame(width: 560)
        .frame(maxHeight: 480)
        .background(palette.panel)
        .onAppear {
            rebuildAllItems()
        }
        .onChange(of: sourceKey) { _, _ in
            rebuildAllItems()
        }
        .onChange(of: query) { _, nextQuery in
            selectedIndex = 0
            applyFilter(all: allItems, query: nextQuery)
        }
        .onExitCommand {
            dismissPalette()
        }
    }

    private func paletteRowsStack(
        rows: [PaletteDisplayRow],
        items: [PaletteActionItem],
        activeIndex: Int
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.showGroupHeader {
                    Text(row.item.group)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 14)
                        .padding(.top, row.index == 0 ? 10 : 14)
                        .padding(.bottom, 4)
                }

                PaletteItemRow(
                    item: row.item,
                    isSelected: row.index == activeIndex,
                    onHover: {
                        if selectedIndex != row.index {
                            selectedIndex = row.index
                        }
                    },
                    onTap: {
                        executeItem(at: row.index, in: items)
                    }
                )
                .id(row.item.id)
            }
        }
        .padding(.bottom, 8)
    }

    private func rebuildAllItems() {
        let built = buildPaletteItems()
        allItems = built
        hasBuiltItems = true
        applyFilter(all: built, query: query)
    }

    private func applyFilter(all: [PaletteActionItem], query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [PaletteActionItem]
        if trimmed.isEmpty {
            matched = all
        } else {
            matched = all.filter { item in
                FuzzySearch.matches(query: trimmed, in: item.searchText)
            }
        }
        filteredItems = matched
        var rows: [PaletteDisplayRow] = []
        rows.reserveCapacity(matched.count)
        var headers = 0
        for (index, item) in matched.enumerated() {
            let showHeader = index == 0 || matched[index - 1].group != item.group
            if showHeader { headers += 1 }
            rows.append(PaletteDisplayRow(index: index, item: item, showGroupHeader: showHeader))
        }
        displayRows = rows
        groupHeaderCount = headers
    }

    // MARK: - Selection & Execution

    private func moveSelection(delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func executeItem(at index: Int, in items: [PaletteActionItem]) {
        guard index >= 0, index < items.count else { return }
        let action = items[index].action
        dismissPalette()
        action()
    }

    private func dismissPalette() {
        store.isCommandPalettePresented = false
    }

    // MARK: - Build Grouped Items (`command_palette.dart:175-337`)

    private func buildPaletteItems() -> [PaletteActionItem] {
        var items: [PaletteActionItem] = []

        let navGroup = l10n.tr("页面导航", "Navigation")
        let actionsGroup = l10n.tr("快捷操作", "Quick Actions")
        let connGroup = l10n.tr("连接", "Connections")
        let favGroup = l10n.tr("收藏目录", "Favorites")
        let taskGroup = l10n.tr("最近任务", "Recent Tasks")

        // 1. 页面导航 (`Navigation`)
        items.append(
            PaletteActionItem(
                id: "nav-sources",
                group: navGroup,
                icon: "folder",
                title: l10n.tr("来源", "Sources"),
                subtitle: "/sources",
                keywords: "来源 sources 连接 浏览 文件 connections browse files",
                action: {
                    store.openConnectionId = nil
                    store.navigateToTab(.sources)
                }
            )
        )
        items.append(
            PaletteActionItem(
                id: "nav-tasks",
                group: navGroup,
                icon: "list.bullet.rectangle",
                title: l10n.tr("任务", "Tasks"),
                subtitle: "/tasks",
                keywords: "任务 tasks 进度 历史 撤销 progress history undo",
                action: {
                    store.navigateToTab(.tasks)
                }
            )
        )
        items.append(
            PaletteActionItem(
                id: "nav-health",
                group: navGroup,
                icon: "checkmark.shield",
                title: l10n.tr("体检", "Health"),
                subtitle: "/health",
                keywords: "体检 health 媒体库 重复 清理 元数据 audit duplicates cleanup",
                action: {
                    store.navigateToTab(.health)
                }
            )
        )
        items.append(
            PaletteActionItem(
                id: "nav-naming",
                group: navGroup,
                icon: "tag",
                title: l10n.tr("命名规则", "Naming Rules"),
                subtitle: "/naming",
                keywords: "命名规则 naming 模板 播放器 片名 template player rules",
                action: {
                    store.navigateToTab(.naming)
                }
            )
        )
        items.append(
            PaletteActionItem(
                id: "nav-settings",
                group: navGroup,
                icon: "gearshape",
                title: l10n.tr("设置", "Settings"),
                subtitle: "/settings",
                keywords: "设置 settings tmdb 外观 并发 限流 语言 language appearance",
                action: {
                    store.navigateToTab(.settings)
                }
            )
        )

        // 2. 快捷操作 (`Quick Actions`)
        let isDark = palette.isDark
        items.append(
            PaletteActionItem(
                id: "action-toggle-theme",
                group: actionsGroup,
                icon: isDark ? "sun.max" : "moon",
                title: isDark
                    ? l10n.tr("切换到浅色主题", "Switch to Light Theme")
                    : l10n.tr("切换到深色主题", "Switch to Dark Theme"),
                subtitle: isDark
                    ? l10n.tr("当前：深色外观", "Current: Dark appearance")
                    : l10n.tr("当前：浅色外观", "Current: Light appearance"),
                keywords: "切换浅色深色主题 主题 外观 浅色 深色 暗黑 theme dark light",
                action: {
                    store.updateSettings { $0.themeMode = isDark ? .light : .dark }
                }
            )
        )

        let nextLangIsEn = !l10n.isEn
        items.append(
            PaletteActionItem(
                id: "action-toggle-language",
                group: actionsGroup,
                icon: "globe",
                title: l10n.tr("切换中英文界面", "Switch Chinese / English"),
                subtitle: nextLangIsEn
                    ? "当前：中文 → English"
                    : "Current: English → 中文",
                keywords: "切换中英文界面 语言 中文 英文 switch chinese english language",
                action: {
                    store.updateSettings { $0.appLanguage = nextLangIsEn ? .en : .zh }
                }
            )
        )

        if !store.connections.isEmpty {
            items.append(
                PaletteActionItem(
                    id: "action-ping-connections",
                    group: actionsGroup,
                    icon: "arrow.clockwise",
                    title: l10n.tr("刷新全部连接状态", "Refresh All Connections"),
                    subtitle: l10n.tr("检测全部来源的连通性", "Check connectivity for all saved sources"),
                    keywords: "刷新连接 重连 测试连通性 refresh ping connections",
                    action: {
                        Task { @MainActor in
                            await store.pingAllConnections()
                        }
                    }
                )
            )
        }

        items.append(
            PaletteActionItem(
                id: "action-clear-cache",
                group: actionsGroup,
                icon: "sparkles",
                title: l10n.tr("清除 TMDB 缓存", "Clear TMDB Cache"),
                subtitle: l10n.tr("清除元数据和海报缓存", "Clear cached metadata and posters"),
                keywords: "清除缓存 清理缓存 海报 tmdb clear cache",
                action: {
                    let msg = l10n.tr("已清除 TMDB 缓存", "TMDB cache cleared")
                    Task { @MainActor in
                        await store.clearCaches()
                        store.showToast(msg)
                    }
                }
            )
        )

        // 3. 连接 (`Connections` -> `store.openBrowser(connection: conn)`)
        for conn in store.connections {
            items.append(
                PaletteActionItem(
                    id: "conn-\(conn.id.value)",
                    group: connGroup,
                    icon: Self.iconForConnection(conn.type),
                    title: conn.name,
                    subtitle: "\(l10n.connectionTypeLabel(conn.type)) · \(conn.endpoint)",
                    keywords: "连接 connection \(conn.name) \(l10n.connectionTypeLabel(conn.type)) \(conn.endpoint) \(conn.startDir)",
                    action: {
                        store.openBrowser(connection: conn)
                    }
                )
            )
        }

        // 4. 收藏目录 (`Favorites` -> `store.openBrowser(connection: conn, path: fav)`)
        for conn in store.connections {
            for fav in conn.favorites {
                let favName = Self.pathBasename(fav, emptyFallback: l10n.rootDir)
                items.append(
                    PaletteActionItem(
                        id: "fav-\(conn.id.value)-\(fav)",
                        group: favGroup,
                        icon: "star",
                        title: favName,
                        subtitle: "\(conn.name) · \(fav)",
                        keywords: "收藏 favorite \(conn.name) \(fav) \(favName)",
                        action: {
                            store.openBrowser(connection: conn, path: fav)
                        }
                    )
                )
            }
        }

        // 5. 最近任务 (`Recent Tasks` -> uses `store.taskCardMeta[t.id]?.works.first?.title` when available!)
        for t in store.tasks.prefix(10) {
            let metaWorks = store.taskCardMeta[t.id]?.works ?? []
            let taskTitle: String = {
                if let firstWork = metaWorks.first {
                    if metaWorks.count > 1 {
                        return l10n.tr(
                            "\(firstWork.title) 等 \(metaWorks.count) 项",
                            "\(firstWork.title) + \(metaWorks.count - 1) more"
                        )
                    }
                    return firstWork.title
                }
                let firstPathName = t.paths.first.map { Self.pathBasename($0, emptyFallback: l10n.rootDir) } ?? t.id.value
                if t.paths.count > 1 {
                    return l10n.tr(
                        "\(firstPathName) 等 \(t.paths.count) 项",
                        "\(firstPathName) + \(t.paths.count - 1) more"
                    )
                }
                return firstPathName
            }()

            let videoText = l10n.tr("\(t.videoCount) 个视频", l10n.plural(t.videoCount, "video"))
            let workNames = metaWorks.map(\.title).joined(separator: " ")

            items.append(
                PaletteActionItem(
                    id: "task-\(t.id.value)",
                    group: taskGroup,
                    icon: t.stage == .awaitingReview ? "checkmark.circle" : "clock",
                    title: taskTitle,
                    subtitle: "\(l10n.stageLabel(t.stage)) · \(videoText) · \(t.id.value)",
                    keywords: "任务 task \(t.id.value) \(workNames) \(t.paths.joined(separator: " ")) \(l10n.stageLabel(t.stage))",
                    action: {
                        if t.stage == .awaitingReview {
                            store.openTaskReview(t.id)
                        } else {
                            store.openTaskDetail(t.id)
                        }
                    }
                )
            )
        }

        return items
    }

    // MARK: - Formatting Helpers

    private static func pathBasename(_ path: String, emptyFallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty { return emptyFallback }
        let base = baseOf(trimmed)
        return base.isEmpty ? emptyFallback : base
    }

    private static func iconForConnection(_ type: ConnectionType) -> String {
        switch type {
        case .alist: return "cloud"
        case .webdav: return "globe"
        case .smb: return "externaldrive.connected.to.line.below"
        case .local: return "folder"
        }
    }
}

// MARK: - Palette Item Model & Row (`_PaletteRow` in `command_palette.dart:546`)

private struct PaletteActionItem: Identifiable {
    let id: String
    let group: String
    let icon: String
    let title: String
    let subtitle: String?
    let keywords: String
    let searchText: String
    let action: () -> Void

    init(
        id: String,
        group: String,
        icon: String,
        title: String,
        subtitle: String?,
        keywords: String,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.group = group
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.searchText = "\(title) \(subtitle ?? "") \(keywords)"
        self.action = action
    }
}

private struct PaletteItemRow: View {
    @Environment(\.palette) private var palette
    let item: PaletteActionItem
    let isSelected: Bool
    let onHover: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? palette.text : palette.textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: TidyreelTypeScale.body, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(isSelected ? palette.selected : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .onHover { hovering in
            if hovering {
                onHover()
            }
        }
    }
}

// MARK: - Native AppKit Search Field with CJK IME-Safe Arrow/Return/Esc Handling

private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let textColor: Color
    let placeholderColor: Color
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: TidyreelTypeScale.headline)
        field.textColor = NSColor(textColor)
        field.placeholderAttributedString = Self.attributedPlaceholder(placeholder, color: NSColor(placeholderColor))
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        context.coordinator.lastTextColor = textColor
        context.coordinator.lastPlaceholder = placeholder
        context.coordinator.lastPlaceholderColor = placeholderColor
        return field
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastTextColor != textColor {
            nsView.textColor = NSColor(textColor)
            context.coordinator.lastTextColor = textColor
        }
        if context.coordinator.lastPlaceholder != placeholder
            || context.coordinator.lastPlaceholderColor != placeholderColor {
            nsView.placeholderAttributedString = Self.attributedPlaceholder(placeholder, color: NSColor(placeholderColor))
            context.coordinator.lastPlaceholder = placeholder
            context.coordinator.lastPlaceholderColor = placeholderColor
        }
    }

    private static func attributedPlaceholder(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: TidyreelTypeScale.headline),
                .foregroundColor: color,
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        var lastTextColor: Color?
        var lastPlaceholder: String?
        var lastPlaceholderColor: Color?

        init(parent: PaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() {
                return false
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onMoveDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

private final class AutoFocusTextField: NSTextField {
    private var didFocusInitially = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didFocusInitially else { return }
        didFocusInitially = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
