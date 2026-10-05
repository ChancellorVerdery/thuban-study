import Foundation

/// The geometry of the series that are not a single function of x: shaded regions (inequalities), families of
/// level curves, parametric curves (with arrows the way t runs), and zero contours of relations, all in data
/// coordinates. Every grid is evaluated in one compiled engine call (`MathEngine.values`), so even a dense contour
/// map builds in well under a second.
public enum ChartShapes {
    /// Grid sizes: a region's mask and a contour map's function are sampled on (n+1)² points.
    static let regionGrid = 240
    static let contourGrid = 200
    static let parametricSamples = 1500

    // MARK: Inequalities

    /// The conditions of a region, each as an expression `g` with `g ≥ 0` inside: "x^2+y^2\le 49, x\ge 0" →
    /// ["(49)-(x^2+y^2)", "(x)-(0)"]; chains ("-1\le x+y\le 1") give one condition per link. Nil when any piece is
    /// not an inequality (an equation is a boundary, not a region).
    public static func conditions(_ latex: String) -> [String]? {
        strictConditions(latex)?.map(\.condition)
    }

    /// The conditions with whether each is strict (< or >: its boundary is not part of the region, drawn dashed).
    public static func strictConditions(_ latex: String) -> [(condition: String, strict: Bool)]? {
        let pieces = splitTopLevel(normalised(latex))
        guard !pieces.isEmpty else { return nil }
        var result: [(condition: String, strict: Bool)] = []
        for piece in pieces {
            let (terms, relations, strict) = splitRelationsDetailed(piece)
            guard !relations.isEmpty, terms.count == relations.count + 1, terms.allSatisfy({ !$0.isEmpty }),
                  !relations.contains(.equal) else { return nil }
            for (k, relation) in relations.enumerated() {
                let a = terms[k], b = terms[k + 1]
                switch relation {
                case .less: result.append(("\\left(\(b)\\right)-\\left(\(a)\\right)", strict[k]))
                case .greater: result.append(("\\left(\(a)\\right)-\\left(\(b)\\right)", strict[k]))
                // Everywhere (|a − b| ≥ 0): the excluded line is drawn as its own dashed curve.
                default: result.append(("\\left|\(a)-\(b)\\right|", true))
                }
            }
        }
        return result
    }

    /// "x^2+y^2=49, x\le 0": one equation restricted by conditions (an arc, a ray, a piece of a curve). The
    /// equation and the conditions (each `g ≥ 0` where the curve is kept); nil for anything else.
    public static func restrictedEquation(_ latex: String) -> (equation: String, conditions: [String])? {
        let pieces = splitTopLevel(normalised(latex))
        guard pieces.count >= 2 else { return nil }
        var equation: String?, conditions: [String] = []
        for piece in pieces {
            let (_, relations) = splitRelations(piece)
            if relations == [.equal] {
                guard equation == nil else { return nil }
                equation = piece
            } else if let parsed = Self.conditions(piece) {
                conditions += parsed
            } else {
                return nil
            }
        }
        guard let equation, !conditions.isEmpty else { return nil }
        return (equation, conditions)
    }

    /// An equation's curve kept only where its conditions hold, broken where they stop holding.
    public static func restrictedRelation(_ equation: String, conditions: [String], window: FigureScene.Window,
                                          engine: MathEngine) async -> [[[Double]]]? {
        guard let curve = await FigureScene.curve(equation, window: window, engine: engine), !curve.isEmpty else { return nil }
        let points = curve.flatMap { $0 }
        guard let rows = try? await engine.values(of: conditions, variables: ["x", "y"], at: points) else { return nil }
        let tolerance = 1e-3 * max(window.x.upperBound - window.x.lowerBound, window.y.upperBound - window.y.lowerBound)
        var pieces: [[[Double]]] = [], k = 0
        for piece in curve {
            var current: [[Double]] = []
            for p in piece {
                let keep = rows.allSatisfy { row in (row?[k]).flatMap { $0 } .map { $0 >= -tolerance } ?? false }
                k += 1
                if keep { current.append(p) }
                else {
                    if current.count >= 2 { pieces.append(current) }
                    current = []
                }
            }
            if current.count >= 2 { pieces.append(current) }
        }
        return pieces
    }

    /// The LaTeX holds an inequality (so a series without a `kind` is a region).
    public static func isInequality(_ latex: String) -> Bool { conditions(latex) != nil }

    /// "x = \cos(5t), y = \sin(2t)": the two coordinates of a parametric curve in t, when the LaTeX is written so.
    public static func parametricPair(_ latex: String) -> (x: String, y: String)? {
        var x: String?, y: String?
        for piece in splitTopLevel(normalised(latex)) {
            let (terms, relations) = splitRelations(piece)
            guard relations == [.equal], terms.count == 2 else { continue }
            let lhs = terms[0].replacingOccurrences(of: " ", with: ""), rhs = terms[1]
            if lhs == "x" || lhs == "x(t)" || lhs == "x\\left(t\\right)" { x = rhs }
            if lhs == "y" || lhs == "y(t)" || lhs == "y\\left(t\\right)" { y = rhs }
        }
        guard let x, let y, mentionsT(x) || mentionsT(y) else { return nil }
        return (x, y)
    }

    private static func mentionsT(_ latex: String) -> Bool {
        // A lone t (not inside a command such as \tan or \theta or \text).
        let scalars = Array(latex.unicodeScalars)
        for (i, c) in scalars.enumerated() where c == "t" {
            var j = i - 1
            while j >= 0, CharacterSet.letters.contains(scalars[j]) { j -= 1 }
            if j >= 0, scalars[j] == "\\" { continue }
            let next = i + 1 < scalars.count ? scalars[i + 1] : " "
            let prev = i > 0 ? scalars[i - 1] : " "
            if !CharacterSet.letters.contains(next) || !CharacterSet.letters.contains(prev) { return true }
        }
        return false
    }

    enum Relation: Equatable { case less, greater, equal, notEqual }

    /// Plain-text formulas as LaTeX the engine reads: sqrt(x) → \sqrt{x}, sin( → \sin(, asin → \arcsin, pi → \pi,
    /// ≤ → \le, "and" between conditions → ",".
    public static func normalised(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "≤", with: "\\le ").replacingOccurrences(of: "≥", with: "\\ge ")
            .replacingOccurrences(of: "<=", with: "\\le ").replacingOccurrences(of: ">=", with: "\\ge ")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "\\pi ")
            .replacingOccurrences(of: "\\text{ and }", with: ",").replacingOccurrences(of: "\\text{and}", with: ",")
            .replacingOccurrences(of: "\\land", with: ",").replacingOccurrences(of: "\\wedge", with: ",")
            .replacingOccurrences(of: "\\leqslant", with: "\\le ").replacingOccurrences(of: "\\geqslant", with: "\\ge ")
            .replacingOccurrences(of: "\\leq", with: "\\le ").replacingOccurrences(of: "\\geq", with: "\\ge ")
            .replacingOccurrences(of: "\\lt", with: "<").replacingOccurrences(of: "\\gt", with: ">")
            .replacingOccurrences(of: "\\neq", with: "≠").replacingOccurrences(of: "\\ne", with: "≠").replacingOccurrences(of: "!=", with: "≠")
        // sqrt(...) → \sqrt{...}
        while let range = bareWord("sqrt", in: s), s[range.upperBound...].first == "(" {
            guard let close = matching(s, from: range.upperBound) else { break }
            let inner = s[s.index(after: range.upperBound)..<close]
            s.replaceSubrange(range.lowerBound...close, with: "\\sqrt{\(inner)}")
        }
        let names: [(String, String)] = [("asin", "\\arcsin"), ("acos", "\\arccos"), ("atan", "\\arctan"), ("arcsin", "\\arcsin"),
                                         ("arccos", "\\arccos"), ("arctan", "\\arctan"), ("sinh", "\\sinh"), ("cosh", "\\cosh"),
                                         ("tanh", "\\tanh"), ("sin", "\\sin"), ("cos", "\\cos"), ("tan", "\\tan"), ("sec", "\\sec"),
                                         ("csc", "\\csc"), ("cot", "\\cot"), ("ln", "\\ln"), ("log", "\\log"), ("exp", "\\exp"), ("pi", "\\pi ")]
        for (word, command) in names {
            while let range = bareWord(word, in: s) { s.replaceSubrange(range, with: command) }
        }
        return s
    }

    /// `word` standing alone (not part of a longer name, not already a command).
    private static func bareWord(_ word: String, in s: String) -> Range<String.Index>? {
        var from = s.startIndex
        while let range = s.range(of: word, range: from..<s.endIndex) {
            let before = range.lowerBound > s.startIndex ? s[s.index(before: range.lowerBound)] : " "
            let after = range.upperBound < s.endIndex ? s[range.upperBound] : " "
            if !before.isLetter, before != "\\", !after.isLetter { return range }
            from = range.upperBound
        }
        return nil
    }

    /// The index of the bracket closing the one at `open`.
    private static func matching(_ s: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if "({[".contains(s[i]) { depth += 1 }
            if ")}]".contains(s[i]) { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    /// Pieces separated by top-level commas or semicolons (inside no bracket).
    static func splitTopLevel(_ s: String) -> [String] {
        var pieces: [String] = [], current = "", depth = 0
        for c in s {
            if "({[".contains(c) { depth += 1 }
            if ")}]".contains(c) { depth = max(0, depth - 1) }
            if depth == 0, c == "," || c == ";" {
                pieces.append(current); current = ""
                continue
            }
            current.append(c)
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A piece split at its top-level relation signs: "-1\le x+y\le 1" → (["-1", "x+y", "1"], [.less, .less]).
    static func splitRelations(_ piece: String) -> ([String], [Relation]) {
        let (terms, relations, _) = splitRelationsDetailed(piece)
        return (terms, relations)
    }

    /// `splitRelations` with whether each relation is strict (< > ≠ rather than ≤ ≥ =).
    static func splitRelationsDetailed(_ piece: String) -> ([String], [Relation], [Bool]) {
        let chars = Array(piece)
        var terms: [String] = [], relations: [Relation] = [], strictness: [Bool] = [], current = "", depth = 0, i = 0
        func command(_ name: String) -> Bool {
            let n = Array(name)
            guard i + n.count <= chars.count, Array(chars[i..<(i + n.count)]) == n else { return false }
            return i + n.count == chars.count || !chars[i + n.count].isLetter
        }
        while i < chars.count {
            let c = chars[i]
            if "({[".contains(c) { depth += 1 }
            if ")}]".contains(c) { depth = max(0, depth - 1) }
            if depth == 0 {
                var relation: Relation?, length = 0
                if command("\\le") { relation = .less; length = 3 }
                else if command("\\ge") { relation = .greater; length = 3 }
                else if c == "<" { relation = .less; length = 1 }
                else if c == ">" { relation = .greater; length = 1 }
                else if c == "=" { relation = .equal; length = 1 }
                else if c == "≠" { relation = .notEqual; length = 1 }
                if let relation {
                    terms.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                    relations.append(relation)
                    strictness.append(length == 1 && (c == "<" || c == ">" || c == "≠"))
                    i += length
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        terms.append(current.trimmingCharacters(in: .whitespaces))
        return (terms, relations, strictness)
    }

    // MARK: Grids

    /// The (n+1)² grid points across the window, row by row from the bottom.
    static func gridPoints(_ window: FigureScene.Window, n: Int) -> [[Double]] {
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        var points: [[Double]] = []
        points.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n { for i in 0...n {
            points.append([window.x.lowerBound + xSpan * Double(i) / Double(n), window.y.lowerBound + ySpan * Double(j) / Double(n)])
        } }
        return points
    }

    /// A shaded region: the inside as rectangles (one per run of inside grid cells along each row,
    /// `[[x0, y0], [x1, y1]]`) and its boundary as polylines. Nil when the conditions cannot be evaluated.
    public static func region(_ latex: String, window: FigureScene.Window, engine: MathEngine) async -> (fill: [[[Double]]], boundary: [[[Double]]], dashed: [[[Double]]])? {
        guard let detailed = strictConditions(latex), !detailed.isEmpty else { return nil }
        let conditions = detailed.map(\.condition)
        let n = regionGrid
        let points = gridPoints(window, n: n)
        guard let rows = try? await engine.values(of: conditions, variables: ["x", "y"], at: points) else { return nil }
        let evaluated = rows.compactMap { $0 }
        guard evaluated.count == conditions.count else { return nil }
        // The tightest condition at each point: ≥ 0 inside.
        var margin = [Double?](repeating: nil, count: points.count)
        for k in 0..<points.count {
            var worst: Double?
            for row in evaluated {
                guard let v = row[k] else { worst = nil; break }
                worst = min(worst ?? v, v)
            }
            margin[k] = worst
        }
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let cw = xSpan / Double(n), ch = ySpan / Double(n)
        var fill: [[[Double]]] = []
        for j in 0...n {
            var start: Int?
            for i in 0...(n + 1) {
                let inside = i <= n && (margin[j * (n + 1) + i] ?? -1) >= 0
                if inside, start == nil { start = i }
                if !inside, let s = start {
                    let x0 = max(window.x.lowerBound, window.x.lowerBound + cw * (Double(s) - 0.5))
                    let x1 = min(window.x.upperBound, window.x.lowerBound + cw * (Double(i - 1) + 0.5))
                    let y0 = max(window.y.lowerBound, window.y.lowerBound + ch * (Double(j) - 0.5))
                    let y1 = min(window.y.upperBound, window.y.lowerBound + ch * (Double(j) + 0.5))
                    fill.append([[x0, y0], [x1, y1]])
                    start = nil
                }
            }
        }
        // Each condition's own edge, kept where the rest of the region holds: solid where the edge belongs to the
        // region (≤, ≥), dashed where it does not (<, >).
        var solid: [[[Double]]] = [], dashed: [[[Double]]] = []
        let tolerance = 1e-3 * max(xSpan, ySpan)
        for (k, row) in evaluated.enumerated() {
            let edge = contours(row, n: n, level: 0, window: window)
            guard !edge.isEmpty else { continue }
            var kept: [[[Double]]] = edge
            if evaluated.count > 1 {
                let others = (0..<conditions.count).filter { $0 != k }.map { conditions[$0] }
                let flat = edge.flatMap { $0 }
                guard let values = try? await engine.values(of: others, variables: ["x", "y"], at: flat) else { continue }
                kept = []
                var index = 0
                for piece in edge {
                    var current: [[Double]] = []
                    for p in piece {
                        let inside = values.allSatisfy { row in (row?[index]).flatMap { $0 }.map { $0 >= -tolerance } ?? false }
                        index += 1
                        if inside { current.append(p) } else { if current.count >= 2 { kept.append(current) }; current = [] }
                    }
                    if current.count >= 2 { kept.append(current) }
                }
            }
            if detailed[k].strict { dashed += kept } else { solid += kept }
        }
        return (fill, solid, dashed)
    }

    /// Level curves `f(x, y) = c` for each level, as polylines (one list per level, in the order given).
    public static func levelCurves(_ latex: String, levels: [Double], window: FigureScene.Window, engine: MathEngine) async -> [[[[Double]]]]? {
        guard let f = levelFunction(latex) else { return nil }
        let n = contourGrid
        let points = gridPoints(window, n: n)
        guard let rows = try? await engine.values(of: [f], variables: ["x", "y"], at: points), let first = rows.first, let values = first,
              values.contains(where: { $0 != nil }) else { return nil }
        return levels.filter(\.isFinite).map { contours(values, n: n, level: $0, window: window) }
    }

    /// The function a level series is a family of: "f(x,y) = x^2+y^2" or "z = …" → its right-hand side; "x^2+y^2"
    /// as it is; any other equation "lhs = rhs" → lhs − rhs.
    static func levelFunction(_ latex: String) -> String? {
        let s = normalised(latex)
        let (terms, relations) = splitRelations(s)
        if relations.isEmpty { return s.isEmpty ? nil : s }
        guard relations == [.equal], terms.count == 2 else { return nil }
        let lhs = terms[0].replacingOccurrences(of: " ", with: "")
        if lhs == "z" || lhs.hasPrefix("f(") || lhs.hasPrefix("f\\left(") || lhs.hasPrefix("g(") { return terms[1] }
        return "\\left(\(terms[0])\\right)-\\left(\(terms[1])\\right)"
    }

    /// The zero set of a relation `lhs = rhs` (or of a plain expression) as chained polylines.
    public static func relation(_ latex: String, window: FigureScene.Window, engine: MathEngine) async -> [[[Double]]]? {
        let s = normalised(latex)
        let (terms, relations) = splitRelations(s)
        let residual: String
        if relations.isEmpty { residual = s }
        else if relations == [.equal], terms.count == 2 { residual = "\\left(\(terms[0])\\right)-\\left(\(terms[1])\\right)" }
        else { return nil }
        let n = contourGrid
        guard let rows = try? await engine.values(of: [residual], variables: ["x", "y"], at: gridPoints(window, n: n)),
              let first = rows.first, let values = first, values.contains(where: { $0 != nil }) else { return nil }
        return contours(values, n: n, level: 0, window: window)
    }

    // MARK: Parametric

    /// A parametric curve sampled over `tRange` (default 0…2π), broken where it is undefined or jumps, and the
    /// arrows along it (`[x, y, dx, dy]`: a point and the direction t runs there) when asked for.
    public static func parametric(x xt: String, y yt: String, tRange: [Double]?, arrows: Bool, window: FigureScene.Window,
                                  engine: MathEngine) async -> (pieces: [[[Double]]], arrows: [[Double]])? {
        let range = tRange.flatMap { $0.count == 2 && $0[0].isFinite && $0[1].isFinite && $0[0] != $0[1] ? $0 : nil } ?? [0, 2 * Double.pi]
        let count = parametricSamples
        let ts = (0...count).map { range[0] + (range[1] - range[0]) * Double($0) / Double(count) }
        guard let rows = try? await engine.values(of: [normalised(xt), normalised(yt)], variables: ["t"], at: ts.map { [$0] }),
              rows.count == 2, let xs = rows[0], let ys = rows[1] else { return nil }
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        var pieces: [[[Double]]] = [], current: [[Double]] = []
        for k in 0...count {
            guard let x = xs[k], let y = ys[k], abs(x) < 1e7, abs(y) < 1e7 else {
                if current.count >= 2 { pieces.append(current) }
                current = []
                continue
            }
            if let last = current.last, abs(x - last[0]) > xSpan * 0.5 || abs(y - last[1]) > ySpan * 0.5 {
                if current.count >= 2 { pieces.append(current) }
                current = []
            }
            current.append([x, y])
        }
        if current.count >= 2 { pieces.append(current) }
        guard !pieces.isEmpty else { return nil }
        return (pieces, arrows ? arrowMarks(along: pieces, window: window) : [])
    }

    /// Arrows spaced along polylines (by length on screen, inside the window): two to six, depending on how long
    /// the curve is.
    static func arrowMarks(along pieces: [[[Double]]], window: FigureScene.Window) -> [[Double]] {
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        func inside(_ p: [Double]) -> Bool { window.x.contains(p[0]) && window.y.contains(p[1]) }
        // Visible length in window units (each axis scaled to 1).
        var total = 0.0
        for piece in pieces { for (a, b) in zip(piece, piece.dropFirst()) where inside(a) && inside(b) {
            total += hypot((b[0] - a[0]) / xSpan, (b[1] - a[1]) / ySpan)
        } }
        guard total > 0 else { return [] }
        let count = min(6, max(2, Int((total / 1.2).rounded())))
        let spacing = total / Double(count)
        var next = spacing / 2, walked = 0.0
        var result: [[Double]] = []
        for piece in pieces {
            for k in 1..<piece.count {
                let a = piece[k - 1], b = piece[k]
                guard inside(a), inside(b) else { continue }
                let step = hypot((b[0] - a[0]) / xSpan, (b[1] - a[1]) / ySpan)
                while step > 0, walked + step >= next, result.count < count {
                    let f = (next - walked) / step
                    // Direction from a few samples either side, so a kink does not tilt the head.
                    let before = piece[max(0, k - 4)], after = piece[min(piece.count - 1, k + 3)]
                    result.append([a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, after[0] - before[0], after[1] - before[1]])
                    next += spacing
                }
                walked += step
            }
        }
        return result
    }

    // MARK: Contours

    /// The curves where a grid of values crosses `level`, chained into polylines (closed loops end where they
    /// start). Edges across a pole (both ends huge) are not crossings.
    static func contours(_ values: [Double?], n: Int, level: Double, window: FigureScene.Window) -> [[[Double]]] {
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let stride = n + 1
        func value(_ i: Int, _ j: Int) -> Double? { values[j * stride + i].map { $0 - level } }
        // Edge ids: horizontal edge from (i, j) to (i+1, j) = 2k, vertical edge from (i, j) to (i, j+1) = 2k+1.
        var crossing: [Int: [Double]] = [:]
        func edge(_ id: Int, _ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int) -> Int? {
            if crossing[id] != nil { return id }
            guard let v0 = value(i0, j0), let v1 = value(i1, j1), (v0 < 0) != (v1 < 0) else { return nil }
            guard max(abs(v0), abs(v1)) < 1e6 else { return nil }
            let t = v0 / (v0 - v1)
            let i = Double(i0) + Double(i1 - i0) * t, j = Double(j0) + Double(j1 - j0) * t
            crossing[id] = [window.x.lowerBound + xSpan * i / Double(n), window.y.lowerBound + ySpan * j / Double(n)]
            return id
        }
        var segments: [(Int, Int)] = []
        for j in 0..<n {
            for i in 0..<n {
                guard let a = value(i, j), let b = value(i + 1, j), let c = value(i + 1, j + 1), let d = value(i, j + 1) else { continue }
                // A cell spanning a pole: the values jump far more than across its neighbours. Skip it.
                let magnitude = max(abs(a), abs(b), abs(c), abs(d))
                guard magnitude.isFinite, magnitude < 1e6 else { continue }
                let bottom = edge(2 * (j * stride + i), i, j, i + 1, j)
                let right = edge(2 * (j * stride + i + 1) + 1, i + 1, j, i + 1, j + 1)
                let top = edge(2 * ((j + 1) * stride + i), i, j + 1, i + 1, j + 1)
                let left = edge(2 * (j * stride + i) + 1, i, j, i, j + 1)
                let found = [bottom, right, top, left].compactMap { $0 }
                if found.count == 2 {
                    segments.append((found[0], found[1]))
                } else if found.count == 4, let bottom, let right, let top, let left {
                    // A saddle: the centre's side decides which corners are joined.
                    let centre = (a + b + c + d) / 4
                    if (centre < 0) == (a < 0) { segments.append((bottom, right)); segments.append((top, left)) }
                    else { segments.append((left, bottom)); segments.append((right, top)) }
                }
            }
        }
        return chain(segments, points: crossing)
    }

    /// Joins segments that share an edge crossing into polylines: open chains from their free ends first, then
    /// the closed loops.
    static func chain(_ segments: [(Int, Int)], points: [Int: [Double]]) -> [[[Double]]] {
        var byEdge: [Int: [Int]] = [:]
        for (k, s) in segments.enumerated() { byEdge[s.0, default: []].append(k); byEdge[s.1, default: []].append(k) }
        var used = [Bool](repeating: false, count: segments.count)
        var result: [[[Double]]] = []
        func walk(from start: Int, segment first: Int) -> [Int] {
            var path = [start], at = start, k = first
            while true {
                used[k] = true
                let s = segments[k]
                let next = s.0 == at ? s.1 : s.0
                path.append(next)
                at = next
                guard let candidates = byEdge[at], let following = candidates.first(where: { !used[$0] }) else { break }
                k = following
            }
            return path
        }
        let ends = byEdge.filter { $0.value.count == 1 }.keys.sorted()
        for end in ends {
            guard let k = byEdge[end]?.first, !used[k] else { continue }
            result.append(walk(from: end, segment: k).compactMap { points[$0] })
        }
        for k in segments.indices where !used[k] {
            result.append(walk(from: segments[k].0, segment: k).compactMap { points[$0] })
        }
        return result.filter { $0.count >= 2 }
    }
}
