import Foundation

/// Pure sRGB color arithmetic on hex strings and `RGB` values.
///
/// Everything here is deterministic. `ThemeResolver` works on the `RGB` overloads; the hex-string overloads are
/// conveniences for the app and the custom-scheme editor and throw `ThubanError.parse` for input that is not a
/// color.
public enum ColorMath {

    // MARK: Value types

    /// An sRGB color with channels in 0...255 (kept as `Double` so repeated shading does not accumulate rounding).
    public struct RGB: Hashable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double

        /// Channels are clamped to 0...255; non-finite input becomes 0.
        public init(r: Double, g: Double, b: Double) {
            self.r = RGB.clamp(r)
            self.g = RGB.clamp(g)
            self.b = RGB.clamp(b)
        }

        /// Lower-case `#rrggbb`.
        public var hex: String { ColorMath.toHex(self) }

        /// WCAG relative luminance, 0 (black) ... 1 (white).
        public var luminance: Double { ColorMath.luminance(self) }

        /// `"r,g,b"` with integer channels, for CSS `rgba(var(--x-rgb), a)` use.
        public var cssTriplet: String {
            "\(Int(r.rounded())),\(Int(g.rounded())),\(Int(b.rounded()))"
        }

        public static let black = RGB(r: 0, g: 0, b: 0)
        public static let white = RGB(r: 255, g: 255, b: 255)

        private static func clamp(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 255)
        }
    }

    /// Hue in degrees (0..<360), saturation and lightness in 0...1.
    public struct HSL: Hashable, Sendable {
        public var h: Double
        public var s: Double
        public var l: Double

        /// Hue is wrapped into 0..<360; saturation and lightness are clamped to 0...1.
        public init(h: Double, s: Double, l: Double) {
            self.h = HSL.wrapHue(h)
            self.s = HSL.clampUnit(s)
            self.l = HSL.clampUnit(l)
        }

        /// The same color with the hue turned by `degrees` (positive = clockwise on the wheel).
        public func rotated(by degrees: Double) -> HSL {
            HSL(h: h + degrees, s: s, l: l)
        }

        static func wrapHue(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            let wrapped = value.truncatingRemainder(dividingBy: 360)
            return wrapped < 0 ? wrapped + 360 : wrapped
        }

        static func clampUnit(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
    }

    // MARK: Constants

    /// Near-black ink used on light accent fills.
    public static let darkOnAccent = "#14100a"
    /// Warm off-white used on dark accent fills.
    public static let lightOnAccent = "#f7f5ef"
    /// How many shading steps `legible` walks in each direction before giving up.
    public static let maxLegibleSteps = 24
    /// Per-step factor when `legible` walks toward white.
    public static let lightenStep = 1.12
    /// Per-step factor when `legible` walks toward black.
    public static let darkenStep = 0.88

    // MARK: Hex parsing

    /// Parses `#rgb`, `#rrggbb`, `rgb`, `rrggbb` (case-insensitive, surrounding whitespace ignored). Four- and
    /// eight-digit forms are accepted with their alpha digits dropped. Throws `ThubanError.parse` otherwise.
    public static func parseHex(_ hex: String) throws -> RGB {
        guard let channels = hexChannels(stripHexPrefix(hex)) else {
            throw ThubanError.parse("Invalid hex color '\(hex)'. Use #rgb or #rrggbb.")
        }
        return RGB(r: channels[0], g: channels[1], b: channels[2])
    }

    /// True when `parseHex` would succeed.
    public static func isValidHex(_ hex: String) -> Bool {
        hexChannels(stripHexPrefix(hex)) != nil
    }

    /// Lower-case `#rrggbb` for any accepted spelling; throws `ThubanError.parse` for bad input.
    public static func normalizeHex(_ hex: String) throws -> String {
        try parseHex(hex).hex
    }

    /// Lower-case `#rrggbb`, channels rounded to the nearest integer.
    public static func toHex(_ color: RGB) -> String {
        let r = Int(color.r.rounded())
        let g = Int(color.g.rounded())
        let b = Int(color.b.rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private static func stripHexPrefix(_ hex: String) -> Substring {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("#") ? trimmed.dropFirst() : Substring(trimmed)
    }

    /// Three channel values (0...255) for 3/4/6/8 hex digits, or nil.
    private static func hexChannels(_ digits: Substring) -> [Double]? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 3, 4:
            let values = digits.prefix(3).compactMap { Int(String($0), radix: 16) }
            return values.count == 3 ? values.map { Double($0 * 17) } : nil
        case 6, 8:
            let values = stride(from: 0, to: 6, by: 2).compactMap { offset -> Int? in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                return Int(digits[start..<digits.index(start, offsetBy: 2)], radix: 16)
            }
            return values.count == 3 ? values.map(Double.init) : nil
        default:
            return nil
        }
    }

    // MARK: Arithmetic

    /// `f < 1` scales every channel toward black (`0.72` keeps 72% of each channel); `f > 1` moves the color
    /// `f - 1` of the way toward white (`1.12` = 12% toward white, so pure black can still be lightened).
    public static func shade(_ color: RGB, _ f: Double) -> RGB {
        guard f.isFinite, f != 1 else { return color }
        if f < 1 {
            let k = max(f, 0)
            return RGB(r: color.r * k, g: color.g * k, b: color.b * k)
        }
        return mix(color, .white, min(f - 1, 1))
    }

    /// Linear blend in sRGB; `t` is the weight of `b` (0 = all `a`, 1 = all `b`).
    public static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let weight = HSL.clampUnit(t)
        return RGB(
            r: a.r + (b.r - a.r) * weight,
            g: a.g + (b.g - a.g) * weight,
            b: a.b + (b.b - a.b) * weight
        )
    }

    /// WCAG 2.x relative luminance.
    public static func luminance(_ color: RGB) -> Double {
        0.2126 * linearChannel(color.r) + 0.7152 * linearChannel(color.g) + 0.0722 * linearChannel(color.b)
    }

    /// WCAG contrast ratio, 1...21, independent of argument order.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Returns `color` unchanged when it already reaches `target` contrast on `background`. Otherwise walks it
    /// toward white (×1.12 per step) and toward black (×0.88 per step), up to `maxLegibleSteps` each, and keeps
    /// the better result: the direction that reaches the target in fewer steps (least drift from the designed
    /// color), or, when neither reaches it, the one with the higher contrast.
    public static func legible(_ color: RGB, on background: RGB, target: Double) -> RGB {
        if contrast(color, background) >= target { return color }
        let lighter = walk(color, on: background, factor: lightenStep, target: target)
        let darker = walk(color, on: background, factor: darkenStep, target: target)
        return better(lighter, darker).color
    }

    /// `darkOnAccent` or `lightOnAccent`, whichever contrasts more with `fill`.
    public static func onAccent(_ fill: RGB) -> RGB {
        let dark = (try? parseHex(darkOnAccent)) ?? .black
        let light = (try? parseHex(lightOnAccent)) ?? .white
        return contrast(fill, dark) >= contrast(fill, light) ? dark : light
    }

    private static func linearChannel(_ value: Double) -> Double {
        let c = value / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private struct Walk {
        var color: RGB
        var contrast: Double
        var steps: Int
        var reached: Bool
    }

    private static func walk(_ start: RGB, on background: RGB, factor: Double, target: Double) -> Walk {
        var current = start
        var best = Walk(color: start, contrast: contrast(start, background), steps: 0, reached: false)
        for step in 1...maxLegibleSteps {
            current = shade(current, factor)
            let ratio = contrast(current, background)
            if ratio > best.contrast {
                best = Walk(color: current, contrast: ratio, steps: step, reached: ratio >= target)
            }
            if ratio >= target { break }
        }
        return best
    }

    private static func better(_ a: Walk, _ b: Walk) -> Walk {
        switch (a.reached, b.reached) {
        case (true, true):
            if a.steps != b.steps { return a.steps < b.steps ? a : b }
            return a.contrast >= b.contrast ? a : b
        case (true, false):
            return a
        case (false, true):
            return b
        case (false, false):
            return a.contrast >= b.contrast ? a : b
        }
    }

    // MARK: Hex conveniences (throw `ThubanError.parse` on bad input)

    /// `shade` on hex strings.
    public static func shade(_ hex: String, _ f: Double) throws -> String {
        try shade(parseHex(hex), f).hex
    }

    /// `mix` on hex strings.
    public static func mix(_ a: String, _ b: String, _ t: Double) throws -> String {
        try mix(parseHex(a), parseHex(b), t).hex
    }

    /// `luminance` on a hex string.
    public static func luminance(_ hex: String) throws -> Double {
        try luminance(parseHex(hex))
    }

    /// `contrast` on hex strings.
    public static func contrast(_ a: String, _ b: String) throws -> Double {
        try contrast(parseHex(a), parseHex(b))
    }

    /// `legible` on hex strings. Returns the input spelling untouched when it already passes.
    public static func legible(_ hex: String, on background: String, target: Double) throws -> String {
        let color = try parseHex(hex)
        let ground = try parseHex(background)
        let result = legible(color, on: ground, target: target)
        return result == color ? hex : result.hex
    }

    /// `onAccent` on a hex string.
    public static func onAccent(_ hex: String) throws -> String {
        try onAccent(parseHex(hex)).hex
    }

    // MARK: HSL

    /// sRGB → HSL.
    public static func rgbToHSL(_ color: RGB) -> HSL {
        let r = color.r / 255, g = color.g / 255, b = color.b / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2
        guard delta > 0 else { return HSL(h: 0, s: 0, l: l) }
        let s = delta / (1 - abs(2 * l - 1))
        return HSL(h: hue(r: r, g: g, b: b, maxC: maxC, delta: delta), s: s, l: l)
    }

    /// HSL → sRGB.
    public static func hslToRGB(_ hsl: HSL) -> RGB {
        let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
        let hPrime = hsl.h / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.l - c / 2
        let (r1, g1, b1) = sector(hPrime, c: c, x: x)
        return RGB(r: (r1 + m) * 255, g: (g1 + m) * 255, b: (b1 + m) * 255)
    }

    /// Hex → HSL; throws `ThubanError.parse` on bad input.
    public static func hexToHSL(_ hex: String) throws -> HSL {
        try rgbToHSL(parseHex(hex))
    }

    /// HSL → lower-case `#rrggbb`.
    public static func hslToHex(_ hsl: HSL) -> String {
        hslToRGB(hsl).hex
    }

    private static func hue(r: Double, g: Double, b: Double, maxC: Double, delta: Double) -> Double {
        let raw: Double
        if maxC == r {
            raw = (g - b) / delta
        } else if maxC == g {
            raw = (b - r) / delta + 2
        } else {
            raw = (r - g) / delta + 4
        }
        return HSL.wrapHue(raw * 60)
    }

    private static func sector(_ hPrime: Double, c: Double, x: Double) -> (Double, Double, Double) {
        switch hPrime {
        case ..<1: return (c, x, 0)
        case ..<2: return (x, c, 0)
        case ..<3: return (0, c, x)
        case ..<4: return (0, x, c)
        case ..<5: return (x, 0, c)
        default: return (c, 0, x)
        }
    }
}
