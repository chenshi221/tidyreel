import AppKit
import SwiftUI
import TidyreelModels

// MARK: - Panel Container (`Panel` in `ui/widgets.dart`)
// Quiet sheet on warm Xuan paper: no drop shadow, borderless by default (`framed = true` adds a 0.5pt hairline).

public struct PanelBox<Content: View>: View {
    @Environment(\.palette) private var palette
    private let padding: EdgeInsets
    private let radius: CGFloat
    private let framed: Bool
    private let fill: Color?
    private let content: Content

    public init(
        padding: EdgeInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16),
        radius: CGFloat = TidyreelRadii.lg,
        framed: Bool = false,
        fill: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.radius = radius
        self.framed = framed
        self.fill = fill
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill ?? palette.panel)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if framed {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.line, lineWidth: hairlineWidth)
                }
            }
    }
}

// MARK: - Window Drag Helper (Header drags window on macOS without blocking button clicks)

private final class DraggableWindowNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let clicks pass through to sibling/overlay controls; only unclaimed drags move the window.
        super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

public struct WindowDragRegion: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { DraggableWindowNSView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Page Scaffold (`PageScaffold` in `widgets/common.dart`)

public struct PageScaffoldView<Leading: View, Actions: View, Content: View>: View {
    @Environment(\.palette) private var palette
    public let title: String
    public let subtitle: String?
    public let maxWidth: CGFloat?
    private let hasLeading: Bool
    private let leading: Leading
    private let actions: Actions
    private let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        maxWidth: CGFloat? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.maxWidth = maxWidth
        self.hasLeading = Leading.self != EmptyView.self
        self.leading = leading()
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        let headerRow = HStack(alignment: .center, spacing: 6) {
            if hasLeading {
                leading
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: TidyreelTypeScale.title, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
            }
            .allowsHitTesting(false)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                actions
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 14)
        .padding(.leading, hasLeading ? 34 : 48)
        .padding(.trailing, 40)

        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                WindowDragRegion()
                if let maxWidth {
                    headerRow
                        .frame(maxWidth: maxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    headerRow
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let maxWidth {
                content
                    .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

public extension PageScaffoldView where Leading == EmptyView, Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        maxWidth: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            maxWidth: maxWidth,
            leading: { EmptyView() },
            actions: { EmptyView() },
            content: content
        )
    }
}

public extension PageScaffoldView where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        maxWidth: CGFloat? = nil,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            maxWidth: maxWidth,
            leading: { EmptyView() },
            actions: actions,
            content: content
        )
    }
}

// MARK: - Section Label (`SectionLabel` in `ui/widgets.dart`)

public struct SectionHeaderLabel<Trailing: View>: View {
    @Environment(\.palette) private var palette
    public let text: String
    private let trailing: Trailing

    public init(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text)
                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                .foregroundStyle(palette.textMuted)
            Spacer()
            trailing
        }
        .padding(.top, 22)
        .padding(.bottom, 7)
        .padding(.horizontal, 4)
    }
}

public extension SectionHeaderLabel where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

// MARK: - Instant 0ms Native Hover Row

public struct InstantHoverRow<Content: View>: View {
    @Environment(\.palette) private var palette
    public let isSelected: Bool
    public let cornerRadius: CGFloat
    public let padding: EdgeInsets
    public let action: (() -> Void)?
    private let content: Content

    @State private var isHovered = false

    public init(
        isSelected: Bool = false,
        cornerRadius: CGFloat = TidyreelRadii.lg,
        padding: EdgeInsets = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10),
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.action = action
        self.content = content()
    }

    public var body: some View {
        let fill: Color = isSelected
            ? palette.selected
            : (isHovered ? palette.hover : .clear)

        Group {
            if let action {
                Button(action: action) {
                    rowContent(fill: fill)
                }
                .buttonStyle(.plain)
            } else {
                rowContent(fill: fill)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func rowContent(fill: Color) -> some View {
        content
            .padding(padding)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
    }
}

// MARK: - Compact Status / Tech Tag Badge (`Tag` in `ui/widgets.dart`)

public struct TagBadge: View {
    @Environment(\.palette) private var palette
    public let text: String
    public let tint: Color?

    public init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        let fg = tint ?? palette.textMuted
        let bg = fg.opacity(palette.isDark ? 0.16 : 0.10)
        Text(text)
            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
    }
}

/// Framed connection/owner tag (`_TypeTag` in `sources_page.dart`): hairline border, no fill.
public struct FramedTypeTag: View {
    @Environment(\.palette) private var palette
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )
    }
}

/// Ink-line icon tile (`IconTile` in `ui/widgets.dart`).
public struct OutlinedIconTile: View {
    @Environment(\.palette) private var palette
    public let systemImage: String
    public let size: CGFloat
    public let outlined: Bool
    public let iconColor: Color?

    public init(
        _ systemImage: String,
        size: CGFloat = 30,
        outlined: Bool = true,
        iconColor: Color? = nil
    ) {
        self.systemImage = systemImage
        self.size = size
        self.outlined = outlined
        self.iconColor = iconColor
    }

    public var body: some View {
        let radius = size * 0.28
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(outlined ? palette.panel : palette.selected)
            if outlined {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            }
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(iconColor ?? palette.textMuted)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Quiet Dot Status Pill (`StatusPill` in `ui/widgets.dart`: dot + label, NO background slab)

public struct StatusDotLabel: View {
    public let label: String
    public let color: Color
    public let busy: Bool
    public let systemImage: String?

    public init(label: String, color: Color, busy: Bool = false, systemImage: String? = nil) {
        self.label = label
        self.color = color
        self.busy = busy
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 5) {
            if busy {
                DashedSpinner(size: 11, color: color)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: TidyreelTypeScale.small))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
    }
}

// MARK: - Signature 8-Dash Ring (`Spinner` in `ui/widgets.dart`)

public struct DashedSpinner: View {
    @Environment(\.palette) private var palette
    public let size: CGFloat
    public let color: Color?

    public init(size: CGFloat = 14, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        let strokeColor = color ?? palette.textMuted
        Canvas { ctx, canvasSize in
            let dashes = 8
            let sweep = Double.pi * 2.0 / Double(dashes)
            let stroke = min(canvasSize.width, canvasSize.height) / 9.0
            let radius = (min(canvasSize.width, canvasSize.height) - stroke * 2.0) * 0.5
            guard radius > 0 else { return }
            let center = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
            for i in 0..<dashes {
                let start = Angle.radians(Double(i) * sweep)
                let end = Angle.radians(Double(i) * sweep + sweep * 0.45)
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                ctx.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Hero Metric (`BigNumber` in `ui/widgets.dart`)

public struct BigHeroNumber<CaptionContent: View>: View {
    @Environment(\.palette) private var palette
    public let value: String
    public let unit: String?
    public let fontSize: CGFloat
    private let hasCaption: Bool
    private let caption: CaptionContent

    public init(
        _ value: String,
        unit: String? = nil,
        fontSize: CGFloat = TidyreelTypeScale.display,
        @ViewBuilder caption: () -> CaptionContent
    ) {
        self.value = value
        self.unit = unit
        self.fontSize = fontSize
        self.hasCaption = CaptionContent.self != EmptyView.self
        self.caption = caption()
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(value)
                .font(.system(size: fontSize, weight: .ultraLight))
                .tracking(-2)
                .monospacedDigit()
                .foregroundStyle(palette.text)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.system(size: fontSize * 0.34, weight: .light))
                    .foregroundStyle(palette.textMuted)
                    .padding(.leading, 4)
            }
            if hasCaption {
                caption
                    .font(.system(size: TidyreelTypeScale.body))
                    .foregroundStyle(palette.text)
                    .padding(.leading, 18)
            }
        }
    }
}

public extension BigHeroNumber where CaptionContent == EmptyView {
    init(_ value: String, unit: String? = nil, fontSize: CGFloat = TidyreelTypeScale.display) {
        self.init(value, unit: unit, fontSize: fontSize) { EmptyView() }
    }
}

// MARK: - Sliding Segmented Control (`Segmented<T>` in `ui/widgets.dart`)
// Calm warm-grey track (`p.selected`) + paper thumb (`p.panel`), ink text — never loud accent slabs!

public struct SlidingSegmented<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    public let options: [(value: Value, label: String)]
    public let selection: Value
    public let onSelect: (Value) -> Void

    @Namespace private var thumbNamespace

    public init(
        options: [(value: Value, label: String)],
        selection: Value,
        onSelect: @escaping (Value) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.value) { _, item in
                let isSelected = item.value == selection
                Button {
                    if item.value != selection {
                        if reduceMotion {
                            onSelect(item.value)
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                onSelect(item.value)
                            }
                        }
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: TidyreelTypeScale.small, weight: isSelected ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                    .fill(palette.panel)
                                    .shadow(color: .black.opacity(palette.isDark ? 0.22 : 0.06), radius: 1.5, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "seg-thumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm + 2, style: .continuous)
                .fill(palette.selected)
        )
    }
}

// MARK: - App Logo (`AppLogo` in `ui/widgets.dart`: pebble icon cropped 1.24x to trim macOS icon margin)

public struct AppLogoView: View {
    public let size: CGFloat

    public init(size: CGFloat = 40) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.24, height: size * 1.24)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: - Primary, Outlined & Quiet Text/Icon Buttons (`theme.dart` lines 162-206)

/// `FilledButton`: reserved ONLY for the one primary action on a screen.
public struct PrimaryActionButton: View {
    @Environment(\.palette) private var palette
    public let title: String
    public let systemImage: String?
    public let isDisabled: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
            }
            .foregroundStyle(isDisabled ? palette.textFaint : palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(
                        isDisabled
                            ? palette.selected
                            : palette.accent.opacity(isHovered ? 0.90 : 1.0)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

/// `OutlinedButton`: transparent fill with crisp 1pt ink outline (`p.text.opacity(0.78)`),
/// or red text when `isDestructive` ("a red word, not a red slab").
public struct SecondaryActionButton: View {
    @Environment(\.palette) private var palette
    public let title: String
    public let systemImage: String?
    public let isDestructive: Bool
    public let isDisabled: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        let fg: Color = isDisabled
            ? palette.textFaint
            : (isDestructive ? palette.danger : palette.text)
        let strokeColor: Color = isDisabled
            ? palette.line
            : (isDestructive ? palette.danger.opacity(0.65) : palette.text.opacity(0.78))

        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: TidyreelTypeScale.body, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(isHovered && !isDisabled ? palette.hover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: isDisabled ? hairlineWidth : 1.0)
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

/// `TextButton`: borderless ink button that tints subtly on hover.
public struct QuietTextButton: View {
    @Environment(\.palette) private var palette
    public let title: String
    public let systemImage: String?
    public let isDestructive: Bool
    public let isDisabled: Bool
    public let fontSize: CGFloat
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        fontSize: CGFloat = TidyreelTypeScale.body,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.fontSize = fontSize
        self.action = action
    }

    public var body: some View {
        let fg: Color = isDisabled
            ? palette.textFaint
            : (isDestructive ? palette.danger : palette.text)

        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 1, weight: .medium))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                    .fill(isHovered && !isDisabled ? palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

/// `IconButton`: 28x28 hover-tinted icon button.
public struct QuietIconButton: View {
    @Environment(\.palette) private var palette
    public let systemImage: String
    public let tooltip: String?
    public let iconSize: CGFloat
    public let tint: Color?
    public let isDisabled: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        systemImage: String,
        tooltip: String? = nil,
        iconSize: CGFloat = 15,
        tint: Color? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.tooltip = tooltip
        self.iconSize = iconSize
        self.tint = tint
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        let btn = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(
                    isDisabled
                        ? palette.textFaint.opacity(0.45)
                        : (tint ?? palette.textMuted)
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(isHovered && !isDisabled ? palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }

        if let tooltip, !tooltip.isEmpty {
            btn.help(tooltip)
        } else {
            btn
        }
    }
}

/// Underlined inline link (`LinkText` in `ui/widgets.dart`).
public struct UnderlinedLinkText: View {
    @Environment(\.palette) private var palette
    public let text: String
    public let action: () -> Void

    @State private var isHovered = false

    public init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(isHovered ? palette.text : palette.textMuted)
                .underline(true, color: isHovered ? palette.text : palette.textFaint)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Square ink checkbox matching `checkboxTheme` in `theme.dart` (ink fill + canvas check when selected).
public struct InkCheckbox: View {
    @Environment(\.palette) private var palette
    public let isChecked: Bool
    public let action: () -> Void

    public init(isChecked: Bool, action: @escaping () -> Void) {
        self.isChecked = isChecked
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChecked ? palette.text : .clear)
                if !isChecked {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(palette.text.opacity(0.70), lineWidth: 1.2)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(palette.canvas)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resizable Pane Divider (`SplitDivider` in `review_panes.dart`)

public struct ResizableVerticalDivider: View {
    @Environment(\.palette) private var palette
    public let onDragDelta: (CGFloat) -> Void
    @State private var isHovering = false
    @State private var isDragging = false

    public init(onDragDelta: @escaping (CGFloat) -> Void) {
        self.onDragDelta = onDragDelta
    }

    public var body: some View {
        let active = isHovering || isDragging
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
            Rectangle()
                .fill(isDragging ? palette.accent : (isHovering ? palette.lineStrong : palette.line))
                .frame(width: active ? 2 : hairlineWidth)
        }
        .frame(width: 6)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    onDragDelta(value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

// MARK: - Empty State Placeholder (`EmptyState` in `ui/widgets.dart` with Concentric Contour Rings)

public struct EmptyStateCard<ActionContent: View>: View {
    @Environment(\.palette) private var palette
    public let icon: String
    public let title: String
    public let subtitle: String?
    private let hasAction: Bool
    private let actionContent: ActionContent

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder action: () -> ActionContent
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.hasAction = ActionContent.self != EmptyView.self
        self.actionContent = action()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Canvas { ctx, size in
                    let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                    var r = min(size.width, size.height) * 0.5
                    while r > 22 {
                        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(
                            Path(ellipseIn: rect),
                            with: .color(palette.contour),
                            lineWidth: 0.6
                        )
                        r -= 7
                    }
                }
                .frame(width: 88, height: 88)

                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.bottom, 16)

            Text(title)
                .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                .foregroundStyle(palette.text)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 360)
                    .padding(.top, 4)
            }

            if hasAction {
                actionContent
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

public extension EmptyStateCard where ActionContent == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Organic Geometry SwiftUI Path Helpers

public extension OrganicGeometry {
    static func closedPath(vertices pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first, pts.count >= 3 else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }

    static func pebblePath(_ poly: [CGPoint]) -> Path {
        closedPath(vertices: smoothPolygon(poly))
    }
}
