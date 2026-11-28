import AppKit
import SwiftUI
import TidyreelModels

// MARK: - Warm Xuan-Paper & Ink Monochrome Palette (宣纸与墨 + 中国传统色)

public struct TidyreelPalette: Equatable, Sendable {
    public let isDark: Bool
    public let canvas: Color
    public let sidebar: Color
    public let panel: Color
    public let hover: Color
    public let pressed: Color
    public let selected: Color
    public let line: Color
    public let lineStrong: Color
    public let text: Color
    public let textMuted: Color
    public let textFaint: Color
    public let accent: Color
    public let accentSoft: Color
    public let onAccent: Color
    public let success: Color
    public let warning: Color
    public let danger: Color
    public let tones: [Color]
    public let contour: Color

    public static func color(argb hex: UInt32) -> Color {
        let a = Double((hex >> 24) & 0xFF) / 255.0
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public static func build(isDark: Bool, accent choice: AccentChoice = .rouge) -> TidyreelPalette {
        let accentHex = isDark ? choice.darkHex : choice.lightHex
        let accentColor = color(argb: accentHex)
        let r = Double((accentHex >> 16) & 0xFF) / 255.0
        let g = Double((accentHex >> 8) & 0xFF) / 255.0
        let b = Double(accentHex & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

        if !isDark {
            let softAlpha = 0.13
            let pr = 0xFC.double255, pg = 0xFB.double255, pb = 0xF9.double255
            let soft = Color(
                .sRGB,
                red: r * softAlpha + pr * (1 - softAlpha),
                green: g * softAlpha + pg * (1 - softAlpha),
                blue: b * softAlpha + pb * (1 - softAlpha),
                opacity: 1
            )
            return TidyreelPalette(
                isDark: false,
                canvas: color(argb: 0xFFF6F5F2),
                sidebar: color(argb: 0xFFEEECE8),
                panel: color(argb: 0xFFFCFBF9),
                hover: color(argb: 0x0B221F1C),
                pressed: color(argb: 0x18221F1C),
                selected: color(argb: 0x14221F1C),
                line: color(argb: 0xFFE5E2DD),
                lineStrong: color(argb: 0xFFCBC6BF),
                text: color(argb: 0xFF221F1C),
                textMuted: color(argb: 0xFF55504A),
                textFaint: color(argb: 0xFF6E6760),
                accent: accentColor,
                accentSoft: soft,
                onAccent: luminance > 0.50 ? color(argb: 0xFFF6F5F2) : .white,
                success: color(argb: 0xFF3D7556),
                warning: color(argb: 0xFF786A1E),
                danger: color(argb: 0xFFA93636),
                tones: [
                    color(argb: 0xFFE7E4DF),
                    color(argb: 0xFFD3CFC8),
                    color(argb: 0xFFA19A92),
                    color(argb: 0xFF746D66),
                    color(argb: 0xFF2E2A27),
                ],
                contour: color(argb: 0x61221F1C)
            )
        } else {
            let softAlpha = 0.22
            let pr = 0x22.double255, pg = 0x20.double255, pb = 0x1F.double255
            let soft = Color(
                .sRGB,
                red: r * softAlpha + pr * (1 - softAlpha),
                green: g * softAlpha + pg * (1 - softAlpha),
                blue: b * softAlpha + pb * (1 - softAlpha),
                opacity: 1
            )
            return TidyreelPalette(
                isDark: true,
                canvas: color(argb: 0xFF1A1918),
                sidebar: color(argb: 0xFF151413),
                panel: color(argb: 0xFF22201F),
                hover: color(argb: 0x0FFFFFFF),
                pressed: color(argb: 0x22FFFFFF),
                selected: color(argb: 0x1AFFFFFF),
                line: color(argb: 0xFF2F2C2A),
                lineStrong: color(argb: 0xFF4A4643),
                text: color(argb: 0xFFEAE7E3),
                textMuted: color(argb: 0xFFAEA8A1),
                textFaint: color(argb: 0xFF8F8881),
                accent: accentColor,
                accentSoft: soft,
                onAccent: luminance > 0.50 ? color(argb: 0xFF1A1918) : .white,
                success: color(argb: 0xFF86B898),
                warning: color(argb: 0xFFCDB56A),
                danger: color(argb: 0xFFE27C72),
                tones: [
                    color(argb: 0xFFE7E4DF),
                    color(argb: 0xFF948E88),
                    color(argb: 0xFF4E4A47),
                    color(argb: 0xFF383532),
                    color(argb: 0xFF2D2A28),
                ],
                contour: color(argb: 0x66EAE7E3)
            )
        }
    }
}

public extension AppSettings {
    func palette(systemIsDark: Bool) -> TidyreelPalette {
        let isDark: Bool
        switch themeMode {
        case .light: isDark = false
        case .dark: isDark = true
        case .system: isDark = systemIsDark
        }
        return TidyreelPalette.build(isDark: isDark, accent: accent)
    }
}

private extension Int {
    var double255: Double { Double(self) / 255.0 }
}

public enum TidyreelSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum TidyreelRadii {
    public static let sm: CGFloat = 6
    public static let lg: CGFloat = 10
    public static let xl: CGFloat = 12
    public static let bar: CGFloat = 18
    public static let pebble: CGFloat = 34
}

public enum TidyreelTypeScale {
    public static let display: CGFloat = 64
    public static let title: CGFloat = 26
    public static let headline: CGFloat = 15
    public static let body: CGFloat = 13
    public static let small: CGFloat = 12
}

public let hairlineWidth: CGFloat = 0.5

public extension EdgeInsets {
    static let zero = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
}

// MARK: - Season Badge Palette (中国传统色)

public func seasonBadgeColor(_ season: Int, isDark: Bool) -> Color {
    let lightHues: [UInt32] = [
        0xFF948E88, // 0: specials
        0xFF9D2933, // 1: 胭脂
        0xFF425066, // 2: 黛蓝
        0xFF4F7D5B, // 3: 竹青
        0xFF7E5A86, // 4: 紫棠
        0xFF7A7030, // 5: 秋香
        0xFF2E6F78, // 6: 石青
        0xFF6E4F5E, // 7: 葡萄褐
    ]
    let darkHues: [UInt32] = [
        0xFFAEA8A1,
        0xFFD87880,
        0xFF8E9DB8,
        0xFF8DBB98,
        0xFFB996C2,
        0xFFCBBF73,
        0xFF6FB1B9,
        0xFFB892A3,
    ]
    let hues = isDark ? darkHues : lightHues
    if season <= 0 {
        return TidyreelPalette.color(argb: hues[0])
    }
    let index = 1 + ((season - 1) % (hues.count - 1))
    return TidyreelPalette.color(argb: hues[index])
}

// MARK: - Environment Keys

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = TidyreelPalette.build(isDark: false)
}

private struct L10nKey: EnvironmentKey {
    static let defaultValue = AppL10n.zh
}

private struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var palette: TidyreelPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }

    var l10n: AppL10n {
        get { self[L10nKey.self] }
        set { self[L10nKey.self] = newValue }
    }

    var tidyreelReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

/// Decimal file sizes (1000-based, matching macOS Finder & `fmtSize` in `common.dart`).
public func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes)
    var i = 0
    while v >= 1000 && i < units.count - 1 {
        v /= 1000
        i += 1
    }
    return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
}

/// Returns empty string when `bytes <= 0`, matching `fmtSize` in `common.dart`.
public func formatBytesOrEmpty(_ bytes: Int64) -> String {
    bytes <= 0 ? "" : formatBytes(bytes)
}
