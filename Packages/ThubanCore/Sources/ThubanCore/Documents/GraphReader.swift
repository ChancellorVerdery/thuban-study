import Foundation
import CoreGraphics
import Vision

/// Reads a plotted figure from its pixels: where the axes are, how pixel rows and columns map to data values
/// (from the tick labels, recognised with Vision), and every curve drawn in a colour other than the ink of the
/// axes and the grey of a field. The figure agent describes the picture; this is how the app checks the
/// description against the picture itself (`FigureReconciler`) instead of against the agent's own readings.
///
/// It is built for course-material plots — black axes, numeric tick labels, coloured curves on white — and gives
/// up (returns nil) on anything else, so nothing downstream depends on it.
public struct GraphReading: Sendable {
    /// Pixel ↔ data mapping for one axis: `pixel = origin + scale × value`.
    public struct AxisMap: Sendable, Equatable {
        public var origin: Double
        public var scale: Double
        /// How many recognised labels the fit used (0 = the agent's window was mapped onto the axis line).
        public var labelCount: Int
        /// Pixel extent of the axis line (first … last pixel along it).
        public var extent: ClosedRange<Double>

        public func pixel(_ value: Double) -> Double { origin + scale * value }
        public func value(_ pixel: Double) -> Double { (pixel - origin) / scale }
        /// Data window covered by the axis line.
        public var range: ClosedRange<Double> {
            let a = value(extent.lowerBound), b = value(extent.upperBound)
            return min(a, b)...max(a, b)
        }
    }

    /// One coloured curve: its pixels by column and a polyline through them in data coordinates.
    public struct Curve: Sendable {
        /// A colour name for series names and notes ("blue", "red").
        public var color: String
        /// Rows occupied in each column (sorted).
        public var rows: [Int: [Int]]
        public var pixelCount: Int
        /// The curve as `[[x, y], …]` in data coordinates, left to right, at most ~80 points.
        public var points: [[Double]]

        public var columns: ClosedRange<Int>? {
            guard let lo = rows.keys.min(), let hi = rows.keys.max() else { return nil }
            return lo...hi
        }
    }

    public var width: Int
    public var height: Int
    public var x: AxisMap
    public var y: AxisMap
    public var curves: [Curve]

    /// Column and row of the data origin.
    public var originColumn: Double { x.pixel(0) }
    public var originRow: Double { y.pixel(0) }

    public func pixel(x value: Double, y valueY: Double) -> (column: Double, row: Double) {
        (x.pixel(value), y.pixel(valueY))
    }

    public func data(column: Double, row: Double) -> (x: Double, y: Double) {
        (x.value(column), y.value(row))
    }

    /// Whether both axes were calibrated from recognised labels (the agent's window was not needed).
    public var isCalibratedFromLabels: Bool { x.labelCount >= 1 && y.labelCount >= 1 }
}

public enum GraphReader {
    /// Minimum pixels for a colour cluster to count as a curve.
    static let minimumCurvePixels = 40
    /// A colour cluster whose median column holds more pixels than this is an area (a field of coloured arrows,
    /// shading), not a curve.
    static let maximumCurveThickness = 7
    /// A dark run this fraction of the image's side or longer is an axis or frame line.
    static let axisRunFraction = 0.35

    /// The reading, or nil when no axes could be found. `hints` supplies the agent's window and tick spacing
    /// for axes without recognisable labels.
    public static func read(png: Data, hints: StandardChart? = nil) async -> GraphReading? {
        guard let image = ImageCodec.image(from: png), let bitmap = Bitmap(image: image) else { return nil }
        let horizontals = longRuns(bitmap, horizontal: true)
        let verticals = longRuns(bitmap, horizontal: false)
        guard !horizontals.isEmpty, !verticals.isEmpty else { return nil }
        let labels = (try? await recognizeLabels(in: image, horizontals: horizontals, verticals: verticals)) ?? []
        return try? await ParserSupport.offloaded {
            read(bitmap: bitmap, horizontals: horizontals, verticals: verticals, labels: labels, hints: hints)
        }
    }

    /// What the reader saw, for development: the long lines, the recognised labels, the tick marks.
    public static func diagnose(png: Data) async -> String {
        guard let image = ImageCodec.image(from: png), let bitmap = Bitmap(image: image) else { return "undecodable" }
        let horizontals = longRuns(bitmap, horizontal: true)
        let verticals = longRuns(bitmap, horizontal: false)
        let labels = (try? await recognizeLabels(in: image, horizontals: horizontals, verticals: verticals)) ?? []
        let h = horizontals.map { "row \($0.position) [\($0.start)…\($0.end)] ticks \(tickPositions(bitmap, along: $0, horizontal: true))" }
        let v = verticals.map { "col \($0.position) [\($0.start)…\($0.end)] ticks \(tickPositions(bitmap, along: $0, horizontal: false))" }
        let l = labels.map { "\($0.value)@(\(Int($0.column)),\(Int($0.row)))" }
        let g = "gridrows \(gridLines(bitmap, horizontal: true)) gridcols \(gridLines(bitmap, horizontal: false))"
        var chosen = "none"
        if let axes = chooseAxes(horizontals: horizontals, verticals: verticals, labels: labels, bitmap: bitmap) {
            chosen = "x-axis row \(axes.0.position), y-axis col \(axes.1.position), x labels \(axes.2.map { "\($0.value)@\(Int($0.column))" }), y labels \(axes.3.map { "\($0.value)@\(Int($0.row))" })"
        }
        return "horizontal: \(h.joined(separator: ", ")) | vertical: \(v.joined(separator: ", ")) | labels: \(l.joined(separator: " ")) | \(g) | chosen: \(chosen)"
    }

    // MARK: - Pixels

    /// 8-bit RGBA pixels, row-major, top row first.
    struct Bitmap: @unchecked Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(image: CGImage) {
            guard let context = ImageCodec.rgbaContext(width: image.width, height: image.height) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else { return nil }
            width = image.width
            height = image.height
            let stride = context.bytesPerRow
            var out = [UInt8](repeating: 0, count: width * height * 4)
            let source = data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let from = row * stride
                out.replaceSubrange((row * width * 4)..<((row + 1) * width * 4), with: UnsafeBufferPointer(start: source + from, count: width * 4))
            }
            pixels = out
        }

        @inline(__always) func rgb(_ column: Int, _ row: Int) -> (r: Int, g: Int, b: Int) {
            let i = (row * width + column) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }

        /// Ink: dark and unsaturated (axes, ticks, labels, frame).
        @inline(__always) func isInk(_ column: Int, _ row: Int) -> Bool {
            let p = rgb(column, row)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            return hi < 110 && hi - lo < 60
        }

        /// Light grey (a gridline), neither white nor ink nor colour.
        @inline(__always) func isGrid(_ column: Int, _ row: Int) -> Bool {
            let p = rgb(column, row)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            return hi >= 150 && hi <= 240 && hi - lo < 25
        }

        /// A saturated pixel's hue bin (0–11, 30° each), or nil for white/grey/black.
        @inline(__always) func hueBin(_ column: Int, _ row: Int) -> Int? {
            let p = rgb(column, row)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            guard hi - lo > 60, hi > 70 else { return nil }
            let d = Double(hi - lo)
            var hue: Double
            if hi == p.r { hue = 60 * (Double(p.g - p.b) / d) }
            else if hi == p.g { hue = 60 * (2 + Double(p.b - p.r) / d) }
            else { hue = 60 * (4 + Double(p.r - p.g) / d) }
            if hue < 0 { hue += 360 }
            return min(11, Int(hue / 30))
        }
    }

    // MARK: - Reading

    struct Label: Sendable {
        var value: Double
        var column: Double
        var row: Double
    }

    struct Line { var position: Int; var start: Int; var end: Int }

    static func read(bitmap: Bitmap, horizontals: [Line], verticals: [Line], labels: [Label], hints: StandardChart?) -> GraphReading? {
        guard !horizontals.isEmpty, !verticals.isEmpty else { return nil }
        guard let (xAxis, yAxis, rawXLabels, rawYLabels) = chooseAxes(horizontals: horizontals, verticals: verticals, labels: labels, bitmap: bitmap) else { return nil }

        // Tick marks on the axis, or gridlines across the plot, paired in order with the tick values the agent
        // read, calibrate an axis whose labels the recogniser could not read.
        // Gridlines and dashed/solid coloured lines across the plot (an asymptote at y = 1 sits exactly at the
        // level its label names) are where labels snap to, alongside tick marks.
        let xMarks = bestTicks(horizontals.map { tickPositions(bitmap, along: $0, horizontal: true) })
        let yMarks = bestTicks(verticals.map { tickPositions(bitmap, along: $0, horizontal: false) })
        let xGrid = gridLines(bitmap, horizontal: false) + colouredLines(bitmap, horizontal: false)
        let yGrid = gridLines(bitmap, horizontal: true) + colouredLines(bitmap, horizontal: true)
        let xTicks = paired(values: hints?.xTicks, positions: xMarks, gridlines: xGrid, ascending: true)
        let yTicks = paired(values: hints?.yTicks, positions: yMarks, gridlines: yGrid, ascending: false)
        // A label is printed beside its tick, not on it: snap each to the nearest mark or gridline.
        let xLabels = snapped(rawXLabels, to: xMarks + xGrid, along: \.column)
        let yLabels = snapped(rawYLabels, to: yMarks + yGrid, along: \.row)

        var x = axisMap(labels: xLabels, ticks: xTicks, axisPixel: Double(yAxis.position), extent: Double(xAxis.start)...Double(xAxis.end),
                        window: hints?.xRange, ascending: true)
        var y = axisMap(labels: yLabels, ticks: yTicks, axisPixel: Double(xAxis.position), extent: Double(yAxis.start)...Double(yAxis.end),
                        window: hints?.yRange, ascending: false)
        // An axis with no labels at all takes the other axis's scale (course plots are drawn to equal scales)
        // when that one was read from labels; the agent's window is used only when neither axis has labels.
        if let yy = y, yy.labelCount >= 1, x == nil || (x!.labelCount == 0 && yy.labelCount >= 2) {
            x = GraphReading.AxisMap(origin: Double(yAxis.position), scale: abs(yy.scale), labelCount: 0, extent: Double(xAxis.start)...Double(xAxis.end))
        }
        if let xx = x, xx.labelCount >= 1, y == nil || (y!.labelCount == 0 && xx.labelCount >= 2) {
            y = GraphReading.AxisMap(origin: Double(xAxis.position), scale: -abs(xx.scale), labelCount: 0, extent: Double(yAxis.start)...Double(yAxis.end))
        }
        guard let x, let y else { return nil }
        let reading = GraphReading(width: bitmap.width, height: bitmap.height, x: x, y: y, curves: [])
        let curves = extractCurves(bitmap, reading: reading)
        return GraphReading(width: bitmap.width, height: bitmap.height, x: x, y: y, curves: curves)
    }

    /// Rows (or columns) holding an ink run at least `axisRunFraction` of the image; adjacent ones merge into one
    /// line (a 2-px axis is one line).
    static func longRuns(_ bitmap: Bitmap, horizontal: Bool) -> [Line] {
        let outer = horizontal ? bitmap.height : bitmap.width
        let inner = horizontal ? bitmap.width : bitmap.height
        let minimum = Int(Double(inner) * axisRunFraction)
        var lines: [Line] = []
        for p in 0..<outer {
            var best = (start: 0, end: -1)
            var runStart = -1
            for q in 0...inner {
                let ink = q < inner && (horizontal ? bitmap.isInk(q, p) : bitmap.isInk(p, q))
                if ink { if runStart < 0 { runStart = q } }
                else if runStart >= 0 {
                    // Tolerate short gaps: a coloured curve crossing the axis, a dashed crossing, anti-aliasing.
                    let gapEnd = min(inner, q + 7)
                    var bridged = false
                    if q + 1 < inner {
                        for r in (q + 1)..<gapEnd where (horizontal ? bitmap.isInk(r, p) : bitmap.isInk(p, r)) { bridged = true; break }
                    }
                    if bridged { continue }
                    if q - runStart > best.end - best.start { best = (runStart, q - 1) }
                    runStart = -1
                }
            }
            if best.end - best.start + 1 >= minimum {
                if let last = lines.last, p - last.position <= 2 {
                    lines[lines.count - 1] = Line(position: last.position, start: min(last.start, best.start), end: max(last.end, best.end))
                } else {
                    lines.append(Line(position: p, start: best.start, end: best.end))
                }
            }
        }
        return lines
    }

    /// Picks the x-axis row and y-axis column among the long lines: the pair that the most numeric labels fit.
    /// Labels left or right of a vertical line belong to the y-axis when they are nearer to it than to the
    /// horizontal line, and vice versa.
    static func chooseAxes(horizontals: [Line], verticals: [Line], labels: [Label], bitmap: Bitmap) -> (Line, Line, [Label], [Label])? {
        var best: (score: Double, x: Line, y: Line, xl: [Label], yl: [Label])?
        for h in horizontals {
            for v in verticals {
                var xl: [Label] = [], yl: [Label] = []
                let near = Double(max(bitmap.width, bitmap.height)) * 0.12
                for label in labels {
                    let dv = abs(label.column - Double(v.position)), dh = abs(label.row - Double(h.position))
                    // A y label sits beside the y-axis, or outside the plot to its left/right, within the axis's
                    // rows; an x label sits beside the x-axis, or outside the plot below/above, within its columns.
                    let inRows = label.row >= Double(v.start) - 10 && label.row <= Double(v.end) + 10
                    let inColumns = label.column >= Double(h.start) - 10 && label.column <= Double(h.end) + 10
                    let outsideH = label.column < Double(h.start) + 4 || label.column > Double(h.end) - 4
                    let outsideV = label.row < Double(v.start) + 4 || label.row > Double(v.end) - 4
                    // Outside the plot, a label belongs to the axis it runs along; inside, to the nearer axis.
                    if outsideH, inRows { yl.append(label) }
                    else if outsideV, inColumns { xl.append(label) }
                    else if dv <= near, dh <= near {
                        if dv / Double(bitmap.width) <= dh / Double(bitmap.height) { yl.append(label) } else { xl.append(label) }
                    } else if dv <= near, inRows { yl.append(label) }
                    else if dh <= near, inColumns { xl.append(label) }
                }
                xl = signed(xl, crossing: Double(v.position), along: \.column, negativeBelow: true)
                yl = signed(yl, crossing: Double(h.position), along: \.row, negativeBelow: false)
                let xKept = consistent(xl, along: \.column), yKept = consistent(yl, along: \.row)
                // The axes are the lines through the labels' zero: the x-axis sits where the y labels say y = 0,
                // the y-axis where the x labels say x = 0. Without such a fit, the line nearer the middle of the
                // image beats a frame line at its edge.
                var misplacement = 0.0
                if yKept.count >= 2, let fit = leastSquares(yKept.map { ($0.value, $0.row) }) {
                    misplacement += abs(fit.origin - Double(h.position))
                } else {
                    misplacement += abs(Double(h.position) - Double(bitmap.height) / 2) * 0.5
                }
                if xKept.count >= 2, let fit = leastSquares(xKept.map { ($0.value, $0.column) }) {
                    misplacement += abs(fit.origin - Double(v.position))
                } else {
                    misplacement += abs(Double(v.position) - Double(bitmap.width) / 2) * 0.5
                }
                let score = Double(xKept.count + yKept.count) * 1000 - misplacement
                if best == nil || score > best!.score { best = (score, h, v, xl, yl) }
            }
        }
        guard let best else { return nil }
        // Keep only labels consistent with the winning fits.
        return (best.x, best.y, consistent(best.xl, along: \.column), consistent(best.yl, along: \.row))
    }

    /// Number of labels a linear fit explains (values must be monotonic in pixels).
    static func fitQuality(_ labels: [Label], along key: KeyPath<Label, Double>) -> Double {
        let kept = consistent(labels, along: key)
        return Double(kept.count)
    }

    /// Keeps the largest set of labels that lie on one straight line (value ↔ pixel): the line through every
    /// pair is tried and the one with the most labels within tolerance wins, so a single misread label — even
    /// a far-off one that would drag a least-squares fit — cannot take the others down with it.
    static func consistent(_ labels: [Label], along key: KeyPath<Label, Double>) -> [Label] {
        guard labels.count >= 3 else {
            if labels.count == 2, labels[0].value == labels[1].value { return [labels[0]] }
            return labels
        }
        let pixels = labels.map { $0[keyPath: key] }
        let tolerance = max(3.0, 0.02 * (pixels.max()! - pixels.min()!))
        var best: [Label] = []
        for i in 0..<labels.count {
            for j in (i + 1)..<labels.count where labels[i].value != labels[j].value {
                let scale = (labels[j][keyPath: key] - labels[i][keyPath: key]) / (labels[j].value - labels[i].value)
                let origin = labels[i][keyPath: key] - scale * labels[i].value
                guard abs(scale) >= 0.5 else { continue }
                var inliers: [Label] = []
                var seen: Set<Double> = []
                for label in labels where abs(origin + scale * label.value - label[keyPath: key]) <= tolerance && !seen.contains(label.value) {
                    inliers.append(label)
                    seen.insert(label.value)
                }
                if inliers.count > best.count { best = inliers }
            }
        }
        return best.count >= 2 ? best : []
    }

    /// Short ink marks crossing the axis line (tick marks), as positions along it. A mark is 2–12 px of ink on
    /// at least one side of the line, at a position where the ink does not continue further (that would be the
    /// other axis, or a frame).
    static func tickPositions(_ bitmap: Bitmap, along axis: Line, horizontal: Bool) -> [Double] {
        var marks: [Int] = []
        let across = horizontal ? bitmap.height : bitmap.width
        for q in axis.start...axis.end {
            func ink(_ offset: Int) -> Bool {
                let p = axis.position + offset
                guard p >= 0, p < across else { return false }
                return horizontal ? bitmap.isInk(q, p) : bitmap.isInk(p, q)
            }
            var below = 0, above = 0
            var k = 1
            while k <= 14, ink(k) { below += 1; k += 1 }
            k = 1
            while k <= 14, ink(-k) { above += 1; k += 1 }
            let longest = max(below, above)
            guard longest >= 2, longest <= 12 else { continue }
            marks.append(q)
        }
        // A 2-px-wide mark gives adjacent positions; merge them.
        var merged: [Double] = []
        var run: [Int] = []
        for m in marks {
            if let last = run.last, m - last > 2 { merged.append(Double(run.reduce(0, +)) / Double(run.count)); run = [] }
            run.append(m)
        }
        if !run.isEmpty { merged.append(Double(run.reduce(0, +)) / Double(run.count)) }
        return merged
    }

    /// Of several lines' tick marks, the set that looks most like ticks: at least two, evenly spaced (a frame
    /// edge with a dense comb of marks is a hatched border, not ticks).
    static func bestTicks(_ candidates: [[Double]]) -> [Double] {
        var best: [Double] = []
        for marks in candidates where marks.count >= 2 && marks.count <= 40 {
            let gaps = zip(marks, marks.dropFirst()).map { $1 - $0 }
            guard let smallest = gaps.min(), smallest >= 6 else { continue }
            let median = gaps.sorted()[gaps.count / 2]
            let even = gaps.allSatisfy { abs($0 - median) <= max(2, median * 0.15) || abs($0 - 2 * median) <= max(2, median * 0.2) }
            guard even else { continue }
            if marks.count > best.count { best = marks }
        }
        return best
    }

    /// Rows (or columns) that are a light-grey line across most of the plot: gridlines, as positions.
    static func gridLines(_ bitmap: Bitmap, horizontal: Bool) -> [Double] {
        let outer = horizontal ? bitmap.height : bitmap.width
        let inner = horizontal ? bitmap.width : bitmap.height
        var positions: [Double] = []
        var run: [Int] = []
        for p in 0..<outer {
            var grey = 0
            for q in 0..<inner where (horizontal ? bitmap.isGrid(q, p) : bitmap.isGrid(p, q)) { grey += 1 }
            if Double(grey) >= Double(inner) * 0.5 {
                if let last = run.last, p - last > 1 { positions.append(Double(run.reduce(0, +)) / Double(run.count)); run = [] }
                run.append(p)
            }
        }
        if !run.isEmpty { positions.append(Double(run.reduce(0, +)) / Double(run.count)) }
        return positions
    }

    /// Rows (or columns) where one colour runs across at least a third of the plot: a drawn horizontal (or
    /// vertical) line such as a dashed asymptote, as positions.
    static func colouredLines(_ bitmap: Bitmap, horizontal: Bool) -> [Double] {
        let outer = horizontal ? bitmap.height : bitmap.width
        let inner = horizontal ? bitmap.width : bitmap.height
        var positions: [Double] = []
        var run: [Int] = []
        for p in 0..<outer {
            var bins = [Int](repeating: 0, count: 12)
            for q in 0..<inner {
                if let bin = horizontal ? bitmap.hueBin(q, p) : bitmap.hueBin(p, q) { bins[bin] += 1 }
            }
            if Double(bins.max() ?? 0) >= Double(inner) * 0.2 {
                if let last = run.last, p - last > 1 { positions.append(Double(run.reduce(0, +)) / Double(run.count)); run = [] }
                run.append(p)
            }
        }
        if !run.isEmpty { positions.append(Double(run.reduce(0, +)) / Double(run.count)) }
        return positions
    }

    /// Pairs the agent's tick values (in printed order) with detected tick marks or gridlines when the counts
    /// agree; nil otherwise.
    static func paired(values: [Double]?, positions: [Double], gridlines: [Double], ascending: Bool) -> [(value: Double, pixel: Double)]? {
        guard let values, values.count >= 2 else { return nil }
        // Printed order is left→right (ascending pixel) for x and top→bottom (ascending pixel) for y.
        for candidates in [positions.sorted(), gridlines.sorted()] where candidates.count == values.count {
            let pairs = zip(values, candidates).map { (value: $0, pixel: $1) }
            // Values must run in a consistent direction along the axis.
            let increasing = zip(pairs, pairs.dropFirst()).allSatisfy { $1.value > $0.value }
            let decreasing = zip(pairs, pairs.dropFirst()).allSatisfy { $1.value < $0.value }
            if ascending ? increasing : decreasing { return pairs }
        }
        return nil
    }

    /// `pixel = origin + scale × value` through the label positions (least squares), else through the agent's tick
    /// values paired with the tick marks, else through one label and the axis crossing (value 0), else — with no
    /// labels — the agent's window stretched over the axis line.
    static func axisMap(labels: [Label], ticks: [(value: Double, pixel: Double)]?, axisPixel: Double, extent: ClosedRange<Double>, window: [Double]?, ascending: Bool) -> GraphReading.AxisMap? {
        let key: KeyPath<Label, Double> = ascending ? \.column : \.row
        let distinct = Dictionary(grouping: labels, by: \.value).compactMap { $0.value.first }
        if distinct.count >= 2, let fit = leastSquares(distinct.map { ($0.value, $0[keyPath: key]) }),
           (ascending ? fit.scale > 0 : fit.scale < 0) {
            return GraphReading.AxisMap(origin: fit.origin, scale: fit.scale, labelCount: distinct.count, extent: extent)
        }
        if let ticks, let fit = leastSquares(ticks), (ascending ? fit.scale > 0 : fit.scale < 0) {
            return GraphReading.AxisMap(origin: fit.origin, scale: fit.scale, labelCount: ticks.count, extent: extent)
        }
        if let one = distinct.first, one.value != 0, abs(one[keyPath: key] - axisPixel) > 3 {
            let scale = (one[keyPath: key] - axisPixel) / one.value
            if ascending ? scale > 0 : scale < 0 {
                return GraphReading.AxisMap(origin: axisPixel, scale: scale, labelCount: 1, extent: extent)
            }
        }
        if let window, window.count == 2, window[1] > window[0] {
            let span = extent.upperBound - extent.lowerBound
            guard span > 0 else { return nil }
            // The window is what the axis line spans; the crossing may not be at 0 (an offset window), so map
            // the ends rather than the origin.
            let scale = (ascending ? 1 : -1) * span / (window[1] - window[0])
            let origin = ascending ? extent.lowerBound - scale * window[0] : extent.upperBound - scale * window[0]
            return GraphReading.AxisMap(origin: origin, scale: scale, labelCount: 0, extent: extent)
        }
        return nil
    }

    /// A positive label on the negative side of the crossing (left of the y-axis, below the x-axis) whose
    /// magnitude also appears on the positive side lost its minus sign in recognition; give it back. Labels a
    /// hair from the crossing are left alone.
    static func signed(_ labels: [Label], crossing: Double, along key: KeyPath<Label, Double>, negativeBelow: Bool) -> [Label] {
        let magnitudes = Set(labels.map { abs($0.value) })
        return labels.map { label in
            guard label.value > 0, magnitudes.contains(label.value) else { return label }
            let offset = label[keyPath: key] - crossing
            let onNegativeSide = negativeBelow ? offset < -6 : offset > 6
            guard onNegativeSide, labels.contains(where: { $0.value == label.value && (negativeBelow ? $0[keyPath: key] - crossing > 6 : $0[keyPath: key] - crossing < -6) }) else { return label }
            var flipped = label
            flipped.value = -label.value
            return flipped
        }
    }

    /// Moves each label to the nearest tick mark or gridline within a label's height, when there is one.
    static func snapped(_ labels: [Label], to marks: [Double], along key: WritableKeyPath<Label, Double>) -> [Label] {
        guard !marks.isEmpty else { return labels }
        return labels.map { label in
            var moved = label
            if let nearest = marks.min(by: { abs($0 - label[keyPath: key]) < abs($1 - label[keyPath: key]) }), abs(nearest - label[keyPath: key]) <= 18 {
                moved[keyPath: key] = nearest
            }
            return moved
        }
    }

    static func leastSquares(_ pairs: [(value: Double, pixel: Double)]) -> (origin: Double, scale: Double)? {
        let n = Double(pairs.count)
        guard n >= 2 else { return nil }
        let sx = pairs.reduce(0) { $0 + $1.value }, sy = pairs.reduce(0) { $0 + $1.pixel }
        let sxx = pairs.reduce(0) { $0 + $1.value * $1.value }, sxy = pairs.reduce(0) { $0 + $1.value * $1.pixel }
        let denominator = n * sxx - sx * sx
        guard abs(denominator) > 1e-9 else { return nil }
        let scale = (n * sxy - sx * sy) / denominator
        let origin = (sy - scale * sx) / n
        // Fewer than a pixel per unit, or more than the image can hold, is a misread, not a scale.
        guard scale.isFinite, origin.isFinite, abs(scale) >= 0.5, abs(scale) <= 5000, abs(origin) <= 100_000 else { return nil }
        return (origin, scale)
    }

    // MARK: - Curves

    /// Colour names by 30° hue bin, coarse enough that a plotting library's "blue" (around 205°) and a pure
    /// blue (240°) share a name.
    static let hueNames = ["red", "orange", "yellow", "green", "green", "teal", "blue", "blue", "blue", "purple", "purple", "pink"]

    /// Coloured pixels grouped by hue; each group thin enough to be a line becomes a curve.
    static func extractCurves(_ bitmap: Bitmap, reading: GraphReading) -> [GraphReading.Curve] {
        var byBin: [Int: [Int: [Int]]] = [:]
        var counts = [Int](repeating: 0, count: 12)
        for row in 0..<bitmap.height {
            for column in 0..<bitmap.width {
                guard let bin = bitmap.hueBin(column, row) else { continue }
                byBin[bin, default: [:]][column, default: []].append(row)
                counts[bin] += 1
            }
        }
        // Merge a small bin into a bigger neighbour (anti-aliased edges drift a bin over).
        var groups: [[Int]] = []
        var assigned = [Int](repeating: -1, count: 12)
        for bin in (0..<12).sorted(by: { counts[$0] > counts[$1] }) where counts[bin] > 0 {
            if assigned[bin] >= 0 { continue }
            var group = [bin]
            assigned[bin] = groups.count
            for neighbour in [(bin + 11) % 12, (bin + 1) % 12] where assigned[neighbour] < 0 && counts[neighbour] > 0 && counts[neighbour] < counts[bin] / 3 {
                group.append(neighbour)
                assigned[neighbour] = groups.count
            }
            groups.append(group)
        }
        var curves: [GraphReading.Curve] = []
        for group in groups {
            var rows: [Int: [Int]] = [:]
            var total = 0
            for bin in group {
                for (column, list) in byBin[bin] ?? [:] {
                    rows[column, default: []].append(contentsOf: list)
                    total += list.count
                }
            }
            guard total >= minimumCurvePixels else { continue }
            for column in rows.keys { rows[column]!.sort() }
            let perColumn = rows.values.map(\.count).sorted()
            let median = perColumn[perColumn.count / 2]
            guard median <= maximumCurveThickness else { continue }
            let name = hueNames[group[0]]
            curves.append(GraphReading.Curve(color: name, rows: rows, pixelCount: total, points: polyline(rows, reading: reading)))
        }
        return curves.sorted { $0.pixelCount > $1.pixelCount }
    }

    /// A left-to-right polyline through the pixels: one point per column at the median row, two where the run
    /// is tall (a steep part or an asymptote), thinned to about 80 points.
    static func polyline(_ rows: [Int: [Int]], reading: GraphReading) -> [[Double]] {
        let columns = rows.keys.sorted()
        guard !columns.isEmpty else { return [] }
        var pixels: [(Double, Double)] = []
        var previous: Double?
        for column in columns {
            let list = rows[column]!
            let top = Double(list.first!), bottom = Double(list.last!)
            if bottom - top > 10 {
                let first = (previous ?? top) - top <= abs((previous ?? top) - bottom) ? top : bottom
                let second = first == top ? bottom : top
                pixels.append((Double(column), first))
                pixels.append((Double(column), second))
                previous = second
            } else {
                let mid = Double(list[list.count / 2])
                pixels.append((Double(column), mid))
                previous = mid
            }
        }
        let stride = max(1, pixels.count / 80)
        var kept: [(Double, Double)] = []
        for (index, point) in pixels.enumerated() where index % stride == 0 || index == pixels.count - 1 {
            kept.append(point)
        }
        return kept.map { point in
            let data = reading.data(column: point.0, row: point.1)
            return [round4(data.x), round4(data.y)]
        }
    }

    static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    // MARK: - Matching

    /// How well a curve in data coordinates (dense, left to right) follows a pixel curve: the fraction of its
    /// samples over the curve's own columns that land within `tolerance` pixels of the ink (a drawn curve stops
    /// at the frame; the prediction need not), and the fraction of the curve's columns that the samples come near.
    public static func match(_ points: [[Double]], to curve: GraphReading.Curve, in reading: GraphReading, tolerance: Double? = nil)
        -> (fit: Double, coverage: Double) {
        let tolerance = tolerance ?? max(3, Double(reading.height) * 0.015)
        guard let span = curve.columns else { return (0, 0) }
        var inside = 0, near = 0
        var covered: Set<Int> = []
        for point in points where point.count >= 2 {
            let p = reading.pixel(x: point[0], y: point[1])
            guard p.column >= Double(span.lowerBound) - 2, p.column <= Double(span.upperBound) + 2,
                  p.row >= 0, p.row < Double(reading.height) else { continue }
            inside += 1
            let column = Int(p.column.rounded())
            var best = Double.infinity
            for c in (column - 2)...(column + 2) {
                guard let list = curve.rows[c] else { continue }
                for r in list { best = min(best, abs(Double(r) - p.row)) }
            }
            if best <= tolerance {
                near += 1
                for c in (column - 2)...(column + 2) where curve.rows[c] != nil { covered.insert(c) }
            }
        }
        let fit = inside == 0 ? 0 : Double(near) / Double(inside)
        let coverage = curve.rows.isEmpty ? 0 : Double(covered.count) / Double(curve.rows.count)
        return (fit, coverage)
    }

    // MARK: - Labels

    /// Numeric tick labels with their centres in image pixels (top-left origin): the whole image, then the strips
    /// beside every long line (where tick labels sit), each magnified for the recogniser.
    static func recognizeLabels(in image: CGImage, horizontals: [Line], verticals: [Line]) async throws -> [Label] {
        var labels = try await recognizeLabels(in: image, region: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let band = max(24, image.width / 8)
        var strips: [CGRect] = []
        for v in verticals {
            strips.append(CGRect(x: v.position - band, y: 0, width: band - 2, height: image.height))
            strips.append(CGRect(x: v.position + 3, y: 0, width: band - 2, height: image.height))
        }
        for h in horizontals {
            strips.append(CGRect(x: 0, y: h.position + 3, width: image.width, height: band - 2))
            strips.append(CGRect(x: 0, y: h.position - band, width: image.width, height: band - 2))
        }
        for strip in strips {
            let clipped = strip.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard clipped.width >= 8, clipped.height >= 8 else { continue }
            for label in try await recognizeLabels(in: image, region: clipped)
            where !labels.contains(where: { $0.value == label.value && abs($0.column - label.column) < 6 && abs($0.row - label.row) < 6 }) {
                labels.append(label)
            }
        }
        return labels
    }

    /// Labels inside `region` (image pixels, top-left origin), magnified ×4 for the recogniser.
    static func recognizeLabels(in image: CGImage, region: CGRect) async throws -> [Label] {
        guard let cropped = image.cropping(to: region) else { return [] }
        let factor = max(1, min(4, 1200 / max(cropped.width, cropped.height)))
        let target: CGImage = {
            guard factor > 1, let context = ImageCodec.rgbaContext(width: cropped.width * factor, height: cropped.height * factor) else { return cropped }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width * factor, height: cropped.height * factor))
            return context.makeImage() ?? cropped
        }()
        let width = Double(cropped.width), height = Double(cropped.height)
        return try await ParserSupport.offloaded {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01
            let handler = VNImageRequestHandler(cgImage: target, options: [:])
            try handler.perform([request])
            var labels: [Label] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, let value = numeric(candidate.string) else { continue }
                let box = observation.boundingBox
                labels.append(Label(value: value, column: region.minX + box.midX * width, row: region.minY + (1 - box.midY) * height))
            }
            return labels
        }
    }

    /// "−2.2", "-12", "0", "1.7" → the number; anything else nil.
    static func numeric(_ text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for minus in ["−", "–", "—", "‐"] { cleaned = cleaned.replacingOccurrences(of: minus, with: "-") }
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        if cleaned == "O" || cleaned == "o" { cleaned = "0" }
        guard !cleaned.isEmpty, cleaned.count <= 8,
              cleaned.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "." }),
              cleaned.contains(where: \.isNumber) else { return nil }
        return Double(cleaned)
    }
}
