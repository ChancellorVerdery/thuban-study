import Foundation

/// Proposes the three companion colors for a custom accent ("Derive from accent" in the custom-scheme editor):
/// the accent's hue rotated in HSL with saturation and lightness kept, so the set reads as one family.
public enum SchemeDeriver {
    /// Hue rotation for "Highlight".
    public static let signalRotation = 150.0
    /// Hue rotation for "Gain".
    public static let posRotation = 100.0
    /// Hue rotation for "Loss".
    public static let negRotation = -30.0

    /// The proposed companions, lower-case `#rrggbb`.
    public struct Proposal: Hashable, Sendable {
        public var signal: String
        public var pos: String
        public var neg: String

        public init(signal: String, pos: String, neg: String) {
            self.signal = signal
            self.pos = pos
            self.neg = neg
        }
    }

    /// Signal / pos / neg for `accent`. Throws `ThubanError.parse` when `accent` is not a hex color.
    public static func derive(fromAccent accent: String) throws -> Proposal {
        let base = try ColorMath.hexToHSL(accent)
        return Proposal(
            signal: ColorMath.hslToHex(base.rotated(by: signalRotation)),
            pos: ColorMath.hslToHex(base.rotated(by: posRotation)),
            neg: ColorMath.hslToHex(base.rotated(by: negRotation))
        )
    }

    /// `scheme` with `accent` set and signal / pos / neg replaced by the derived proposal. Grounds are untouched.
    public static func applying(accent: String, to scheme: ColorScheme) throws -> ColorScheme {
        let proposal = try derive(fromAccent: accent)
        var copy = scheme
        copy.accent = try ColorMath.normalizeHex(accent)
        copy.signal = proposal.signal
        copy.pos = proposal.pos
        copy.neg = proposal.neg
        return copy
    }

    /// `hex` with its hue turned by `degrees`, saturation and lightness kept. Throws `ThubanError.parse`.
    public static func rotate(_ hex: String, by degrees: Double) throws -> String {
        try ColorMath.hslToHex(ColorMath.hexToHSL(hex).rotated(by: degrees))
    }
}
