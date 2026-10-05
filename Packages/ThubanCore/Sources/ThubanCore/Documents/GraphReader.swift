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
        /// The curve as `[[x, y], …]` in data coordinates, left to right.
        public var points: [[Double]]
        /// Drawn dashed (the ink breaks at regular gaps along its span).
        public var dashed: Bool = false

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
    /// How many arrows a drawn slope field has across and down, measured from the periodic pattern of the arrow
    /// ink along each axis; nil when the picture has no such pattern.
    public var fieldColumns: Int?
    public var fieldRows: Int?
    /// The field's arrows as the picture draws them: `[x, y, m]` at each arrow's centre, m its slope.
    public var fieldSamples: [[Double]]?
    /// The labels printed along each axis, as `(value, text)`: numbers as printed ("1.7", "−2.2") and symbols
    /// ("c") at the value their position maps to. Empty when the axis prints none.
    public var xTickLabels: [(value: Double, text: String)] = []
    public var yTickLabels: [(value: Double, text: String)] = []
    /// False when neither axis could be calibrated (no labels, ticks or window): coordinates are then in
    /// arbitrary units of equal scale, fine for tracing a sketch but not for checking numbers.
    public var isCalibrated: Bool = true

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
    /// A colour cluster filling more than this fraction of its bounding box is an area (a field of coloured
    /// arrows, shading), not a curve; a curve, however steep, fills little of its box.
    static let maximumCurveFill = 0.12
    /// A dark run this fraction of the image's side or longer is an axis or frame line.
    static let axisRunFraction = 0.35

    /// The reading, or nil when no axes could be found. `hints` supplies the agent's window and tick spacing
    /// for axes without recognisable labels.
    public static func read(png: Data, hints: StandardChart? = nil) async -> GraphReading? {
        // One picture is read several times while a chart is checked (fitted, verified, re-checked); the reading
        // depends only on the picture and the hints' window and ticks, so it is remembered.
        let key = ReadingCache.key(png: png, hints: hints)
        if let cached = ReadingCache.shared.value(key) { return cached.reading }
        guard let image = ImageCodec.image(from: png), let bitmap = Bitmap(image: image) else { return nil }
        let horizontals = longRuns(bitmap, horizontal: true)
        let verticals = longRuns(bitmap, horizontal: false)
        guard !horizontals.isEmpty, !verticals.isEmpty else { ReadingCache.shared.store(key, nil); return nil }
        let labelKey = ReadingCache.key(png: png, hints: nil) + "|labels"
        let labels: [Label]
        if let cached = ReadingCache.shared.labels(labelKey) { labels = cached }
        else {
            labels = (try? await recognizeLabels(in: image, horizontals: horizontals, verticals: verticals)) ?? []
            ReadingCache.shared.storeLabels(labelKey, labels)
        }
        let reading = try? await ParserSupport.offloaded {
            read(bitmap: bitmap, horizontals: horizontals, verticals: verticals, labels: labels, hints: hints)
        }
        ReadingCache.shared.store(key, reading)
        return reading
    }

    /// Recent readings and recognised labels, by picture (and hints), so a chart's checks read each picture once.
    final class ReadingCache: @unchecked Sendable {
        static let shared = ReadingCache()
        struct Entry { var reading: GraphReading? }
        private let lock = NSLock()
        private var readings: [String: Entry] = [:], order: [String] = []
        private var labelSets: [String: [Label]] = [:], labelOrder: [String] = []
        static let limit = 48

        static func key(png: Data, hints: StandardChart?) -> String {
            var hasher = Hasher()
            hasher.combine(png)
            var key = "\(png.count)-\(hasher.finalize())"
            if let hints {
                key += "|\(hints.xRange ?? [])|\(hints.yRange ?? [])|\(hints.xTicks ?? [])|\(hints.yTicks ?? [])|\(hints.xStep ?? 0)|\(hints.yStep ?? 0)"
            }
            return key
        }

        func value(_ key: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return readings[key] }
        func store(_ key: String, _ reading: GraphReading?) {
            lock.lock(); defer { lock.unlock() }
            if readings[key] == nil { order.append(key) }
            readings[key] = Entry(reading: reading)
            while order.count > Self.limit { readings[order.removeFirst()] = nil }
        }
        func labels(_ key: String) -> [Label]? { lock.lock(); defer { lock.unlock() }; return labelSets[key] }
        func storeLabels(_ key: String, _ labels: [Label]) {
            lock.lock(); defer { lock.unlock() }
            if labelSets[key] == nil { labelOrder.append(key) }
            labelSets[key] = labels
            while labelOrder.count > Self.limit { labelSets[labelOrder.removeFirst()] = nil }
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
        let l = labels.map { "\($0.value)[\($0.text)]@(\(Int($0.column)),\(Int($0.row)))" }
        let g = "gridrows \(gridLines(bitmap, horizontal: true)) gridcols \(gridLines(bitmap, horizontal: false))"
        var chosen = "none"
        if let axes = chooseAxes(horizontals: horizontals, verticals: verticals, labels: labels, bitmap: bitmap) {
            chosen = "x-axis row \(axes.0.position), y-axis col \(axes.1.position), x labels \(axes.2.map { "\($0.value)@\(Int($0.column))" }), y labels \(axes.3.map { "\($0.value)@\(Int($0.row))" })"
        }
        var field = "field: none"
        if let reading = read(bitmap: bitmap, horizontals: horizontals, verticals: verticals, labels: labels, hints: nil) {
            let x0 = Int(reading.x.extent.lowerBound), x1 = Int(reading.x.extent.upperBound)
            let y0 = Int(reading.y.extent.lowerBound), y1 = Int(reading.y.extent.upperBound)
            var columnProfile = [Double](repeating: 0, count: max(1, x1 - x0 + 1)), rowProfile = [Double](repeating: 0, count: max(1, y1 - y0 + 1))
            for row in max(0, y0)...min(bitmap.height - 1, y1) { for column in max(0, x0)...min(bitmap.width - 1, x1) where bitmap.isArrow(column, row) { columnProfile[column - x0] += 1; rowProfile[row - y0] += 1 } }
            func peaks(_ profile: [Double]) -> Int {
                let mean = profile.reduce(0, +) / Double(profile.count)
                var count = 0, last = -10
                for i in 1..<(profile.count - 1) where profile[i] > mean && profile[i] >= profile[i - 1] && profile[i] >= profile[i + 1] && i - last >= 4 { count += 1; last = i }
                return count
            }
            field = "field: \(reading.fieldColumns.map(String.init) ?? "-")x\(reading.fieldRows.map(String.init) ?? "-") periods x \(period(of: columnProfile).map { String(format: "%.1f", $0) } ?? "-") y \(period(of: rowProfile).map { String(format: "%.1f", $0) } ?? "-") peaks x \(peaks(columnProfile)) y \(peaks(rowProfile)) extent \(x1 - x0 + 1)x\(y1 - y0 + 1)"
        }
        return "horizontal: \(h.joined(separator: ", ")) | vertical: \(v.joined(separator: ", ")) | labels: \(l.joined(separator: " ")) | \(g) | chosen: \(chosen) | \(field)"
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

        /// Arrow ink of a drawn field: mid grey (WebAssign) or any saturated colour (textbook fields), but not
        /// the near-black of axes and labels, the light grey of gridlines, or white.
        @inline(__always) func isArrow(_ column: Int, _ row: Int) -> Bool {
            let p = rgb(column, row)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            // Any tint that is not paper (pale arrows included), or mid grey.
            if hi - lo > 25 { return hi > 70 && lo < 235 }
            return hi >= 70 && hi <= 210
        }

        /// Paper: near white.
        @inline(__always) func isBackground(_ column: Int, _ row: Int) -> Bool {
            let p = rgb(column, row)
            return min(p.r, p.g, p.b) >= 235
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
        /// As printed ("−2.2", "c").
        var text: String = ""
        /// A letter such as "c": placed by position, never used to calibrate.
        var symbolic: Bool = false
        /// For a negative label: the text box's centre (the minus included), when `column` is the digits' centre.
        /// Typesetting differs — some centre the digits on the tick, some the whole "−3" — and the reader keeps
        /// whichever puts zero on the y-axis.
        var boxColumn: Double? = nil
    }

    struct Line { var position: Int; var start: Int; var end: Int }

    static func read(bitmap: Bitmap, horizontals: [Line], verticals: [Line], labels allLabels: [Label], hints: StandardChart?) -> GraphReading? {
        guard !horizontals.isEmpty, !verticals.isEmpty else { return nil }
        let labels = allLabels.filter { !$0.symbolic }
        let symbols = allLabels.filter(\.symbolic)
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
        // Negative x labels: digits-centred or box-centred, whichever puts zero on the y-axis.
        func zeroMiss(_ list: [Label]) -> Double {
            let kept = consistent(list, along: \.column)
            guard kept.count >= 2, let fit = leastSquares(kept.map { ($0.value, $0.column) }) else { return .infinity }
            return abs(fit.origin - Double(yAxis.position))
        }
        let boxCentred = rawXLabels.map { label -> Label in var l = label; if let b = label.boxColumn { l.column = b }; return l }
        let chosenXLabels = zeroMiss(boxCentred) < zeroMiss(rawXLabels) ? boxCentred : rawXLabels
        // A label is printed beside its tick, not on it: snap each to the nearest mark or gridline.
        let xLabels = snapped(chosenXLabels, to: xMarks + xGrid, along: \.column)
        let yLabels = snapped(rawYLabels, to: yMarks + yGrid, along: \.row)

        var x = axisMap(labels: xLabels, ticks: xTicks, axisPixel: Double(yAxis.position), extent: Double(xAxis.start)...Double(xAxis.end),
                        window: hints?.xRange, ascending: true)
        var y = axisMap(labels: yLabels, ticks: yTicks, axisPixel: Double(xAxis.position), extent: Double(yAxis.start)...Double(yAxis.end),
                        window: hints?.yRange, ascending: false)
        // An axis with no labels takes the other axis's scale (course plots are drawn to equal scales) — the
        // picture's own evidence beats the agent's window. With no labels anywhere the agent's window is used, and
        // failing that equal pixel units (a sketch has no numbers to honour).
        if let yy = y, yy.labelCount >= 1, x == nil || x!.labelCount == 0 {
            x = GraphReading.AxisMap(origin: Double(yAxis.position), scale: abs(yy.scale), labelCount: 0, extent: Double(xAxis.start)...Double(xAxis.end))
        }
        if let xx = x, xx.labelCount >= 1, y == nil || y!.labelCount == 0 {
            y = GraphReading.AxisMap(origin: Double(xAxis.position), scale: -abs(xx.scale), labelCount: 0, extent: Double(yAxis.start)...Double(yAxis.end))
        }
        var calibrated = true
        if x == nil || y == nil {
            calibrated = false
            let unit = Double(min(bitmap.width, bitmap.height)) / 10
            x = GraphReading.AxisMap(origin: Double(yAxis.position), scale: unit, labelCount: 0, extent: Double(xAxis.start)...Double(xAxis.end))
            y = GraphReading.AxisMap(origin: Double(xAxis.position), scale: -unit, labelCount: 0, extent: Double(yAxis.start)...Double(yAxis.end))
        }
        guard let x, let y else { return nil }
        var reading = GraphReading(width: bitmap.width, height: bitmap.height, x: x, y: y, curves: [])
        reading.isCalibrated = calibrated
        reading.curves = extractCurves(bitmap, reading: reading)
        if let grid = fieldGrid(bitmap, reading: reading, axisRow: xAxis.position, axisColumn: yAxis.position) {
            reading.fieldColumns = grid.columns
            reading.fieldRows = grid.rows
            reading.fieldSamples = grid.samples
        }
        // The labels exactly as the original prints them.
        // Where a label would be printed for `value`, is it covered by a coloured curve (so unreadable)?
        func hiddenUnderCurve(_ value: Double, horizontal: Bool, map: GraphReading.AxisMap) -> Bool {
            let p = Int(map.pixel(value).rounded())
            var coloured = 0
            let (columns, rows): (ClosedRange<Int>, ClosedRange<Int>) = horizontal
                ? ((p - 9)...(p + 9), (xAxis.position + 3)...(xAxis.position + 20))
                : ((yAxis.position - 24)...(yAxis.position - 3), (p - 7)...(p + 7))
            for r in rows where r >= 0 && r < bitmap.height {
                for c in columns where c >= 0 && c < bitmap.width && bitmap.hueBin(c, r) != nil { coloured += 1 }
            }
            return coloured >= 8
        }
        func printed(_ list: [Label], along key: KeyPath<Label, Double>, map: GraphReading.AxisMap, fallback: [Double]?, marks: [Double], horizontal: Bool) -> [(value: Double, text: String)] {
            let kept = x.labelCount > 0 || y.labelCount > 0 ? consistent(list, along: key) : []
            var out = kept.map { (value: $0.value, text: ChartGeometry.number($0.value).replacingOccurrences(of: "-", with: "−")) }
            if out.isEmpty, map.labelCount > 0, let fallback { out = fallback.map { (value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) } }
            out.sort { $0.value < $1.value }
            // Evenly spaced labels (every unit, every 5 …) are a progression the recogniser may have missed a term
            // of where a curve crosses it: fill the progression across the axis. Uneven ones stay as printed.
            // Labels a curve hides: a value printed on one side with a tick at its mirror image is printed there too.
            for label in out where !out.contains(where: { abs($0.value + label.value) < 1e-9 }) {
                let mirror = -label.value
                guard abs(mirror) > 1e-9, map.range.contains(mirror), marks.contains(where: { abs($0 - map.pixel(mirror)) <= 3 }) else { continue }
                out.append((value: mirror, text: ChartGeometry.number(mirror).replacingOccurrences(of: "-", with: "−")))
            }
            out.sort { $0.value < $1.value }
            // Evenly spaced labels with every other term hidden under a curve (−3, −1, 1, 3 where the curve crosses
            // ±2): half-step positions with a tick whose label spot is covered by a curve get their label back.
            if out.count >= 2 {
                let known = out.map(\.value)
                let gaps = zip(known, known.dropFirst()).map { $1 - $0 }
                // Only the "every other label" pattern: all printed values are odd multiples of half the step.
                let half = (gaps.min() ?? 0) / 2
                let alternate = half > 0 && known.allSatisfy { value in
                    let k = (value / half).rounded()
                    return abs(k * half - value) < half * 0.02 && Int(k) % 2 != 0
                }
                if alternate, let step = gaps.min(), step > 0, gaps.allSatisfy({ abs(($0 / step).rounded() * step - $0) < step * 0.02 }) {
                    var v = known.first! + step / 2
                    while v < known.last! {
                        let value = (v * 1e9).rounded() / 1e9
                        if abs(value) > step * 1e-6, !known.contains(where: { abs($0 - value) < step * 0.02 }),
                           marks.contains(where: { abs($0 - map.pixel(value)) <= 3 }),
                           hiddenUnderCurve(value, horizontal: horizontal, map: map) {
                            out.append((value: value, text: ChartGeometry.number(value).replacingOccurrences(of: "-", with: "−")))
                        }
                        v += step / 2
                    }
                    out.sort { $0.value < $1.value }
                }
            }
            // Evenly spaced labels are a progression: a term missing between two printed ones was hidden, not left out.
            let values = out.map(\.value)
            if values.count >= 3 {
                let gaps = zip(values, values.dropFirst()).map { $1 - $0 }
                let step = gaps.min()!
                if step > 0, gaps.allSatisfy({ abs(($0 / step).rounded() * step - $0) < step * 0.02 }) {
                    var filled: [(value: Double, text: String)] = []
                    var v = values.first!
                    while v <= values.last! + step * 0.01 {
                        let value = (v * 1e9).rounded() / 1e9
                        if abs(value) > step * 1e-6 {
                            filled.append(out.first { abs($0.value - value) < step * 0.02 } ?? (value: value, text: ChartGeometry.number(value).replacingOccurrences(of: "-", with: "−")))
                        }
                        v += step
                    }
                    out = filled
                }
            }
            return out
        }
        reading.xTickLabels = x.labelCount > 0 ? printed(xLabels, along: \.column, map: x, fallback: hints?.xTicks, marks: xMarks, horizontal: true) : []
        reading.yTickLabels = y.labelCount > 0 ? printed(yLabels, along: \.row, map: y, fallback: hints?.yTicks, marks: yMarks, horizontal: false) : []
        // Symbols ("c") beside an axis mark the value their position maps to — only on an axis that prints no
        // numbers (elsewhere a "letter" is an arrowhead or a fragment of a glyph). One of each.
        let near = Double(max(bitmap.width, bitmap.height)) * 0.08
        let numericX = !reading.xTickLabels.isEmpty, numericY = !reading.yTickLabels.isEmpty
        for symbol in symbols {
            let dv = abs(symbol.column - Double(yAxis.position)), dh = abs(symbol.row - Double(xAxis.position))
            if dv <= near, dv <= dh {
                guard !numericY, !reading.yTickLabels.contains(where: { $0.text == symbol.text }) else { continue }
                reading.yTickLabels.append((value: y.value(symbol.row), text: symbol.text))
            } else if dh <= near {
                guard !numericX, !reading.xTickLabels.contains(where: { $0.text == symbol.text }) else { continue }
                reading.xTickLabels.append((value: x.value(symbol.column), text: symbol.text))
            }
        }
        return reading
    }

    // MARK: - Slope-field density

    /// The number of arrows across and down a drawn field: the arrow ink (grey, or a colour that fills an area
    /// rather than a curve) projected onto each axis is periodic, and the period found by autocorrelation
    /// divides the axis extent into that many cells. Nil when no clear period exists.
    static func fieldGrid(_ bitmap: Bitmap, reading: GraphReading, axisRow: Int? = nil, axisColumn: Int? = nil) -> (columns: Int, rows: Int, samples: [[Double]])? {
        let x0 = Int(reading.x.extent.lowerBound), x1 = Int(reading.x.extent.upperBound)
        let y0 = Int(reading.y.extent.lowerBound), y1 = Int(reading.y.extent.upperBound)
        guard x1 - x0 > 40, y1 - y0 > 40 else { return nil }
        // Curve pixels are not arrows; everything else that is grey or coloured inside the plot is.
        var curvePixels: Set<Int> = []
        for curve in reading.curves { for (column, list) in curve.rows { for row in list { curvePixels.insert(row * bitmap.width + column) } } }
        var columnProfile = [Double](repeating: 0, count: x1 - x0 + 1)
        var rowProfile = [Double](repeating: 0, count: y1 - y0 + 1)
        var total = 0
        for row in max(0, y0)...min(bitmap.height - 1, y1) {
            for column in max(0, x0)...min(bitmap.width - 1, x1) where bitmap.isArrow(column, row) && !curvePixels.contains(row * bitmap.width + column) {
                columnProfile[column - x0] += 1
                rowProfile[row - y0] += 1
                total += 1
            }
        }
        // Too little ink to be a field (a few stray grey pixels), or so much that it is shading.
        let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
        guard Double(total) >= area * 0.01, Double(total) <= area * 0.5 else { return nil }
        guard let columnPeriod = period(of: columnProfile), let rowPeriod = period(of: rowProfile) else { return nil }
        // The arrows may stop short of the axis ends (a margin inside the frame): count cells over the span of the
        // arrow ink, first arrow to last, plus one.
        guard let columnBounds = inkBounds(columnProfile), let rowBounds = inkBounds(rowProfile) else { return nil }
        let columnSpan = Double(columnBounds.last - columnBounds.first), rowSpan = Double(rowBounds.last - rowBounds.first)
        let columns = Int((columnSpan / columnPeriod).rounded()) + 1
        let rows = Int((rowSpan / rowPeriod).rounded()) + 1
        guard columns >= 4, rows >= 4, columns <= 60, rows <= 60 else { return nil }

        // Each arrow's direction: the principal axis of its ink inside its cell (the head is symmetric about the
        // shaft, so it does not tilt the axis). Near-vertical arrows take their sign from the side the head is on.
        // Arrow centres: the phase of the periodic ink that best lines a comb of the measured period up with the
        // ink (arrows concentrate their ink about their centres), within the first period of the ink.
        let pitchX = columnPeriod, pitchY = rowPeriod
        func phase(_ profile: [Double], period: Double, first: Int, count: Int) -> Double {
            // Smooth over a quarter period so a shaft and its head read as one bump.
            let radius = max(1, Int(period / 4))
            var smooth = [Double](repeating: 0, count: profile.count)
            for i in profile.indices {
                var sum = 0.0
                for j in max(0, i - radius)...min(profile.count - 1, i + radius) { sum += profile[j] }
                smooth[i] = sum
            }
            var best = (offset: Double(first) + period / 2, score: -Double.infinity)
            var offset = Double(first)
            while offset < Double(first) + period {
                var score = 0.0
                for k in 0..<count {
                    let at = Int((offset + Double(k) * period).rounded())
                    if at >= 0, at < smooth.count { score += smooth[at] }
                }
                if score > best.score { best = (offset, score) }
                offset += 0.5
            }
            return best.offset
        }
        let startX = Double(x0) + phase(columnProfile, period: pitchX, first: columnBounds.first, count: columns)
        let startY = Double(y0) + phase(rowProfile, period: pitchY, first: rowBounds.first, count: rows)
        let xScale = abs(reading.x.scale), yScale = abs(reading.y.scale)
        var samples: [[Double]] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let cx = startX + Double(i) * pitchX, cy = startY + Double(j) * pitchY
                let halfX = pitchX / 2, halfY = pitchY / 2
                let radius2 = pow(min(halfX, halfY) * 1.05, 2)
                var n = 0.0, sx = 0.0, sy = 0.0
                var pixels: [(Double, Double)] = []
                let c0 = max(0, Int((cx - halfX).rounded(.up))), c1 = min(bitmap.width - 1, Int((cx + halfX).rounded(.down)))
                let r0 = max(0, Int((cy - halfY).rounded(.up))), r1 = min(bitmap.height - 1, Int((cy + halfY).rounded(.down)))
                guard c0 < c1, r0 < r1 else { continue }
                for row in r0...r1 {
                    if let axisRow, abs(row - axisRow) <= 1 { continue }
                    for column in c0...c1 {
                        if let axisColumn, abs(column - axisColumn) <= 1 { continue }
                        let dx = Double(column) - cx, dy = Double(row) - cy
                        guard dx * dx + dy * dy <= radius2 else { continue }
                        guard bitmap.isArrow(column, row), !curvePixels.contains(row * bitmap.width + column) else { continue }
                        pixels.append((Double(column), Double(row))); n += 1; sx += Double(column); sy += Double(row)
                    }
                }
                guard n >= 3 else { continue }
                // Only the arrow at the centre counts: the 8-connected blob of ink nearest the centre (neighbours'
                // tips reaching into the disk are other arrows). Falls back to all the ink when the blob is tiny.
                let lookup = Set(pixels.map { Int($0.1) * bitmap.width + Int($0.0) })
                if let seed = pixels.min(by: { hypot($0.0 - cx, $0.1 - cy) < hypot($1.0 - cx, $1.1 - cy) }) {
                    var blob: [(Double, Double)] = []
                    var stack = [Int(seed.1) * bitmap.width + Int(seed.0)]
                    var seen: Set<Int> = [stack[0]]
                    while let key = stack.popLast() {
                        let c = key % bitmap.width, r = key / bitmap.width
                        blob.append((Double(c), Double(r)))
                        for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
                            let next = (r + dr) * bitmap.width + (c + dc)
                            if lookup.contains(next), seen.insert(next).inserted { stack.append(next) }
                        } }
                    }
                    if blob.count >= 3 {
                        pixels = blob
                        n = Double(blob.count); sx = blob.reduce(0) { $0 + $1.0 }; sy = blob.reduce(0) { $0 + $1.1 }
                    }
                }
                let mx = sx / n, my = sy / n
                var cxx = 0.0, cyy = 0.0, cxy = 0.0
                for (px, py) in pixels { cxx += (px - mx) * (px - mx); cyy += (py - my) * (py - my); cxy += (px - mx) * (py - my) }
                // Length along the principal axis (a uniform stroke of length L has variance L²/12), relative to the
                // arrow pitch: fields that scale arrows by magnitude draw short ones where the slope is small.
                let major = 0.5 * (cxx + cyy + ((cxx - cyy) * (cxx - cyy) + 4 * cxy * cxy).squareRoot()) / n
                let relativeLength = min(1.2, (12 * major).squareRoot() / min(pitchX, pitchY))
                let theta = 0.5 * atan2(2 * cxy, cxx - cyy)      // pixel space, rows grow downwards
                var pixelSlope = tan(theta)
                if !pixelSlope.isFinite || abs(pixelSlope) > 25 {
                    // Vertical: up when the head (the heavier end) is above the centre.
                    pixelSlope = my < cy ? -1e4 : 1e4
                }
                // Pixel slope Δrow/Δcolumn = −(yScale·Δy)/(xScale·Δx), so dy/dx = −pixelSlope · xScale / yScale.
                let m = -pixelSlope * xScale / yScale
                let data = reading.data(column: cx, row: cy)
                samples.append([data.x, data.y, (m * 1e6).rounded() / 1e6, (relativeLength * 1000).rounded() / 1000])
            }
        }
        return (columns, rows, samples)
    }

    /// First and last positions where the profile is at least 15 % of its maximum.
    static func inkBounds(_ profile: [Double]) -> (first: Int, last: Int)? {
        guard let peak = profile.max(), peak > 0 else { return nil }
        let threshold = peak * 0.15
        guard let first = profile.firstIndex(where: { $0 >= threshold }), let last = profile.lastIndex(where: { $0 >= threshold }), last > first else { return nil }
        return (first, last)
    }

    /// Distance from the first to the last position where the profile is at least 15 % of its maximum.
    static func inkSpan(_ profile: [Double]) -> Double? {
        guard let peak = profile.max(), peak > 0 else { return nil }
        let threshold = peak * 0.15
        guard let first = profile.firstIndex(where: { $0 >= threshold }), let last = profile.lastIndex(where: { $0 >= threshold }), last > first else { return nil }
        return Double(last - first)
    }

    /// The dominant period of a profile (pixels): the autocorrelation's first peak after its first dip, over lags
    /// from 2 px to a fifth of the length; nil when no lag correlates clearly.
    static func period(of profile: [Double]) -> Double? {
        let n = profile.count
        guard n >= 40 else { return nil }
        let mean = profile.reduce(0, +) / Double(n)
        let centred = profile.map { $0 - mean }
        let variance = centred.reduce(0) { $0 + $1 * $1 }
        guard variance > 0 else { return nil }
        let maxLag = n / 5
        guard maxLag >= 6 else { return nil }
        var values = [Double](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum = 0.0
            for i in 0..<(n - lag) { sum += centred[i] * centred[i + lag] }
            values[lag] = sum / variance
        }
        // Past the first dip, the highest correlation is the period (later peaks are its multiples and lower).
        var dip = 2
        while dip < maxLag, values[dip + 1] < values[dip] { dip += 1 }
        guard dip < maxLag else { return nil }
        var best: (lag: Int, value: Double)?
        for lag in dip...maxLag where best == nil || values[lag] > best!.value { best = (lag, values[lag]) }
        guard let best, best.value >= 0.25, best.lag >= 3 else { return nil }
        // Refine the lag to a fraction of a pixel with a parabola through the neighbouring correlations.
        let a = values[best.lag - 1], b = best.value, c = best.lag + 1 <= maxLag ? values[best.lag + 1] : 0
        let denominator = a - 2 * b + c
        let offset = abs(denominator) > 1e-9 ? 0.5 * (a - c) / denominator : 0
        return Double(best.lag) + max(-0.5, min(0.5, offset))
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
                        for r in (q + 1)..<gapEnd where (horizontal ? bitmap.isInk(r, p) : bitmap.isInk(p, r)) {
                            // Within two pixels: anti-aliasing. Farther: only where a coloured curve crosses the line,
                            // never across the white gap to a tick label.
                            if r - q <= 2 { bridged = true } else {
                                // Something drawn over the line (a curve, a field arrow) bridges; white paper does not.
                                let drawn = (q..<r).filter { !(horizontal ? bitmap.isBackground($0, p) : bitmap.isBackground(p, $0)) }.count
                                bridged = drawn * 2 >= r - q
                            }
                            break
                        }
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
                let near = Double(max(bitmap.width, bitmap.height)) * 0.08
                for label in labels {
                    let dv = abs(label.column - Double(v.position)), dh = abs(label.row - Double(h.position))
                    // A y label sits beside the y-axis, or outside the plot to its left/right, within the axis's
                    // rows; an x label sits beside the x-axis, or outside the plot below/above, within its columns.
                    let inRows = label.row >= Double(v.start) - 10 && label.row <= Double(v.end) + 10
                    let inColumns = label.column >= Double(h.start) - 10 && label.column <= Double(h.end) + 10
                    let outsideH = label.column < Double(h.start) + 4 || label.column > Double(h.end) - 4
                    let outsideV = label.row < Double(v.start) + 4 || label.row > Double(v.end) - 4
                    // Beside an axis line, a label belongs to that axis (the nearer one when beside both); away
                    // from both, one outside the plot belongs to the axis it runs along.
                    if dv <= near, dh <= near {
                        if dv / Double(bitmap.width) <= dh / Double(bitmap.height) { yl.append(label) } else { xl.append(label) }
                    } else if dv <= near, inRows { yl.append(label) }
                    else if dh <= near, inColumns { xl.append(label) }
                    else if outsideH, inRows { yl.append(label) }
                    else if outsideV, inColumns { xl.append(label) }
                }
                xl = signed(xl, crossing: Double(v.position), along: \.column, negativeBelow: true)
                yl = signed(yl, crossing: Double(h.position), along: \.row, negativeBelow: false)
                let xKept = consistent(xl, along: \.column), yKept = consistent(yl, along: \.row)
                // The axes are the lines through the labels' zero: the x-axis sits where the y labels say y = 0,
                // the y-axis where the x labels say x = 0. Without such a fit, the line nearer the middle of the
                // image beats a frame line at its edge.
                // A line more than a few pixels from where the labels put zero is a frame, not an axis, whatever
                // it scores on labels.
                var misplacement = 0.0
                var wrongLine = false
                if yKept.count >= 2, let fit = leastSquares(yKept.map { ($0.value, $0.row) }) {
                    misplacement += abs(fit.origin - Double(h.position))
                    if abs(fit.origin - Double(h.position)) > 8 { wrongLine = true }
                } else {
                    misplacement += abs(Double(h.position) - Double(bitmap.height) / 2) * 0.5
                }
                if xKept.count >= 2, let fit = leastSquares(xKept.map { ($0.value, $0.column) }) {
                    misplacement += abs(fit.origin - Double(v.position))
                    if abs(fit.origin - Double(v.position)) > 8 { wrongLine = true }
                } else {
                    misplacement += abs(Double(v.position) - Double(bitmap.width) / 2) * 0.5
                }
                let score = Double(xKept.count + yKept.count) * 1000 - misplacement - (wrongLine ? 100_000 : 0)
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
            // The window's span sets the scale; the axes cross at 0, so the crossing anchors the map (the agent's
            // window is only a guess at the numbers, never at where the picture's own axes are).
            let scale = (ascending ? 1 : -1) * span / (window[1] - window[0])
            return GraphReading.AxisMap(origin: axisPixel, scale: scale, labelCount: 0, extent: extent)
        }
        return nil
    }

    /// A positive label on the negative side of the crossing (left of the y-axis, below the x-axis) whose
    /// magnitude also appears on the positive side lost its minus sign in recognition; give it back. Labels a
    /// hair from the crossing are left alone.
    static func signed(_ labels: [Label], crossing: Double, along key: KeyPath<Label, Double>, negativeBelow: Bool) -> [Label] {
        // Left of the y-axis (for x) or below the x-axis (for y) every value is negative: a positive label there
        // lost its minus sign in recognition.
        labels.map { label in
            guard label.value > 0 else { return label }
            let offset = label[keyPath: key] - crossing
            let onNegativeSide = negativeBelow ? offset < -6 : offset > 6
            guard onNegativeSide else { return label }
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
    /// Coloured pixels that are the fringes of sub-pixel antialiased black text (blue on one side of a glyph,
    /// orange on the other) rather than a drawn curve: connected groups of colour that mostly touch dark ink. A
    /// curve touches ink only where it crosses an axis or a tick.
    static func fringePixels(_ bitmap: Bitmap) -> Set<Int> {
        let w = bitmap.width, h = bitmap.height
        var coloured = [Bool](repeating: false, count: w * h)
        for row in 0..<h { for column in 0..<w where bitmap.hueBin(column, row) != nil { coloured[row * w + column] = true } }
        // Text is near-black at its core even when blurred; grey (a field's arrows, gridlines) does not count.
        func touchesInk(_ column: Int, _ row: Int) -> Bool {
            for dy in -2...2 { for dx in -2...2 {
                let c = column + dx, r = row + dy
                guard c >= 0, r >= 0, c < w, r < h else { continue }
                let p = bitmap.rgb(c, r)
                let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
                if hi < 100 && hi - lo < 50 { return true }
            } }
            return false
        }
        var seen = [Bool](repeating: false, count: w * h)
        var fringe = Set<Int>()
        var small: [(members: [Int], touching: Int)] = []
        var large: [Int] = []
        for start in 0..<(w * h) where coloured[start] && !seen[start] {
            var stack = [start], members: [Int] = []
            seen[start] = true
            while let index = stack.popLast() {
                members.append(index)
                let column = index % w, row = index / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let c = column + dx, r = row + dy
                    guard c >= 0, r >= 0, c < w, r < h else { continue }
                    let n = r * w + c
                    if coloured[n] && !seen[n] { seen[n] = true; stack.append(n) }
                } }
            }
            // A drawn curve is one long stroke; only small pieces can be a glyph's fringe.
            let touching = members.count < 60 ? members.filter { touchesInk($0 % w, $0 / w) }.count : 0
            if Double(touching) > 0.4 * Double(members.count) { fringe.formUnion(members); continue }
            if members.count < 30 { small.append((members, touching)) } else if members.count >= 60 { large.append(contentsOf: members) }
        }
        // A small piece of colour away from every sizeable stroke that touches ink (a glyph's fringe the blur
        // lightened) or is a mere speck is not part of a curve. Pieces of a curve broken where it crosses an axis
        // lie beside the rest of it; a dashed curve's dashes touch no ink.
        guard !large.isEmpty else { return fringe }
        var nearLarge = [Bool](repeating: false, count: w * h)
        let reach = 6
        for index in large {
            let column = index % w, row = index / w
            for r in max(0, row - reach)...min(h - 1, row + reach) {
                for c in max(0, column - reach)...min(w - 1, column + reach) { nearLarge[r * w + c] = true }
            }
        }
        for piece in small where piece.touching > 0 || piece.members.count < 8 {
            if !piece.members.contains(where: { nearLarge[$0] }) { fringe.formUnion(piece.members) }
        }
        return fringe
    }

    static func extractCurves(_ bitmap: Bitmap, reading: GraphReading) -> [GraphReading.Curve] {
        var byBin: [Int: [Int: [Int]]] = [:]
        var counts = [Int](repeating: 0, count: 12)
        let fringe = fringePixels(bitmap)
        for row in 0..<bitmap.height {
            for column in 0..<bitmap.width {
                guard !fringe.contains(row * bitmap.width + column), let bin = bitmap.hueBin(column, row) else { continue }
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
            // A curve fills little of its box (the box is at least a tenth of the image tall, so a horizontal
            // line is not "full") and averages few pixels per column; a field of arrows fails both.
            let columns = rows.keys.max()! - rows.keys.min()! + 1
            let top = rows.values.compactMap(\.first).min()!, bottom = rows.values.compactMap(\.last).max()!
            let boxHeight = max(bottom - top + 1, bitmap.height / 10)
            let fill = Double(total) / Double(max(1, columns * boxHeight))
            let perColumn = Double(total) / Double(max(1, rows.count))
            guard fill <= maximumCurveFill, perColumn <= 14 else { continue }
            let name = hueNames[group[0]]
            // Dashed: the ink covers well under the columns of its span, broken into many runs.
            // Dashed: many short pieces and no long unbroken stretch (a solid curve another colour is painted over
            // in places still has one).
            let sortedColumns = rows.keys.sorted()
            var runs = 1, runLength = 1, longest = 1
            for (a, b) in zip(sortedColumns, sortedColumns.dropFirst()) {
                if b - a > 2 { runs += 1; runLength = 1 } else { runLength += b - a; longest = max(longest, runLength) }
            }
            let coverage = Double(rows.count) / Double(max(1, columns))
            let hue = Double(group[0]) * 30 + 15
            var curve = GraphReading.Curve(color: name, rows: rows, pixelCount: total, points: polyline(rows, reading: reading, bitmap: bitmap, hue: hue))
            curve.dashed = coverage < 0.85 && runs >= 4 && Double(longest) < 0.25 * Double(columns)
            curves.append(curve)
        }
        return curves.sorted { $0.pixelCount > $1.pixelCount }
    }

    /// A left-to-right polyline through the pixels: one point per column at the median row, two where the run
    /// is tall (a steep part or an asymptote), thinned to about 80 points.
    static func polyline(_ rows: [Int: [Int]], reading: GraphReading, bitmap: Bitmap? = nil, hue: Double? = nil) -> [[Double]] {
        let columns = rows.keys.sorted()
        guard !columns.isEmpty else { return [] }
        // Flat stretches: one point per column at the middle of the ink. Steep stretches (runs of columns where
        // the ink is tall): one point per row, at the mean column of that row's ink, ordered from where the curve
        // enters the stretch to where it leaves — the stroke's own centreline, with no stair steps.
        var pixels: [(Double, Double)] = []
        func isTall(_ column: Int) -> Bool { Double(rows[column]!.last!) - Double(rows[column]!.first!) > 4 }
        var index = 0
        while index < columns.count {
            let column = columns[index]
            if !isTall(column) {
                let list = rows[column]!
                var centre = Double(list[list.count / 2])
                if let bitmap, let hue, let weighted = weightedCentre(bitmap, hue: hue, fixed: column, from: list.first! - 2, to: list.last! + 2, alongRows: true) {
                    centre = weighted
                }
                pixels.append((Double(column), centre))
                index += 1
                continue
            }
            var end = index
            while end + 1 < columns.count, columns[end + 1] - columns[end] <= 2, isTall(columns[end + 1]) { end += 1 }
            var byRow: [Int: [Int]] = [:]
            for c in columns[index...end] { for r in rows[c]! { byRow[r, default: []].append(c) } }
            let orderedRows = byRow.keys.sorted()
            let before = pixels.last?.1
            let after: Double? = end + 1 < columns.count ? Double(rows[columns[end + 1]]![rows[columns[end + 1]]!.count / 2]) : nil
            // Enter at the end of the row range nearest the curve before (or leave nearest the curve after).
            var descending = false
            if let before { descending = abs(before - Double(orderedRows.last!)) < abs(before - Double(orderedRows.first!)) }
            else if let after { descending = abs(after - Double(orderedRows.first!)) < abs(after - Double(orderedRows.last!)) }
            else {
                // A lone steep stroke: order rows so x increases along it.
                let top = byRow[orderedRows.first!]!, bottom = byRow[orderedRows.last!]!
                descending = Double(top.reduce(0, +)) / Double(top.count) > Double(bottom.reduce(0, +)) / Double(bottom.count)
            }
            for r in (descending ? orderedRows.reversed() : orderedRows) {
                let list = byRow[r]!.sorted()
                var centre = Double(list.reduce(0, +)) / Double(list.count)
                if let bitmap, let hue, let weighted = weightedCentre(bitmap, hue: hue, fixed: r, from: list.first! - 2, to: list.last! + 2, alongRows: false) {
                    centre = weighted
                }
                pixels.append((centre, Double(r)))
            }
            index = end + 1
        }
        pixels = bridgeAxisCrossings(pixels, axisRow: reading.y.pixel(0), axisColumn: reading.x.pixel(0))
        pixels = smoothStroke(pixels)
        // Thin by distance along the stroke (about every 2.5 px), keeping both ends.
        var kept: [(Double, Double)] = []
        for point in pixels {
            if let last = kept.last, hypot(point.0 - last.0, point.1 - last.1) < 2.5 { continue }
            kept.append(point)
        }
        if let last = pixels.last, kept.last.map({ $0 != last }) ?? true { kept.append(last) }
        return kept.map { point in
            let data = reading.data(column: point.0, row: point.1)
            return [round4(data.x), round4(data.y)]
        }
    }

    static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    /// The anti-aliased centre of a stroke across one column (or row): pixels weighted by how strongly they carry
    /// the curve's own hue, so an overlapping line of another colour (a red asymptote under a blue curve) cannot
    /// pull the centre. Nil when nothing of the hue is there.
    static func weightedCentre(_ bitmap: Bitmap, hue: Double, fixed: Int, from: Int, to: Int, alongRows: Bool) -> Double? {
        var weight = 0.0, sum = 0.0
        let limit = alongRows ? bitmap.height : bitmap.width
        for position in max(0, from)...min(limit - 1, max(from, to)) {
            let (column, row) = alongRows ? (fixed, position) : (position, fixed)
            guard column >= 0, column < bitmap.width, row >= 0, row < bitmap.height else { continue }
            let p = bitmap.rgb(column, row)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            let chroma = Double(hi - lo)
            guard chroma > 12 else { continue }
            let d = Double(hi - lo)
            var h: Double
            if hi == p.r { h = 60 * (Double(p.g - p.b) / d) }
            else if hi == p.g { h = 60 * (2 + Double(p.b - p.r) / d) }
            else { h = 60 * (4 + Double(p.r - p.g) / d) }
            if h < 0 { h += 360 }
            var gap = abs(h - hue); gap = min(gap, 360 - gap)
            guard gap <= 40 else { continue }
            let w = chroma * (1 - gap / 60)
            weight += w
            sum += w * Double(position)
        }
        return weight > 0 ? sum / weight : nil
    }

    /// Where a curve crosses a black axis the axis ink hides the curve's colour, so the traced centre leans to one
    /// side and leaves a bump. A short stretch of the trace lying on an axis line (a crossing) is dropped and
    /// bridged straight from the curve on either side; a long one (a curve running along the axis) is kept.
    static func bridgeAxisCrossings(_ points: [(Double, Double)], axisRow: Double, axisColumn: Double) -> [(Double, Double)] {
        let band = 5.0, longest = 18
        func onAxis(_ p: (Double, Double)) -> Bool { abs(p.1 - axisRow) <= band || abs(p.0 - axisColumn) <= band }
        var out: [(Double, Double)] = []
        var i = 0
        while i < points.count {
            guard onAxis(points[i]) else { out.append(points[i]); i += 1; continue }
            var j = i
            while j + 1 < points.count, onAxis(points[j + 1]) { j += 1 }
            let run = j - i + 1
            if run <= longest, i > 0, j + 1 < points.count, let before = out.last {
                // A straight bridge across the crossing, as dense as the trace it replaces.
                let after = points[j + 1]
                for k in 1...run {
                    let t = Double(k) / Double(run + 1)
                    out.append((before.0 + (after.0 - before.0) * t, before.1 + (after.1 - before.1) * t))
                }
            } else if run > longest {
                // Running along an axis: the partly hidden ink wobbles the centre, so this stretch (with a margin
                // either side) is smoothed much more strongly than the rest of the stroke.
                let lo = max(0, i - 10), hi = min(points.count - 1, j + 10)
                let window = Array(points[lo...hi])
                let sigma = 8.0, reach = 24
                for k in i...j {
                    let c = k - lo
                    var w = 0.0, sx = 0.0, sy = 0.0
                    for m in max(0, c - reach)...min(window.count - 1, c + reach) {
                        let weight = exp(-Double((m - c) * (m - c)) / (2 * sigma * sigma))
                        w += weight; sx += weight * window[m].0; sy += weight * window[m].1
                    }
                    out.append((sx / w, sy / w))
                }
            } else {
                out.append(contentsOf: points[i...j])
            }
            i = j + 1
        }
        return out
    }

    /// Removes pixel quantisation and stray jumps from a traced stroke: a running median (outliers such as a
    /// row where another colour crossed), then a Gaussian average along the stroke. Ends stay where they are.
    static func smoothStroke(_ points: [(Double, Double)]) -> [(Double, Double)] {
        let n = points.count
        guard n >= 7 else { return points }
        func median(_ values: [Double]) -> Double { let s = values.sorted(); return s[s.count / 2] }
        var filtered = points
        for i in 2..<(n - 2) {
            filtered[i] = (median((i - 2...i + 2).map { points[$0].0 }), median((i - 2...i + 2).map { points[$0].1 }))
        }
        let sigma = 2.5, reach = 7
        var smoothed = filtered
        for i in 1..<(n - 1) {
            // Symmetric window, shrinking towards the ends so the endpoints are not dragged inwards.
            let k = min(reach, i, n - 1 - i)
            var wx = 0.0, sx = 0.0, sy = 0.0
            for j in (i - k)...(i + k) {
                let w = exp(-Double((j - i) * (j - i)) / (2 * sigma * sigma))
                wx += w; sx += w * filtered[j].0; sy += w * filtered[j].1
            }
            smoothed[i] = (sx / wx, sy / wx)
        }
        return smoothed
    }

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
        // Each region is read on its own: one the recogniser rejects costs only its own labels.
        var labels = (try? await recognizeLabels(in: image, region: CGRect(x: 0, y: 0, width: image.width, height: image.height))) ?? []
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
        // Beside every tick mark, the small box where its label is printed, read on its own (a lone digit beside a
        // tick is often missed in a larger crop).
        if let bitmap = Bitmap(image: image) {
            for v in verticals {
                for tick in tickPositions(bitmap, along: v, horizontal: false) {
                    strips.append(CGRect(x: v.position - 46, y: Int(tick) - 11, width: 42, height: 22))
                    strips.append(CGRect(x: v.position + 4, y: Int(tick) - 11, width: 42, height: 22))
                }
            }
            for h in horizontals {
                for tick in tickPositions(bitmap, along: h, horizontal: true) {
                    strips.append(CGRect(x: Int(tick) - 22, y: h.position + 3, width: 44, height: 20))
                    strips.append(CGRect(x: Int(tick) - 22, y: h.position - 23, width: 44, height: 20))
                }
            }
        }
        for strip in strips {
            let clipped = strip.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard clipped.width >= 8, clipped.height >= 8 else { continue }
            for label in (try? await recognizeLabels(in: image, region: clipped)) ?? []
            where !labels.contains(where: { $0.text == label.text && abs($0.column - label.column) < 6 && abs($0.row - label.row) < 6 }) {
                labels.append(label)
            }
        }
        return labels
    }

    /// Labels inside `region` (image pixels, top-left origin), magnified ×4 for the recogniser.
    static func recognizeLabels(in image: CGImage, region: CGRect) async throws -> [Label] {
        guard let cropped = image.cropping(to: region) else { return [] }
        let factor = max(1, min(4, 1200 / max(cropped.width, cropped.height)))
        // Small crops sit on a white margin (a glyph touching the crop's edge is often not recognised).
        let margin = cropped.width <= 60 && cropped.height <= 60 ? 12 * factor : 0
        let target: CGImage = {
            guard let context = ImageCodec.rgbaContext(width: cropped.width * factor + 2 * margin, height: cropped.height * factor + 2 * margin) else { return cropped }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: margin, y: margin, width: cropped.width * factor, height: cropped.height * factor))
            // Labels are ink: saturated colour (the curves, and the colour fringes of sub-pixel antialiased text)
            // is painted white so a steep curve is never read as a "1" and fringed digits read cleanly.
            if let data = context.data {
                let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
                for row in 0..<context.height {
                    var i = row * context.bytesPerRow
                    for _ in 0..<context.width {
                        let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                        if max(r, g, b) - min(r, g, b) > 60 { bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255 }
                        i += 4
                    }
                }
            }
            return context.makeImage() ?? cropped
        }()
        // Vision's box is relative to the padded image; map it back to the crop.
        let paddedWidth = Double(cropped.width * factor + 2 * margin), paddedHeight = Double(cropped.height * factor + 2 * margin)
        let marginX = Double(margin) / paddedWidth, marginY = Double(margin) / paddedHeight
        let innerX = Double(cropped.width * factor) / paddedWidth, innerY = Double(cropped.height * factor) / paddedHeight
        let width = Double(cropped.width), height = Double(cropped.height)
        let small = cropped.width <= 60 && cropped.height <= 60
        return try await ParserSupport.offloaded {
            func read(_ level: VNRequestTextRecognitionLevel) throws -> [Label] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = level
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                request.minimumTextHeight = 0.01
                let handler = VNImageRequestHandler(cgImage: target, options: [:])
                try handler.perform([request])
                var labels: [Label] = []
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let padded = observation.boundingBox
                    let box = CGRect(x: (padded.minX - marginX) / innerX, y: (padded.minY - marginY) / innerY,
                                     width: padded.width / innerX, height: padded.height / innerY)
                    let raw = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    // The digits' centre, not the text box's: a leading minus sign would pull a label left of its tick.
                    var midX = box.midX
                    var boxColumn: Double?
                    let characters = Array(raw)
                    if characters.count >= 2, let first = characters.first, "-−–—".contains(first) {
                        midX = box.minX + box.width * (0.5 + 0.5 / Double(characters.count))
                        boxColumn = region.minX + box.midX * width
                    }
                    let column = region.minX + midX * width, row = region.minY + (1 - box.midY) * height
                    let lookalikes: [String: String] = ["b": "6", "G": "6", "б": "6", "l": "1", "I": "1", "|": "1", "S": "5", "s": "5", "Z": "2", "z": "2", "B": "8", "g": "9", "q": "9"]
                    let letters = raw.filter { $0.isLetter }
                    if let value = numeric(raw) ?? lookalikes[raw].flatMap({ Double($0) }) {
                        labels.append(Label(value: value, column: column, row: row, text: ChartGeometry.number(value).replacingOccurrences(of: "-", with: "−"), boxColumn: boxColumn))
                    } else if letters.count == 1, raw.count <= 2, let letter = letters.first, letter.isASCII,
                              !["x", "y", "f", "t", "o", "l", "i", "j"].contains(String(letter).lowercased()) {
                        // A symbolic tick label ("c", "a", "k"; a tick mark may ride along as "c-"), printed lowercase.
                        labels.append(Label(value: .nan, column: column, row: row, text: String(letter).lowercased(), symbolic: true))
                    }
                }
                return labels
            }
            let accurate = try read(.accurate)
            // A lone glyph in a small crop is sometimes missed by the accurate recogniser and read by the fast one.
            if accurate.isEmpty, small { return (try? read(.fast)) ?? [] }
            return accurate
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
