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
    /// A recognised family draws (nearly) every curve of the picture: one curve of seven left out still clears the
    /// check's general recall, but a family's redraw that drops a curve is wrong.
    static let minimumRecall = 0.9

    /// A level chart recognised from a picture alone (a plot the agent called a diagram), or nil.
    public static func recognise(png: Data, engine: MathEngine) async -> StandardChart? {
        // Plots side by side (maps I and II): each recognised on its own, drawn as panels.
        if let crops = PictureInk.panels(png: png) {
            var panels: [StandardChart] = []
            for (k, crop) in crops.enumerated() {
                guard var panel = await recognise(single: crop, engine: engine) else { return nil }
                panel.title = ["I", "II", "III", "IV"][safe: k] ?? "\(k + 1)"
                panels.append(panel)
            }
            var chart = StandardChart(chartType: "function", provenance: StandardChart.traced, verification: ChartVerification(
                passed: true, summary: "Verified against the picture: " + panels.enumerated().map { k, p in
                    "panel \(p.title ?? "\(k + 1)"): " + (p.verification?.summary ?? "") }.joined(separator: " ")))
            chart.panels = panels
            chart.monochrome = true
            chart.confidence = panels.map(\.confidence).min() ?? 0.8
            return chart
        }
        return await recognise(single: png, engine: engine)
    }

    static func recognise(single png: Data, engine: MathEngine) async -> StandardChart? {
        let seed = StandardChart(chartType: "function", provenance: StandardChart.traced)
        guard let picture = await ShapeVerifier.Picture(png: png, hints: seed) else { return nil }
        return await recognise(seed, picture: picture, engine: engine)
    }

    /// A level chart for the picture's curves, or nil when no family fits (fewer than three curves, nothing
    /// within `maximumDispersion`, or the redraw fails the picture check or leaves a curve out).
    static func recognise(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let samples = levelSamples(picture)
        guard samples.curves.count >= 3 else { return nil }
        let maps = axisMaps(picture)
        let tried = picture.reading.isCalibratedFromLabels ? [1.0] : scales
        let lines = samples.curves + samples.axes
        var points: [[Double]] = []
        for s in tried { for line in lines { for (c, r) in line {
            points.append([maps.x.value(Double(c)) * s, maps.y.value(Double(r)) * s])
        } } }
        guard let rows = try? await engine.values(of: library, variables: ["x", "y"], at: points) else { return nil }
        let perScale = lines.reduce(0) { $0 + $1.count }
        var ranked: [(f: String, scale: Double, fit: ShapeFitter.LevelFit)] = []
        for (k, f) in library.enumerated() {
            guard let values = rows[k] else { continue }
            var best: (Double, ShapeFitter.LevelFit)?
            for (j, s) in tried.enumerated() {
                let slice = Array(values[(j * perScale)..<((j + 1) * perScale)])
                guard let fit = ShapeFitter.levelFit(slice, sizes: samples.curves.map(\.count), axes: samples.axes.map(\.count)) else { continue }
                // Scales where the values underflow to a constant (dispersion ~0) only win when nothing else fits.
                func plausible(_ d: Double) -> Double { d < 0.002 ? 1 + d : d }
                if best == nil || plausible(fit.dispersion) < plausible(best!.1.dispersion) { best = (s, fit) }
            }
            if let best, best.1.dispersion <= maximumDispersion { ranked.append((f, best.0, best.1)) }
            if ProcessInfo.processInfo.environment["THUBAN_FAMILY_DEBUG"] != nil, let best {
                print("FAMILY \(f) scale \(best.0) dispersion \(best.1.dispersion) levels \(best.1.levels.map { (($0 * 1000).rounded() / 1000) })")
            }
        }
        // A fit too perfect for drawn lines of any thickness is values underflowing to a constant (e^{x} far out):
        // tried last, after every plausible family.
        func rank(_ d: Double) -> Double { d < 0.002 ? 1 + d : d }
        ranked.sort { rank($0.fit.dispersion) < rank($1.fit.dispersion) }
        for candidate in ranked.prefix(12) {
            var result = chart
            var series = ChartSeries(name: "Level curves of \(candidate.f)", latex: candidate.f)
            series.kind = "level"
            series.levels = candidate.fit.levels.map(ShapeFitter.rounded)
            result.series = [series]
            result.chartType = "function"
            result.monochrome = true
            setWindow(&result, picture: picture, maps: maps, scale: candidate.scale)
            let scene = await FigureScene.build(result, engine: engine)
            let scaled = picture.reading(in: maps, scale: candidate.scale)
            let verdict = ShapeVerifier.verify(scene: scene, picture: scaled)
            if ProcessInfo.processInfo.environment["THUBAN_FAMILY_DEBUG"] != nil { print("FAMILY try \(candidate.f) scale \(candidate.scale) levels \(series.levels ?? []): \(verdict.summary)") }
            guard verdict.passed, (ShapeVerifier.lineScore(scene, picture: scaled).recall ?? 0) >= minimumRecall else { continue }
            result.verification = verdict
            result.confidence = max(chart.confidence, 0.8)
            result.notes = [chart.notes, "Recognised from the picture as level curves of \(candidate.f)."].compactMap { $0 }.joined(separator: " ")
            return result
        }
        return nil
    }

    /// What the level fit reads from the picture: points along each of its curves, cut into strands where curves
    /// meet (a family's curves converge, and curves that touch are one run of ink), about equally spaced so a long
    /// curve weighs more than a scrap; and points along each axis the picture draws over in the curves' colour.
    static func levelSamples(_ picture: ShapeVerifier.Picture) -> (curves: [[(Int, Int)]], axes: [[(Int, Int)]]) {
        let curves = picture.curves.flatMap(strands).filter { $0.count >= 25 }
        let spacing = max(1, curves.reduce(0) { $0 + $1.count } / 400)
        func sample(_ curve: [(Int, Int)]) -> [(Int, Int)] {
            Swift.stride(from: 0, to: curve.count, by: max(1, min(spacing, curve.count / 6))).map { curve[$0] }
        }
        return (curves.map(sample), drawnAxes(picture).map(sample))
    }

    /// One run of curve ink cut into strands: the ink in each small tile split into its separate pieces, and pieces
    /// in neighbouring tiles joined unless either meets more than two others (where curves meet or cross).
    static func strands(_ pixels: [(Int, Int)]) -> [[(Int, Int)]] {
        let tile = 10
        func key(_ c: Int, _ r: Int) -> Int { c << 24 | r }
        let ink = Set(pixels.map { key($0.0, $0.1) })
        var piece: [Int: Int] = [:], sizes: [Int] = []
        for (c, r) in pixels where piece[key(c, r)] == nil {
            piece[key(c, r)] = sizes.count
            var stack = [(c, r)], size = 0
            while let (pc, pr) = stack.popLast() {
                size += 1
                for dr in -1...1 { for dc in -1...1 {
                    let nc = pc + dc, nr = pr + dr, k = key(nc, nr)
                    guard ink.contains(k), piece[k] == nil, nc / tile == c / tile, nr / tile == r / tile else { continue }
                    piece[k] = sizes.count
                    stack.append((nc, nr))
                } }
            }
            sizes.append(size)
        }
        var contacts = [[Int: Int]](repeating: [:], count: sizes.count)
        for (c, r) in pixels {
            let p = piece[key(c, r)]!
            for dr in -1...1 { for dc in -1...1 { if let q = piece[key(c + dc, r + dr)], q != p { contacts[p][q, default: 0] += 1 } } }
        }
        var parent = Array(sizes.indices)
        func root(_ p: Int) -> Int { parent[p] == p ? p : root(parent[p]) }
        // A curve clipping a tile's corner leaves a scrap there: part of the piece it touches most, not a branch.
        for p in sizes.indices where sizes[p] < tile {
            if let best = contacts[p].max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key, root(best) != root(p) {
                parent[root(p)] = root(best)
            }
        }
        // Pieces of one curve share the line's width across a tile edge; a curve passing near a tile's corner only
        // grazes the piece beyond it, which makes no branch.
        var shared: [Int: [Int: Int]] = [:]
        for p in sizes.indices { for (q, n) in contacts[p] where root(q) != root(p) { shared[root(p), default: [:]][root(q), default: 0] += n } }
        let neighbours = shared.mapValues { Set($0.filter { $0.value >= 3 }.keys) }
        for (p, others) in neighbours where others.count <= 2 {
            for q in others where (neighbours[q]?.count ?? 0) <= 2 && root(p) != root(q) { parent[root(p)] = root(q) }
        }
        var index: [Int: Int] = [:]
        var result: [[(Int, Int)]] = []
        for (c, r) in pixels {
            let group = root(piece[key(c, r)]!)
            if let k = index[group] { result[k].append((c, r)) } else { index[group] = result.count; result.append([(c, r)]) }
        }
        return result
    }

    /// An axis drawn over in curve colour along most of its length (a level curve on the axis, hidden from the
    /// curves because axis pixels are left out of them), as a curve of its own.
    static func drawnAxes(_ picture: ShapeVerifier.Picture) -> [[(Int, Int)]] {
        let bitmap = picture.bitmap
        func coloured(_ c: Int, _ r: Int) -> Bool { c >= 0 && r >= 0 && c < bitmap.width && r < bitmap.height && bitmap.hueBin(c, r) != nil }
        let row = Int(picture.axisRow.rounded()), column = Int(picture.axisColumn.rounded())
        var result: [[(Int, Int)]] = []
        if picture.rows.contains(row) {
            let along = picture.columns.filter { abs(Double($0) - picture.axisColumn) > 2 }
            let drawn = along.filter { c in (-1...1).contains { coloured(c, row + $0) } }
            if Double(drawn.count) >= 0.6 * Double(along.count) { result.append(drawn.map { ($0, row) }) }
        }
        if picture.columns.contains(column) {
            let along = picture.rows.filter { abs(Double($0) - picture.axisRow) > 2 }
            let drawn = along.filter { r in (-1...1).contains { coloured(column + $0, r) } }
            if Double(drawn.count) >= 0.6 * Double(along.count) { result.append(drawn.map { (column, $0) }) }
        }
        return result
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
        // Pieces far smaller than the curves (a label, a stray mark) are not curves.
        func extent(_ c: [(Int, Int)]) -> Int {
            let xs = c.map(\.0), ys = c.map(\.1)
            return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        }
        let all = picture.curves.filter { $0.count >= 25 }
        guard let largest = all.map(extent).max() else { return nil }
        let curves = all.filter { extent($0) * 6 >= largest }
        guard !curves.isEmpty else { return nil }
        let maps = axisMaps(picture)
        // Pieces whose ends meet (a curve cut where it crosses an axis) are one curve again.
        var lines = curves.flatMap { SkeletonTracer.paths(of: $0) }.filter { $0.count >= 2 }
        var joined = true
        while joined {
            joined = false
            search: for i in lines.indices { for j in lines.indices where j != i {
                let a = lines[i], b = lines[j]
                let ends: [([(Double, Double)], Double)] = [
                    (a + b, hypot(a.last!.0 - b.first!.0, a.last!.1 - b.first!.1)),
                    (a + b.reversed(), hypot(a.last!.0 - b.last!.0, a.last!.1 - b.last!.1)),
                    (a.reversed() + b, hypot(a.first!.0 - b.first!.0, a.first!.1 - b.first!.1)),
                ]
                guard let best = ends.min(by: { $0.1 < $1.1 }), best.1 <= 12 else { continue }
                lines[i] = best.0
                lines.remove(at: j)
                joined = true
                break search
            } }
        }
        var series: [ChartSeries] = []
        for piece in lines {
            let stride = max(1, piece.count / 160)
            let points = Swift.stride(from: 0, to: piece.count, by: stride).map { piece[$0] } + [piece[piece.count - 1]]
            series.append(ChartSeries(name: "Curve \(series.count + 1)", points: points.map { [maps.x.value($0.0), maps.y.value($0.1)] }))
        }
        guard !series.isEmpty else { return nil }
        var result = chart
        result.series = series
        result.chartType = "line"
        result.provenance = StandardChart.traced
        result.monochrome = PictureInk.isMonochrome(picture.bitmap)
        // Numbers growing down the side (depth in a lake profile): the axis runs downward, as printed.
        if picture.reading.y.scale > 0 { result.yReversed = true }
        result.shapeCandidates = nil
        if !picture.reading.isCalibratedFromLabels { setWindow(&result, picture: picture, maps: maps, scale: 1) }
        return result
    }
}
