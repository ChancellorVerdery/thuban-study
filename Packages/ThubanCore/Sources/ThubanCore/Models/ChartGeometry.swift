import Foundation

/// The Desmos-style LaTeX behind a standardized chart (a dialect of LaTeX, not a Desmos dependency; the Thuban
/// Graph engine reads the same syntax): smooth curves through tabulated points, bars, and slope / direction fields.
/// Pure functions shared by the native figure pipeline (`FigureScene`, `FigureCanvasView`) and the agents.
public enum ChartGeometry {
    /// One Desmos-style expression row of a rendered chart.
    public struct Row: Equatable, Sendable {
        public var id: String
        public var latex: String
        /// Rows that only hold data (lists, helper functions) are hidden from the graph.
        public var hidden: Bool
        /// Filled polygons (bars, arrowheads) get this opacity; nil = the renderer's default (outline + light fill).
        public var fillOpacity: Double?
        /// Parametric rows run t over [0, 1] unless told otherwise.
        public var parametricDomain: ClosedRange<Double>?
        /// Point lists draw as dots; curves draw as lines.
        public var showsPoints: Bool
        /// Stroke width in px; nil = the renderer's default (2.5).
        public var lineWidth: Double?
        /// Stroke opacity 0–1; nil = the renderer's default.
        public var lineOpacity: Double?
        /// "SOLID" | "DASHED" | "DOTTED"; nil = solid.
        public var lineStyle: String?

        public init(id: String, latex: String, hidden: Bool = false, fillOpacity: Double? = nil,
                    parametricDomain: ClosedRange<Double>? = nil, showsPoints: Bool = false, lineWidth: Double? = nil,
                    lineOpacity: Double? = nil, lineStyle: String? = nil) {
            self.id = id
            self.latex = latex
            self.hidden = hidden
            self.fillOpacity = fillOpacity
            self.parametricDomain = parametricDomain
            self.showsPoints = showsPoints
            self.lineWidth = lineWidth
            self.lineOpacity = lineOpacity
            self.lineStyle = lineStyle
        }
    }

    // MARK: Curves

    /// Resamples a polyline as a centripetal Catmull-Rom spline so a dozen points read off a figure draw as one
    /// smooth curve. Points are sorted by x first when the series is a function of x (strictly increasing x).
    public static func smoothed(_ raw: [[Double]], samplesPerSegment: Int = 8) -> [[Double]] {
        var points = raw.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }.map { [$0[0], $0[1]] }
        guard points.count >= 2 else { return points }
        // Points read left to right with a slip or two are put in order; a curve that loops, closes or doubles
        // back keeps the order it was traced in (sorting it by x would zigzag across it).
        let steps = zip(points, points.dropFirst()).map { $1[0] - $0[0] }
        let rising = steps.filter { $0 > 0 }.count, falling = steps.filter { $0 < 0 }.count
        let xs = points.map { $0[0] }
        if Set(xs).count == xs.count, steps.count >= 2 {
            if Double(falling) <= max(1, Double(steps.count) * 0.15) { points.sort { $0[0] < $1[0] } }
            else if Double(rising) <= max(1, Double(steps.count) * 0.15) { points.sort { $0[0] > $1[0] } }
        }
        guard points.count >= 3, samplesPerSegment > 1 else { return points }

        // Duplicate the ends so the spline passes through the first and last points.
        let padded = [points[0]] + points + [points[points.count - 1]]
        var out: [[Double]] = [points[0]]
        for i in 1..<(padded.count - 2) {
            let p0 = padded[i - 1], p1 = padded[i], p2 = padded[i + 1], p3 = padded[i + 2]
            for s in 1...samplesPerSegment {
                let t = Double(s) / Double(samplesPerSegment)
                out.append(catmullRom(p0, p1, p2, p3, t))
            }
        }
        return out
    }

    private static func catmullRom(_ p0: [Double], _ p1: [Double], _ p2: [Double], _ p3: [Double], _ t: Double) -> [Double] {
        func axis(_ k: Int) -> Double {
            let a = 2 * p1[k]
            let b = p2[k] - p0[k]
            let c = 2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]
            let d = -p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]
            return 0.5 * (a + b * t + c * t * t + d * t * t * t)
        }
        return [axis(0), axis(1)]
    }

    /// A polyline through `points` as one parametric row: segment k runs from point k to point k + 1 as t goes
    /// 0 → 1, and Desmos draws every segment of the lists at once.
    public static func polylineRow(id: String, points: [[Double]]) -> Row? {
        let pts = points.filter { $0.count >= 2 }
        guard pts.count >= 2 else { return nil }
        let x0 = list(pts.dropLast().map { $0[0] })
        let x1 = list(pts.dropFirst().map { $0[0] })
        let y0 = list(pts.dropLast().map { $0[1] })
        let y1 = list(pts.dropFirst().map { $0[1] })
        let latex = "\\left(\(x0)+t\\left(\(x1)-\(x0)\\right),\(y0)+t\\left(\(y1)-\(y0)\\right)\\right)"
        return Row(id: id, latex: latex, parametricDomain: 0...1)
    }

    /// The dots of a scatter series.
    public static func pointsRow(id: String, points: [[Double]]) -> Row? {
        let pts = points.filter { $0.count >= 2 }
        guard !pts.isEmpty else { return nil }
        let latex = "\\left[" + pts.map { "\\left(\(number($0[0])),\(number($0[1]))\\right)" }.joined(separator: ",") + "\\right]"
        return Row(id: id, latex: latex, showsPoints: true)
    }

    /// `y = f(x)` (or the equation as given when it already has an `=`).
    public static func functionRow(id: String, latex: String) -> Row? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Row(id: id, latex: trimmed.contains("=") ? trimmed : "y=\(trimmed)")
    }

    /// Bars centred on each x, `width` wide, from the axis to y — one polygon row for the whole series.
    public static func barsRow(id: String, points: [[Double]], width: Double = 0.8) -> Row? {
        let pts = points.filter { $0.count >= 2 }
        guard !pts.isEmpty else { return nil }
        let half = width / 2
        let xs = list(pts.map { $0[0] })
        let ys = list(pts.map { $0[1] })
        let latex = "\\operatorname{polygon}\\left(\\left(\(xs)-\(number(half)),0\\right),\\left(\(xs)+\(number(half)),0\\right),"
            + "\\left(\(xs)+\(number(half)),\(ys)\\right),\\left(\(xs)-\(number(half)),\(ys)\\right)\\right)"
        return Row(id: id, latex: latex, fillOpacity: 0.55)
    }

    // MARK: Slope / direction fields

    /// Rows for a direction field of `dy/dx = slope(x, y)` over the ranges: a helper function, the grid lists,
    /// the slopes, a short segment through every grid point in the direction (1, m) and an arrowhead at its tip.
    /// `arrows == false` draws the classic slope-field ticks without heads.
    public static func slopeFieldRows(
        idPrefix: String, slope: String, xRange: ClosedRange<Double>, yRange: ClosedRange<Double>,
        columns: Int = 20, rows: Int = 20, arrows: Bool = true
    ) -> [Row] {
        let expression = slope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, columns >= 2, rows >= 2 else { return [] }
        let (xs, ys) = grid(xRange: xRange, yRange: yRange, columns: columns, rows: rows)
        // Segment half-length: 40 % of the grid spacing, so neighbours never touch.
        let spacing = min((xRange.upperBound - xRange.lowerBound) / Double(columns - 1), (yRange.upperBound - yRange.lowerBound) / Double(rows - 1))
        let fn = "S_{\(idPrefix)}"
        let X = "X_{\(idPrefix)}", Y = "Y_{\(idPrefix)}", M = "M_{\(idPrefix)}"
        let D = "D_{\(idPrefix)}" // 1 / sqrt(1 + m²)
        let H = "H_{\(idPrefix)}" // half-length of a segment
        var out: [Row] = [
            Row(id: "\(idPrefix)-fn", latex: "\(fn)\\left(x,y\\right)=\(expression)", hidden: true),
            Row(id: "\(idPrefix)-h", latex: "\(H)=\(number(spacing * 0.4))", hidden: true),
            Row(id: "\(idPrefix)-x", latex: "\(X)=\(list(xs))", hidden: true),
            Row(id: "\(idPrefix)-y", latex: "\(Y)=\(list(ys))", hidden: true),
            Row(id: "\(idPrefix)-m", latex: "\(M)=\(fn)\\left(\(X),\(Y)\\right)", hidden: true),
            Row(id: "\(idPrefix)-d", latex: "\(D)=\\frac{1}{\\sqrt{1+\(M)^{2}}}", hidden: true),
        ]
        // Segment: centre ± H·(1, m)/√(1+m²), as a two-vertex polygon over the lists. A polygon is drawn straight
        // from its vertices, whereas a parametric curve is sampled hundreds of times per list element — which is
        // what made a 400-arrow field take seconds to appear.
        let segment = "\\operatorname{polygon}\\left(\\left(\(X)-\(H)\(D),\(Y)-\(H)\(M)\(D)\\right),\\left(\(X)+\(H)\(D),\(Y)+\(H)\(M)\(D)\\right)\\right)"
        out.append(Row(id: "\(idPrefix)-seg", latex: segment, fillOpacity: 0, lineWidth: 1.6, lineOpacity: 0.85))
        if arrows {
            // Arrowhead: tip at the segment's end, base 45 % of H back along it, half-width 22 % of H.
            // The unit normal to (1, m)/√(1+m²) is (-m, 1)/√(1+m²).
            let tipX = "\(X)+\(H)\(D)", tipY = "\(Y)+\(H)\(M)\(D)"
            let baseX = "\(X)+0.55\(H)\(D)", baseY = "\(Y)+0.55\(H)\(M)\(D)"
            let head = "\\operatorname{polygon}\\left(\\left(\(tipX),\(tipY)\\right),"
                + "\\left(\(baseX)-0.22\(H)\(M)\(D),\(baseY)+0.22\(H)\(D)\\right),"
                + "\\left(\(baseX)+0.22\(H)\(M)\(D),\(baseY)-0.22\(H)\(D)\\right)\\right)"
            out.append(Row(id: "\(idPrefix)-head", latex: head, fillOpacity: 0.85))
        }
        return out
    }

    /// Row-major grid coordinates (x varies fastest).
    public static func grid(xRange: ClosedRange<Double>, yRange: ClosedRange<Double>, columns: Int, rows: Int) -> (xs: [Double], ys: [Double]) {
        var xs: [Double] = []
        var ys: [Double] = []
        for r in 0..<rows {
            let y = yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * Double(r) / Double(rows - 1)
            for c in 0..<columns {
                let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * Double(c) / Double(columns - 1)
                xs.append(x)
                ys.append(y)
            }
        }
        return (xs, ys)
    }

    // MARK: Formatting

    /// `[1,2.5,-3]`
    public static func list(_ values: [Double]) -> String {
        "\\left[" + values.map(number).joined(separator: ",") + "\\right]"
    }

    /// Short decimal text Desmos parses: integers without a point, otherwise up to 5 significant digits.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e12 { return String(Int(value)) }
        var text = String(format: "%.5g", value)
        if text.contains("e") { text = String(format: "%.5f", value) }
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
