import Foundation

/// Step three of the figure workflow: does the equation the agent found in the question actually produce the
/// picture? The agent reads a handful of points off the figure (`StandardChart.checks`); this evaluates the stated
/// equation at each and passes the chart only when the picture agrees.
///
/// - A curve series with `latex` is sampled at every `[x, y]` check; a check passes when some stated curve is
///   within `curveTolerance` of it (explicit `y = f(x)`) or its residual is small relative to the sides (an
///   implicit relation).
/// - A slope field's `slope` is compared with every `[x, y, m]` check by the angle of the arrow, and its solution
///   curves (`through`) with every `[x, y]` check by integrating the field.
/// - Nothing to check (no checks, no stated equation, a traced curve) → nil, not a failure.
public enum FigureVerifier {
    /// Fewer checks than this and the verdict is not worth reporting.
    public static let minimumChecks = 2
    /// Curve checks pass within this fraction of the y-window (at least `minimumTolerance` in y units).
    public static let toleranceFraction = 0.06
    public static let minimumTolerance = 0.12
    /// Field checks pass when the stated slope's direction is within this many radians of the arrow read (~15°).
    public static let angleTolerance = 0.27
    /// Implicit relations pass when |lhs − rhs| is within this fraction of the larger side (at least 1).
    public static let residualFraction = 0.1

    public static func verify(_ chart: StandardChart, engine: MathEngine) async -> ChartVerification? {
        guard !chart.isTraced else { return nil }
        let checks = (chart.checks ?? []).filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }
        guard checks.count >= minimumChecks else { return nil }
        if chart.isSlopeField { return await verifyField(chart, checks: checks, engine: engine) }
        return await verifyCurves(chart, checks: checks, engine: engine)
    }

    // MARK: Curves

    private static func verifyCurves(_ chart: StandardChart, checks: [[Double]], engine: MathEngine) async -> ChartVerification? {
        let stated = chart.series.compactMap { $0.latex?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !stated.isEmpty else { return nil }
        let points = checks.map { (x: $0[0], y: $0[1]) }
        let tolerance = curveTolerance(chart, checks: checks)
        var samples: [(latex: String, samples: MathEngine.Samples)] = []
        for latex in stated {
            do {
                samples.append((latex, try await engine.samples(of: latex, at: points)))
            } catch {
                return ChartVerification(passed: false, summary: "The equation \(display(latex)) could not be evaluated: \(error.localizedDescription)")
            }
        }
        var failures: [String] = []
        for (index, point) in points.enumerated() {
            var passed = false
            var nearest: (latex: String, value: Double)?
            for (latex, sampled) in samples {
                guard let value = sampled.values[index] else { continue }
                if sampled.explicit {
                    let off = abs(value - point.y)
                    if off <= tolerance { passed = true; break }
                    if nearest == nil || off < abs(nearest!.value - point.y) { nearest = (latex, value) }
                } else {
                    let scale = max(1, sampled.scales[index] ?? 1)
                    if abs(value) <= residualFraction * scale { passed = true; break }
                    if nearest == nil { nearest = (latex, value) }
                }
            }
            if !passed {
                if let nearest, samples.first(where: { $0.latex == nearest.latex })?.samples.explicit == true {
                    failures.append("at x = \(number(point.x)) \(display(nearest.latex)) gives \(number(nearest.value)) but the picture shows \(number(point.y))")
                } else {
                    failures.append("(\(number(point.x)), \(number(point.y))) is not on \(display(nearest?.latex ?? stated[0]))")
                }
            }
        }
        return verdict(checks: points.count, failures: failures, subject: stated.map(display).joined(separator: ", "))
    }

    /// Reading a point off a raster is good to a few percent of the window.
    private static func curveTolerance(_ chart: StandardChart, checks: [[Double]]) -> Double {
        var span = 0.0
        if let range = chart.yRange, range.count == 2, range[1] > range[0] { span = range[1] - range[0] }
        else if let low = checks.map({ $0[1] }).min(), let high = checks.map({ $0[1] }).max() { span = high - low }
        return max(minimumTolerance, toleranceFraction * span)
    }

    // MARK: Fields

    private static func verifyField(_ chart: StandardChart, checks: [[Double]], engine: MathEngine) async -> ChartVerification? {
        guard let slope = chart.slope?.trimmingCharacters(in: .whitespacesAndNewlines), !slope.isEmpty else { return nil }
        let arrowChecks = checks.filter { $0.count >= 3 }
        let curveChecks = checks.filter { $0.count == 2 }
        var failures: [String] = []
        var counted = 0

        if !arrowChecks.isEmpty {
            let points = arrowChecks.map { (x: $0[0], y: $0[1]) }
            let sampled: MathEngine.Samples
            do {
                sampled = try await engine.samples(of: slope, at: points)
            } catch {
                return ChartVerification(passed: false, summary: "The slope dy/dx = \(slope) could not be evaluated: \(error.localizedDescription)")
            }
            for (index, check) in arrowChecks.enumerated() {
                counted += 1
                guard let value = sampled.values[index] else {
                    failures.append("dy/dx is undefined at (\(number(check[0])), \(number(check[1])))")
                    continue
                }
                if abs(atan(value) - atan(check[2])) > angleTolerance {
                    failures.append("at (\(number(check[0])), \(number(check[1]))) dy/dx = \(slope) gives slope \(number(value)) but the arrow shows \(number(check[2]))")
                }
            }
        }

        // Points read along a drawn solution curve must lie on the integral curve through its initial condition.
        let solutions = chart.series.compactMap(\.throughPoint)
        if !curveChecks.isEmpty, !solutions.isEmpty {
            let xs = curveChecks.map { $0[0] } + solutions.map(\.x)
            let window = Self.xWindow(chart, xs: xs)
            let tolerance = curveTolerance(chart, checks: curveChecks)
            var curves: [[[Double]]] = []
            for start in solutions {
                if let curve = try? await engine.integrateSlope(slope, through: start, xRange: window, steps: 800) { curves.append(curve) }
            }
            for check in curveChecks {
                counted += 1
                let readings = curves.compactMap { Self.value(of: $0, at: check[0]) }
                guard let nearest = readings.min(by: { abs($0 - check[1]) < abs($1 - check[1]) }) else {
                    failures.append("no solution curve reaches x = \(number(check[0]))")
                    continue
                }
                if abs(nearest - check[1]) > tolerance {
                    failures.append("at x = \(number(check[0])) the solution curve gives \(number(nearest)) but the picture shows \(number(check[1]))")
                }
            }
        }
        guard counted >= minimumChecks else { return nil }
        return verdict(checks: counted, failures: failures, subject: "dy/dx = \(slope)")
    }

    private static func xWindow(_ chart: StandardChart, xs: [Double]) -> ClosedRange<Double> {
        if let range = chart.xRange, range.count == 2, range[1] > range[0] {
            return min(range[0], xs.min() ?? range[0])...max(range[1], xs.max() ?? range[1])
        }
        let low = (xs.min() ?? -5) - 1, high = (xs.max() ?? 5) + 1
        return low...high
    }

    /// Linear interpolation of a sampled curve at `x`; nil outside the sampled span.
    static func value(of curve: [[Double]], at x: Double) -> Double? {
        let pts = curve.filter { $0.count >= 2 }
        guard let first = pts.first, let last = pts.last, first[0] <= x, x <= last[0] else { return nil }
        for i in 1..<pts.count where pts[i][0] >= x {
            let (a, b) = (pts[i - 1], pts[i])
            guard b[0] > a[0] else { return b[1] }
            let t = (x - a[0]) / (b[0] - a[0])
            return a[1] + t * (b[1] - a[1])
        }
        return last[1]
    }

    // MARK: Verdict

    /// Passes when at most a third of the checks disagree (one misread point should not sink a right equation).
    static func verdict(checks: Int, failures: [String], subject: String) -> ChartVerification {
        if failures.count * 3 <= checks {
            let agreed = checks - failures.count
            return ChartVerification(passed: true, summary: "Verified: \(agreed) of \(checks) points read from the picture agree with \(subject).")
        }
        let shown = failures.prefix(2).joined(separator: "; ")
        return ChartVerification(passed: false, summary: "Mismatch: \(failures.count) of \(checks) points disagree with \(subject) — \(shown).")
    }

    static func number(_ value: Double) -> String { ChartGeometry.number(value) }

    static func display(_ latex: String) -> String {
        latex.contains("=") ? latex : "y = \(latex)"
    }
}
