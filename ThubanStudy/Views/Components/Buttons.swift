import SwiftUI
import ThubanCore

/// Accent fill, `onAccent` text, 600 weight, radius 8, 36 pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = ThubanMetrics.buttonHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.z, weight: .semibold))
            .foregroundStyle(theme.onAccentColor)
            .padding(.horizontal, 16.z)
            .frame(height: height)
            .background(
                configuration.isPressed ? theme.accentDeepColor : theme.accentColor,
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}

/// `panel` fill, 1 px `line2` border, `ink` text.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = ThubanMetrics.buttonHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.z, weight: .semibold))
            .foregroundStyle(theme.inkColor)
            .padding(.horizontal, 14.z)
            .frame(height: height)
            .background(
                configuration.isPressed ? theme.panel2Color : theme.panelColor,
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}

/// No background; `panel2` on hover/press; `inkDim` text (brass text when `tinted`).
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 32
    var tinted: Bool = false
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, theme: theme, height: height, tinted: tinted,
                  horizontalPadding: horizontalPadding, isEnabled: isEnabled)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        let theme: ResolvedTheme
        let height: CGFloat
        let tinted: Bool
        let horizontalPadding: CGFloat
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14.z, weight: .semibold))
                .foregroundStyle(tinted ? theme.brassInkColor : theme.inkDimColor)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(
                    (hovering || configuration.isPressed) ? theme.panel2Color : .clear,
                    in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// A 34×34 (default) ghost button showing one icon; always carries an accessibility label.
struct IconButton: View {
    @Environment(\.thubanTheme) private var theme
    var icon: IconName?
    var glyph: Glyph.Kind?
    var label: String
    var size: CGFloat = 34
    var iconSize: CGFloat = 18
    var tinted: Bool = false
    var action: () -> Void
    @State private var hovering = false

    init(_ icon: IconName, label: String, size: CGFloat = 34, iconSize: CGFloat = 18, tinted: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.glyph = nil
        self.label = label
        self.size = size
        self.iconSize = iconSize
        self.tinted = tinted
        self.action = action
    }

    init(glyph: Glyph.Kind, label: String, size: CGFloat = 34, iconSize: CGFloat = 18, tinted: Bool = false, action: @escaping () -> Void) {
        self.icon = nil
        self.glyph = glyph
        self.label = label
        self.size = size
        self.iconSize = iconSize
        self.tinted = tinted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon { Icon(icon, size: iconSize) } else if let glyph { Glyph(glyph, size: iconSize) }
            }
            .foregroundStyle(tinted ? theme.brassInkColor : theme.inkDimColor)
            .frame(width: size, height: size)
            .background(hovering ? theme.panel2Color : .clear, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var thubanPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var thubanSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var thubanGhost: GhostButtonStyle { GhostButtonStyle() }
    static var thubanGhostTinted: GhostButtonStyle { GhostButtonStyle(tinted: true) }
}
