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
        // A series with nothing to draw (no equation, no points, no initial condition) is noise.
        result.series = chart.series.filter { !($0.latex ?? "").isEmpty || !($0.points ?? []).isEmpty || $0.throughPoint != nil }
        // The window and the printed labels are the picture's own.
        result.xRange = [round3(reading.x.range.lowerBound), round3(reading.x.range.upperBound)]
        result.yRange = [round3(reading.y.range.lowerBound), round3(reading.y.range.upperBound)]
        result.xAxisLabels = reading.xTickLabels.map { ChartTick(value: round3($0.value), text: $0.text) }
        result.yAxisLabels = reading.yTickLabels.map { ChartTick(value: round3($0.value), text: $0.text) }
        // Specks (anti-aliasing in a coloured arrow field, a coloured label) are not curves.
        let curves = reading.curves.filter { curve in
            guard let span = curve.columns else { return false }
            return curve.pixelCount >= 120 && Double(span.count) >= 0.15 * Double(reading.width)
        }
        if chart.isSlopeField {
            let slope = chart.slope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !slope.isEmpty || (reading.fieldSamples?.count ?? 0) >= 12 else { return nil }
            return await reconcileField(result, slope: slope, reading: reading, curves: curves, engine: engine)
        }
        return await reconcileCurves(result, reading: reading, curves: curves, engine: engine)
    }

    /// A chart built from the picture alone, for a figure the agent called a chart but could not describe: every
    /// drawn curve as a traced series, the window from the axes. Nil when the picture cannot be read or shows
    /// no curve.
    public static func chartFromPixels(png: Data, hints: StandardChart? = nil, engine: MathEngine? = nil) async -> StandardChart? {
        // A sibling's slope field: the same field with this picture's own curve found by the reconciler.
        if let hints, hints.isSlopeField, let slope = hints.slope, !slope.isEmpty, let engine {
            var field = StandardChart(chartType: "slopeField", xLabel: hints.xLabel, yLabel: hints.yLabel, series: [],
                                      xRange: hints.xRange, yRange: hints.yRange, confidence: 0.7, slope: slope, arrows: hints.arrows,
                                      xStep: hints.xStep, yStep: hints.yStep, fieldColumns: hints.fieldColumns, fieldRows: hints.fieldRows,
                                      provenance: StandardChart.stated, definition: hints.definition, xTicks: hints.xTicks, yTicks: hints.yTicks,
                                      candidates: hints.candidates)
            field.definition = nil
            if let reconciled = await reconcile(field, png: png, engine: engine) { return reconciled }
        }
        guard let reading = await GraphReader.read(png: png, hints: hints) else { return nil }
        let curves = reading.curves.filter { curve in
            guard let span = curve.columns else { return false }
            return curve.pixelCount >= minimumUnclaimedPixels && Double(span.count) >= minimumUnclaimedSpan * Double(reading.width) && curve.points.count >= 4
        }
        guard !curves.isEmpty else { return nil }
        var chart = StandardChart(
            chartType: "line", xLabel: hints?.xLabel, yLabel: hints?.yLabel,
            series: curves.map { ChartSeries(name: "\($0.color) curve", points: $0.points) },
            xRange: [round3(reading.x.range.lowerBound), round3(reading.x.range.upperBound)],
            yRange: [round3(reading.y.range.lowerBound), round3(reading.y.range.upperBound)],
            confidence: reading.isCalibratedFromLabels ? 0.8 : 0.5, provenance: StandardChart.traced
        )
        chart.verification = ChartVerification(passed: true, summary: "Read from the picture: \(curves.count) curve\(curves.count == 1 ? "" : "s") traced from the pixels" + (reading.isCalibratedFromLabels ? "." : " (axes not labelled; scale approximate)."))
        return chart
    }

    // MARK: Slope fields

    static func reconcileField(_ chart: StandardChart, slope: String, reading: GraphReading, curves: [GraphReading.Curve], engine: MathEngine) async -> StandardChart? {
        var result = chart
        // The field is redrawn with as many arrows across and down as the picture has.
        if let columns = reading.fieldColumns, let rows = reading.fieldRows {
            result.fieldColumns = columns
            result.fieldRows = rows
        }
        // The arrows as drawn decide whether the stated slope is the field: where it disagrees (or cannot be
        // evaluated) the field is drawn from the measured arrows and every curve on it is traced from the pixels.
        var fieldNote: String?
        if let samples = reading.fieldSamples, samples.count >= 12 {
            result.fieldSamples = samples
            var matches = false
            if !slope.isEmpty, let sampled = try? await engine.samples(of: slope, at: samples.map { (x: $0[0], y: $0[1]) }) {
                let k = abs(reading.y.scale) / abs(reading.x.scale)
                var errors: [Double] = []
                for (sample, value) in zip(samples, sampled.values) {
                    guard let value, value.isFinite else { continue }
                    var d = abs(atan(value * k) - atan(sample[2] * k))
                    d = min(d, .pi - d)
                    errors.append(d)
                }
                errors.sort()
                if errors.count * 2 >= samples.count {
                    let median = errors[errors.count / 2]
                    let bad = Double(errors.filter { $0 > 0.4 }.count) / Double(errors.count)
                    matches = median < 0.18 && bad < 0.15
                    fieldNote = "dy/dx = \(slope) matches \(errors.filter { $0 <= 0.4 }.count) of \(samples.count) arrows"
                }
            }
            result.fieldFromPicture = !matches
            if !matches {
                var traced: [ChartSeries] = []
                for curve in curves where curve.points.count >= 4 {
                    traced.append(ChartSeries(name: "\(curve.color) curve", points: curve.points, style: curve.dashed ? "dashed" : nil))
                }
                result.series = traced
                result.provenance = StandardChart.traced
                result.definition = nil
                let why = slope.isEmpty ? "no usable slope was stated" : (fieldNote.map { "the stated slope does not match its arrows (\($0))" } ?? "the stated slope could not be evaluated")
                result.verification = ChartVerification(passed: true, summary: "Read from the picture: the field is drawn from its \(samples.count) measured arrows because \(why)" + (traced.isEmpty ? "." : "; \(traced.count) curve\(traced.count == 1 ? "" : "s") traced from the pixels."))
                return result
            }
        } else if slope.isEmpty {
            return nil
        }
        let claimed = chart.series.compactMap(\.throughPoint)
        guard !curves.isEmpty else {
            // Nothing drawn in colour: a bare field is right as it is; a claimed curve cannot be checked here.
            if claimed.isEmpty {
                result.verification = ChartVerification(passed: true, summary: "Verified against the picture: a direction field with no solution curve drawn on it" + (fieldNote.map { "; \($0)" } ?? "") + ".")
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
            guard let points = try? await engine.integrateSlope(slope, through: candidate.point, xRange: window, yRange: reading.y.range, steps: max(400, reading.width * 3)) else { continue }
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
        var kept: [ChartSeries] = []
        var notes: [String] = []
        let step = (reading.x.range.upperBound - reading.x.range.lowerBound) / Double(max(100, reading.width))
        let columns = stride(from: reading.x.range.lowerBound, through: reading.x.range.upperBound, by: step).map { $0 }

        // Stated functions the picture draws keep their equation (and take the drawn curve's dash style).
        if reading.isCalibrated {
            for original in chart.series {
                guard let latex = original.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty else { continue }
                guard let sampled = try? await engine.samples(of: latex, at: columns.map { (x: $0, y: 0) }), sampled.explicit else { continue }
                let points = zip(columns, sampled.values).compactMap { x, y -> [Double]? in y.map { [x, $0] } }
                var best: (index: Int, fit: Double, coverage: Double)?
                for (index, curve) in curves.enumerated() where !consumed.contains(index) {
                    let score = GraphReader.match(points, to: curve, in: reading)
                    if best == nil || score.fit * 0.7 + score.coverage * 0.3 > best!.fit * 0.7 + best!.coverage * 0.3 { best = (index, score.fit, score.coverage) }
                }
                if let best, best.fit >= minimumFit, best.coverage >= minimumCoverage {
                    consumed.insert(best.index)
                    var matched = original
                    matched.style = curves[best.index].dashed ? "dashed" : (original.style == "dashed" ? nil : original.style)
                    kept.append(matched)
                    notes.append("\(display(latex)) follows the \(curves[best.index].color) curve (fit \(percent(best.fit)))")
                } else {
                    notes.append("\(display(latex)) is not what is drawn; removed")
                }
            }
        }

        // Every other drawn curve is traced from the pixels. It keeps the name of the agent's series nearest it.
        let span = reading.y.range.upperBound - reading.y.range.lowerBound
        var namesUsed: Set<Int> = []
        var keptCurves: [GraphReading.Curve] = curves.enumerated().filter { consumed.contains($0.offset) }.map(\.element)
        for (index, curve) in curves.enumerated() where !consumed.contains(index) && curve.points.count >= 4 {
            if keptCurves.contains(where: { distance($0.points, curve) < 0.02 * span }) { continue }
            keptCurves.append(curve)
            var name = "\(curve.color) curve"
            let nearest = chart.series.enumerated()
                .filter { !namesUsed.contains($0.offset) && !($0.element.points ?? []).isEmpty }
                .min { distance($0.element.points!, curve) < distance($1.element.points!, curve) }
            if let nearest, distance(nearest.element.points!, curve) < 0.3 * span, !nearest.element.name.isEmpty {
                name = nearest.element.name
                namesUsed.insert(nearest.offset)
            }
            kept.append(ChartSeries(name: name, points: curve.points, style: curve.dashed ? "dashed" : nil))
        }
        let traced = curves.indices.filter { !consumed.contains($0) }.count
        if traced > 0 { notes.append("\(traced) curve\(traced == 1 ? "" : "s") traced from the picture") }
        guard !kept.isEmpty else { return nil }
        result.series = kept
        if kept.allSatisfy({ ($0.latex ?? "").isEmpty }) { result.provenance = StandardChart.traced }
        result.verification = ChartVerification(passed: true, summary: "Verified against the picture: " + notes.joined(separator: "; ") + ".")
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
