import Foundation
import ImageIO

/// Decides, before any model call, whether an extracted image can be a figure at all. Course pages (WebAssign,
/// Canvas, MathType) render equations, single symbols, status icons and toolbar sprites as images; none of those
/// belong under Figures, and sending them to the figure agent wastes a call each.
public enum FigureGate {
    public enum Rejection: String, Sendable, Equatable {
        /// Below the smallest size a chart, diagram or photo could be.
        case tooSmall
        /// A rule, brace or bar: one side is many times the other.
        case extremeAspect
        /// Served by a known equation renderer or editor (WIRIS/MathType, WebAssign watex, MathJax, CodeCogs …).
        case mathRenderer
        /// Site chrome: status marks, toolbar sprites, spacers.
        case chrome
        /// The page sizes it as an inline glyph (a few ems).
        case inlineGlyph
    }

    /// Shortest side, in pixels, a figure must reach.
    public static let minimumSide = 48
    /// Smallest area, in pixels, a figure must cover (≈ 110 × 110).
    public static let minimumArea = 12_000
    /// Longest side ÷ shortest side beyond which the image is a rule or a brace.
    public static let maximumAspect = 8.0

    /// Pixel-level check shared by every parser.
    public static func verdict(width: Int, height: Int) -> Rejection? {
        guard width > 0, height > 0 else { return .tooSmall }
        if min(width, height) < minimumSide || width * height < minimumArea { return .tooSmall }
        if Double(max(width, height)) / Double(min(width, height)) > maximumAspect { return .extremeAspect }
        return nil
    }

    /// Pixel-level check on encoded image bytes (only the header is read).
    public static func verdict(imageData: Data) -> Rejection? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return verdict(width: width, height: height)
    }

    // MARK: HTML

    /// Substrings of an `<img src>` that mark equation renderers and editor chrome.
    static let rendererSourceMarkers = [
        "/watex/", "/mathtype/", "/wiris/", "mathjax", "codecogs", "latex.php", "/tex.cgi", "/mathtex", "/mimetex",
        "/equation/", "/img/questions/", "/spacer.", "/blank.", "/pixel.", "/1x1.",
    ]
    /// Class names of equation renderers and editors.
    static let rendererClassMarkers = ["wrs_image", "watex", "mathjax", "mjx-", "math-tex", "latex", "equation", "mathml"]

    /// Attribute-level check for an HTML `<img>`; nil means "could be a figure, look at the pixels".
    public static func verdict(source: String, cssClass: String, alt: String, style: String) -> Rejection? {
        let src = source.lowercased()
        let classes = cssClass.lowercased()
        if rendererClassMarkers.contains(where: { classes.contains($0) }) { return .mathRenderer }
        if rendererSourceMarkers.contains(where: { src.contains($0) }) {
            return src.contains("/img/questions/") || src.contains("spacer") || src.contains("blank") || src.contains("pixel") || src.contains("1x1")
                ? .chrome : .mathRenderer
        }
        let lowerAlt = alt.lowercased()
        if lowerAlt.hasPrefix("correct:") || lowerAlt.hasPrefix("incorrect:") || lowerAlt.hasPrefix("changed:") { return .chrome }
        if let (w, h) = emSize(style), max(w, h) < 4 { return .inlineGlyph }
        return nil
    }

    /// Reads `width: 1.2em; height: 2em` (both in em) from an inline style, if present.
    static func emSize(_ style: String) -> (Double, Double)? {
        var width: Double?
        var height: Double?
        for declaration in style.lowercased().split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[1].hasSuffix("em"), let value = Double(pair[1].dropLast(2).trimmingCharacters(in: .whitespaces)) else { continue }
            if pair[0] == "width" { width = value } else if pair[0] == "height" { height = value }
        }
        guard let width, let height else { return nil }
        return (width, height)
    }
}
