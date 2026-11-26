import AppKit
import Foundation
import Observation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices
import TidyreelStorage

// MARK: - Sheet Coordinator

@Observable
@MainActor
final class SourcesCoordinator {
    struct EditorRequest: Identifiable, Equatable {
        let id = UUID()
        var existing: ConnectionConfig?
        var isCopy: Bool

        init(existing: ConnectionConfig? = nil, isCopy: Bool = false) {
            self.existing = existing
            self.isCopy = isCopy
        }
    }

    var editorRequest: EditorRequest?

    func presentAddConnection() {
        editorRequest = EditorRequest(existing: nil, isCopy: false)
    }

    func presentEditConnection(_ conn: ConnectionConfig, copy: Bool = false) {
        editorRequest = EditorRequest(existing: conn, isCopy: copy)
    }
}

// MARK: - Connection Type Icons

enum SourcesConnectionIcon {
    static func systemName(for type: ConnectionType) -> String {
        switch type {
        case .alist: return "cloud"
        case .webdav: return "globe"
        case .smb: return "externaldrive.connected.to.line.below"
        case .local: return "folder"
        }
    }
}

// MARK: - Wrapping Horizontal Flow Layout (`Wrap` in Flutter)

struct FlowHStack: Layout {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            if idx > 0 { totalHeight += runSpacing }
            totalHeight += row.height
            widest = max(widest, row.width)
        }
        return CGSize(width: proposal.width ?? widest, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let itemY = y + (row.height - item.size.height) * 0.5
                item.subview.place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + runSpacing
        }
    }

    private struct RowItem {
        var subview: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : (current.width + spacing + size.width)
            if !current.items.isEmpty && nextWidth > maxWidth {
                rows.append(current)
                current = Row(items: [RowItem(subview: subview, size: size)], width: size.width, height: size.height)
            } else {
                current.items.append(RowItem(subview: subview, size: size))
                current.width = nextWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

// MARK: - Quiet `…` More Menu Button (`MoreButton` in `ui/widgets.dart`)

struct MoreMenuButton<MenuItems: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    private let menuItems: MenuItems
    @State private var isHovered = false

    init(@ViewBuilder items: () -> MenuItems) {
        self.menuItems = items()
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.textMuted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isHovered ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .onHover { isHovered = $0 }
        .help(l10n.more)
    }
}

// MARK: - Ping Status & Error Formatting

struct ConnectionStatusPresentation: Equatable {
    var label: String
    var color: Color
    var isBusy: Bool
    var isFailed: Bool
    var detail: String?
}

enum ConnectionDiagnostics {
    static func presentation(
        for state: ConnectionPingState,
        config: ConnectionConfig,
        palette: TidyreelPalette,
        l10n: AppL10n
    ) -> ConnectionStatusPresentation {
        switch state {
        case .online:
            return ConnectionStatusPresentation(
                label: l10n.tr("已连接", "Connected"),
                color: palette.success,
                isBusy: false,
                isFailed: false,
                detail: nil
            )
        case .unauthorized(let raw):
            let msg = localizeCoreMessage(l10n, raw)
            let detail = l10n.tr(
                "用户名或密码错误（区分大小写）：\(msg)",
                "Incorrect username or password (case-sensitive): \(msg)"
            )
            return ConnectionStatusPresentation(
                label: l10n.tr("认证失败", "Auth Failed"),
                color: palette.danger,
                isBusy: false,
                isFailed: true,
                detail: detail
            )
        case .offline(let raw):
            return ConnectionStatusPresentation(
                label: l10n.tr("离线", "Offline"),
                color: palette.warning,
                isBusy: false,
                isFailed: true,
                detail: enrichOfflineMessage(raw, config: config, l10n: l10n)
            )
        case .checking, .unknown:
            return ConnectionStatusPresentation(
                label: l10n.tr("检测中", "Checking"),
                color: palette.textFaint,
                isBusy: true,
                isFailed: false,
                detail: nil
            )
        }
    }

    static func enrichOfflineMessage(
        _ raw: String,
        config: ConnectionConfig?,
        l10n: AppL10n
    ) -> String {
        let base = localizeCoreMessage(l10n, raw)
        if looksLikeAlistWithoutDav(config: config, errorMessage: raw) {
            let hint = l10n.tr(
                "提示：这看起来是 Alist / OpenList，它的 WebDAV 路径是 /dav；也可以把类型改成 Alist",
                "Tip: This looks like Alist / OpenList. Use /dav for WebDAV or switch the type to Alist."
            )
            return "\(base)\n\(hint)"
        }
        return base
    }

    static func looksLikeAlistWithoutDav(config: ConnectionConfig?, errorMessage: String) -> Bool {
        guard let config, config.type == .webdav else { return false }
        guard let comps = URLComponents(string: config.endpoint) else { return false }
        var cleanPath = comps.path
        while cleanPath.count > 1 && cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        if cleanPath.hasSuffix("/dav") { return false }
        let hasHttp404Or405 = errorMessage.contains("HTTP 404") || errorMessage.contains("HTTP 405")
        let isAlistPort = comps.port == 5244
        if !errorMessage.contains("HTTP ") { return false }
        return hasHttp404Or405 || isAlistPort
    }

    /// Creates a temporary `StorageBackend` for testing or browsing unsaved settings in `ConnectionEditorSheet`.
    @MainActor
    static func openTemporaryBackend(
        config: ConnectionConfig,
        password: String,
        dirPasswords: [String: String],
        store: AppStore
    ) -> (backend: any StorageBackend, shouldClose: Bool) {
        if store.isDemoMode, let firstId = store.connections.first?.id, let demoBe = try? store.backend(for: firstId) {
            return (demoBe, false)
        }
        let creds = Credentials(
            password: password.isEmpty ? nil : password,
            dirPasswords: dirPasswords
        )
        let raw = createStorageBackend(config: config, credentials: creds)
        return (CachedBackend(raw), true)
    }
}

// MARK: - Endpoint Parser & Composer

struct EndpointParts: Equatable {
    var scheme: String = "http"
    var host: String = ""
    var port: String = ""
    var path: String = ""

    static func parse(_ endpoint: String) -> EndpointParts {
        var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return EndpointParts() }
        if !s.contains("://") {
            let colonCount = s.filter { $0 == ":" }.count
            if colonCount >= 2 && !s.hasPrefix("[") {
                s = "http://[\(s)]"
            } else {
                s = "http://\(s)"
            }
        }
        guard let comps = URLComponents(string: s), let rawHost = comps.host, !rawHost.isEmpty else {
            return EndpointParts(host: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var cleanPath = comps.percentEncodedPath.removingPercentEncoding ?? comps.path
        while cleanPath.count > 1 && cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        if cleanPath == "/" { cleanPath = "" }
        return EndpointParts(
            scheme: comps.scheme?.lowercased() == "https" ? "https" : "http",
            host: rawHost,
            port: comps.port.map(String.init) ?? "",
            path: cleanPath
        )
    }

    static func formatHostAndPort(rawHost: String, rawPort: String) -> (hostPart: String, portPart: String) {
        let h = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let colons = h.filter { $0 == ":" }.count
        let hostPart: String
        if colons >= 2 {
            hostPart = h.hasPrefix("[") ? h : "[\(h)]"
        } else if colons == 1, !h.hasPrefix("["), let colonIdx = h.firstIndex(of: ":") {
            hostPart = String(h[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let inlinePort = String(h[h.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            if !inlinePort.isEmpty { p = inlinePort }
        } else {
            hostPart = h
        }
        return (hostPart, p)
    }

    func compose() -> String {
        let segs = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let (hostPart, effectivePort) = Self.formatHostAndPort(rawHost: host, rawPort: port)
        let portStr = effectivePort.isEmpty ? "" : ":\(effectivePort)"
        let pathStr = segs.isEmpty ? "" : "/\(segs.joined(separator: "/"))"
        return "\(scheme)://\(hostPart)\(portStr)\(pathStr)"
    }
}

// MARK: - Search & Date Formatting Helpers

func fuzzyMatch(query: String, target: String) -> Bool {
    let q = toSimplified(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    guard !q.isEmpty else { return true }
    let t = toSimplified(target.lowercased())
    return fuzzyMatch(simplifiedLowerQuery: q, simplifiedLowerTarget: t)
}

func fuzzyMatch(simplifiedLowerQuery q: String, simplifiedLowerTarget t: String) -> Bool {
    guard !q.isEmpty else { return true }
    if t.contains(q) { return true }
    let tokens = q.split(whereSeparator: \.isWhitespace)
    return tokens.allSatisfy { token in
        if t.contains(token) { return true }
        var idx = t.startIndex
        for ch in token {
            guard let found = t[idx...].firstIndex(of: ch) else { return false }
            idx = t.index(after: found)
        }
        return true
    }
}

private enum EntryDateFormatters {
    static let shortDateTime: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()
}

func formatEntryDate(_ date: Date?) -> String {
    guard let date else { return "" }
    return EntryDateFormatters.shortDateTime.string(from: date)
}

func copyStringToPasteboard(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
}
