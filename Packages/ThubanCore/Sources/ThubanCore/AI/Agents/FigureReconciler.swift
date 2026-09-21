import Foundation

/// Checks and corrects a chart against the picture itself (`GraphReader`) rather than against the agent's own
/// readings: the curves drawn in colour are extracted from the pixels, every candidate definition is drawn and
/// scored against them, and the chart is rewritten to whatever the picture shows.
///
/// - Slope field with a solution curve: each initial condition the question offers (`candidates`) and each one
///   the agent chose is integrated and matched against the drawn curve; the best match wins and becomes the
///   series, its label the definition. If none fits, the curve's own point on the y-axis (or its midpoint) is
///   used instead and the chart is marked traced.
/// - Stated functions: each `latex` series is sampled and matched; a series the picture does not show is
///   replaced by the pixel curve it overlaps (traced) when the axes were calibrated from labels.
/// - Traced series are replaced by the pixel curve nearest to them, and drawn curves the agent left out are
///   added as traced series.
///
/// Returns nil when the picture cannot be read (no axes, no calibration), so the caller falls back to the
/// agent's check points (`FigureVerifier`).
public enum FigureReconciler {
    /// A curve counts as matched when this fraction of its predicted samples lie on the ink …
    public static let minimumFit = 0.8
    /// … and the predicted samples come near this fraction of the ink's columns.
    public static let minimumCoverage = 0.55
    /// A drawn curve nobody claimed is added as a series when it has at least this many pixels and spans this
    /// fraction of the plot.
    static let minimumUnclaimedPixels = 150
    static let minimumUnclaimedSpan = 0.25

    public struct Match: Sendable {
        public var label: String
        public var through: (x: Double, y: Double)?
        public var latex: String?
        public var curveIndex: Int
        public var fit: Double
        public var coverage: Double
        public var stated: Bool
        var quality: Double { fit * 0.7 + coverage * 0.3 }
        var passes: Bool { fit >= FigureReconciler.minimumFit && coverage >= FigureReconciler.minimumCoverage }
    }

    public static func reconcile(_ chart: StandardChart, png: Data, engine: MathEngine) async -> StandardChart? {
        guard chart.chartType != "scatter", chart.chartType != "bar", chart.chartType != "histogram" else { return nil }
        guard let reading = await GraphReader.read(png: png, hints: chart) else { return nil }
        var result = chart
        if reading.isCalibratedFromLabels {
            result.xRange = [round3(reading.x.range.lowerBound), round3(reading.x.range.upperBound)]
            result.yRange = [round3(reading.y.range.lowerBound), round3(reading.y.range.upperBound)]
        }
        // Specks (anti-aliasing in a coloured arrow field, a coloured label) are not curves.
        let curves = reading.curves.filter { curve in
            guard let span = curve.columns else { return false }
            return curve.pixelCount >= 120 && Double(span.count) >= 0.15 * Double(reading.width)
        }
        if chart.isSlopeField, let slope = chart.slope?.trimmingCharacters(in: .whitespacesAndNewlines), !slope.isEmpty {
            return await reconcileField(result, slope: slope, reading: reading, curves: curves, engine: engine)
        }
        return await reconcileCurves(result, reading: reading, curves: curves, engine: engine)
    }

    // MARK: Slope fields

    static func reconcileField(_ chart: StandardChart, slope: String, reading: GraphReading, curves: [GraphReading.Curve], engine: MathEngine) async -> StandardChart? {
        var result = chart
        let claimed = chart.series.compactMap(\.throughPoint)
        guard !curves.isEmpty else {
            // Nothing drawn in colour: a bare field is right as it is; a claimed curve cannot be checked here.
            if claimed.isEmpty {
                result.verification = ChartVerification(passed: true, summary: "Verified against the picture: a direction field with no solution curve drawn on it.")
                return result
            }
            return nil
        }
        // Candidates: the question's initial conditions, the agent's, and each drawn curve's own point.
        var candidates: [(label: String, point: (x: Double, y: Double), stated: Bool)] = []
        for candidate in chart.candidates ?? [] where candidate.x.isFinite && candidate.y.isFinite {
            candidates.append((candidate.label, (candidate.x, candidate.y), true))
        }
        for (offset, series) in chart.series.enumerated() {
            guard let point = series.throughPoint else { continue }
            let label = chart.definition?.blankToNil ?? series.name.blankToNil ?? "solution \(offset + 1)"
            if !candidates.contains(where: { abs($0.point.x - point.x) < 1e-6 && abs($0.point.y - point.y) < 1e-6 }) {
                candidates.append((label, point, true))
            }
        }
        for curve in curves {
            for own in anchors(of: curve) {
                candidates.append(("the curve drawn through (\(number(own.x)), \(number(own.y))) — read from the picture", own, false))
            }
        }
        let window = reading.x.range
        var matches: [Match] = []
        for candidate in candidates {
            guard let points = try? await engine.integrateSlope(slope, through: candidate.point, xRange: window, steps: max(400, reading.width * 3)) else { continue }
            for (index, curve) in curves.enumerated() {
                let score = GraphReader.match(points, to: curve, in: reading)
                matches.append(Match(label: candidate.label, through: candidate.point, latex: nil, curveIndex: index, fit: score.fit, coverage: score.coverage, stated: candidate.stated))
            }
        }
        // One series per drawn curve: the best stated candidate that passes, else the curve's own anchor.
        var series: [ChartSeries] = []
        var definitions: [String] = []
        var notes: [String] = []
        var allStated = true
        var passed = true
        for index in curves.indices {
            let forCurve = matches.filter { $0.curveIndex == index }
            let stated = forCurve.filter { $0.stated && $0.passes }.max(by: { $0.quality < $1.quality })
            let own = forCurve.filter { !$0.stated && $0.passes }.max(by: { $0.quality < $1.quality })
            if let stated, let point = stated.through {
                series.append(ChartSeries(name: shortName(stated.label), through: [point.x, point.y]))
                definitions.append(stated.label)
                notes.append("\(stated.label): fit \(percent(stated.fit)), coverage \(percent(stated.coverage))")
            } else if let own, let point = own.through {
                series.append(ChartSeries(name: "Solution through (\(number(point.x)), \(number(point.y)))", through: [round3(point.x), round3(point.y)]))
                allStated = false
                notes.append("no stated initial condition fits this curve; drawn through (\(number(point.x)), \(number(point.y))) read from the picture (fit \(percent(own.fit)))")
            } else if let curve = curves[safe: index], curve.points.count >= 4 {
                // The field's equation does not produce this curve at all: trace it.
                series.append(ChartSeries(name: "\(curve.color) curve", points: curve.points))
                allStated = false
                passed = false
                notes.append("the \(curve.color) curve does not follow dy/dx = \(slope) from any point; traced from the picture")
            }
        }
        // The field's own confidence: arrow checks, if the agent read any.
        result.series = series
        result.provenance = allStated ? StandardChart.stated : StandardChart.traced
        if !definitions.isEmpty { result.definition = definitions.joined(separator: "; ") }
        else if !allStated { result.definition = nil }
        result.verification = ChartVerification(
            passed: passed,
            summary: (passed ? "Verified against the picture: " : "Mismatch: ") + notes.joined(separator: "; ") + "."
        )
        return result
    }

    /// Points to integrate a drawn curve from: where it crosses the y-axis, and five points spread along it —
    /// a solution can be unstable in one direction, so the anchor that reproduces the whole curve is found by
    /// trying several.
    static func anchors(of curve: GraphReading.Curve) -> [(x: Double, y: Double)] {
        let pts = curve.points.filter { $0.count >= 2 }
        guard pts.count >= 2 else { return [] }
        var out: [(x: Double, y: Double)] = []
        for i in 1..<pts.count where pts[i - 1][0] <= 0 && pts[i][0] >= 0 {
            let a = pts[i - 1], b = pts[i]
            if b[0] > a[0] {
                let t = (0 - a[0]) / (b[0] - a[0])
                out.append((0, a[1] + t * (b[1] - a[1])))
            } else {
                out.append((0, b[1]))
            }
            break
        }
        for fraction in [0.08, 0.3, 0.5, 0.7, 0.92] {
            let p = pts[min(pts.count - 1, Int(Double(pts.count - 1) * fraction))]
            out.append((p[0], p[1]))
        }
        return out
    }

    // MARK: Curves

    static func reconcileCurves(_ chart: StandardChart, reading: GraphReading, curves: [GraphReading.Curve], engine: MathEngine) async -> StandardChart? {
        guard !curves.isEmpty else { return nil }
        var result = chart
        var consumed: Set<Int> = []
        var series: [ChartSeries?] = Array(repeating: nil, count: chart.series.count)
        var notes: [String] = []
        var passed = true
        let step = (reading.x.range.upperBound - reading.x.range.lowerBound) / Double(max(100, reading.width))
        let columns = stride(from: reading.x.range.lowerBound, through: reading.x.range.upperBound, by: step).map { $0 }

        // First pass: stated functions that the picture shows, and traced series re-read from the nearest curve.
        var unmatched: [(offset: Int, latex: String, sampled: [[Double]])] = []
        for (offset, original) in chart.series.enumerated() {
            if let latex = original.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty {
                var sampledPoints: [[Double]] = []
                if let sampled = try? await engine.samples(of: latex, at: columns.map { (x: $0, y: 0) }), sampled.explicit {
                    sampledPoints = zip(columns, sampled.values).compactMap { x, y -> [Double]? in y.map { [x, $0] } }
                }
                var best: (index: Int, fit: Double, coverage: Double)?
                for (index, curve) in curves.enumerated() where !consumed.contains(index) && !sampledPoints.isEmpty {
                    let score = GraphReader.match(sampledPoints, to: curve, in: reading)
                    if best == nil || score.fit * 0.7 + score.coverage * 0.3 > best!.fit * 0.7 + best!.coverage * 0.3 {
                        best = (index, score.fit, score.coverage)
                    }
                }
                if let best, best.fit >= minimumFit, best.coverage >= minimumCoverage {
                    consumed.insert(best.index)
                    series[offset] = original
                    notes.append("\(display(latex)) follows the \(curves[best.index].color) curve (fit \(percent(best.fit)))")
                } else {
                    unmatched.append((offset, latex, sampledPoints))
                }
            } else if let points = original.points, !points.isEmpty {
                let nearest = curves.enumerated().filter { !consumed.contains($0.offset) }
                    .min(by: { distance(points, $0.element) < distance(points, $1.element) })
                if let nearest, distance(points, nearest.element) < 0.15 * (reading.y.range.upperBound - reading.y.range.lowerBound) {
                    consumed.insert(nearest.offset)
                    var traced = original
                    traced.points = nearest.element.points
                    series[offset] = traced
                    notes.append("\(original.name.blankToNil ?? "a traced curve") re-read from the picture")
                } else {
                    series[offset] = original
                }
            } else {
                series[offset] = original
            }
        }

        // Second pass: a stated function the picture does not show is replaced by a drawn curve nobody claimed
        // (the picture wins) when the axes were read from labels; otherwise it is kept and flagged.
        for failed in unmatched {
            let remaining = curves.enumerated().filter { !consumed.contains($0.offset) && $0.element.points.count >= 4 }
            let replacement = remaining.min(by: { distance(failed.sampled, $0.element) < distance(failed.sampled, $1.element) })
            if reading.isCalibratedFromLabels, let replacement {
                consumed.insert(replacement.offset)
                var traced = chart.series[failed.offset]
                traced.latex = nil
                traced.points = replacement.element.points
                series[failed.offset] = traced
                passed = false
                notes.append("\(display(failed.latex)) is not what is drawn; the \(replacement.element.color) curve was traced from the picture instead")
            } else {
                series[failed.offset] = chart.series[failed.offset]
                passed = false
                notes.append("\(display(failed.latex)) was not found among the drawn curves")
            }
        }

        // Curves the agent did not mention.
        var extra: [ChartSeries] = []
        for (index, curve) in curves.enumerated() where !consumed.contains(index) {
            guard curve.pixelCount >= minimumUnclaimedPixels, let span = curve.columns,
                  Double(span.count) >= minimumUnclaimedSpan * Double(reading.width), curve.points.count >= 4 else { continue }
            extra.append(ChartSeries(name: "\(curve.color) curve", points: curve.points))
            notes.append("added the \(curve.color) curve from the picture")
        }
        let all = series.compactMap { $0 } + extra
        guard !all.isEmpty else { return nil }
        result.series = all
        if all.allSatisfy({ ($0.latex ?? "").isEmpty }) { result.provenance = StandardChart.traced }
        result.verification = ChartVerification(
            passed: passed,
            summary: (passed ? "Verified against the picture: " : "Mismatch: ") + notes.joined(separator: "; ") + "."
        )
        return result
    }

    /// Mean vertical distance from the agent's points to a drawn curve, in data units (∞ when they do not overlap).
    static func distance(_ points: [[Double]], _ curve: GraphReading.Curve) -> Double {
        var total = 0.0, count = 0
        for p in points where p.count >= 2 {
            guard let y = FigureVerifier.value(of: curve.points, at: p[0]) else { continue }
            total += abs(y - p[1]); count += 1
        }
        return count == 0 ? .infinity : total / Double(count)
    }

    // MARK: Helpers

    static func shortName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(38)) + "…" : trimmed
    }

    static func number(_ value: Double) -> String { ChartGeometry.number((value * 100).rounded() / 100) }
    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
    static func display(_ latex: String) -> String { latex.contains("=") ? latex : "y = \(latex)" }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    var blankToNil: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
