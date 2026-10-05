import Foundation

/// Recognises a picture of many curves (a contour map, a family of solutions) without the agent's help: each separate
/// curve in the picture lies on one level of the right f(x, y), so f is the standard family along whose curves it is
/// most nearly constant — tried at a range of scales when the axes carry no numbers. When no family fits, the
/// curves are traced straight from the pixels (`trace`), so the redraw still follows the picture.
public enum FamilyRecognizer {
    /// Standard families of level curves, in x and y.
    static let library: [String] = [
        "x^2+y^2", "xy", "x^2-y^2", "y^2-x^2", "x-y^2", "y-x^2", "x+y^2", "y+x^2",
        "y-\\sqrt{x}", "y+\\sqrt{x}", "x-\\sqrt{y}", "x+\\sqrt{y}", "y-\\sqrt{-x}", "y+\\sqrt{-x}",
        "ye^{x}", "ye^{-x}", "xe^{y}", "xe^{-y}", "y-e^{x}", "y-e^{-x}", "y-\\ln|x|", "y+\\ln|x|",
        "x^2y", "y|x|", "\\frac{y}{x}", "\\frac{x}{y}", "y-x^3", "x-y^3", "y-|x|", "x+y", "x-y",
        "x^2+4y^2", "4x^2+y^2", "y-\\sin(x)", "y-\\cos(x)", "\\frac{y}{x^2}", "x-|y|",
    ]
    static let scales: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5, 3, 4]
    /// A family fits when the spread along each curve is under this share of the spacing between levels.
    static let maximumDispersion = 0.08

    /// A level chart for the picture's curves, or nil when no family fits (fewer than three curves, nothing
    /// within `maximumDispersion`, or the redraw fails the picture check).
    static func recognise(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let curves = picture.curves.filter { $0.count >= 25 }
        guard curves.count >= 3 else { return nil }
        let samples: [[(Int, Int)]] = curves.map { curve in
            let stride = max(1, curve.count / 30)
            return Swift.stride(from: 0, to: curve.count, by: stride).map { curve[$0] }
        }
        let maps = axisMaps(picture)
        let tried = picture.reading.isCalibratedFromLabels ? [1.0] : scales
        var points: [[Double]] = []
        for s in tried { for sample in samples { for (c, r) in sample {
            points.append([maps.x.value(Double(c)) * s, maps.y.value(Double(r)) * s])
        } } }
        guard let rows = try? await engine.values(of: library, variables: ["x", "y"], at: points) else { return nil }
        let perScale = samples.reduce(0) { $0 + $1.count }
        var ranked: [(f: String, scale: Double, fit: ShapeFitter.LevelFit)] = []
        for (k, f) in library.enumerated() {
            guard let values = rows[k] else { continue }
            var best: (Double, ShapeFitter.LevelFit)?
            for (j, s) in tried.enumerated() {
                let slice = Array(values[(j * perScale)..<((j + 1) * perScale)])
                guard let fit = ShapeFitter.levelFit(slice, sizes: samples.map(\.count)) else { continue }
                if best == nil || fit.dispersion < best!.1.dispersion { best = (s, fit) }
            }
            if let best, best.1.dispersion <= maximumDispersion { ranked.append((f, best.0, best.1)) }
        }
        ranked.sort { $0.fit.dispersion < $1.fit.dispersion }
        for candidate in ranked.prefix(4) {
            var result = chart
            var series = ChartSeries(name: "Level curves of \(candidate.f)", latex: candidate.f)
            series.kind = "level"
            series.levels = candidate.fit.levels.map(ShapeFitter.rounded)
            result.series = [series]
            result.chartType = "function"
            result.monochrome = true
            setWindow(&result, picture: picture, maps: maps, scale: candidate.scale)
            let scene = await FigureScene.build(result, engine: engine)
            let verdict = ShapeVerifier.verify(scene: scene, picture: picture)
            guard verdict.passed else { continue }
            result.verification = verdict
            result.confidence = max(chart.confidence, 0.8)
            result.notes = [chart.notes, "Recognised from the picture as level curves of \(candidate.f)."].compactMap { $0 }.joined(separator: " ")
            return result
        }
        return nil
    }

    /// The picture's own axes when they carry numbers; otherwise equal scales on both axes (pixels are square in a
    /// textbook figure), a tenth of the plot's width per unit, about the axes' crossing.
    static func axisMaps(_ picture: ShapeVerifier.Picture) -> (x: GraphReading.AxisMap, y: GraphReading.AxisMap) {
        let reading = picture.reading
        guard !reading.isCalibratedFromLabels else { return (reading.x, reading.y) }
        let unit = Double(picture.columns.count) / 10
        let x = GraphReading.AxisMap(origin: reading.x.pixel(0), scale: unit, labelCount: 0, extent: reading.x.extent)
        let y = GraphReading.AxisMap(origin: reading.y.pixel(0), scale: -unit, labelCount: 0, extent: reading.y.extent)
        return (x, y)
    }

    /// The chart's window: the picture's plot box in the fitted units; unnumbered axes stay unnumbered.
    static func setWindow(_ chart: inout StandardChart, picture: ShapeVerifier.Picture, maps: (x: GraphReading.AxisMap, y: GraphReading.AxisMap), scale: Double) {
        let x0 = maps.x.value(Double(picture.columns.lowerBound)) * scale, x1 = maps.x.value(Double(picture.columns.upperBound)) * scale
        let y0 = maps.y.value(Double(picture.rows.lowerBound)) * scale, y1 = maps.y.value(Double(picture.rows.upperBound)) * scale
        chart.xRange = [min(x0, x1), max(x0, x1)]
        chart.yRange = [min(y0, y1), max(y0, y1)]
        chart.xStep = nil; chart.yStep = nil
        if !picture.reading.isCalibratedFromLabels { chart.xAxisLabels = []; chart.yAxisLabels = [] }
    }

    /// The picture's curves traced from its pixels, one series each, in one colour: for pictures no formula
    /// describes (measured data) or that the agent traced badly. Nil when the picture has no separate curves.
    static func trace(_ chart: StandardChart, picture: ShapeVerifier.Picture) -> StandardChart? {
        let curves = picture.curves.filter { $0.count >= 25 }
        guard !curves.isEmpty else { return nil }
        let maps = axisMaps(picture)
        var series: [ChartSeries] = []
        for curve in curves {
            for piece in polylines(curve) where piece.count >= 2 {
                let stride = max(1, piece.count / 120)
                let points = Swift.stride(from: 0, to: piece.count, by: stride).map { piece[$0] } + [piece[piece.count - 1]]
                series.append(ChartSeries(name: "Curve \(series.count + 1)", points: points.map { [maps.x.value($0.0), maps.y.value($0.1)] }))
            }
        }
        guard !series.isEmpty else { return nil }
        var result = chart
        result.series = series
        result.chartType = "line"
        result.provenance = StandardChart.traced
        result.monochrome = PictureInk.isMonochrome(picture.bitmap)
        result.shapeCandidates = nil
        if !picture.reading.isCalibratedFromLabels { setWindow(&result, picture: picture, maps: maps, scale: 1) }
        return result
    }

    /// One curve's pixels as ordered polylines (pixel coordinates): a function of x when each column holds one run
    /// of it, a function of y when each row does, else its upper and lower halves as functions of x (a loop).
    static func polylines(_ pixels: [(Int, Int)]) -> [[(Double, Double)]] {
        func runs(_ values: [Int]) -> [[Int]] {
            var out: [[Int]] = []
            for v in values.sorted() {
                if let last = out.last?.last, v - last <= 2 { out[out.count - 1].append(v) } else { out.append([v]) }
            }
            return out
        }
        func asFunction(_ pixels: [(Int, Int)], ofX: Bool) -> [(Double, Double)]? {
            var groups: [Int: [Int]] = [:]
            for (c, r) in pixels { if ofX { groups[c, default: []].append(r) } else { groups[r, default: []].append(c) } }
            var single = 0
            var line: [(Double, Double)] = []
            for key in groups.keys.sorted() {
                let rs = runs(groups[key]!)
                if rs.count == 1 { single += 1 }
                // The run nearest the previous point continues the curve.
                let previous = line.last.map { ofX ? $0.1 : $0.0 }
                let chosen = rs.min { a, b in
                    let ma = Double(a.reduce(0, +)) / Double(a.count), mb = Double(b.reduce(0, +)) / Double(b.count)
                    return abs(ma - (previous ?? ma)) < abs(mb - (previous ?? mb))
                }!
                let mean = Double(chosen.reduce(0, +)) / Double(chosen.count)
                line.append(ofX ? (Double(key), mean) : (mean, Double(key)))
            }
            return Double(single) >= Double(groups.count) * 0.9 ? line : nil
        }
        if let line = asFunction(pixels, ofX: true) { return [line] }
        if let line = asFunction(pixels, ofX: false) { return [line] }
        let middle = Double(pixels.reduce(0) { $0 + $1.1 }) / Double(pixels.count)
        let upper = pixels.filter { Double($0.1) <= middle }, lower = pixels.filter { Double($0.1) > middle }
        return [upper, lower].compactMap { half in
            guard half.count >= 10 else { return nil }
            return asFunction(half, ofX: true) ?? asFunction(half, ofX: false)
        }
    }
}
