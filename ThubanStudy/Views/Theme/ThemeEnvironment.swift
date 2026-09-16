import SwiftUI
import ThubanCore

// MARK: - Environment

private struct ThubanThemeKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = ThemeResolver.resolve(.default, systemIsDark: false)
}

extension EnvironmentValues {
    /// The resolved color tokens for the current appearance. Set once at the shell root by `ShellView` / `SettingsView`.
    var thubanTheme: ResolvedTheme {
        get { self[ThubanThemeKey.self] }
        set { self[ThubanThemeKey.self] = newValue }
    }
}

// MARK: - Color(hex:)

extension Color {
    /// `#rgb`, `#rrggbb` or `#rrggbbaa` (the `#` is optional). Invalid input yields black.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value), text.count == 6 || text.count == 8 else {
            self = .black
            return
        }
        let r, g, b, a: Double
        if text.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value), text.count == 6 else {
            self.init(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Token colors

extension ResolvedTheme {
    var bgColor: Color { Color(hex: bg) }
    var panelColor: Color { Color(hex: panel) }
    var panel2Color: Color { Color(hex: panel2) }
    var lineColor: Color { Color(hex: line) }
    var line2Color: Color { Color(hex: line2) }
    var inkColor: Color { Color(hex: ink) }
    var inkDimColor: Color { Color(hex: inkDim) }
    var inkFaintColor: Color { Color(hex: inkFaint) }
    var accentColor: Color { Color(hex: accent) }
    var accentTextColor: Color { Color(hex: accentText) }
    var accentDeepColor: Color { Color(hex: accentDeep) }
    var accentTintColor: Color { Color(hex: accentTint) }
    var onAccentColor: Color { Color(hex: onAccent) }
    var signalColor: Color { Color(hex: signal) }
    var signalTextColor: Color { Color(hex: signalText) }
    var posColor: Color { Color(hex: pos) }
    var posTextColor: Color { Color(hex: posText) }
    var negColor: Color { Color(hex: neg) }
    var negTextColor: Color { Color(hex: negText) }
    var posSoftColor: Color { Color(hex: posSoft) }
    var negSoftColor: Color { Color(hex: negSoft) }
    var warnSoftColor: Color { Color(hex: warnSoft) }
    var signalSoftColor: Color { Color(hex: signalSoft) }

    /// Brass-colored text/icon color: `accentText` on light ground, the accent itself on dark.
    var brassInkColor: Color { isDark ? accentColor : accentTextColor }
}

// MARK: - Radii and metrics (design brief)

enum ThubanMetrics {
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let chipRadius: CGFloat = 6
    static let modalRadius: CGFloat = 14
    static let titleBarHeight: CGFloat = 52
    static let sectionBarHeight: CGFloat = 44
    static let trafficLightInset: CGFloat = 78
    static let buttonHeight: CGFloat = 36
    static let hairline: CGFloat = 1
}

// MARK: - Fonts

enum ThubanFont {
    /// Display: class names, page titles, big numbers.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func body(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// 12 pt, 600, uppercase eyebrow labels (apply `.textCase(.uppercase)` + `.kerning(0.5)` at the call site).
    static let micro: Font = .system(size: 12, weight: .semibold)
    static let small: Font = .system(size: 13)
}

// MARK: - Modifiers

/// A panel card: `panel` fill, 1 px `line` border, 10 px radius.
struct ThubanPanelModifier: ViewModifier {
    @Environment(\.thubanTheme) private var theme
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                    .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
            )
    }
}

enum ChipKind: String, CaseIterable {
    case pos, neg, warn, signal, neutral, accent

    func colors(_ theme: ResolvedTheme) -> (fill: Color, text: Color, border: Color?) {
        switch self {
        case .pos: return (theme.posSoftColor, theme.posTextColor, nil)
        case .neg: return (theme.negSoftColor, theme.negTextColor, nil)
        case .warn: return (theme.warnSoftColor, theme.brassInkColor, nil)
        case .signal: return (theme.signalSoftColor, theme.signalTextColor, nil)
        case .neutral: return (theme.panel2Color, theme.inkDimColor, nil)
        case .accent: return (theme.accentTintColor, theme.brassInkColor, theme.accentColor)
        }
    }
}

/// Chip chrome: soft fill, 6 px radius, 12 pt semibold text in the kind's text color.
struct ThubanChipModifier: ViewModifier {
    @Environment(\.thubanTheme) private var theme
    var kind: ChipKind

    func body(content: Content) -> some View {
        let colors = kind.colors(theme)
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(colors.fill, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
                    .strokeBorder(colors.border ?? .clear, lineWidth: ThubanMetrics.hairline)
            )
    }
}

extension View {
    func thubanPanel(padding: CGFloat = 16) -> some View {
        modifier(ThubanPanelModifier(padding: padding))
    }

    func thubanChip(kind: ChipKind) -> some View {
        modifier(ThubanChipModifier(kind: kind))
    }

    /// A 1 px hairline along one edge.
    func thubanHairline(_ edge: Edge, color: Color) -> some View {
        overlay(alignment: alignment(for: edge)) {
            Rectangle()
                .fill(color)
                .frame(width: edge == .leading || edge == .trailing ? ThubanMetrics.hairline : nil,
                       height: edge == .top || edge == .bottom ? ThubanMetrics.hairline : nil)
        }
    }

    private func alignment(for edge: Edge) -> Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}
