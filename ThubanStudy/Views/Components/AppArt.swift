import AppKit
import SwiftUI
#if !APPICON_TOOL
import ThubanCore
#endif

/// The app's own mark: 24×24 line art in the family style (the Thuban coil and star plus this app's purpose), kept as
/// SVG source in `AppArt.svg` and drawn natively in theme colors. Classes in the SVG name colour roles: `a` accent
/// stroke, `s` signal stroke, `af`/`sf` accent/signal fill, `pf` panel fill, `bf` background fill (knockouts).
enum AppArt {
    enum Role: String {
        case accentStroke = "a", signalStroke = "s", accentFill = "af", signalFill = "sf", panelFill = "pf", bgFill = "bf"

        var isStroke: Bool { self == .accentStroke || self == .signalStroke }
    }

    struct Layer {
        var role: Role
        var lineWidth: CGFloat
        /// In the 24×24 art space (y down).
        var path: CGPath
    }

    /// Parsed once.
    static let layers: [Layer] = SVGArtParser.parse(svg)

    /// Draws the art into `rect` (square) in a flipped (y-down) context. A role whose colour is nil is punched out
    /// (clear), which is how knockouts work in a template image.
    static func draw(in context: CGContext, rect: CGRect, colors: (Role) -> CGColor?) {
        let scale = min(rect.width, rect.height) / 24
        var transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale)
        for layer in layers {
            guard let path = layer.path.copy(using: &transform) else { continue }
            context.saveGState()
            context.addPath(path)
            if layer.role.isStroke {
                context.setStrokeColor(colors(layer.role) ?? CGColor(gray: 0, alpha: 0))
                context.setLineWidth(layer.lineWidth * scale)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
            } else if let color = colors(layer.role) {
                context.setFillColor(color)
                context.fillPath()
            } else {
                context.setBlendMode(.clear)
                context.fillPath()
            }
            context.restoreGState()
        }
    }
}

#if !APPICON_TOOL
/// The app mark at a square size in theme colours: accent as ink for the mode, signal for the star, and knockouts in
/// the ground colour the mark sits on.
struct AppArtView: View {
    var size: CGFloat = 20
    var ink: Color
    var signal: Color
    var panel: Color
    var background: Color

    init(size: CGFloat = 20, theme: ResolvedTheme, ground: Color? = nil) {
        self.size = size
        ink = theme.brassInkColor
        signal = theme.isDark ? theme.signalColor : theme.signalTextColor
        panel = ground ?? theme.panelColor
        background = ground ?? theme.bgColor
    }

    var body: some View {
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                AppArt.draw(in: cg, rect: CGRect(origin: .zero, size: canvasSize)) { role in
                    switch role {
                    case .accentStroke, .accentFill: return NSColor(ink).cgColor
                    case .signalStroke, .signalFill: return NSColor(signal).cgColor
                    case .panelFill: return NSColor(panel).cgColor
                    case .bgFill: return NSColor(background).cgColor
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#endif

// MARK: - A small SVG reader for the icon art (path, circle, ellipse, rect, line, polyline, polygon; g with transform)

enum SVGArtParser {
    static func parse(_ svg: String) -> [AppArt.Layer] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.layers
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Context { var role: AppArt.Role?; var width: CGFloat; var transform: CGAffineTransform }
        var stack: [Context] = [Context(role: nil, width: 1.75, transform: .identity)]
        var layers: [AppArt.Layer] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            var ctx = stack.last!
            if let cls = a["class"], let role = AppArt.Role(rawValue: cls.split(separator: " ").first.map(String.init) ?? "") { ctx.role = role }
            if let w = a["stroke-width"], let v = Double(w) { ctx.width = CGFloat(v) }
            if let t = a["transform"] { ctx.transform = SVGTransform.parse(t).concatenating(ctx.transform) }
            stack.append(ctx)

            func num(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "") ?? 0) }
            let path = CGMutablePath()
            switch name {
            case "path": SVGPathData.append(a["d"] ?? "", to: path)
            case "circle": path.addEllipse(in: CGRect(x: num("cx") - num("r"), y: num("cy") - num("r"), width: 2 * num("r"), height: 2 * num("r")))
            case "ellipse": path.addEllipse(in: CGRect(x: num("cx") - num("rx"), y: num("cy") - num("ry"), width: 2 * num("rx"), height: 2 * num("ry")))
            case "rect":
                let r = CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))
                let rx = min(a["rx"] != nil ? num("rx") : num("ry"), r.width / 2), ry = min(a["ry"] != nil ? num("ry") : rx, r.height / 2)
                if rx > 0 { path.addRoundedRect(in: r, cornerWidth: rx, cornerHeight: ry) } else { path.addRect(r) }
            case "line":
                path.move(to: CGPoint(x: num("x1"), y: num("y1"))); path.addLine(to: CGPoint(x: num("x2"), y: num("y2")))
            case "polyline", "polygon":
                let v = SVGPathData.numbers(a["points"] ?? "")
                for i in stride(from: 0, to: v.count - 1, by: 2) {
                    let p = CGPoint(x: v[i], y: v[i + 1])
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                if name == "polygon" { path.closeSubpath() }
            default: return
            }
            guard let role = ctx.role, !path.isEmpty else { return }
            var t = ctx.transform
            layers.append(.init(role: role, lineWidth: ctx.width * t.scaleFactor, path: path.copy(using: &t) ?? path))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }
    }
}

private extension CGAffineTransform {
    var scaleFactor: CGFloat { sqrt(abs(a * d - b * c)) }
}

enum SVGTransform {
    static func parse(_ s: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let scanner = s.replacingOccurrences(of: ",", with: " ")
        let pattern = try! NSRegularExpression(pattern: "(translate|scale|rotate|matrix)\\s*\\(([^)]*)\\)")
        for m in pattern.matches(in: scanner, range: NSRange(scanner.startIndex..., in: scanner)) {
            let kind = String(scanner[Range(m.range(at: 1), in: scanner)!])
            let v = SVGPathData.numbers(String(scanner[Range(m.range(at: 2), in: scanner)!]))
            var t = CGAffineTransform.identity
            switch kind {
            case "translate": t = .init(translationX: v.first ?? 0, y: v.count > 1 ? v[1] : 0)
            case "scale": t = .init(scaleX: v.first ?? 1, y: v.count > 1 ? v[1] : (v.first ?? 1))
            case "rotate":
                let angle = (v.first ?? 0) * .pi / 180
                if v.count >= 3 {
                    t = CGAffineTransform(translationX: v[1], y: v[2]).rotated(by: angle).translatedBy(x: -v[1], y: -v[2])
                } else { t = .init(rotationAngle: angle) }
            case "matrix" where v.count == 6: t = .init(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            default: break
            }
            // SVG applies the list left to right onto the element: result = t_n … t_1 applied first-to-last.
            result = t.concatenating(result)
        }
        return result
    }
}

/// SVG path data (`d`) → CGPath, all commands incl. arcs (converted to cubic Béziers).
enum SVGPathData {
    static func numbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            let (value, remaining) = scanNumber(rest)
            if let value { out.append(value); rest = remaining } else { rest = rest.dropFirst() }
        }
        return out
    }

    /// Tokenises into commands with their numbers; arc flags may be written without separators ("a1 1 0 011 1").
    private static func commands(_ d: String) -> [(Character, [CGFloat])] {
        var result: [(Character, [CGFloat])] = []
        var current: Character?
        var buffer = ""
        func flush() {
            if let c = current { result.append((c, c == "a" || c == "A" ? arcNumbers(buffer) : numbers(buffer))) }
            buffer = ""
        }
        for ch in d {
            if "MmLlHhVvCcSsQqTtAaZz".contains(ch) { flush(); current = ch } else { buffer.append(ch) }
        }
        flush()
        return result
    }

    /// Arc arguments: rx ry rot large-flag sweep-flag x y — flags are single characters "0"/"1".
    private static func arcNumbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var rest = Substring(s)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            if rest.isEmpty { break }
            let slot = out.count % 7
            if slot == 3 || slot == 4 {
                guard let f = rest.first, f == "0" || f == "1" else { break }
                out.append(f == "1" ? 1 : 0)
                rest = rest.dropFirst()
            } else {
                let (value, remaining) = scanNumber(rest)
                guard let value else { break }
                out.append(value)
                rest = remaining
            }
        }
        return out
    }

    private static func scanNumber(_ s: Substring) -> (CGFloat?, Substring) {
        var j = s.startIndex
        var seenDot = false, seenExp = false, seenDigit = false
        if j < s.endIndex, s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
        while j < s.endIndex {
            let c = s[j]
            if c.isNumber { seenDigit = true; j = s.index(after: j) }
            else if c == "." && !seenDot && !seenExp { seenDot = true; j = s.index(after: j) }
            else if (c == "e" || c == "E") && seenDigit && !seenExp {
                seenExp = true; j = s.index(after: j)
                if j < s.endIndex, s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
            } else { break }
        }
        guard seenDigit, let v = Double(s[s.startIndex..<j]) else { return (nil, s) }
        return (CGFloat(v), s[j...])
    }

    static func append(_ d: String, to path: CGMutablePath) {
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        for (cmd, v) in commands(d) {
            let rel = cmd.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            let upper = Character(cmd.uppercased())
            let arity: Int = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7][upper] ?? 0
            if upper == "Z" { path.closeSubpath(); cur = start; lastCubic = nil; lastQuad = nil; continue }
            var i = 0
            while arity > 0 && i + arity <= v.count {
                let a = Array(v[i..<i + arity])
                let first = i == 0
                i += arity
                switch upper {
                case "M":
                    let p = pt(a[0], a[1])
                    if first { path.move(to: p); start = p } else { path.addLine(to: p) }
                    cur = p; lastCubic = nil; lastQuad = nil
                case "L":
                    cur = pt(a[0], a[1]); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
                case "H":
                    cur = CGPoint(x: rel ? cur.x + a[0] : a[0], y: cur.y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
                case "V":
                    cur = CGPoint(x: cur.x, y: rel ? cur.y + a[0] : a[0]); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
                case "C":
                    let c1 = pt(a[0], a[1]), c2 = pt(a[2], a[3]), p = pt(a[4], a[5])
                    path.addCurve(to: p, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = p
                case "S":
                    let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let c2 = pt(a[0], a[1]), p = pt(a[2], a[3])
                    path.addCurve(to: p, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = p
                case "Q":
                    let c = pt(a[0], a[1]), p = pt(a[2], a[3])
                    path.addQuadCurve(to: p, control: c); lastQuad = c; lastCubic = nil; cur = p
                case "T":
                    let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let p = pt(a[0], a[1])
                    path.addQuadCurve(to: p, control: c); lastQuad = c; lastCubic = nil; cur = p
                case "A":
                    let p = pt(a[5], a[6])
                    addArc(to: path, from: cur, rx: a[0], ry: a[1], rotation: a[2], large: a[3] != 0, sweep: a[4] != 0, end: p)
                    cur = p; lastCubic = nil; lastQuad = nil
                default: break
                }
            }
        }
    }

    /// Endpoint-parameterised elliptical arc (SVG spec F.6.5) as cubic Béziers.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               large: Bool, sweep: Bool, end p1: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            let x = -rx * sin(t), y = ry * cos(t)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        var t = theta1
        for s in 0..<segments {
            let t2 = t + step
            let a = point(t), b = s == segments - 1 ? p1 : point(t2)
            let da = derivative(t), db = derivative(t2)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = t2
        }
    }
}
