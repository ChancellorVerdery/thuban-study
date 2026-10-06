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
        if let straightened = await fitStraightLines(result, picture: picture, engine: engine) { result = straightened }
        if let edged = await fitStrictEdges(result, picture: picture, engine: engine) { result = edged }
        if let ranged = await ParametricFitter.fitRange(result, picture: picture, engine: engine) { result = ranged }
        if let marked = await fitMarkedPoint(result, picture: picture, engine: engine) { result = marked }
        if let chosen = best?.chart, chosen != chart, !candidates.isEmpty, let shape = chosen.series.first(where: { FigureScene.shape(of: $0) != .curve }) {
            let note = "Chose \(shape.name) from the question's \(candidates.count + 1) options: it matches the picture best."
            result.notes = [chart.notes, note].compactMap { $0 }.joined(separator: " ")
        }
        return result
    }

    /// A straight line drawn a little off the picture's line (a slope or intercept read a few pixels wrong, still
    /// within the check's tolerance, so marked dots on the line are missed): moved onto the picture's own straight
    /// line beside it, its slope and intercept written as simple fractions, and a stated domain widened to the ink.
    static func fitStraightLines(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let scene = await FigureScene.build(chart, engine: engine)
        let reading = picture.reading
        typealias Line = (mx: Double, my: Double, ux: Double, uy: Double, off: Double)
        func pca(_ points: [(Double, Double)]) -> Line? {
            guard points.count >= 2 else { return nil }
            let n = Double(points.count)
            let mx = points.reduce(0.0) { $0 + $1.0 } / n, my = points.reduce(0.0) { $0 + $1.1 } / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for (x, y) in points { sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my); sxy += (x - mx) * (y - my) }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(angle), uy = sin(angle)
            let offs = points.map { abs(-($0.0 - mx) * uy + ($0.1 - my) * ux) }.sorted()
            return (mx, my, ux, uy, offs[offs.count / 2])
        }
        var result = chart, changed = false
        for k in chart.series.indices where chart.series[k].seriesKind == .curve && (chart.series[k].latex ?? "").isEmpty == false {
            let drawn = scene.marks.filter { $0.kind == .line && $0.seriesIndex == k }.flatMap(\.pieces).flatMap { $0 }
                .map { (reading.x.pixel($0[0]), reading.y.pixel($0[1])) }
            guard drawn.count >= 2, let stated = pca(drawn), stated.off <= 0.75, abs(stated.ux) > 0.05 else { continue }
            let xs = drawn.map(\.0), ys = drawn.map(\.1)
            guard hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!) >= 40 else { continue }
            // The picture's straight pieces along the stated line (an axis splits one line into several).
            var ink: [(Double, Double)] = []
            for curve in picture.curves where curve.count >= 20 {
                let points = curve.map { (Double($0.0), Double($0.1)) }
                guard let line = pca(points), line.off <= 1.5 else { continue }
                let cross = abs(line.ux * stated.uy - line.uy * stated.ux)
                let apart = abs(-(line.mx - stated.mx) * stated.uy + (line.my - stated.my) * stated.ux)
                if cross <= 0.09, apart <= 20 { ink += points }
            }
            guard ink.count >= 40, let found = pca(ink), found.off <= 1.5 else { continue }
            let apart = abs(-(found.mx - stated.mx) * stated.uy + (found.my - stated.my) * stated.ux)
            let turned = abs(found.ux * stated.uy - found.uy * stated.ux)
            guard apart > 1.5 || turned > 0.02, abs(found.ux) > 0.05 else { continue }
            let a = reading.data(column: found.mx - found.ux * 100, row: found.my - found.uy * 100)
            let b = reading.data(column: found.mx + found.ux * 100, row: found.my + found.uy * 100)
            guard abs(b.x - a.x) > 1e-9 else { continue }
            let slope = (b.y - a.y) / (b.x - a.x), intercept = a.y - slope * a.x
            let (mn, md) = fraction(slope, tolerance: 0.015 * max(1, abs(slope)))
            let ySpan = reading.y.range.upperBound - reading.y.range.lowerBound
            let bd = Double(md)
            let bn = Int((intercept * bd).rounded())
            let snapped = abs(Double(bn) / bd - intercept) <= ySpan * 0.006 ? (bn, md) : fraction(intercept, tolerance: ySpan * 0.004)
            var option = result
            option.series[k].latex = "y=" + term(mn, md, suffix: "x", leading: true) + term(snapped.0, snapped.1, suffix: "", leading: false)
            if option.series[k].domain != nil {
                let lo = ink.map { reading.data(column: $0.0, row: $0.1).x }.min()!, hi = ink.map { reading.data(column: $0.0, row: $0.1).x }.max()!
                option.series[k].domain = [(lo * 100).rounded() / 100, (hi * 100).rounded() / 100]
            }
            let before = ShapeVerifier.lineScore(await FigureScene.build(result, engine: engine), picture: picture).coverage ?? 0
            let after = ShapeVerifier.lineScore(await FigureScene.build(option, engine: engine), picture: picture).coverage ?? 0
            guard after >= before - 0.02 else { continue }
            result = option; changed = true
        }
        return changed ? result : nil
    }

    /// A shaded region whose picture draws an edge dashed (a sector's outer arc for r < 4) but whose stated
    /// condition includes it (r ≤ 4): each non-strict condition tried as strict, the version whose solid and dashed
    /// edges agree best with the picture's dark ink along them kept. A dashed edge is on ink a quarter to four fifths
    /// of the way, a solid one nearly all of it.
    static func fitStrictEdges(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        let reading = picture.reading, bitmap = picture.bitmap
        func darkNear(_ c: Int, _ r: Int) -> Bool {
            for dy in -1...1 { for dx in -1...1 where c + dx >= 0 && r + dy >= 0 && c + dx < bitmap.width && r + dy < bitmap.height {
                if bitmap.isInk(c + dx, r + dy) { return true }
            } }
            return false
        }
        /// Agreement of the region's drawn edges with the picture, weighted by length (nil when nothing to judge).
        func agreement(_ option: StandardChart, series k: Int) async -> Double? {
            let scene = await FigureScene.build(option, engine: engine)
            var agree = 0.0, total = 0.0
            for mark in scene.marks where mark.kind == .line && mark.seriesIndex == k {
                for piece in mark.pieces {
                    var on = 0, seen = 0
                    for (a, b) in zip(piece, piece.dropFirst()) {
                        let ax = reading.x.pixel(a[0]), ay = reading.y.pixel(a[1]), bx = reading.x.pixel(b[0]), by = reading.y.pixel(b[1])
                        let steps = max(1, Int(hypot(bx - ax, by - ay).rounded()))
                        for i in 0..<steps {
                            let c = Int((ax + (bx - ax) * Double(i) / Double(steps)).rounded()), r = Int((ay + (by - ay) * Double(i) / Double(steps)).rounded())
                            guard picture.columns.contains(c), picture.rows.contains(r), !picture.nearAxis(c, r) else { continue }
                            seen += 1
                            if darkNear(c, r) { on += 1 }
                        }
                    }
                    guard seen >= 20 else { continue }
                    let share = Double(on) / Double(seen)
                    let fits = mark.style == .dashed ? (0.2...0.82).contains(share) : share >= 0.85
                    total += Double(seen)
                    if fits { agree += Double(seen) }
                }
            }
            return total > 0 ? agree / total : nil
        }
        let nonStrict = try! NSRegularExpression(pattern: #"\\(le|ge)(q)?(?![a-z])|≤|≥"#)
        func strict(_ term: String) -> String {
            var out = term
            for (from, to) in [("\\leq", "<"), ("\\geq", ">"), ("≤", "<"), ("≥", ">")] { out = out.replacingOccurrences(of: from, with: to) }
            out = out.replacingOccurrences(of: #"\\le(?![a-z])"#, with: "<", options: .regularExpression)
            return out.replacingOccurrences(of: #"\\ge(?![a-z])"#, with: ">", options: .regularExpression)
        }
        var result = chart, changed = false
        for k in chart.series.indices where FigureScene.shape(of: chart.series[k]).isRegion {
            guard let latex = chart.series[k].latex else { continue }
            let terms = latex.split(separator: ",").map(String.init)
            let open = terms.indices.filter { nonStrict.firstMatch(in: terms[$0], range: NSRange(terms[$0].startIndex..., in: terms[$0])) != nil }
            guard !open.isEmpty, open.count <= 4, let base = await agreement(result, series: k), base < 0.98 else { continue }
            var best = (latex: latex, score: base)
            for mask in 1..<(1 << open.count) {
                var option = result
                var changedTerms = terms
                for (bit, index) in open.enumerated() where mask & (1 << bit) != 0 { changedTerms[index] = strict(terms[index]) }
                option.series[k].latex = changedTerms.joined(separator: ",")
                if let score = await agreement(option, series: k), score > best.score + 0.15 { best = (option.series[k].latex!, score) }
            }
            if best.latex != latex { result.series[k].latex = best.latex; changed = true }
        }
        return changed ? result : nil
    }

    /// The simplest fraction p/q (q ≤ 12) within `tolerance` of v, else v to two decimals as hundredths.
    static func fraction(_ v: Double, tolerance: Double) -> (Int, Int) {
        for q in 1...12 {
            let p = (v * Double(q)).rounded()
            if abs(p / Double(q) - v) <= tolerance { return (Int(p), q) }
        }
        return (Int((v * 100).rounded()), 100)
    }

    /// p/q as a LaTeX term: "\\frac{8}{5}x", "-\\frac{39}{5}", "+3"; nothing for a zero intercept.
    static func term(_ p: Int, _ q: Int, suffix: String, leading: Bool) -> String {
        let g = gcd(abs(p), q), n = p / max(1, g), d = q / max(1, g)
        if n == 0 { return leading ? "0" : "" }
        let sign = n < 0 ? "-" : (leading ? "" : "+")
        let body: String
        if d == 1 { body = (abs(n) == 1 && !suffix.isEmpty) ? "" : "\(abs(n))" }
        else { body = "\\frac{\(abs(n))}{\(d)}" }
        return sign + body + suffix
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

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
