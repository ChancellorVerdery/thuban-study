import Foundation

/// Replaces curves traced from a picture with the exact curves they are: the solution of the differential
/// equation the question states (or of dy/dx = f(y) built from the equilibria the figure labels), or the
/// polynomial a "the graph of f is shown" figure draws. Every fit is scored against the traced pixels and kept
/// only when it lands on the drawn curve; otherwise the trace stays.
public enum CurveFitter {
    /// A fit is kept when its mean distance to the trace is within this fraction of the window's size (a couple
    /// of pixels on a course plot).
    public static let tolerance = 0.008

    // MARK: Equations from the question

    /// The right-hand side of the first `dy/dx = …` (or `y' = …`) the text states, as LaTeX; nil when there is
    /// none or it is only a name ("f(y)").
    public static func statedSlope(in text: String) -> String? {
        let patterns = [#"\\d?frac\{dy\}\{dx\}\s*=\s*([^$]+)"#, #"y'\s*=\s*([^$]+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            var rhs = String(text[range])
            // The equation ends at a comma, a spacing command or a new clause ("y(0) = 1" after it).
            for stop in [",", ";", "\\quad", "\\qquad", "\\text", "\\,", "\n"] {
                if let cut = rhs.range(of: stop) { rhs = String(rhs[..<cut.lowerBound]) }
            }
            rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = rhs.last, ".\\".contains(last) { rhs.removeLast() }
            rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            if rhs.isEmpty || rhs.range(of: #"^[a-zA-Z]\s*\(\s*[xy]\s*\)$"#, options: .regularExpression) != nil { continue }
            return rhs
        }
        return nil
    }

    /// Whether the text is about an autonomous equation dy/dx = f(y) whose f is given only by its graph.
    static func mentionsAutonomousF(_ text: String) -> Bool {
        text.range(of: #"=\s*f\s*\(\s*y\s*\)"#, options: .regularExpression) != nil
    }

    /// Whether the figure is the graph of a function (not a sketch of solutions): its vertical axis is named f,
    /// or the question shows "the graph of f" and is not about solutions of dy/dx = f(y).
    static func isGraphOfF(_ text: String, chart: StandardChart) -> Bool {
        let vertical = (chart.yLabel ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if vertical.hasPrefix("f") { return true }
        if vertical == "y" { return false }
        let lower = text.lowercased()
        return (lower.contains("graph of $f") || lower.contains("graph of f")) && !mentionsAutonomousF(text)
    }

    /// True when the right-hand side does not involve x (after dropping LaTeX command names such as \exp).
    static func isAutonomous(_ rhs: String) -> Bool {
        !rhs.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: "", options: .regularExpression).contains("x")
    }

    // MARK: Fitting

    public static func fit(_ chart: StandardChart, questionText: String, engine: MathEngine) async -> StandardChart? {
        guard !chart.isSlopeField, !chart.isPhaseLine, !questionText.isEmpty else { return nil }
        let window = FigureScene.window(for: chart)
        let traced = chart.series.indices.filter {
            (chart.series[$0].latex ?? "").isEmpty && chart.series[$0].throughPoint == nil && (chart.series[$0].points?.count ?? 0) >= 6
        }
        guard !traced.isEmpty else { return nil }
        var result = chart
        var notes: [String] = []
        var exact = 0

        // Function graphs: a polynomial through the trace.
        if isGraphOfF(questionText, chart: chart) {
            for index in traced {
                guard let polynomial = fitPolynomial(chart.series[index].points!, window: window) else {
                    notes.append("\(chart.series[index].name) kept as traced (no low-degree polynomial follows it)")
                    continue
                }
                let variable = (chart.xLabel ?? "").trimmingCharacters(in: .whitespaces) == "y" ? "y" : "x"
                result.series[index].latex = polynomial.latex
                result.series[index].points = nil
                exact += 1
                notes.append("\(chart.series[index].name): \(variable == "y" ? "f(y)" : "f(x)") = \(polynomial.latex.replacingOccurrences(of: "x", with: variable)) (within \(percent(polynomial.error)) of the window)")
            }
            return finish(result, exact: exact, of: traced.count, notes: notes, definition: nil)
        }

        // Solution curves: the stated equation, or f(y) built from the labelled equilibria.
        var models: [(label: String, rhs: String)] = []
        if let stated = statedSlope(in: questionText) {
            models.append(("dy/dx = \(stated)", stated))
        } else if mentionsAutonomousF(questionText) {
            let labels = (chart.yAxisLabels ?? []).filter { $0.value.isFinite }
            let values = labels.map(\.value)
            var rootSets: [[Double]] = []
            if !values.isEmpty { rootSets.append(values.sorted()) }
            if !values.contains(where: { abs($0) < 1e-9 }) { rootSets.append((values + [0]).sorted()) }
            for roots in rootSets {
                let product = roots.map { r -> String in
                    r == 0 ? "y" : r > 0 ? "\\left(y-\(number(r))\\right)" : "\\left(y+\(number(-r))\\right)"
                }.joined()
                let names = roots.map { r in labels.first { abs($0.value - r) < 1e-9 }?.text ?? number(r) }
                let label = "dy/dx = f(y), f read as zero only at y = \(names.joined(separator: ", "))"
                models.append((label, product))
                models.append((label, "-" + product))
            }
        }
        guard !models.isEmpty else { return nil }
        // An x axis printed without numbers leaves the time scale free: it is fitted too (dy/dx = k·f).
        let freeScale = (chart.xAxisLabels ?? []).isEmpty
        // A flat line is an equilibrium: it is matched to a zero of f, and says nothing about the time scale.
        let h = window.y.upperBound - window.y.lowerBound
        let flat = traced.filter { index in
            let ys = chart.series[index].points!.map { $0[1] }
            return ys.max()! - ys.min()! < 0.02 * h
        }
        let moving = traced.filter { !flat.contains($0) }
        func level(_ index: Int) -> Double {
            let ys = chart.series[index].points!.map { $0[1] }
            return ys.reduce(0, +) / Double(ys.count)
        }
        var best: (label: String, rhs: String, scale: Double, fits: [Int: SolutionFit], total: Double, solver: Solver)?
        for model in models {
            guard let solver = await Solver.make(model.rhs, window: window, engine: engine) else { continue }
            // Each flat line costs its distance to the nearest equilibrium of this model.
            let flatCost = flat.reduce(0.0) { sum, index in
                sum + min(0.25, solver.equilibrium(near: level(index)).map { abs($0 - level(index)) / h } ?? 0.25)
            }
            var total = Double.infinity, fits: [Int: SolutionFit] = [:]
            // A scale is abandoned as soon as its curves already miss by more than the best one's.
            func score(_ scale: Double) async -> (Double, [Int: SolutionFit]) {
                let bound = min(total, best?.total ?? .infinity)
                var sum = flatCost, found: [Int: SolutionFit] = [:]
                if sum > bound { return (.infinity, [:]) }
                for index in moving {
                    guard let fit = await fitSolution(solver, scale: scale, trace: chart.series[index].points!, window: window) else { return (.infinity, [:]) }
                    found[index] = fit
                    sum += fit.error
                    if sum > bound { return (.infinity, [:]) }
                }
                return (sum, found)
            }
            var scale = 1.0
            (total, fits) = await score(1)
            if freeScale, solver.autonomous, !moving.isEmpty {
                // Coarse scan of log₂ k, then a golden-section refinement around the best.
                var bestLog = 0.0
                for log in stride(from: -4.0, through: 4.0, by: 0.5) where log != 0 {
                    let (t, f) = await score(pow(2, log))
                    if t < total { total = t; fits = f; bestLog = log }
                }
                guard total.isFinite else { continue }
                var a = bestLog - 0.5, b = bestLog + 0.5
                let ratio = (sqrt(5) - 1) / 2
                for _ in 0..<9 {
                    let c = b - ratio * (b - a), d = a + ratio * (b - a)
                    let (tc, fc) = await score(pow(2, c)), (td, fd) = await score(pow(2, d))
                    if tc < td { b = d; if tc < total { total = tc; fits = fc; bestLog = c } }
                    else { a = c; if td < total { total = td; fits = fd; bestLog = d } }
                }
                scale = pow(2, bestLog)
            }
            if total < (best?.total ?? .infinity) { best = (model.label, model.rhs, scale, fits, total, solver) }
        }
        guard let best else { return nil }
        for index in flat {
            guard let root = best.solver.equilibrium(near: level(index)), abs(root - level(index)) <= 0.015 * h else {
                notes.append("\(chart.series[index].name) kept as traced (no equilibrium of the equation at its height)")
                continue
            }
            result.series[index].latex = "y=\(number(root))"
            result.series[index].points = nil
            exact += 1
            notes.append("\(chart.series[index].name): the equilibrium y = \(number(root))")
        }
        for index in moving {
            guard let fit = best.fits[index], fit.error <= tolerance else {
                notes.append("\(chart.series[index].name) kept as traced (no solution of the equation follows it closely)")
                continue
            }
            let xs = chart.series[index].points!.map { $0[0] }
            result.series[index].through = [round4(fit.x0), round4(fit.y0)]
            result.series[index].domain = [round4(xs.min()!), round4(xs.max()!)]
            result.series[index].points = nil
            exact += 1
            notes.append("\(chart.series[index].name): the solution through (\(number(fit.x0)), \(number(fit.y0))) (within \(percent(fit.error)) of the window)")
        }
        guard exact > 0 else { return nil }
        guard !moving.isEmpty, moving.contains(where: { result.series[$0].through != nil }) else {
            return finish(result, exact: exact, of: traced.count, notes: notes, definition: best.label)
        }
        let scaled = abs(best.scale - 1) > 0.005
        result.odeSlope = scaled ? "\(number(best.scale))\\left(\(best.rhs)\\right)" : best.rhs
        let definition = best.label + (scaled ? " (the x axis has no numbers, so its scale was fitted: dy/dx = \(number(best.scale))·f)" : "")
        return finish(result, exact: exact, of: traced.count, notes: notes, definition: definition)
    }

    static func finish(_ chart: StandardChart, exact: Int, of total: Int, notes: [String], definition: String?) -> StandardChart? {
        guard exact > 0 else { return nil }
        var result = chart
        if let definition { result.definition = definition }
        if exact == total { result.provenance = StandardChart.stated }
        result.confidence = max(result.confidence, 0.75 + 0.25 * Double(exact) / Double(max(total, 1)))
        result.verification = ChartVerification(passed: true, summary: "Exact curves: \(exact) of \(total) drawn curve\(total == 1 ? "" : "s") matched to their equation — " + notes.joined(separator: "; ") + ".")
        return result
    }

    // MARK: Solutions

    struct SolutionFit { var x0: Double; var y0: Double; var error: Double }

    /// Integrates dy/dx = k·f. Autonomous right-hand sides are tabulated once over y and integrated here (RK4),
    /// so many candidate starts and scales cost little; others go through the engine.
    struct Solver {
        var rhs: String
        var autonomous: Bool
        var engine: MathEngine
        var window: FigureScene.Window
        var low = 0.0, step = 0.0
        var table: [Double?] = []

        static func make(_ rhs: String, window: FigureScene.Window, engine: MathEngine) async -> Solver? {
            var solver = Solver(rhs: rhs, autonomous: isAutonomous(rhs), engine: engine, window: window)
            guard solver.autonomous else { return solver }
            let h = window.y.upperBound - window.y.lowerBound
            let n = 4000
            solver.low = window.y.lowerBound - h
            solver.step = 3 * h / Double(n)
            let ys = (0...n).map { solver.low + solver.step * Double($0) }
            guard let sampled = try? await engine.samples(of: rhs, at: ys.map { (x: 0, y: $0) }),
                  sampled.values.contains(where: { $0 != nil }) else { return nil }
            solver.table = sampled.values.map { $0.flatMap { $0.isFinite ? $0 : nil } }
            return solver
        }

        /// The zero of f nearest `y` (autonomous only), from sign changes of the table refined linearly.
        func equilibrium(near y: Double) -> Double? {
            guard autonomous else { return nil }
            var nearest: Double?
            let largest = table.compactMap { $0.map(abs) }.max() ?? 0
            for i in 0..<(table.count - 1) {
                guard let a = table[i], let b = table[i + 1] else { continue }
                let root: Double
                if a == 0 { root = low + step * Double(i) }
                else if a * b < 0 { root = low + step * (Double(i) + a / (a - b)) }
                else if i > 0, let before = table[i - 1], abs(a) <= abs(before), abs(a) <= abs(b), abs(a) < largest * 1e-7 {
                    // A zero f touches without crossing ((y − 4)⁴).
                    root = low + step * Double(i)
                }
                else { continue }
                if nearest == nil || abs(root - y) < abs(nearest! - y) { nearest = root }
            }
            // Snap away interpolation dust (1.0000003 → 1).
            return nearest.map { ($0 * 1000).rounded() / 1000 }
        }

        func f(_ y: Double) -> Double? {
            let t = (y - low) / step
            let i = Int(t.rounded(.down))
            guard i >= 0, i + 1 < table.count, let a = table[i], let b = table[i + 1] else { return nil }
            return a + (b - a) * (t - Double(i))
        }

        /// The solution through (x0, y0) across the window, as points; stops where it leaves a band around it.
        func solve(scale k: Double, x0: Double, y0: Double, over span: ClosedRange<Double>? = nil) async -> [[Double]] {
            let xRange = span ?? window.x
            guard autonomous else {
                let rhs = abs(k - 1) < 1e-9 ? self.rhs : "\(number(k))\\left(\(self.rhs)\\right)"
                return (try? await engine.integrateSlope(rhs, through: (x0, y0), xRange: xRange, yRange: window.y, steps: 300)) ?? []
            }
            let w = window.x.upperBound - window.x.lowerBound, h = window.y.upperBound - window.y.lowerBound
            let top = window.y.upperBound + h * 0.5, bottom = window.y.lowerBound - h * 0.5
            var forward: [[Double]] = [], backward: [[Double]] = []
            for direction in [1.0, -1.0] {
                var x = x0, y = y0
                let end = direction > 0 ? xRange.upperBound : xRange.lowerBound
                let base = w / 200 * direction
                while direction > 0 ? x < end : x > end {
                    // Smaller steps where the curve is steep on screen.
                    guard let k1 = f(y) else { break }
                    let screen = abs(k * k1) * w / h
                    let dx = base / max(1, min(12, screen))
                    guard let k2 = f(y + dx * k * k1 / 2), let k3 = f(y + dx * k * k2 / 2), let k4 = f(y + dx * k * k3) else { break }
                    y += dx * k * (k1 + 2 * k2 + 2 * k3 + k4) / 6
                    x += dx
                    guard y.isFinite, y < top, y > bottom else { break }
                    if direction > 0 { forward.append([x, y]) } else { backward.append([x, y]) }
                }
            }
            return backward.reversed() + [[x0, y0]] + forward
        }
    }

    /// The solution of dy/dx = k·f that best follows a traced curve: anchored where the drawn curve runs closest
    /// to 45° on screen (flat where it is flat everywhere), its height there refined by a golden-section search.
    static func fitSolution(_ solver: Solver, scale: Double, trace: [[Double]], window: FigureScene.Window) async -> SolutionFit? {
        let w = window.x.upperBound - window.x.lowerBound, h = window.y.upperBound - window.y.lowerBound
        let pts = trace.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
        guard pts.count >= 6 else { return nil }
        var anchor = pts.count / 2, closest = Double.infinity
        for i in 2..<(pts.count - 2) {
            let dx = (pts[i + 2][0] - pts[i - 2][0]) / w, dy = (pts[i + 2][1] - pts[i - 2][1]) / h
            let angle = abs(atan2(abs(dy), abs(dx)) - .pi / 4)
            if angle < closest { closest = angle; anchor = i }
        }
        let x0 = pts[anchor][0], guess = pts[anchor][1]
        let sample = thinned(pts, to: 40)
        let xs = pts.map { $0[0] }
        let span = (xs.min()! - 0.02 * w)...(xs.max()! + 0.02 * w)
        func error(_ y0: Double) async -> Double {
            let path = await solver.solve(scale: scale, x0: x0, y0: y0, over: span)
            guard path.count >= 2 else { return .infinity }
            return distance(from: sample, to: thinned(path, to: 240), w: w, h: h)
        }
        var a = guess - 0.05 * h, b = guess + 0.05 * h
        let ratio = (sqrt(5) - 1) / 2
        var c = b - ratio * (b - a), d = a + ratio * (b - a)
        var fc = await error(c), fd = await error(d)
        for _ in 0..<14 {
            if fc < fd { b = d; d = c; fd = fc; c = b - ratio * (b - a); fc = await error(c) }
            else { a = c; c = d; fc = fd; d = a + ratio * (b - a); fd = await error(d) }
        }
        let fitted = fc < fd ? (c, fc) : (d, fd)
        guard fitted.1.isFinite else { return nil }
        return SolutionFit(x0: x0, y0: fitted.0, error: fitted.1)
    }

    /// At most `n` evenly chosen points, keeping both ends.
    static func thinned(_ points: [[Double]], to n: Int) -> [[Double]] {
        guard points.count > n, n >= 2 else { return points }
        return (0..<n).map { points[Int((Double($0) * Double(points.count - 1) / Double(n - 1)).rounded())] }
    }

    /// Mean distance from each traced point to a path (to its nearest segment), in window-normalised units.
    static func distance(from trace: [[Double]], to path: [[Double]], w: Double, h: Double) -> Double {
        let q = path.map { ($0[0] / w, $0[1] / h) }
        guard q.count >= 2 else { return .infinity }
        var total = 0.0
        for p in trace {
            let px = p[0] / w, py = p[1] / h
            var best = Double.infinity
            for i in 0..<(q.count - 1) {
                let (ax, ay) = q[i], (bx, by) = q[i + 1]
                let vx = bx - ax, vy = by - ay
                let len = vx * vx + vy * vy
                let t = len > 0 ? max(0, min(1, ((px - ax) * vx + (py - ay) * vy) / len)) : 0
                let dx = px - (ax + t * vx), dy = py - (ay + t * vy)
                best = min(best, dx * dx + dy * dy)
            }
            total += min(best.squareRoot(), 0.25)
        }
        return total / Double(trace.count)
    }

    // MARK: Polynomials

    /// The lowest-degree polynomial (1…6) that follows the trace within tolerance, with its coefficients rounded
    /// (to integers, halves or quarters) when that still follows it. Nil when none fits.
    static func fitPolynomial(_ trace: [[Double]], window: FigureScene.Window) -> (latex: String, error: Double)? {
        let pts = trace.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
        guard pts.count >= 6 else { return nil }
        let h = window.y.upperBound - window.y.lowerBound, w = window.x.upperBound - window.x.lowerBound
        let lo = pts.map { $0[0] }.min()!, hi = pts.map { $0[0] }.max()!
        func error(_ coefficients: [Double]) -> Double {
            let path = stride(from: lo, through: hi, by: (hi - lo) / 400).map { x in [x, evaluate(coefficients, x)] }
            return distance(from: pts, to: path, w: w, h: h)
        }
        for degree in 1...6 {
            guard let coefficients = leastSquares(pts, degree: degree) else { continue }
            let raw = error(coefficients)
            guard raw <= tolerance else { continue }
            let allowed = min(tolerance, max(raw * 1.25, raw + 0.001))
            for step in [1.0, 0.5, 0.25] {
                let rounded = coefficients.map { ($0 / step).rounded() * step }
                let e = error(rounded)
                if e <= allowed { return (latex(rounded), e) }
            }
            // Factored: its zeros snapped to tenths (as a figure labels them) and a round leading coefficient.
            let roots = realRoots(coefficients, in: lo...hi)
            if roots.count == degree {
                let snapped = roots.map { ($0 * 10).rounded() / 10 }
                let product = { (x: Double) in snapped.reduce(1.0) { $0 * (x - $1) } }
                let num = pts.reduce(0.0) { $0 + $1[1] * product($1[0]) }, den = pts.reduce(0.0) { $0 + pow(product($1[0]), 2) }
                if den > 0 {
                    let lead = num / den
                    for step in [0.25, 0.05] {
                        let a = (lead / step).rounded() * step
                        guard a != 0 else { continue }
                        let expanded = snapped.reduce([a]) { c, r in
                            // Multiply by (x − r).
                            var next = [Double](repeating: 0, count: c.count + 1)
                            for (k, v) in c.enumerated() { next[k + 1] += v; next[k] -= r * v }
                            return next
                        }
                        let e = error(expanded)
                        if e <= allowed { return (factored(a, snapped), e) }
                    }
                }
            }
            return (latex(coefficients.map { ($0 * 1000).rounded() / 1000 }), raw)
        }
        return nil
    }

    static func evaluate(_ c: [Double], _ x: Double) -> Double { c.reversed().reduce(0) { $0 * x + $1 } }

    /// Coefficients c0…cn of the least-squares polynomial (normal equations, Gauss–Jordan with pivoting).
    static func leastSquares(_ pts: [[Double]], degree n: Int) -> [Double]? {
        let m = n + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
        for p in pts {
            var powers = [Double](repeating: 1, count: 2 * m)
            for k in 1..<(2 * m) { powers[k] = powers[k - 1] * p[0] }
            for i in 0..<m {
                for j in 0..<m { a[i][j] += powers[i + j] }
                a[i][m] += powers[i] * p[1]
            }
        }
        for col in 0..<m {
            guard let pivot = (col..<m).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<m where row != col {
                let f = a[row][col] / a[col][col]
                for k in col...m { a[row][k] -= f * a[col][k] }
            }
        }
        return (0..<m).map { a[$0][m] / a[$0][$0] }
    }

    /// The real zeros of a polynomial within a range (sign changes on a fine grid, refined by bisection).
    static func realRoots(_ c: [Double], in range: ClosedRange<Double>) -> [Double] {
        let n = 2000
        let step = (range.upperBound - range.lowerBound) / Double(n)
        var roots: [Double] = []
        var previous = evaluate(c, range.lowerBound)
        for i in 1...n {
            let x = range.lowerBound + step * Double(i)
            let value = evaluate(c, x)
            if previous == 0 || previous * value < 0 {
                var a = x - step, b = x
                for _ in 0..<50 {
                    let m = (a + b) / 2
                    if evaluate(c, a) * evaluate(c, m) <= 0 { b = m } else { a = m }
                }
                roots.append((a + b) / 2)
            }
            previous = value
        }
        return roots
    }

    /// "-0.5\left(x+2.2\right)\left(x-0.5\right)\left(x-1.7\right)".
    static func factored(_ lead: Double, _ roots: [Double]) -> String {
        let coefficient = lead == 1 ? "" : lead == -1 ? "-" : number(lead)
        return coefficient + roots.map { r in
            r == 0 ? "x" : r > 0 ? "\\left(x-\(number(r))\\right)" : "\\left(x+\(number(-r))\\right)"
        }.joined()
    }

    /// "x^{4}-5x^{2}+4" from coefficients c0…cn.
    static func latex(_ c: [Double]) -> String {
        var out = ""
        for power in stride(from: c.count - 1, through: 0, by: -1) {
            let value = c[power]
            guard abs(value) > 1e-9 else { continue }
            let magnitude = abs(value)
            let sign = value < 0 ? "-" : (out.isEmpty ? "" : "+")
            let coefficient = (abs(magnitude - 1) < 1e-12 && power > 0) ? "" : number(magnitude)
            let variable = power == 0 ? "" : power == 1 ? "x" : "x^{\(power)}"
            out += sign + coefficient + variable
        }
        return out.isEmpty ? "0" : out
    }

    static func number(_ v: Double) -> String { ChartGeometry.number((v * 10_000).rounded() / 10_000) }
    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
    static func percent(_ v: Double) -> String { String(format: "%.1f %%", v * 100) }
}
