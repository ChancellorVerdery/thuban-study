import Foundation

/// Fits a parametric curve's t-range to its picture. The agent reads the formulas well but guesses where t starts
/// and stops, so a redraw can stop short of a branch the picture draws (a missing arm) or run past where the
/// picture ends (an extra loop); the loose picture check lets both through. Each end of the range is moved in
/// steps of a tenth of it (and in coarser steps out to three times it), then refined, and the range whose drawing
/// matches the picture best (`ShapeVerifier.fitScore`) is kept. The curve is evaluated once over the widest range
/// tried, so each candidate is only a slice of the same samples, cut to the picture so the check skips what lies
/// off it.
public enum ParametricFitter {
    /// Ranges are searched only when the drawing misses this share of the picture's curves, or draws this share
    /// off them.
    static let exactShare = 0.97
    /// A new range must beat the old one's fit score by more than this.
    static let minimumGain = 0.01
    /// Samples per span of the stated range, as `ChartShapes.parametric` draws it.
    static let density = Double(ChartShapes.parametricSamples)

    /// The chart with each parametric series' t-range fitted to the picture, or nil when no range fits better.
    static func fitRange(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        var result = chart
        var changed = false
        for index in chart.series.indices {
            if let range = await fitRange(result, series: index, picture: picture, engine: engine) {
                result.series[index].tRange = range
                changed = true
            }
        }
        return changed ? result : nil
    }

    /// The fitted t-range of one parametric series, or nil when it is not parametric, already matches, or no
    /// range does better.
    static func fitRange(_ chart: StandardChart, series index: Int, picture: ShapeVerifier.Picture, engine: MathEngine) async -> [Double]? {
        let series = chart.series[index]
        guard case .parametric(let xt, let yt) = FigureScene.shape(of: series) else { return nil }
        let stated = series.tRange.flatMap { $0.count == 2 && $0[0].isFinite && $0[1].isFinite && $0[0] < $0[1] ? $0 : nil } ?? [0, 2 * Double.pi]
        let scene = await FigureScene.build(chart, engine: engine)
        guard let line = scene.marks.firstIndex(where: { $0.kind == .line && $0.seriesIndex == index }) else { return nil }
        let score = ShapeVerifier.lineScore(scene, picture: picture)
        guard (score.coverage ?? 1) < exactShare || (score.recall ?? 1) < exactShare else { return nil }

        let span = stated[1] - stated[0], step = span / 10
        let lower = stated[0] - 3 * span, upper = stated[1] + 3 * span
        guard let curve = await Samples(x: xt, y: yt, from: lower, to: upper, count: Int(7 * density), window: scene.window,
                                        picture: picture, engine: engine) else { return nil }
        let anchors = anchors(chart, series: index, curve: curve)

        func fit(_ a: Double, _ b: Double) -> Double? {
            guard a < b - step / 4, anchors.allSatisfy({ (a...b).contains($0) }) else { return nil }
            var trial = scene
            trial.marks[line].pieces = curve.pieces(from: a, to: b)
            return ShapeVerifier.fitScore(trial, picture: picture)
        }
        let original = ShapeVerifier.fitScore(scene, picture: picture)
        var best = (a: stated[0], b: stated[1], score: original)
        // An equal score (the end moved off the picture, where nothing is drawn) keeps the smaller change.
        func consider(_ a: Double, _ b: Double) {
            guard let s = fit(a, b) else { return }
            let change = abs(a - stated[0]) + abs(b - stated[1]), bestChange = abs(best.a - stated[0]) + abs(best.b - stated[1])
            if s > best.score + 1e-9 || (s > best.score - 1e-9 && change < bestChange) { best = (a, b, max(s, best.score)) }
        }
        // Each end scanned with the other held (the ends shape different stretches of the curve), the start once
        // more against the best end, then both refined in halving steps.
        let offsets = (-5...5).map { Double($0) * step } + (2...6).map { -Double($0) * span / 2 }
        for d in offsets { consider(stated[0] + d, best.b) }
        for d in offsets { consider(best.a, stated[1] - d) }
        for d in offsets { consider(stated[0] + d, best.b) }
        var refine = step / 2
        while refine >= step / 16 {
            let (a, b) = (best.a, best.b)
            for d in [-refine, refine] { consider(a + d, b); consider(a, b + d) }
            refine /= 2
        }
        guard best.score > original + minimumGain else { return nil }
        // Printed as a reader would write it, when that draws as well.
        let printed = [ShapeFitter.rounded(best.a), ShapeFitter.rounded(best.b)]
        if let s = fit(printed[0], printed[1]), s >= best.score - minimumGain / 2 { return printed }
        return [best.a, best.b]
    }

    /// The t of every marked point on the curve (r(t₀), and plotted points within 2 % of the window of it): a
    /// fitted range must still reach them.
    static func anchors(_ chart: StandardChart, series index: Int, curve: Samples) -> [Double] {
        var result: [Double] = []
        if let t0 = chart.series[index].markAt, t0.isFinite { result.append(t0) }
        let points = chart.series.filter { $0.seriesKind == .point }.flatMap { $0.points ?? [] }.filter { $0.count >= 2 }
        for p in points {
            if let t = curve.nearest(p, within: 0.02) { result.append(t) }
        }
        return result
    }

    /// A parametric curve evaluated once over a wide t-range, sliced into the pieces any narrower range draws.
    struct Samples {
        let ts: [Double]
        let points: [[Double]?]
        /// The sample, or a neighbour, lands on the picture's plot (with a margin for the drawn line's width).
        let visible: [Bool]
        let window: FigureScene.Window

        init?(x xt: String, y yt: String, from lower: Double, to upper: Double, count: Int, window: FigureScene.Window,
              picture: ShapeVerifier.Picture, engine: MathEngine) async {
            let ts = (0...count).map { lower + (upper - lower) * Double($0) / Double(count) }
            guard let rows = try? await engine.values(of: [ChartShapes.normalised(xt), ChartShapes.normalised(yt)], variables: ["t"], at: ts.map { [$0] }),
                  rows.count == 2, let xs = rows[0], let ys = rows[1] else { return nil }
            let points: [[Double]?] = zip(xs, ys).map { x, y in
                guard let x, let y, abs(x) < 1e7, abs(y) < 1e7 else { return nil }
                return [x, y]
            }
            let margin = Double(picture.radius + 2)
            let columns = (Double(picture.columns.lowerBound) - margin)...(Double(picture.columns.upperBound) + margin)
            let rowsBox = (Double(picture.rows.lowerBound) - margin)...(Double(picture.rows.upperBound) + margin)
            let inside = points.map { p in
                p.map { columns.contains(picture.reading.x.pixel($0[0])) && rowsBox.contains(picture.reading.y.pixel($0[1])) } ?? false
            }
            self.ts = ts
            self.points = points
            visible = inside.indices.map { k in inside[k] || inside[max(0, k - 1)] || inside[min(inside.count - 1, k + 1)] }
            self.window = window
        }

        /// The curve for t in a…b on the picture, broken where it is undefined or jumps (as `ChartShapes.parametric`
        /// breaks it) or leaves the plot.
        func pieces(from a: Double, to b: Double) -> [[[Double]]] {
            let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
            var pieces: [[[Double]]] = [], current: [[Double]] = []
            for k in ts.indices where ts[k] >= a && ts[k] <= b {
                guard visible[k], let point = points[k] else {
                    if current.count >= 2 { pieces.append(current) }
                    current = []
                    continue
                }
                if let last = current.last, abs(point[0] - last[0]) > xSpan * 0.5 || abs(point[1] - last[1]) > ySpan * 0.5 {
                    if current.count >= 2 { pieces.append(current) }
                    current = []
                }
                current.append(point)
            }
            if current.count >= 2 { pieces.append(current) }
            return pieces
        }
        /// The t where the curve passes nearest `p`, when that is within `share` of the window (each axis scaled to 1).
        func nearest(_ p: [Double], within share: Double) -> Double? {
            let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
            var best: (t: Double, distance: Double)?
            for (t, point) in zip(ts, points) {
                guard let point else { continue }
                let d = hypot((point[0] - p[0]) / xSpan, (point[1] - p[1]) / ySpan)
                if best == nil || d < best!.distance { best = (t, d) }
            }
            guard let best, best.distance <= share else { return nil }
            return best.t
        }
    }
}
