import Foundation

/// Repairs a shaded region bounded by straight lines whose stated lines miss the picture (a slope read as 1 that
/// is 2, a band drawn the other way): the picture's own straight boundary lines are measured, and each of the
/// region's conditions is replaced by one of them, on whichever side matches the picture's shading best.
public enum RegionFixer {
    /// The repaired chart, or nil when the picture has no straight boundaries to use or no combination passes.
    static func fix(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart? {
        // Every region series' conditions together (a union is two series: |y - x| >= 1).
        let regions = chart.series.indices.filter { FigureScene.shape(of: chart.series[$0]).isRegion }
        var conditions: [(series: Int, strict: Bool)] = []
        for index in regions {
            guard let latex = chart.series[index].latex, let parsed = ChartShapes.strictConditions(latex) else { return nil }
            conditions += parsed.map { (index, $0.strict) }
        }
        guard (1...3).contains(conditions.count) else { return nil }
        let lines = straightLines(picture)
        guard lines.count >= conditions.count else { return nil }
        // Every way to give each condition its own picture line, on either side.
        var options: [[(line: Int, flip: Bool)]] = [[]]
        for _ in conditions {
            options = options.flatMap { partial in
                lines.indices.filter { l in !partial.contains { $0.line == l } }.flatMap { l in [false, true].map { partial + [(l, $0)] } }
            }
        }
        var best: (chart: StandardChart, score: Double)?
        for option in options.prefix(96) {
            var bySeries: [Int: [String]] = [:]
            for (condition, choice) in zip(conditions, option) {
                let (m, q, vertical) = lines[choice.line]
                let relation = condition.strict ? (choice.flip ? "<" : ">") : (choice.flip ? "\\le" : "\\ge")
                bySeries[condition.series, default: []].append(vertical ? "x \(relation) \(number(q))" : "y \(relation) \(number(m))x + \(number(q))")
            }
            var candidate = chart
            for (index, pieces) in bySeries { candidate.series[index].latex = pieces.joined(separator: ", ") }
            let scene = await FigureScene.build(candidate, engine: engine)
            let verdict = ShapeVerifier.verify(scene: scene, picture: picture)
            let score = ShapeVerifier.fitScore(scene, picture: picture) + (verdict.passed ? 1 : 0)
            if verdict.passed, best == nil || score > best!.score {
                candidate.verification = verdict
                best = (candidate, score)
            }
        }
        guard var fixed = best?.chart else { return nil }
        fixed = await dropStrayLines(fixed, picture: picture, engine: engine)
        fixed.notes = [chart.notes, "Boundary lines measured from the picture."].compactMap { $0 }.joined(separator: " ")
        return fixed
    }

    /// A region chart without the separate curves that do not lie on the picture (stated boundary lines that were
    /// wrong): the region draws its own edges.
    static func dropStrayLines(_ chart: StandardChart, picture: ShapeVerifier.Picture, engine: MathEngine) async -> StandardChart {
        guard chart.series.contains(where: { FigureScene.shape(of: $0).isRegion }) else { return chart }
        var result = chart
        var kept: [ChartSeries] = []
        for series in chart.series {
            if FigureScene.shape(of: series).isRegion || (series.latex ?? "").isEmpty { kept.append(series); continue }
            var alone = chart
            alone.series = [series]
            let scene = await FigureScene.build(alone, engine: engine)
            if (ShapeVerifier.lineScore(scene, picture: picture).coverage ?? 1) >= 0.6 { kept.append(series) }
        }
        result.series = kept
        return result
    }

    /// The picture's straight boundary lines in data units: (slope, intercept, vertical) — vertical lines as x = q.
    static func straightLines(_ picture: ShapeVerifier.Picture) -> [(Double, Double, Bool)] {
        var found: [(Double, Double, Bool)] = []
        for curve in picture.curves where curve.count >= 30 {
            let n = Double(curve.count)
            let mx = curve.reduce(0.0) { $0 + Double($1.0) } / n, my = curve.reduce(0.0) { $0 + Double($1.1) } / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for (c, r) in curve { let dx = Double(c) - mx, dy = Double(r) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(angle), uy = sin(angle)
            let off = curve.map { abs(-(Double($0.0) - mx) * uy + (Double($0.1) - my) * ux) }.sorted()
            guard off[off.count / 2] <= 1.5 else { continue }
            // Two points on the line, in data units.
            let a = picture.reading.data(column: mx - ux * 50, row: my - uy * 50)
            let b = picture.reading.data(column: mx + ux * 50, row: my + uy * 50)
            if abs(b.x - a.x) < 1e-9 * max(1, abs(b.y - a.y)) || abs(ux) < 0.02 {
                found.append((0, (a.x + b.x) / 2, true))
            } else {
                let m = (b.y - a.y) / (b.x - a.x)
                found.append((m, a.y - m * a.x, false))
            }
        }
        // One entry per line (a line split by an axis gives two pieces).
        var unique: [(Double, Double, Bool)] = []
        for line in found where !unique.contains(where: { $0.2 == line.2 && abs($0.0 - line.0) < 0.08 * max(1, abs(line.0)) && abs($0.1 - line.1) < 0.15 }) {
            unique.append(line)
        }
        return unique.map { ($0.0.snapped, $0.1.snapped, $0.2) }
    }

    static func number(_ v: Double) -> String {
        let text = ChartGeometry.number(v)
        return v < 0 ? "(\(text))" : text
    }
}

private extension Double {
    /// Within a little of a whole number or a half: that value (lines on a printed grid are drawn through them).
    var snapped: Double {
        if abs(self - rounded()) <= 0.06 { return rounded() }
        let half = (self * 2).rounded() / 2
        return abs(self - half) <= 0.04 ? half : (self * 100).rounded() / 100
    }
}
