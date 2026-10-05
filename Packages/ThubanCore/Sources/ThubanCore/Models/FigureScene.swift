import Foundation

/// Everything needed to draw a `StandardChart` natively, in data coordinates: the window, the ticks, the field's
/// arrows and every curve, dot and bar. Built once per chart (the math runs through `MathEngine`); the app's
/// figure view only maps it to pixels and strokes it, so a figure appears instantly and works offline.
public struct FigureScene: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var x: ClosedRange<Double>
        public var y: ClosedRange<Double>
        public init(x: ClosedRange<Double>, y: ClosedRange<Double>) { self.x = x; self.y = y }
    }

    /// One arrow (or tick) of a slope field: its centre and the slope there (nil where undefined).
    public struct Arrow: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var slope: Double?
        /// Length relative to the arrow pitch, as measured in the picture (nil: the standard length).
        public var length: Double? = nil
    }

    public enum LineStyle: String, Sendable, Equatable { case solid, dashed, dotted }

    /// One series as drawn: polylines (a curve may break at a gap or asymptote), dots, bars, a shaded region, or
    /// arrowheads along a curve.
    public struct Mark: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case line, dots, bars, fill, arrows, vector }
        public var kind: Kind
        public var name: String
        /// Polylines, each `[[x, y], …]`; for dots and bars one list of points; for a fill rectangles
        /// `[[x0, y0], [x1, y1]]`; for arrows one list of `[x, y, dx, dy]`.
        public var pieces: [[[Double]]]
        public var style: LineStyle
        /// Hex colour from the chart, or nil for the theme palette.
        public var color: String?
        /// Position among the chart's series (picks the palette colour).
        public var paletteIndex: Int
        /// Dots: the label printed beside each point.
        public var labels: [String]? = nil
        /// The chart series it draws (−1: none).
        public var seriesIndex: Int = -1
    }

    public var window: Window
    public var xStep: Double
    public var yStep: Double
    public var xLabel: String?
    public var yLabel: String?
    public var arrows: [Arrow]
    /// Arrowheads on the field (a direction field) or plain ticks (a slope field).
    public var arrowheads: Bool
    public var fieldColumns: Int
    public var fieldRows: Int
    public var marks: [Mark]
    /// The labels the original prints on each axis; nil draws evenly spaced numbers at the tick step, an empty
    /// list draws none (the original prints none on that axis).
    public var xTickLabels: [ChartTick]?
    public var yTickLabels: [ChartTick]?

    public var hasField: Bool { !arrows.isEmpty }

    /// The picture draws arrows of clearly different lengths (a field scaled by magnitude): draw them so too.
    public var variesInLength: Bool {
        let lengths = arrows.compactMap(\.length).sorted()
        guard lengths.count >= 12 else { return false }
        return lengths[lengths.count / 10] < lengths[lengths.count * 9 / 10] * 0.6
    }

    // MARK: Building

    public static let defaultWindow = Window(x: -5...5, y: -5...5)

    /// The chart's window: its ranges when given, else the extent of its points with 10 % padding, else −5…5.
    public static func window(for chart: StandardChart) -> Window {
        if let x = chart.xRange, let y = chart.yRange, x.count == 2, y.count == 2, x[0] < x[1], y[0] < y[1] {
            return Window(x: x[0]...x[1], y: y[0]...y[1])
        }
        let points = chart.series.flatMap { $0.points ?? [] }.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max() else { return defaultWindow }
        let padX = max((maxX - minX) * 0.1, 1), padY = max((maxY - minY) * 0.1, 1)
        return Window(x: (minX - padX)...(maxX + padX), y: (min(0, minY) - padY)...(maxY + padY))
    }

    /// A round tick spacing (1, 2 or 5 × 10ⁿ) giving about `target` ticks across `span`.
    public static func niceStep(_ span: Double, target: Double = 8) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / target
        let magnitude = pow(10, floor(log10(raw)))
        let normalised = raw / magnitude
        let nice: Double = normalised < 1.5 ? 1 : normalised < 3 ? 2 : normalised < 7 ? 5 : 10
        return nice * magnitude
    }

    /// Tick values of `step` inside `range`.
    public static func ticks(in range: ClosedRange<Double>, step: Double) -> [Double] {
        guard step > 0, step.isFinite else { return [] }
        let first = (range.lowerBound / step).rounded(.up)
        let last = (range.upperBound / step).rounded(.down)
        guard last >= first, last - first < 400 else { return [] }
        return stride(from: first, through: last, by: 1).map { ($0 * step * 1e9).rounded() / 1e9 }
    }

    /// Samples across the window used for a function of x, and the implicit-relation grid size.
    static let explicitSamples = 600
    static let implicitGrid = 140

    public static func build(_ chart: StandardChart, engine: MathEngine) async -> FigureScene {
        let window = window(for: chart)
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let xStep = chart.xStep.flatMap { $0 > 0 && xSpan / $0 <= 60 ? $0 : nil } ?? niceStep(xSpan)
        let yStep = chart.yStep.flatMap { $0 > 0 && ySpan / $0 <= 60 ? $0 : nil } ?? niceStep(ySpan)
        let columns = min(40, max(6, chart.fieldColumns ?? 20))
        let rows = min(40, max(6, chart.fieldRows ?? 16))

        // The field: the arrows as the picture draws them when the stated slope lost to the picture, else one engine
        // call for every arrow.
        var arrows: [Arrow] = []
        var columnsDrawn = columns, rowsDrawn = rows
        let slope = chart.isSlopeField ? chart.slope?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let measured = (chart.fieldSamples ?? []).filter { $0.count >= 3 }
        if chart.isSlopeField, chart.fieldFromPicture == true, !measured.isEmpty {
            arrows = measured.map { Arrow(x: $0[0], y: $0[1], slope: $0[2].isFinite ? $0[2] : nil, length: $0.count >= 4 ? $0[3] : nil) }
        } else if let slope, !slope.isEmpty {
            var centres: [(x: Double, y: Double)] = []
            for r in 0..<rows {
                for c in 0..<columns {
                    // Cell centres, so the outermost arrows sit half a cell inside the window like a printed field.
                    let x = window.x.lowerBound + xSpan * (Double(c) + 0.5) / Double(columns)
                    let y = window.y.lowerBound + ySpan * (Double(r) + 0.5) / Double(rows)
                    centres.append((x, y))
                }
            }
            if let sampled = try? await engine.samples(of: slope, at: centres), sampled.values.contains(where: { $0 != nil }) {
                arrows = zip(centres, sampled.values).map { Arrow(x: $0.x, y: $0.y, slope: $1.flatMap { $0.isFinite ? $0 : nil }) }
            } else if !measured.isEmpty {
                arrows = measured.map { Arrow(x: $0[0], y: $0[1], slope: $0[2].isFinite ? $0[2] : nil) }
            }
        }
        if arrows.count == measured.count, !measured.isEmpty, let c = chart.fieldColumns, let r = chart.fieldRows { columnsDrawn = c; rowsDrawn = r }

        var marks: [Mark] = []
        for (index, series) in chart.series.enumerated() {
            let style = LineStyle(rawValue: (series.style ?? "solid").lowercased()) ?? .solid
            func mark(_ kind: Mark.Kind, _ pieces: [[[Double]]]) -> Mark {
                // A one-colour original is redrawn in one colour.
                Mark(kind: kind, name: series.name, pieces: pieces, style: style, color: chart.monochrome == true ? nil : series.color?.nilIfBlank,
                     paletteIndex: chart.monochrome == true ? 0 : index, seriesIndex: index)
            }
            let latex = series.latex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let given = (series.points ?? []).filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
            if series.seriesKind == .point {
                if !given.isEmpty {
                    var dots = mark(.dots, [given])
                    dots.labels = series.labels
                    marks.append(dots)
                }
                continue
            }
            if series.seriesKind == .vector {
                if given.count >= 2 { marks.append(mark(.vector, [Array(given.prefix(2))])) }
                continue
            }
            switch shape(of: series) {
            case .region(let conditions):
                if let region = await ChartShapes.region(conditions, window: window, engine: engine) {
                    if !region.fill.isEmpty { marks.append(mark(.fill, region.fill)) }
                    // An edge along an axis (y ≥ 0) is the axis itself, already drawn.
                    let xEps = (window.x.upperBound - window.x.lowerBound) * 0.004, yEps = (window.y.upperBound - window.y.lowerBound) * 0.004
                    func offAxis(_ pieces: [[[Double]]]) -> [[[Double]]] {
                        pieces.filter { piece in !(piece.allSatisfy { abs($0[1]) <= yEps } || piece.allSatisfy { abs($0[0]) <= xEps }) }
                    }
                    let solidEdges = offAxis(region.boundary), dashedEdges = offAxis(region.dashed)
                    if !solidEdges.isEmpty { marks.append(mark(.line, solidEdges)) }
                    if !dashedEdges.isEmpty {
                        var edge = mark(.line, dashedEdges)
                        edge.style = .dashed
                        marks.append(edge)
                    }
                }
                continue
            case .level(let function, let levels):
                if let curves = await ChartShapes.levelCurves(function, levels: levels, window: window, engine: engine) {
                    let pieces = curves.flatMap { $0 }
                    if !pieces.isEmpty { marks.append(mark(.line, pieces)) }
                }
                continue
            case .parametric(let x, let y):
                // A marked point r(t₀), its position vector and its tangent vector r′(t₀), computed from the formulas.
                if let t0 = series.markAt, t0.isFinite {
                    let h = 1e-5
                    if let rows = try? await engine.values(of: [ChartShapes.normalised(x), ChartShapes.normalised(y)], variables: ["t"], at: [[t0], [t0 - h], [t0 + h]]),
                       rows.count == 2, let xs = rows[0], let ys = rows[1],
                       let px = xs[0], let py = ys[0] {
                        if series.positionVector == true { marks.append(mark(.vector, [[[0, 0], [px, py]]])) }
                        if series.tangentVector == true, let xa = xs[1], let xb = xs[2], let ya = ys[1], let yb = ys[2] {
                            let dx = (xb - xa) / (2 * h), dy = (yb - ya) / (2 * h)
                            if dx.isFinite, dy.isFinite { marks.append(mark(.vector, [[[px, py], [px + dx, py + dy]]])) }
                        }
                        marks.append(mark(.dots, [[[px, py]]]))
                    }
                }
                if let curve = await ChartShapes.parametric(x: x, y: y, tRange: series.tRange, arrows: series.directionArrows == true,
                                                            window: window, engine: engine) {
                    marks.append(mark(.line, curve.pieces))
                    if let measured = series.arrowMarks, !measured.isEmpty { marks.append(mark(.arrows, [measured])) }
                    else if !curve.arrows.isEmpty { marks.append(mark(.arrows, [curve.arrows])) }
                }
                continue
            case .restricted(let equation, let conditions):
                if let pieces = await ChartShapes.restrictedRelation(equation, conditions: conditions, window: window, engine: engine), !pieces.isEmpty {
                    marks.append(mark(.line, pieces))
                    if series.directionArrows == true { marks.append(mark(.arrows, [ChartShapes.arrowMarks(along: pieces, window: window)])) }
                }
                continue
            case .curve:
                break
            }
            if !latex.isEmpty {
                if var pieces = await curve(latex, window: window, engine: engine), !pieces.isEmpty {
                    // A stretch of the curve only (a segment, one arm of a parabola).
                    if let domain = series.domain, domain.count == 2, domain[0] < domain[1] {
                        pieces = pieces.flatMap { piece in
                            piece.split { $0[0] < domain[0] - 1e-9 || $0[0] > domain[1] + 1e-9 }.map(Array.init)
                        }.filter { $0.count >= 2 }
                    }
                    marks.append(mark(.line, pieces))
                    if let measured = series.arrowMarks, !measured.isEmpty { marks.append(mark(.arrows, [measured])) }
                    else if series.directionArrows == true { marks.append(mark(.arrows, [ChartShapes.arrowMarks(along: pieces, window: window)])) }
                }
                continue
            }
            let points = (series.points ?? []).filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
            if !points.isEmpty {
                switch chart.chartType {
                case "scatter": marks.append(mark(.dots, [points]))
                case "bar", "histogram": marks.append(mark(.bars, [points]))
                default:
                    if points.count == 1 { marks.append(mark(.dots, [points])) }
                    else {
                        let line = ChartGeometry.smoothed(points)
                        marks.append(mark(.line, [line]))
                        if let measured = series.arrowMarks, !measured.isEmpty { marks.append(mark(.arrows, [measured])) }
                        else if series.directionArrows == true { marks.append(mark(.arrows, [ChartShapes.arrowMarks(along: [line], window: window)])) }
                    }
                }
                continue
            }
            if let slope, !slope.isEmpty, chart.fieldFromPicture != true, let start = series.throughPoint,
               let path = try? await engine.integrateSlope(slope, through: start, xRange: window.x, yRange: window.y, steps: 800), path.count >= 2 {
                marks.append(mark(.line, split(path, window: window)))
                continue
            }
            // A solution sketch: the curve solves the chart's differential equation, over the stretch it is drawn.
            if let ode = chart.odeSlope?.nilIfBlank, let start = series.throughPoint {
                var xRange = window.x
                if let domain = series.domain, domain.count == 2, domain[0] < domain[1] {
                    xRange = max(window.x.lowerBound, domain[0])...min(window.x.upperBound, domain[1])
                }
                let margin = (window.y.upperBound - window.y.lowerBound) * 0.5
                if let path = try? await engine.integrateSlope(ode, through: start, xRange: xRange,
                                                               yRange: (window.y.lowerBound - margin)...(window.y.upperBound + margin), steps: 800),
                   path.count >= 2 {
                    marks.append(mark(.line, split(path, window: window)))
                }
            }
        }

        // A curve drawn along a dashed (strict) region edge is that edge: dashed too.
        let dashedEdges = marks.filter { $0.kind == .line && $0.style == .dashed }.flatMap(\.pieces).flatMap { $0 }
        if !dashedEdges.isEmpty {
            let reach = max(window.x.upperBound - window.x.lowerBound, window.y.upperBound - window.y.lowerBound) * 0.01
            for k in marks.indices where marks[k].kind == .line && marks[k].style == .solid {
                let points = marks[k].pieces.flatMap { $0 }.filter { window.x.contains($0[0]) && window.y.contains($0[1]) }
                guard points.count >= 10 else { continue }
                let near = points.filter { p in dashedEdges.contains { hypot($0[0] - p[0], $0[1] - p[1]) <= reach } }.count
                if near * 10 >= points.count * 8 { marks[k].style = .dashed }
            }
        }
        return FigureScene(window: window, xStep: xStep, yStep: yStep, xLabel: chart.xLabel?.nilIfBlank, yLabel: chart.yLabel?.nilIfBlank,
                           arrows: arrows, arrowheads: chart.arrows, fieldColumns: columnsDrawn, fieldRows: rowsDrawn, marks: marks,
                           xTickLabels: chart.xAxisLabels, yTickLabels: chart.yAxisLabels)
    }

    /// What a series draws, from its `kind` or (for series stored before kinds existed) from its LaTeX: an
    /// inequality is a region, "x = f(t), y = g(t)" a parametric curve.
    public enum Shape: Equatable {
        case curve
        case region(String)
        case level(String, [Double])
        case parametric(String, String)
        public var isRegion: Bool { if case .region = self { return true } else { return false } }
        /// One equation kept where some conditions hold ("x^2+y^2=49, x\\le 0": the left half of the circle).
        case restricted(String, [String])
    }

    public static func shape(of series: ChartSeries) -> Shape {
        let latex = series.latex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch series.seriesKind {
        case .region:
            return latex.isEmpty ? .curve : .region(latex)
        case .level:
            let levels = (series.levels ?? []).filter(\.isFinite)
            return latex.isEmpty || levels.isEmpty ? .curve : .level(latex, levels)
        case .parametric:
            if let x = series.xt?.trimmingCharacters(in: .whitespacesAndNewlines), let y = series.yt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !x.isEmpty, !y.isEmpty { return .parametric(x, y) }
            if let pair = ChartShapes.parametricPair(latex) { return .parametric(pair.x, pair.y) }
            return .curve
        case .point, .vector, .segment, .angle:
            return .curve
        case .curve:
            guard !latex.isEmpty else { return .curve }
            if ChartShapes.isInequality(latex) { return .region(latex) }
            if let pair = ChartShapes.parametricPair(latex) { return .parametric(pair.x, pair.y) }
            if let restricted = ChartShapes.restrictedEquation(latex) { return .restricted(restricted.equation, restricted.conditions) }
            return .curve
        }
    }

    /// A function or relation as polylines: `y = f(x)` sampled across the window (broken where it is undefined
    /// or jumps across the window — an asymptote); any other equation as the chained zero contour of its residual.
    static func curve(_ rawLatex: String, window: Window, engine: MathEngine) async -> [[[Double]]]? {
        let latex = ChartShapes.normalised(rawLatex)
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let xs = (0...explicitSamples).map { window.x.lowerBound + xSpan * Double($0) / Double(explicitSamples) }
        guard let probe = try? await engine.samples(of: latex, at: xs.map { (x: $0, y: 0) }) else { return nil }
        if probe.explicit {
            var pieces: [[[Double]]] = [], current: [[Double]] = []
            let margin = ySpan * 2
            for (x, value) in zip(xs, probe.values) {
                guard let y = value, y.isFinite, y > window.y.lowerBound - margin, y < window.y.upperBound + margin else {
                    if current.count >= 2 { pieces.append(current) }
                    current = []
                    continue
                }
                if let last = current.last, abs(y - last[1]) > ySpan * 0.9 {
                    if current.count >= 2 { pieces.append(current) }
                    current = []
                }
                current.append([x, y])
            }
            if current.count >= 2 { pieces.append(current) }
            return pieces
        }
        // Implicit: the residual on a grid (one compiled call), contour at zero, chained into polylines.
        return await ChartShapes.relation(latex, window: window, engine: engine)
    }

    /// Zero contour of a residual sampled on an (n+1)×(n+1) grid, as two-point segments.
    static func marchingSquares(values: [Double?], n: Int, window: Window) -> [[[Double]]] {
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        func value(_ i: Int, _ j: Int) -> Double? { values[j * (n + 1) + i] }
        func point(_ i: Double, _ j: Double) -> [Double] {
            [window.x.lowerBound + xSpan * i / Double(n), window.y.lowerBound + ySpan * j / Double(n)]
        }
        var segments: [[[Double]]] = []
        for j in 0..<n {
            for i in 0..<n {
                guard let a = value(i, j), let b = value(i + 1, j), let c = value(i + 1, j + 1), let d = value(i, j + 1) else { continue }
                // Crossings on the four edges (bottom, right, top, left), interpolated.
                var crossings: [[Double]] = []
                func edge(_ v0: Double, _ v1: Double, _ p0: (Double, Double), _ p1: (Double, Double)) {
                    guard (v0 < 0) != (v1 < 0), v0 != v1 else { return }
                    let t = v0 / (v0 - v1)
                    crossings.append(point(p0.0 + (p1.0 - p0.0) * t, p0.1 + (p1.1 - p0.1) * t))
                }
                let fi = Double(i), fj = Double(j)
                edge(a, b, (fi, fj), (fi + 1, fj))
                edge(b, c, (fi + 1, fj), (fi + 1, fj + 1))
                edge(c, d, (fi + 1, fj + 1), (fi, fj + 1))
                edge(d, a, (fi, fj + 1), (fi, fj))
                // A sign change across a pole (1/x) is not a crossing: skip cells whose values are huge.
                let magnitude = max(abs(a), abs(b), abs(c), abs(d))
                guard magnitude.isFinite, magnitude < 1e6 else { continue }
                if crossings.count == 2 { segments.append(crossings) }
                else if crossings.count == 4 { segments.append([crossings[0], crossings[1]]); segments.append([crossings[2], crossings[3]]) }
            }
        }
        return segments
    }

    /// An integrated solution split where it leaves the window by far (the part beyond is never drawn).
    static func split(_ path: [[Double]], window: Window) -> [[[Double]]] {
        let margin = (window.y.upperBound - window.y.lowerBound) * 0.5
        var pieces: [[[Double]]] = [], current: [[Double]] = []
        for p in path where p.count >= 2 {
            if p[1] < window.y.lowerBound - margin || p[1] > window.y.upperBound + margin {
                if current.count >= 2 { pieces.append(current) }
                current = []
            } else {
                current.append(p)
            }
        }
        if current.count >= 2 { pieces.append(current) }
        return pieces
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
