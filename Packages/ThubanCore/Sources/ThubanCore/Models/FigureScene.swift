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

    /// One series as drawn: polylines (a curve may break at a gap or asymptote), dots, or bars.
    public struct Mark: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case line, dots, bars }
        public var kind: Kind
        public var name: String
        /// Polylines, each `[[x, y], …]`; for dots and bars one list of points.
        public var pieces: [[[Double]]]
        public var style: LineStyle
        /// Hex colour from the chart, or nil for the theme palette.
        public var color: String?
        /// Position among the chart's series (picks the palette colour).
        public var paletteIndex: Int
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
                Mark(kind: kind, name: series.name, pieces: pieces, style: style, color: series.color?.nilIfBlank, paletteIndex: index)
            }
            if let latex = series.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty {
                if let pieces = await curve(latex, window: window, engine: engine), !pieces.isEmpty { marks.append(mark(.line, pieces)) }
                continue
            }
            let points = (series.points ?? []).filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
            if !points.isEmpty {
                switch chart.chartType {
                case "scatter": marks.append(mark(.dots, [points]))
                case "bar", "histogram": marks.append(mark(.bars, [points]))
                default:
                    if points.count == 1 { marks.append(mark(.dots, [points])) }
                    else { marks.append(mark(.line, [ChartGeometry.smoothed(points)])) }
                }
                continue
            }
            if let slope, !slope.isEmpty, chart.fieldFromPicture != true, let start = series.throughPoint,
               let path = try? await engine.integrateSlope(slope, through: start, xRange: window.x, yRange: window.y, steps: 800), path.count >= 2 {
                marks.append(mark(.line, split(path, window: window)))
            }
        }

        return FigureScene(window: window, xStep: xStep, yStep: yStep, xLabel: chart.xLabel?.nilIfBlank, yLabel: chart.yLabel?.nilIfBlank,
                           arrows: arrows, arrowheads: chart.arrows, fieldColumns: columnsDrawn, fieldRows: rowsDrawn, marks: marks,
                           xTickLabels: chart.xAxisLabels, yTickLabels: chart.yAxisLabels)
    }

    /// A function or relation as polylines: `y = f(x)` sampled across the window (broken where it is undefined
    /// or jumps across the window — an asymptote); any other equation by marching squares on its residual.
    static func curve(_ latex: String, window: Window, engine: MathEngine) async -> [[[Double]]]? {
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
        // Implicit: residual on a grid, contour at zero.
        let n = implicitGrid
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n { for i in 0...n {
            points.append((window.x.lowerBound + xSpan * Double(i) / Double(n), window.y.lowerBound + ySpan * Double(j) / Double(n)))
        } }
        guard let grid = try? await engine.samples(of: latex, at: points) else { return nil }
        return marchingSquares(values: grid.values, n: n, window: window)
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
