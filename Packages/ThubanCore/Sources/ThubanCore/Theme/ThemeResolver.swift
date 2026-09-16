import Foundation

/// Turns a `ThemeSelection` (or a raw `ColorScheme`) into the full `ResolvedTheme` token set for one mode,
/// applying the contrast rules from the architecture contract. Never throws: invalid custom colors fall back to
/// the brass value for that slot.
public enum ThemeResolver {
    /// Body ink must reach this ratio on bg.
    public static let inkTarget = 7.0
    /// Secondary ink must reach this ratio on bg.
    public static let inkDimTarget = 4.5
    /// Tertiary ink must reach this ratio on bg.
    public static let inkFaintTarget = 3.2
    /// Accent / signal / pos / neg fills must reach this ratio on bg.
    public static let fillTarget = 3.2
    /// `*Text` variants must reach this ratio on bg.
    public static let textTarget = 4.5

    static let panel2Mix = 0.06
    static let lineMix = 0.08
    static let line2Mix = 0.15
    static let tintMix = 0.14
    static let softMix = 0.18
    static let deepShade = 0.72

    /// Resolves the selection for the current system appearance.
    public static func resolve(_ selection: ThemeSelection, systemIsDark: Bool) -> ResolvedTheme {
        resolve(scheme: selection.effectiveScheme, isDark: selection.isDark(systemIsDark: systemIsDark))
    }

    /// Resolves one scheme for one mode. Slots that are not valid hex fall back to brass.
    public static func resolve(scheme: ColorScheme, isDark: Bool) -> ResolvedTheme {
        let slots = Slots(scheme: scheme, isDark: isDark)
        let ramp = InkRamp.ramp(isDark: isDark)
        let inks = resolveInk(ramp, on: slots.bg)
        let accent = resolveChroma(slots.accent, on: slots.bg)
        let signal = resolveChroma(slots.signal, on: slots.bg)
        let pos = resolveChroma(slots.pos, on: slots.bg)
        let neg = resolveChroma(slots.neg, on: slots.bg)
        let lineInk = ramp.lineInk

        return ResolvedTheme(
            bg: slots.bg.hex,
            panel: slots.panel.hex,
            panel2: ColorMath.mix(slots.panel, inks.ink, panel2Mix).hex,
            line: ColorMath.mix(slots.bg, lineInk, lineMix).hex,
            line2: ColorMath.mix(slots.bg, lineInk, line2Mix).hex,
            ink: inks.ink.hex,
            inkDim: inks.inkDim.hex,
            inkFaint: inks.inkFaint.hex,
            accent: accent.fill.hex,
            accentText: accent.text.hex,
            accentDeep: ColorMath.shade(slots.accent, deepShade).hex,
            accentTint: ColorMath.mix(slots.panel, slots.accent, tintMix).hex,
            onAccent: ColorMath.onAccent(accent.fill).hex,
            signal: signal.fill.hex,
            signalText: signal.text.hex,
            pos: pos.fill.hex,
            posText: pos.text.hex,
            neg: neg.fill.hex,
            negText: neg.text.hex,
            posSoft: ColorMath.mix(slots.panel, slots.pos, softMix).hex,
            negSoft: ColorMath.mix(slots.panel, slots.neg, softMix).hex,
            warnSoft: ColorMath.mix(slots.panel, slots.accent, softMix).hex,
            signalSoft: ColorMath.mix(slots.panel, slots.signal, softMix).hex,
            isDark: isDark,
            inkRGB: ramp.inkRGB,
            accentRGB: accent.fill.cssTriplet,
            schemeId: scheme.id
        )
    }

    // MARK: Pieces

    /// The scheme's slots for one mode, parsed with per-slot brass fallback.
    private struct Slots {
        let bg: ColorMath.RGB
        let panel: ColorMath.RGB
        let accent: ColorMath.RGB
        let signal: ColorMath.RGB
        let pos: ColorMath.RGB
        let neg: ColorMath.RGB

        init(scheme: ColorScheme, isDark: Bool) {
            let safe = scheme.sanitized(fallback: SchemePresets.default)
            bg = Slots.rgb(safe.background(isDark: isDark), fallback: isDark ? .black : .white)
            panel = Slots.rgb(safe.panel(isDark: isDark), fallback: bg)
            accent = Slots.rgb(safe.accent, fallback: .white)
            signal = Slots.rgb(safe.signal, fallback: accent)
            pos = Slots.rgb(safe.pos, fallback: accent)
            neg = Slots.rgb(safe.neg, fallback: accent)
        }

        /// `sanitized` guarantees validity; the fallback only guards against a corrupted preset table.
        private static func rgb(_ hex: String, fallback: ColorMath.RGB) -> ColorMath.RGB {
            (try? ColorMath.parseHex(hex)) ?? fallback
        }
    }

    private struct Inks {
        let ink: ColorMath.RGB
        let inkDim: ColorMath.RGB
        let inkFaint: ColorMath.RGB
    }

    private struct Chroma {
        let fill: ColorMath.RGB
        let text: ColorMath.RGB
    }

    private static func resolveInk(_ ramp: InkRamp, on bg: ColorMath.RGB) -> Inks {
        let opposite: ColorMath.RGB = bg.luminance > 0.5 ? .black : .white
        let ink = (try? ColorMath.parseHex(ramp.ink)) ?? opposite
        let dim = (try? ColorMath.parseHex(ramp.inkDim)) ?? opposite
        let faint = (try? ColorMath.parseHex(ramp.inkFaint)) ?? opposite
        return Inks(
            ink: ColorMath.legible(ink, on: bg, target: inkTarget),
            inkDim: ColorMath.legible(dim, on: bg, target: inkDimTarget),
            inkFaint: ColorMath.legible(faint, on: bg, target: inkFaintTarget)
        )
    }

    private static func resolveChroma(_ color: ColorMath.RGB, on bg: ColorMath.RGB) -> Chroma {
        Chroma(
            fill: ColorMath.legible(color, on: bg, target: fillTarget),
            text: ColorMath.legible(color, on: bg, target: textTarget)
        )
    }
}
