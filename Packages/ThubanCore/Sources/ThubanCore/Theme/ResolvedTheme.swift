import Foundation

/// Every color token the UI and the web views need, already contrast-nudged for one mode. All values are
/// lower-case `#rrggbb`. Produced by `ThemeResolver`.
public struct ResolvedTheme: Sendable, Equatable {
    /// Window ground.
    public var bg: String
    /// Cards, sidebars, sheets.
    public var panel: String
    /// Hover / inset surface: panel mixed with 6% ink.
    public var panel2: String
    /// Hairline: ink at 8% over bg.
    public var line: String
    /// Stronger hairline: ink at 15% over bg.
    public var line2: String
    /// Body text, ≥ 7:1 on bg.
    public var ink: String
    /// Secondary text, ≥ 4.5:1 on bg.
    public var inkDim: String
    /// Tertiary / decorative text, ≥ 3.2:1 on bg (use at 14px and above).
    public var inkFaint: String
    /// Accent fill, ≥ 3.2:1 on bg.
    public var accent: String
    /// Accent for text and icons, ≥ 4.5:1 on bg.
    public var accentText: String
    /// Accent shaded ×0.72 (pressed states, dashed tutor graph rows).
    public var accentDeep: String
    /// Accent at 14% over panel (hover / selection).
    public var accentTint: String
    /// Text on the accent fill.
    public var onAccent: String
    /// "Highlight" fill, ≥ 3.2:1 on bg.
    public var signal: String
    /// "Highlight" for text, ≥ 4.5:1 on bg.
    public var signalText: String
    /// "Gain" fill, ≥ 3.2:1 on bg.
    public var pos: String
    /// "Gain" for text, ≥ 4.5:1 on bg.
    public var posText: String
    /// "Loss" fill, ≥ 3.2:1 on bg.
    public var neg: String
    /// "Loss" for text, ≥ 4.5:1 on bg.
    public var negText: String
    /// Status chip grounds: the raw scheme color at 18% over panel.
    public var posSoft: String
    public var negSoft: String
    public var warnSoft: String
    public var signalSoft: String
    /// Whether the theme was resolved for dark mode.
    public var isDark: Bool
    /// `"r,g,b"` for `rgba(var(--ink-rgb), a)`.
    public var inkRGB: String
    /// `"r,g,b"` for `rgba(var(--accent-rgb), a)`.
    public var accentRGB: String
    /// The id of the scheme this was resolved from (a preset id or `ColorScheme.customId`).
    public var schemeId: String

    public init(bg: String, panel: String, panel2: String, line: String, line2: String,
                ink: String, inkDim: String, inkFaint: String,
                accent: String, accentText: String, accentDeep: String, accentTint: String, onAccent: String,
                signal: String, signalText: String, pos: String, posText: String, neg: String, negText: String,
                posSoft: String, negSoft: String, warnSoft: String, signalSoft: String,
                isDark: Bool, inkRGB: String, accentRGB: String, schemeId: String) {
        self.bg = bg
        self.panel = panel
        self.panel2 = panel2
        self.line = line
        self.line2 = line2
        self.ink = ink
        self.inkDim = inkDim
        self.inkFaint = inkFaint
        self.accent = accent
        self.accentText = accentText
        self.accentDeep = accentDeep
        self.accentTint = accentTint
        self.onAccent = onAccent
        self.signal = signal
        self.signalText = signalText
        self.pos = pos
        self.posText = posText
        self.neg = neg
        self.negText = negText
        self.posSoft = posSoft
        self.negSoft = negSoft
        self.warnSoft = warnSoft
        self.signalSoft = signalSoft
        self.isDark = isDark
        self.inkRGB = inkRGB
        self.accentRGB = accentRGB
        self.schemeId = schemeId
    }

    /// Kebab-case CSS custom property names in emission order (without the `--` prefix), one per color token.
    public static let cssTokenNames: [String] = [
        "bg", "panel", "panel-2", "line", "line-2", "ink", "ink-dim", "ink-faint",
        "accent", "accent-text", "accent-deep", "accent-tint", "on-accent",
        "signal", "signal-text", "pos", "pos-text", "neg", "neg-text",
        "pos-soft", "neg-soft", "warn-soft", "signal-soft",
    ]

    /// `(name, value)` pairs in `cssTokenNames` order, followed by the `ink-rgb` and `accent-rgb` triplets.
    public var cssVariablePairs: [(name: String, value: String)] {
        [
            ("bg", bg), ("panel", panel), ("panel-2", panel2), ("line", line), ("line-2", line2),
            ("ink", ink), ("ink-dim", inkDim), ("ink-faint", inkFaint),
            ("accent", accent), ("accent-text", accentText), ("accent-deep", accentDeep),
            ("accent-tint", accentTint), ("on-accent", onAccent),
            ("signal", signal), ("signal-text", signalText), ("pos", pos), ("pos-text", posText),
            ("neg", neg), ("neg-text", negText),
            ("pos-soft", posSoft), ("neg-soft", negSoft), ("warn-soft", warnSoft), ("signal-soft", signalSoft),
            ("ink-rgb", inkRGB), ("accent-rgb", accentRGB),
        ]
    }

    /// `":root{--bg:#…;--panel:#…;…;--ink-rgb:r,g,b;--accent-rgb:r,g,b}"` for the web views' `<style id="theme">`.
    public var cssVariables: String {
        let body = cssVariablePairs.map { "--\($0.name):\($0.value)" }.joined(separator: ";")
        return ":root{\(body)}"
    }
}
