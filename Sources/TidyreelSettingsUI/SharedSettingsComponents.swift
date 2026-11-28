import AppKit
import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels

// MARK: - Hairline Divider (`Rows` divider in `ui/widgets.dart`)

struct SettingsDivider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.line)
            .frame(height: hairlineWidth)
    }
}

// MARK: - Setting Row (`SettingRow` in `ui/widgets.dart`)

struct SettingRow<Control: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let caption: String?
    private let control: Control

    init(
        title: String,
        caption: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Form Row (`FormRow` in `ui/widgets.dart`: right-aligned labelWidth)

struct FormRow<Content: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    let labelWidth: CGFloat
    let help: String?
    private let content: Content

    init(
        label: String,
        labelWidth: CGFloat = 110,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.labelWidth = labelWidth
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.trailing)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                content
                if let help, !help.isEmpty {
                    Text(help)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textFaint)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.vertical, 5)
    }
}

// MARK: - Monochrome Ink Switch (`MacSwitch` in `ui/widgets.dart`)

struct InkSwitch: View {
    @Environment(\.palette) private var palette
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    let isOn: Bool
    var isDisabled: Bool = false
    let onChange: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard !isDisabled else { return }
            if reduceMotion {
                onChange(!isOn)
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    onChange(!isOn)
                }
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)
                    .overlay {
                        if !isOn {
                            Capsule(style: .continuous)
                                .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                        }
                    }

                Circle()
                    .fill(isOn ? palette.canvas : palette.panel)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(palette.isDark ? 0.30 : 0.12), radius: 1, x: 0, y: 0.5)
                    .padding(.horizontal, 2)
            }
            .frame(width: 32, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "1" : "0")
    }

    private var trackColor: Color {
        if isOn {
            return isHovered ? palette.text.opacity(0.88) : palette.text
        } else {
            return isHovered ? palette.pressed : palette.selected
        }
    }
}

// MARK: - Compact Header Menu Pill (`_PlayerMenu` & `_ExportImportMenu` in `naming_page.dart`)

struct HeaderMenuPillLabel: View {
    @Environment(\.palette) private var palette
    let systemImage: String
    let title: String
    var showsChevron: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(palette.textMuted)
            Text(title)
                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                    .padding(.leading, -2)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(isHovered ? palette.hover : palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Xuan-Paper & Ink Text Field

struct InkTextField<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var monospaced: Bool = false
    var isSecure: Bool = false
    var onSubmit: (() -> Void)? = nil
    private let hasTrailing: Bool
    private let trailing: Trailing

    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        monospaced: Bool = false,
        isSecure: Bool = false,
        onSubmit: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.monospaced = monospaced
        self.isSecure = isSecure
        self.onSubmit = onSubmit
        self.hasTrailing = Trailing.self != EmptyView.self
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.textMuted)
            }
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(
                .system(
                    size: monospaced ? TidyreelTypeScale.small : TidyreelTypeScale.body,
                    design: monospaced ? .monospaced : .default
                )
            )
            .foregroundStyle(palette.text)
            .focused($isFocused)
            .onSubmit {
                onSubmit?()
            }

            if hasTrailing {
                trailing
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(
                    isFocused ? palette.text.opacity(0.75) : palette.lineStrong,
                    lineWidth: isFocused ? 1.0 : hairlineWidth
                )
        )
    }
}

extension InkTextField where Trailing == EmptyView {
    init(
        placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        monospaced: Bool = false,
        isSecure: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.init(
            placeholder: placeholder,
            text: text,
            icon: icon,
            monospaced: monospaced,
            isSecure: isSecure,
            onSubmit: onSubmit
        ) {
            EmptyView()
        }
    }
}

// MARK: - Template Text Option (`_TextOption` in `naming_page.dart`)

struct TemplateTextOption: View {
    @Environment(\.palette) private var palette
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var variables: [String] = []

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(
                    .system(
                        size: monospaced ? TidyreelTypeScale.small : TidyreelTypeScale.body,
                        design: monospaced ? .monospaced : .default
                    )
                )
                .foregroundStyle(palette.text)
                .focused($isFocused)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(
                            isFocused ? palette.text.opacity(0.75) : palette.lineStrong,
                            lineWidth: isFocused ? 1.0 : hairlineWidth
                        )
                )

            if !variables.isEmpty {
                FlowWrapLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(variables, id: \.self) { variable in
                        VariableInsertChip(variable: variable) {
                            insertVariable(variable)
                        }
                    }
                }
            }
        }
    }

    private func insertVariable(_ token: String) {
        if isFocused,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.string == text {
            let nsRange = editor.selectedRange()
            if let range = Range(nsRange, in: text) {
                var updated = text
                updated.replaceSubrange(range, with: token)
                text = updated
                let nextLocation = nsRange.location + (token as NSString).length
                DispatchQueue.main.async {
                    editor.setSelectedRange(NSRange(location: nextLocation, length: 0))
                }
                return
            }
        }
        text += token
    }
}

// MARK: - Style Chip & Variable Insert Chip (`_StyleChip` & `_VarChip` in `naming_page.dart`)

struct MonoStyleChip: View {
    @Environment(\.palette) private var palette
    let label: String
    let isSelected: Bool
    var isMonospaced: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .regular, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(isSelected ? palette.canvas : palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isSelected ? palette.text : (isHovered ? palette.hover : palette.panel))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(isSelected ? palette.text : palette.lineStrong, lineWidth: hairlineWidth)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct VariableInsertChip: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    let variable: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("+ \(variable)")
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(isHovered ? palette.text : palette.textMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isHovered ? palette.selected : palette.sidebar)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(isHovered ? palette.lineStrong : palette.line, lineWidth: hairlineWidth)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Self.tooltip(for: variable, l10n: l10n))
    }

    static func tooltip(for variable: String, l10n: AppL10n) -> String {
        switch variable {
        case "{title}":
            return l10n.tr("中文或首选标题", "Localized or preferred title")
        case "{en_title}":
            return l10n.tr("英文标题", "English title")
        case "{original_title}":
            return l10n.tr("原语言标题", "Original-language title")
        case "{year}":
            return l10n.tr("发行或首播年份", "Release or first-air year")
        case "{season}":
            return l10n.tr("季号（不补零，如 1）", "Season number (unpadded, e.g. 1)")
        case "{season:02}":
            return l10n.tr("两位季号（如 01）", "Two-digit season number (e.g. 01)")
        case "{episode}":
            return l10n.tr("集号（不补零，如 2）", "Episode number (unpadded, e.g. 2)")
        case "{episode:02}":
            return l10n.tr("两位集号（如 02）", "Two-digit episode number (e.g. 02)")
        case "{episode_end:02}":
            return l10n.tr("连集结束集号（如 [-E{episode_end:02}]）", "Multi-episode end number (e.g. [-E{episode_end:02}])")
        case "{episode_title}":
            return l10n.tr("分集标题（来自 TMDB）", "Episode title (from TMDB)")
        case "{extra_info}":
            return l10n.tr("附加信息（分辨率、HDR 等）", "Extra tags (resolution, HDR, etc.)")
        case "{group}":
            return l10n.tr("发布组名称", "Release group name")
        case "{tmdbid}":
            return l10n.tr("TMDB 数字 ID", "Numeric TMDB ID")
        case "{tmdb_tag}":
            return l10n.tr("TMDB ID 标签（如 {tmdb-1668}）", "TMDB ID tag (e.g. {tmdb-1668})")
        default:
            return variable
        }
    }
}

// MARK: - Flow Wrap Layout (`Wrap` in Flutter)

struct FlowWrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            if idx > 0 { totalHeight += lineSpacing }
            totalHeight += row.height
            widest = max(widest, row.width)
        }
        return CGSize(width: widest, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = (row.height - item.size.height) * 0.5
                item.subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct RowLine {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [RowLine] {
        var rows: [RowLine] = []
        var current = RowLine()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && nextWidth > maxWidth {
                rows.append(current)
                current = RowLine(items: [RowItem(subview: subview, size: size)], width: size.width, height: size.height)
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

// MARK: - Regex Rewrite List Editor (`_RewriteRow` in `naming_page.dart`)

struct RegexRewriteEditorList: View {
    let items: [NameRewrite]
    let onUpdate: (Int, NameRewrite) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                RegexRewriteRowView(
                    item: item,
                    onUpdate: { updated in onUpdate(index, updated) },
                    onRemove: { onRemove(index) }
                )
            }
        }
    }
}

private struct RegexRewriteRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    let item: NameRewrite
    let onUpdate: (NameRewrite) -> Void
    let onRemove: () -> Void

    @State private var patternDraft: String = ""
    @State private var replacementDraft: String = ""
    @State private var regexError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                InkTextField(
                    placeholder: l10n.tr("查找（正则）", "Find (regex)"),
                    text: Binding(
                        get: { patternDraft },
                        set: { newVal in
                            patternDraft = newVal
                            validateAndCommit(pattern: newVal, replacement: replacementDraft)
                        }
                    ),
                    monospaced: true
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.textFaint)

                InkTextField(
                    placeholder: l10n.tr("替换为，$1 是分组", "Replace with ($1 for group)"),
                    text: Binding(
                        get: { replacementDraft },
                        set: { newVal in
                            replacementDraft = newVal
                            validateAndCommit(pattern: patternDraft, replacement: newVal)
                        }
                    ),
                    monospaced: true
                )

                QuietIconButton(
                    systemImage: "xmark",
                    tooltip: l10n.tr("删除规则", "Remove rule"),
                    iconSize: 12
                ) {
                    onRemove()
                }
            }

            if let regexError {
                Text(l10n.tr("正则有误：\(regexError)", "Invalid regex: \(regexError)"))
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.danger)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            patternDraft = item.pattern
            replacementDraft = item.replacement
            regexError = Self.validateRegex(item.pattern)
        }
        .onChange(of: item) { _, next in
            if next.pattern != patternDraft {
                patternDraft = next.pattern
                regexError = Self.validateRegex(next.pattern)
            }
            if next.replacement != replacementDraft {
                replacementDraft = next.replacement
            }
        }
    }

    private func validateAndCommit(pattern: String, replacement: String) {
        if let err = Self.validateRegex(pattern) {
            regexError = err
            return
        }
        regexError = nil
        onUpdate(NameRewrite(pattern, replacement))
    }

    private static func validateRegex(_ pattern: String) -> String? {
        guard !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Clean Confirmation Sheet (`confirmDialog` / `MacSheet` in `ui/widgets.dart`)

struct ConfirmActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    let title: String
    let message: String
    let confirmLabel: String
    var isDestructive: Bool = false
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            Text(message)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.textMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                QuietTextButton(l10n.cancel) {
                    dismiss()
                }
                if isDestructive {
                    SecondaryActionButton(confirmLabel, isDestructive: true) {
                        onConfirm()
                        dismiss()
                    }
                } else {
                    PrimaryActionButton(confirmLabel) {
                        onConfirm()
                        dismiss()
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 420)
        .background(palette.panel)
    }
}

// MARK: - Fuzzy Search Matcher

enum FuzzySearch {
    /// Matches multi-token queries where every whitespace-separated token matches either as a
    /// substring or an ordered character subsequence in `haystack`.
    static func matches(query: String, in haystack: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        let target = haystack.lowercased()
        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        for token in tokens {
            let sub = String(token)
            if target.contains(sub) { continue }
            if !isSubsequence(sub, in: target) { return false }
        }
        return true
    }

    private static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        var idx = haystack.startIndex
        for ch in needle {
            guard let found = haystack[idx...].firstIndex(of: ch) else {
                return false
            }
            idx = haystack.index(after: found)
        }
        return true
    }
}
