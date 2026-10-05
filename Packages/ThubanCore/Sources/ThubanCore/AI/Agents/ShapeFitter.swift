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
        if let chosen = best?.chart, chosen != chart, !candidates.isEmpty, let shape = chosen.series.first(where: { FigureScene.shape(of: $0) != .curve }) {
            let note = "Chose \(shape.name) from the question's \(candidates.count + 1) options: it matches the picture best."
            result.notes = [chart.notes, note].compactMap { $0 }.joined(separator: " ")
        }
        return result
    }

    /// The levels (and, for unnumbered axes, the scale) of a level series, read from the picture's curves; nil when
    /// the picture has no separate curves or f cannot be evaluated on them.
    static func fitLevels(_ chart: StandardChart, series index: Int, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let series = chart.series[index]
        guard let latex = series.latex, let f = ChartShapes.levelFunction(latex) else { return nil }
        let curves = picture.curves.filter { $0.count >= 25 }
        guard !curves.isEmpty else { return nil }
        let samples: [[(Int, Int)]] = curves.map { curve in
            let stride = max(1, curve.count / 40)
            return Swift.stride(from: 0, to: curve.count, by: stride).map { curve[$0] }
        }
        let maps = FamilyRecognizer.axisMaps(picture)
        let tried = picture.reading.isCalibratedFromLabels ? [1.0] : FamilyRecognizer.scales
        var points: [[Double]] = []
        for s in tried { for sample in samples { for (c, r) in sample {
            points.append([maps.x.value(Double(c)) * s, maps.y.value(Double(r)) * s])
        } } }
        guard let rows = try? await engine.values(of: [f], variables: ["x", "y"], at: points), let first = rows.first, let values = first else { return nil }
        let perScale = samples.reduce(0) { $0 + $1.count }
        var best: (scale: Double, fit: LevelFit)?
        for (k, s) in tried.enumerated() {
            guard let fit = levelFit(Array(values[(k * perScale)..<((k + 1) * perScale)]), sizes: samples.map(\.count)) else { continue }
            if best == nil || fit.dispersion < best!.fit.dispersion { best = (s, fit) }
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

    /// `values`: f at each curve's sample points, curve after curve (`sizes`).
    static func levelFit(_ values: [Double?], sizes: [Int]) -> LevelFit? {
        var offset = 0, medians: [Double] = [], spreads: [Double] = [], undefined = 0
        for size in sizes {
            let vs = values[offset..<(offset + size)].compactMap { $0 }
            offset += size
            undefined += size - vs.count
            guard vs.count >= max(3, size / 2) else { continue }
            let sorted = vs.sorted()
            let m = sorted[sorted.count / 2]
            medians.append(m)
            spreads.append(vs.map { abs($0 - m) }.sorted()[vs.count / 2])
        }
        guard !medians.isEmpty else { return nil }
        let typical = spreads.sorted()[spreads.count / 2]
        let levels = cluster(medians, noise: typical)
        let gap: Double
        if levels.count >= 2 {
            let gaps = zip(levels, levels.dropFirst()).map { $1 - $0 }.sorted()
            gap = gaps[gaps.count / 2]
        } else {
            gap = max(abs(levels[0]), 1e-9)
        }
        // A constant f (every curve on one level) or a degenerate one is no fit.
        guard gap > 1e-9 else { return nil }
        let total = sizes.reduce(0, +)
        return LevelFit(dispersion: typical / gap + Double(undefined) / Double(max(1, total)), levels: levels)
    }

    /// Distinct levels: medians closer than a few times the curves' own spread are one level (two branches of one
    /// hyperbola), averaged.
    static func cluster(_ values: [Double], noise: Double) -> [Double] {
        let sorted = values.sorted()
        guard var group = sorted.first.map({ [$0] }) else { return [] }
        let span = (sorted.last! - sorted.first!)
        let tolerance = max(noise * 3, span * 0.02)
        var result: [Double] = []
        for v in sorted.dropFirst() {
            if v - group.last! <= tolerance { group.append(v) }
            else { result.append(group.reduce(0, +) / Double(group.count)); group = [v] }
        }
        result.append(group.reduce(0, +) / Double(group.count))
        return result
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
