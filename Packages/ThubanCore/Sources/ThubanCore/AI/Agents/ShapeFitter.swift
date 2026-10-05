import Foundation

/// Fits a chart's shapes to its picture before the check (`ShapeVerifier`):
/// - level curves: each separate curve in the picture lies on one level of f, so the picture itself gives the
///   levels (the value of f along each curve) and, when the axes carry no numbers, the scale (the one at which f
///   is most nearly constant along every curve);
/// - candidates: when the question offers several shapes (six parametric pairs, four functions for four contour
///   maps), each is drawn against the picture and the one that matches best is kept.
public enum ShapeFitter {
    /// Scales tried when the axes carry no numbers (the agent's window × s).
    static let scales: [Double] = [0.35, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5, 3]

    public static func fit(_ chart: StandardChart, png: Data, engine: MathEngine) async -> StandardChart {
        guard let picture = await ShapeVerifier.Picture(png: png, hints: chart) else { return chart }
        return await fit(chart, picture: picture, engine: engine)
    }

    static func fit(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart {
        let candidates = (chart.shapeCandidates ?? []).filter { FigureScene.shape(of: $0) != .curve }
        let index = chart.series.firstIndex { FigureScene.shape(of: $0) != .curve }
        var options: [StandardChart] = [chart]
        for candidate in candidates {
            var option = chart
            if let index { option.series[index] = candidate } else { option.series.append(candidate) }
            // A candidate named like the series keeps the series' look.
            option.series[index ?? option.series.count - 1].style = chart.series[safe: index ?? -1]?.style ?? candidate.style
            options.append(option)
        }
        var best: (chart: StandardChart, score: Double)?
        for var option in options {
            for k in option.series.indices where option.series[k].seriesKind == .level {
                if let fitted = await fitLevels(option, series: k, picture: picture, engine: engine) { option = fitted }
            }
            let scene = await FigureScene.build(option, engine: engine)
            let score = ShapeVerifier.fitScore(scene, picture: picture)
            if best == nil || score > best!.score + 1e-9 { best = (option, score) }
        }
        var result = best?.chart ?? chart
        if let marked = await fitMarkedPoint(result, picture: picture, engine: engine) { result = marked }
        if let chosen = best?.chart, chosen != chart, !candidates.isEmpty, let shape = chosen.series.first(where: { FigureScene.shape(of: $0) != .curve }) {
            let note = "Chose \(shape.name) from the question's \(candidates.count + 1) options: it matches the picture best."
            result.notes = [chart.notes, note].compactMap { $0 }.joined(separator: " ")
        }
        return result
    }

    /// A parametric curve with a marked r(t0) and its vectors that misses the picture (answer choices share one
    /// caption but each marks its own point, or draws the curve turned): t0 tried at the common values and the curve
    /// mirrored or turned, the version that fits the picture kept.
    static func fitMarkedPoint(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        guard let index = chart.series.firstIndex(where: { $0.seriesKind == .parametric && $0.markAt != nil }),
              let xt = chart.series[index].xt, let yt = chart.series[index].yt else { return nil }
        let first = await FigureScene.build(chart, engine: engine)
        guard !ShapeVerifier.verify(scene: first, picture: picture).passed else { return nil }
        let pi = Double.pi
        var times: [Double] = [chart.series[index].markAt!]
        for k in -8...8 { times.append(Double(k) * pi / 4); times.append(Double(k) * pi / 6) }
        for k in -3...3 { times.append(Double(k)); times.append(Double(k) + 0.5) }
        var seen = Set<Int>(); times = times.filter { seen.insert(Int(($0 * 1000).rounded())).inserted }
        let turns: [(String, String)] = [(xt, yt), ("-(\(xt))", yt), (xt, "-(\(yt))"), ("-(\(xt))", "-(\(yt))"),
                                         (yt, xt), ("-(\(yt))", xt), (yt, "-(\(xt))"), ("-(\(yt))", "-(\(xt))")]
        var best: (StandardChart, Double)?
        for (x, y) in turns {
            // The curve first (cheap): only orientations whose curve fits are tried with every t0.
            var curveOnly = chart
            curveOnly.series[index].xt = x; curveOnly.series[index].yt = y
            curveOnly.series[index].markAt = nil
            let curveScene = await FigureScene.build(curveOnly, engine: engine)
            guard (ShapeVerifier.lineScore(curveScene, picture: picture).coverage ?? 0) >= 0.7 else { continue }
            for t in times {
                var option = curveOnly
                option.series[index].markAt = t
                let scene = await FigureScene.build(option, engine: engine)
                let verdict = ShapeVerifier.verify(scene: scene, picture: picture)
                let score = ShapeVerifier.fitScore(scene, picture: picture) + (verdict.passed ? 1 : 0)
                if best == nil || score > best!.1 { best = (option, score) }
            }
        }
        guard let found = best, found.1 > 1 else { return nil }
        return found.0
    }

    /// The levels (and, for unnumbered axes, the scale) of a level series, read from the picture's curves; nil when
    /// the picture has no separate curves or f cannot be evaluated on them.
    static func fitLevels(_ chart: StandardChart, series index: Int, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let series = chart.series[index]
        guard let latex = series.latex, let f = ChartShapes.levelFunction(latex) else { return nil }
        let samples = FamilyRecognizer.levelSamples(picture)
        guard !samples.curves.isEmpty else { return nil }
        let maps = FamilyRecognizer.axisMaps(picture)
        let tried = picture.reading.isCalibratedFromLabels ? [1.0] : FamilyRecognizer.scales
        let lines = samples.curves + samples.axes
        var points: [[Double]] = []
        for s in tried { for line in lines { for (c, r) in line {
            points.append([maps.x.value(Double(c)) * s, maps.y.value(Double(r)) * s])
        } } }
        guard let rows = try? await engine.values(of: [f], variables: ["x", "y"], at: points), let first = rows.first, let values = first else { return nil }
        let perScale = lines.reduce(0) { $0 + $1.count }
        // A homogeneous f (x^2 + y^2, xy) fits every scale alike: then the scale nearest the chart's own window wins.
        let unitWidth = abs(maps.x.value(Double(picture.columns.upperBound)) - maps.x.value(Double(picture.columns.lowerBound)))
        let own = chart.xRange.flatMap { $0.count == 2 && unitWidth > 0 ? ($0[1] - $0[0]) / unitWidth : nil } ?? 1
        var best: (scale: Double, fit: LevelFit)?
        for (k, s) in tried.enumerated() {
            let slice = Array(values[(k * perScale)..<((k + 1) * perScale)])
            guard let fit = levelFit(slice, sizes: samples.curves.map(\.count), axes: samples.axes.map(\.count)) else { continue }
            guard let current = best else { best = (s, fit); continue }
            let tied = abs(fit.dispersion - current.fit.dispersion) <= 1e-6 * max(fit.dispersion, current.fit.dispersion)
            if tied ? abs(log(s / own)) < abs(log(current.scale / own)) : fit.dispersion < current.fit.dispersion { best = (s, fit) }
        }
        guard let best, best.fit.dispersion < 0.5 else { return nil }
        var result = chart
        result.series[index].levels = best.fit.levels.map(rounded)
        if !picture.reading.isCalibratedFromLabels || result.xRange == nil || result.yRange == nil {
            FamilyRecognizer.setWindow(&result, picture: picture, maps: maps, scale: best.scale)
        }
        return result
    }

    /// How nearly constant f is along each of the picture's curves: the typical spread of f along a curve as a
    /// share of the spacing between levels (plus the share of points where f is undefined), and the levels.
    struct LevelFit {
        var dispersion: Double
        var levels: [Double]
    }

    /// `values`: f at each curve's sample points, curve after curve (`sizes`), then along each axis drawn in curve
    /// colour (`axes`).
    static func levelFit(_ values: [Double?], sizes: [Int], axes: [Int] = []) -> LevelFit? {
        var offset = 0, curves: [CurveValues] = [], undefined = 0
        for size in sizes {
            let vs = values[offset..<(offset + size)].compactMap { $0 }
            offset += size
            undefined += size - vs.count
            guard vs.count >= max(3, size / 2) else { continue }
            let sorted = vs.sorted()
            let m = sorted[sorted.count / 2]
            curves.append(CurveValues(median: m, spread: vs.map { abs($0 - m) }.sorted()[vs.count / 2], weight: vs.count))
        }
        guard curves.count >= 2 else { return nil }
        let levels = cluster(curves)
        // A constant f (every curve on one level) is no fit.
        guard levels.count >= 2 else { return nil }
        // Each curve's spread against the distance to the nearest other level, so a family whose values span many
        // orders of magnitude (e^{x} over a wide window) is judged curve by curve, not by its largest values; the
        // typical share is taken along the ink (long curves weigh most), so scraps where curves meet cannot carry it.
        let ratios: [(value: Double, weight: Int)] = curves.map { curve in
            // levels[closest] is this curve's own level; the next is its neighbour.
            let neighbour = levels.map { abs($0 - curve.median) }.sorted()[1]
            guard neighbour > 0, neighbour.isFinite else { return (1, curve.weight) }
            return (min(1, curve.spread / neighbour), curve.weight)
        }
        let total = sizes.reduce(0, +)
        var all = levels
        for size in axes {
            let along = values[offset..<(offset + size)]
            offset += size
            if let level = axisLevel(along, levels: all.sorted()) { all.append(level) }
        }
        return LevelFit(dispersion: weightedMedian(ratios) + Double(undefined) / Double(max(1, total)), levels: all.sorted())
    }

    /// The level along an axis the picture draws in curve colour (y = 0 for y = ce^{x}): nil unless f is defined and
    /// constant along it to a tenth of the spacing between levels, and unless it is a level the curves lack.
    static func axisLevel(_ values: ArraySlice<Double?>, levels: [Double]) -> Double? {
        let vs = values.compactMap { $0 }.sorted()
        guard !vs.isEmpty, Double(vs.count) >= 0.9 * Double(values.count) else { return nil }
        let m = vs[vs.count / 2], spread = vs.map { abs($0 - m) }.sorted()[vs.count / 2]
        let spacing = zip(levels, levels.dropFirst()).map { $1 - $0 }.min() ?? 0
        guard spacing > 0, spread <= 0.1 * spacing, levels.allSatisfy({ abs($0 - m) > spacing / 2 }) else { return nil }
        return m
    }

    /// f along one of the picture's curves: its median, the median distance from it, and the samples behind them.
    struct CurveValues {
        var median: Double
        var spread: Double
        var weight: Int
    }

    /// The middle of `values` counting each as often as its weight.
    static func weightedMedian(_ values: [(value: Double, weight: Int)]) -> Double {
        let sorted = values.sorted { $0.value < $1.value }
        let half = sorted.reduce(0) { $0 + $1.weight } / 2
        var running = 0
        return (sorted.first { running += $0.weight; return running > half } ?? sorted[sorted.count - 1]).value
    }

    /// Distinct levels: curves whose values lie within a few times their own spread of each other are one level
    /// (two branches of one hyperbola, a curve cut where another meets it), the level the middle of their values along
    /// the ink (a branch drawn a pixel off does not move it). Each curve's own spread decides, so a family whose values
    /// span orders of magnitude (e^{y}) keeps its small levels apart. Curves far looser than most (ink where curves
    /// meet, f steep across the line) would join levels that are apart, so they found none.
    static func cluster(_ curves: [CurveValues]) -> [Double] {
        guard !curves.isEmpty else { return [] }
        let floor = max(1e-9 * curves.map { abs($0.median) }.max()!, 1e-300)
        let loose = max(4 * weightedMedian(curves.map { ($0.spread, $0.weight) }), floor)
        // Apart by a few times the looser curve's spread and not much more than the tighter's, so a curve between two
        // levels, looser than the curves on them, joins neither.
        func oneLevel(_ a: CurveValues, _ b: CurveValues) -> Bool {
            let gap = abs(b.median - a.median)
            return gap <= 3 * max(a.spread, b.spread, floor) && gap <= 6 * max(min(a.spread, b.spread), floor)
        }
        var groups: [[CurveValues]] = []
        for curve in curves.filter({ $0.spread <= loose }).sorted(by: { $0.median < $1.median }) {
            if let last = groups.last?.last, oneLevel(last, curve) {
                groups[groups.count - 1].append(curve)
            } else {
                groups.append([curve])
            }
        }
        return groups.map { group in weightedMedian(group.map { ($0.median, $0.weight) }) }
    }

    /// A level as a reader would print it: 3 significant figures, and exact when it is within 2 % of a round value.
    static func rounded(_ v: Double) -> Double {
        guard v != 0, v.isFinite else { return 0 }
        let whole = v.rounded()
        if abs(v - whole) <= max(0.02 * abs(v), 0.02) { return whole }
        let magnitude = pow(10, floor(log10(abs(v))) - 2)
        return (v / magnitude).rounded() * magnitude
    }
}
