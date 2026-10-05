import Foundation

/// Reads the marks a picture draws on its curves — arrowheads (the direction of motion, including a curve traced out
/// and back) and dots (endpoints, marked points) — by walking each drawn curve across the picture and measuring the
/// ink's width across it: a widening that tapers to a point is an arrowhead, pointing the way it narrows; a round
/// bulge is a dot. Crossings (where another curve or an axis passes) are told apart by the ink around them. The
/// redraw then shows the picture's own arrows and dots instead of guessing them.
public enum MarkerReader {
    public struct Markers: Sendable, Equatable {
        /// `[x, y, dx, dy]` per arrowhead, in data units, by the index of the series it sits on.
        public var arrows: [Int: [[Double]]] = [:]
        /// `[x, y]` per dot.
        public var dots: [[Double]] = []
        public var isEmpty: Bool { arrows.isEmpty && dots.isEmpty }
    }

    /// The chart with the picture's arrows on its curves (`arrowMarks`, `directionArrows`) and its dots as a point
    /// series; its window widened to the picture's frame when the axes carry numbers. Unchanged when the picture
    /// cannot be read.
    public static func apply(_ chart: StandardChart, png: Data, engine: MathEngine) async -> StandardChart {
        let hasCurves = chart.series.contains { [.curve, .parametric].contains($0.seriesKind) && (($0.latex ?? "").isEmpty == false || $0.xt != nil || ($0.points?.count ?? 0) >= 2) }
        let hasMarks = chart.series.contains { $0.seriesKind == .vector || $0.seriesKind == .point }
        guard !chart.isSlopeField, !chart.isPhaseLine, !chart.hasPanels, hasCurves || hasMarks,
              let picture = await ShapeVerifier.Picture(png: png, hints: chart) else { return chart }
        var result = chart
        // Vectors and plotted points where the picture draws them.
        // Vectors are refitted only when the stated ones miss the picture (exact ones, computed from r(t), stay).
        if result.series.contains(where: { $0.seriesKind == .vector }) {
            let stated = await FigureScene.build(result, engine: engine)
            // With a curve on the same axes (a tangent vector at a point of r(t)) arrows touch each other and the
            // curve, and a refit cannot tell them apart: there the stated vectors are only corrected in place.
            let withCurves = result.series.contains { [.curve, .parametric, .level].contains($0.seriesKind) && ($0.points == nil || $0.latex != nil || $0.xt != nil) }
            if ShapeVerifier.verify(scene: stated, picture: picture).passed, let corrected = correctVectors(result, picture: picture) {
                result = corrected
            } else if !withCurves {
                result = fitVectors(result, picture: picture)
            }
        }
        result = snapPoints(result, picture: picture)
        guard hasCurves else { return result }
        // A numbered plot shows its whole frame: a window cut to the curve's own extent clips it at the edges.
        if picture.reading.isCalibratedFromLabels {
            let box = frame(picture)
            if let x = result.xRange, x.count == 2 { result.xRange = [min(x[0], box.x.lowerBound), max(x[1], box.x.upperBound)] }
            if let y = result.yRange, y.count == 2 { result.yRange = [min(y[0], box.y.lowerBound), max(y[1], box.y.upperBound)] }
        }
        // A loop or traced curve that touches the window's edge exactly (a radius-9 circle in a ±9 window) is clipped
        // there, arrows and all: give that side a little room.
        let shaped = result.series.indices.filter { result.series[$0].seriesKind == .parametric || (result.series[$0].latex ?? "").isEmpty }
        if !shaped.isEmpty, let x = result.xRange, let y = result.yRange, x.count == 2, y.count == 2 {
            let first = await FigureScene.build(result, engine: engine)
            let points = first.marks.filter { $0.kind == .line && shaped.contains($0.seriesIndex) }.flatMap(\.pieces).flatMap { $0 }
            if let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
               let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max() {
                let w = x[1] - x[0], h = y[1] - y[0]
                func touches(_ edge: Double, _ extent: Double, _ span: Double) -> Bool { abs(edge - extent) <= span * 0.015 }
                var nx = x, ny = y
                if touches(x[0], minX, w) { nx[0] -= w * 0.06 }
                if touches(x[1], maxX, w) { nx[1] += w * 0.06 }
                if touches(y[0], minY, h) { ny[0] -= h * 0.06 }
                if touches(y[1], maxY, h) { ny[1] += h * 0.06 }
                result.xRange = nx; result.yRange = ny
            }
        }
        let scene = await FigureScene.build(result, engine: engine)
        let markers = read(scene: scene, picture: picture)
        // Arrows only on curves that are traced out (parametric) or that the picture shows with arrows: a plain graph
        // has none, and a blob on it (a label, a crossing) is not one.
        for (index, arrows) in markers.arrows where result.series.indices.contains(index) && !arrows.isEmpty
            && (result.series[index].seriesKind == .parametric || chart.series[safe: index]?.directionArrows == true) {
            result.series[index].arrowMarks = arrows
            result.series[index].directionArrows = true
        }
        let hasPoints = result.series.contains { $0.seriesKind == .point }
        if !markers.dots.isEmpty, !hasPoints {
            var dots = ChartSeries(name: "Marked points", points: markers.dots)
            dots.kind = "point"
            result.series.append(dots)
        }
        return result
    }

    /// Each vector moved onto the straight ink segment the picture draws nearest it (pieces split by an axis joined
    /// again), its head at the end that carries the arrowhead; endpoints within a little of a grid point snap to it.
    static func fitVectors(_ chart: StandardChart, picture: ShapeVerifier.Picture) -> StandardChart {
        let vectors = chart.series.indices.filter { chart.series[$0].seriesKind == .vector && (chart.series[$0].points?.count ?? 0) >= 2 }
        guard !vectors.isEmpty else { return chart }
        struct Segment { var pixels: [(Int, Int)]; var a: (Double, Double); var b: (Double, Double); var dir: (Double, Double); var length: Double; var hue: Int? = nil }
        func fit(_ pixels: [(Int, Int)]) -> Segment? {
            guard pixels.count >= 6 else { return nil }
            let n = Double(pixels.count)
            let mx = pixels.reduce(0.0) { $0 + Double($1.0) } / n, my = pixels.reduce(0.0) { $0 + Double($1.1) } / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for (c, r) in pixels { let dx = Double(c) - mx, dy = Double(r) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(angle), uy = sin(angle)
            var lo = Double.infinity, hi = -Double.infinity
            var off: [Double] = []
            for (c, r) in pixels {
                let t = (Double(c) - mx) * ux + (Double(r) - my) * uy
                lo = min(lo, t); hi = max(hi, t)
                off.append(abs(-(Double(c) - mx) * uy + (Double(r) - my) * ux))
            }
            off.sort()
            // Straight: most of the ink hugs the line (an arrowhead's wings are the few pixels that do not).
            guard off[off.count / 2] <= 1.6, hi - lo >= 4 else { return nil }
            return Segment(pixels: pixels, a: (mx + ux * lo, my + uy * lo), b: (mx + ux * hi, my + uy * hi), dir: (ux, uy), length: hi - lo)
        }
        // Short pieces too (a vector cut in two where it crosses an axis), joined below.
        let pieces = PictureInk.curves(picture.bitmap, columns: picture.columns, rows: picture.rows, skip: { c, r in picture.nearAxis(c, r) },
                                       minimum: 6, minimumExtent: 4)
        // Arrows that touch (a position vector's head meeting a tangent's tail) are one blob of ink: split each blob
        // into its straight runs, the line through the most pixels first.
        func straightRuns(_ pixels: [(Int, Int)]) -> [[(Int, Int)]] {
            var remaining = pixels, runs: [[(Int, Int)]] = []
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(max(1, bound)))
            }
            while remaining.count >= 12, runs.count < 6 {
                var best: [Int] = []
                var bestLine = (0.0, 0.0, 0.0, 0.0)
                for _ in 0..<90 {
                    let p = remaining[next(remaining.count)], q = remaining[next(remaining.count)]
                    let dx = Double(q.0 - p.0), dy = Double(q.1 - p.1), length = hypot(dx, dy)
                    guard length >= 8 else { continue }
                    let ux = dx / length, uy = dy / length
                    var inliers: [Int] = []
                    for (k, r) in remaining.enumerated() where abs(-(Double(r.0 - p.0)) * uy + Double(r.1 - p.1) * ux) <= 1.5 { inliers.append(k) }
                    if inliers.count > best.count { best = inliers; bestLine = (Double(p.0), Double(p.1), ux, uy) }
                }
                guard best.count >= 12 else { break }
                // The longest stretch along the line without a gap (collinear ink elsewhere is another piece).
                let along = best.map { k -> (Double, Int) in
                    let r = remaining[k]
                    return ((Double(r.0) - bestLine.0) * bestLine.2 + (Double(r.1) - bestLine.1) * bestLine.3, k)
                }.sorted { $0.0 < $1.0 }
                var longest: [Int] = [], current: [Int] = [], last = -Double.infinity
                for (t, k) in along {
                    if t - last > 6, !current.isEmpty { if current.count > longest.count { longest = current }; current = [] }
                    current.append(k); last = t
                }
                if current.count > longest.count { longest = current }
                guard longest.count >= 12 else { break }
                runs.append(longest.map { remaining[$0] })
                let taken = Set(longest)
                remaining = remaining.enumerated().filter { !taken.contains($0.offset) }.map(\.element)
            }
            return runs
        }
        // A blob is arrows when a few straight runs explain most of it (a V of two vectors); a curve (an ellipse) is
        // not, and its straight slivers are not vectors.
        var segments = pieces.flatMap { piece -> [Segment] in
            if let single = fit(piece) { return [single] }
            let runs = straightRuns(piece)
            guard runs.prefix(3).reduce(0, { $0 + $1.count }) * 10 >= piece.count * 7 else { return [] }
            return runs.compactMap(fit)
        }
        // Join collinear pieces an axis cut apart.
        var merged = true
        while merged {
            merged = false
            outer: for i in segments.indices { for j in segments.indices where j > i {
                let s = segments[i], t = segments[j]
                guard abs(s.dir.0 * t.dir.0 + s.dir.1 * t.dir.1) > 0.995 else { continue }
                let mid = ((t.a.0 + t.b.0) / 2, (t.a.1 + t.b.1) / 2)
                let away = abs(-(mid.0 - s.a.0) * s.dir.1 + (mid.1 - s.a.1) * s.dir.0)
                let gap = [hypot(s.a.0 - t.a.0, s.a.1 - t.a.1), hypot(s.a.0 - t.b.0, s.a.1 - t.b.1),
                           hypot(s.b.0 - t.a.0, s.b.1 - t.a.1), hypot(s.b.0 - t.b.0, s.b.1 - t.b.1)].min()!
                guard away <= 3, gap <= 14, let joined = fit(s.pixels + t.pixels) else { continue }
                segments[i] = joined
                segments.remove(at: j)
                merged = true
                break outer
            } }
        }
        // Each segment followed along its own line through arrowheads, dots and axis gaps to where its ink ends.
        let bitmap = picture.bitmap
        segments = segments.map { segment in
            var bins = [Int](repeating: 0, count: 12)
            for (c, r) in segment.pixels { if let bin = bitmap.hueBin(c, r) { bins[bin] += 1 } }
            let bin = (0..<12).max { bins[$0] < bins[$1] }!
            let coloured = bins[bin] * 2 > segment.pixels.count
            func ink(_ x: Double, _ y: Double) -> Bool {
                for d in -2...2 {
                    let c = Int((x - segment.dir.1 * Double(d)).rounded()), r = Int((y + segment.dir.0 * Double(d)).rounded())
                    guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                    if coloured {
                        if let b = bitmap.hueBin(c, r), min(abs(b - bin), 12 - abs(b - bin)) <= 1 { return true }
                    } else if bitmap.isInk(c, r), !picture.nearAxis(c, r) { return true }
                }
                return false
            }
            func reach(from end: (Double, Double), sign: Double) -> (Double, Double) {
                var last = end, gap = 0
                for t in 1...22 {
                    let p = (end.0 + segment.dir.0 * Double(t) * sign, end.1 + segment.dir.1 * Double(t) * sign)
                    if ink(p.0, p.1) { last = p; gap = 0 } else { gap += 1; if gap > 4 { break } }
                }
                return last
            }
            var extended = segment
            extended.hue = coloured ? bin : nil
            extended.a = reach(from: segment.a, sign: -1)
            extended.b = reach(from: segment.b, sign: 1)
            extended.length = hypot(extended.b.0 - extended.a.0, extended.b.1 - extended.a.1)
            return extended
        }
        if ProcessInfo.processInfo.environment["THUBAN_MARKER_DEBUG"] != nil {
            print("VECTORS curves \(picture.curves.map(\.count)) segments \(segments.map { "(\(Int($0.a.0)),\(Int($0.a.1)))-(\(Int($0.b.0)),\(Int($0.b.1)))" }) origin \(picture.reading.originColumn),\(picture.reading.originRow)")
        }
        guard !segments.isEmpty else { return chart }
        var reading = picture.reading
        var calibrated = false
        // Axes without numbers: the vectors' own lengths set the scale (equal on both axes, pixels being square),
        // from the stated vector that best matches a drawn segment in direction, about the axes' crossing.
        if !reading.isCalibratedFromLabels {
            var best: (scale: Double, error: Double)?
            for index in vectors {
                let p = chart.series[index].points!
                let dx = p[1][0] - p[0][0], dy = p[1][1] - p[0][1], length = hypot(dx, dy)
                guard length > 0 else { continue }
                for segment in segments {
                    // Pixel rows grow downward: the data direction (dx, dy) is (dx, −dy) in pixels.
                    let cosine = abs((dx * segment.dir.0 - dy * segment.dir.1) / length)
                    guard cosine > 0.996 else { continue }
                    let k = segment.length / length
                    // Where the stated tail lands with this scale, against the segment's nearer end.
                    let tail = (reading.originColumn + p[0][0] * k, reading.originRow - p[0][1] * k)
                    let error = min(hypot(tail.0 - segment.a.0, tail.1 - segment.a.1), hypot(tail.0 - segment.b.0, tail.1 - segment.b.1)) / k
                    if error < 0.4, best == nil || error < best!.error { best = (k, error) }
                }
            }
            guard let best else { return chart }
            reading.x = GraphReading.AxisMap(origin: reading.originColumn, scale: best.scale, labelCount: 0, extent: reading.x.extent)
            reading.y = GraphReading.AxisMap(origin: reading.originRow, scale: -best.scale, labelCount: 0, extent: reading.y.extent)
            calibrated = true
        }
        func pixel(_ p: [Double]) -> (Double, Double) { (reading.x.pixel(p[0]), reading.y.pixel(p[1])) }
        func data(_ p: (Double, Double)) -> [Double] {
            let d = reading.data(column: p.0, row: p.1)
            // Grid points: within 0.12 of a multiple of a half step, take it.
            func snap(_ v: Double) -> Double {
                if abs(v.rounded() - v) <= 0.3 { return v.rounded() }
                let h = (v * 2).rounded() / 2
                return abs(h - v) <= 0.15 ? h : (v * 100).rounded() / 100
            }
            return [snap(d.x), snap(d.y)]
        }
        /// The end with the arrowhead: more ink off the line near it.
        func headEnd(_ s: Segment) -> (Double, Double) {
            // Wing ink sits a little back from the tip, past any dot at the very end.
            let bitmap = picture.bitmap
            func wings(_ e: (Double, Double)) -> Int {
                let inward: (Double, Double) = hypot(e.0 - s.a.0, e.1 - s.a.1) < 1 ? s.dir : (-s.dir.0, -s.dir.1)
                // Both sides of the shaft: a head has a wing on each; another arrow arriving at this end adds ink to one.
                var counts = [0, 0]
                for (k, side) in [-1.0, 1.0].enumerated() { for t in 9...20 { for d in 3...9 {
                    let x = e.0 + inward.0 * Double(t) - inward.1 * Double(d) * side
                    let y = e.1 + inward.1 * Double(t) + inward.0 * Double(d) * side
                    let c = Int(x.rounded()), r = Int(y.rounded())
                    guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                    // Only the arrow's own colour: a curve of another colour passing its end is not a wing.
                    if let hue = s.hue {
                        if let b = bitmap.hueBin(c, r), min(abs(b - hue), 12 - abs(b - hue)) <= 1 { counts[k] += 1 }
                    } else if !picture.nearAxis(c, r), !bitmap.isBackground(c, r), !bitmap.isGrid(c, r) { counts[k] += 1 }
                } } }
                return min(counts[0], counts[1])
            }
            return wings(s.a) >= wings(s.b) ? s.a : s.b
        }
        var result = chart
        // The window in the vectors' own scale (the axes' extent), so the picture is read the same way when checked.
        if calibrated {
            let x0 = reading.x.value(reading.x.extent.lowerBound), x1 = reading.x.value(reading.x.extent.upperBound)
            let y0 = reading.y.value(reading.y.extent.lowerBound), y1 = reading.y.value(reading.y.extent.upperBound)
            result.xRange = [min(x0, x1), max(x0, x1)]
            result.yRange = [min(y0, y1), max(y0, y1)]
            result.xAxisLabels = []; result.yAxisLabels = []
        }
        var used = Set<Int>()
        // Label strokes are short: only segments long enough to be a vector are candidates.
        let candidates = segments.indices.filter { segments[$0].length >= 18 }
        func cost(_ index: Int, _ k: Int, strict: Bool) -> Double? {
            let given = result.series[index].points!
            let tail = pixel(given[0]), head = pixel(given[1])
            let s = segments[k]
            let d1 = hypot(tail.0 - s.a.0, tail.1 - s.a.1) + hypot(head.0 - s.b.0, head.1 - s.b.1)
            let d2 = hypot(tail.0 - s.b.0, tail.1 - s.b.1) + hypot(head.0 - s.a.0, head.1 - s.a.1)
            let vx = head.0 - tail.0, vy = head.1 - tail.1, vl = hypot(vx, vy)
            let cosine = vl > 0 ? abs((vx * s.dir.0 + vy * s.dir.1) / vl) : 0
            let d = min(d1, d2)
            // A matching vector runs the same way as the drawn one; a stated vector far off (a stub, a wrong
            // direction) still takes the drawn vector nobody else claims.
            if strict { return cosine >= 0.85 && d <= s.length * 0.8 + 30 ? d : nil }
            return d + 80 * (1 - cosine)
        }
        var assignment: [Int: Int] = [:]
        for strict in [true, false] {
            for index in vectors where assignment[index] == nil {
                var best: (Int, Double)?
                for k in candidates where !used.contains(k) {
                    guard let c = cost(index, k, strict: strict) else { continue }
                    if best == nil || c < best!.1 { best = (k, c) }
                }
                if let (k, _) = best { assignment[index] = k; used.insert(k) }
            }
        }
        for index in vectors {
            let given = result.series[index].points!
            guard let k = assignment[index] else { continue }
            used.insert(k)
            let s = segments[k]
            let tip = headEnd(s)
            let start = hypot(tip.0 - s.a.0, tip.1 - s.a.1) < 1 ? s.b : s.a
            // An end within a little of the stated one is that point (its printed label); otherwise the picture's.
            func settle(_ found: [Double], near stated: [Double]) -> [Double] {
                hypot(found[0] - stated[0], found[1] - stated[1]) <= 0.35 ? stated : found
            }
            let a = data(start), b = data(tip)
            let forward = hypot(a[0] - given[0][0], a[1] - given[0][1]) + hypot(b[0] - given[1][0], b[1] - given[1][1])
            let backward = hypot(a[0] - given[1][0], a[1] - given[1][1]) + hypot(b[0] - given[0][0], b[1] - given[0][1])
            let (ta, tb) = forward <= backward ? (given[0], given[1]) : (given[1], given[0])
            result.series[index].points = [settle(a, near: ta), settle(b, near: tb)]
        }
        return result
    }

    /// Stated vectors that lie on the picture's ink, checked against it: each end carried out along the vector's own
    /// line as far as its ink goes (a vector drawn short), and the head put at the end with the arrowhead (one drawn
    /// backwards).
    /// Nil when a stated vector does not lie on ink of one colour (it rides on another curve): refit them all instead.
    static func correctVectors(_ chart: StandardChart, picture: ShapeVerifier.Picture) -> StandardChart? {
        var result = chart
        let reading = picture.reading, bitmap = picture.bitmap
        for index in result.series.indices where result.series[index].seriesKind == .vector {
            guard let given = result.series[index].points, given.count >= 2 else { continue }
            var tail = (reading.x.pixel(given[0][0]), reading.y.pixel(given[0][1]))
            var head = (reading.x.pixel(given[1][0]), reading.y.pixel(given[1][1]))
            let length = hypot(head.0 - tail.0, head.1 - tail.1)
            guard length >= 8 else { continue }
            let u = ((head.0 - tail.0) / length, (head.1 - tail.1) / length)
            // The vector's colour: the commonest hue along it.
            var bins = [Int](repeating: 0, count: 12)
            for t in Swift.stride(from: 0.2, through: 0.8, by: 0.05) {
                let c = Int((tail.0 + (head.0 - tail.0) * t).rounded()), r = Int((tail.1 + (head.1 - tail.1) * t).rounded())
                if picture.columns.contains(c), picture.rows.contains(r), let b = bitmap.hueBin(c, r) { bins[b] += 1 }
            }
            let bin = (0..<12).max { bins[$0] < bins[$1] }!
            let colouredPicture = PictureInk.isMonochrome(bitmap) == false || bins.reduce(0, +) > 0
            // Most of the shaft on one colour, or (a black drawing) on dark ink.
            if colouredPicture, bins[bin] < 9 { return nil }
            let hue: Int? = bins[bin] >= 4 ? bin : nil
            func ink(_ x: Double, _ y: Double) -> Bool {
                for d in -2...2 {
                    let c = Int((x - u.1 * Double(d)).rounded()), r = Int((y + u.0 * Double(d)).rounded())
                    guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                    if let hue { if let b = bitmap.hueBin(c, r), min(abs(b - hue), 12 - abs(b - hue)) <= 1 { return true } }
                    else if bitmap.isInk(c, r), !picture.nearAxis(c, r) { return true }
                }
                return false
            }
            func reach(_ from: (Double, Double), _ sign: Double) -> (Double, Double) {
                var last = from, gap = 0
                for t in 1...400 {
                    let p = (from.0 + u.0 * Double(t) * sign, from.1 + u.1 * Double(t) * sign)
                    if ink(p.0, p.1) { last = p; gap = 0 } else { gap += 1; if gap > 4 { break } }
                }
                return last
            }
            head = reach(head, 1)
            // A tail only reaches a little past its stated start (another arrow often continues the same line there).
            let reachedTail = reach(tail, -1)
            if hypot(reachedTail.0 - tail.0, reachedTail.1 - tail.1) <= 12 { tail = reachedTail }
            func wings(_ e: (Double, Double), inward: (Double, Double)) -> Int {
                var counts = [0, 0]
                for (k, side) in [-1.0, 1.0].enumerated() { for t in 9...20 { for d in 3...9 {
                    let c = Int((e.0 + inward.0 * Double(t) - inward.1 * Double(d) * side).rounded())
                    let r = Int((e.1 + inward.1 * Double(t) + inward.0 * Double(d) * side).rounded())
                    guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                    if let hue { if let b = bitmap.hueBin(c, r), min(abs(b - hue), 12 - abs(b - hue)) <= 1 { counts[k] += 1 } }
                    else if !picture.nearAxis(c, r), bitmap.isInk(c, r) { counts[k] += 1 }
                } } }
                return min(counts[0], counts[1])
            }
            let atHead = wings(head, inward: (-u.0, -u.1)), atTail = wings(tail, inward: u)
            if atTail > atHead + 3, Double(atTail) > Double(atHead) * 1.5 { swap(&head, &tail) }
            func data(_ p: (Double, Double), near stated: [Double]) -> [Double] {
                let d = reading.data(column: p.0, row: p.1)
                let found = [(d.x * 100).rounded() / 100, (d.y * 100).rounded() / 100]
                // The stated end, when the picture agrees with it (an exact value from the question).
                return hypot(found[0] - stated[0], found[1] - stated[1]) <= 0.15 ? stated : found
            }
            let swapped = hypot(head.0 - reading.x.pixel(given[0][0]), head.1 - reading.y.pixel(given[0][1])) < hypot(tail.0 - reading.x.pixel(given[0][0]), tail.1 - reading.y.pixel(given[0][1]))
            result.series[index].points = swapped ? [data(tail, near: given[1]), data(head, near: given[0])]
                                                  : [data(tail, near: given[0]), data(head, near: given[1])]
        }
        return result
    }

    /// Each plotted point moved to the centre of the dot the picture draws near it.
    static func snapPoints(_ chart: StandardChart, picture: ShapeVerifier.Picture) -> StandardChart {
        var result = chart
        let reading = picture.reading
        for index in result.series.indices where result.series[index].seriesKind == .point {
            guard var points = result.series[index].points else { continue }
            for k in points.indices where points[k].count >= 2 {
                let c = reading.x.pixel(points[k][0]), r = reading.y.pixel(points[k][1])
                let reach = max(14, picture.radius * 3)
                var best: (Double, Double, Double)?
                for dy in Swift.stride(from: -reach, through: reach, by: 1) { for dx in Swift.stride(from: -reach, through: reach, by: 1) {
                    var on = 0, total = 0
                    for y in -3...3 { for x in -3...3 where x * x + y * y <= 9 {
                        total += 1
                        if picture.isInk(Int(c.rounded()) + dx + x, Int(r.rounded()) + dy + y) { on += 1 }
                    } }
                    let density = Double(on) / Double(total)
                    // The densest disc, nearest first among equals.
                    let score = density - hypot(Double(dx), Double(dy)) * 0.002
                    if density >= 0.75, best == nil || score > best!.2 { best = (c + Double(dx), r + Double(dy), score) }
                } }
                guard let found = best else { continue }
                // The blob's centre: the mean of the ink around it.
                var sx = 0.0, sy = 0.0, n = 0.0
                for y in -7...7 { for x in -7...7 where x * x + y * y <= 49 {
                    let cc = Int(found.0.rounded()) + x, rr = Int(found.1.rounded()) + y
                    if picture.isInk(cc, rr) { sx += Double(cc); sy += Double(rr); n += 1 }
                } }
                guard n > 0 else { continue }
                let d = reading.data(column: sx / n, row: sy / n)
                points[k] = [(d.x * 100).rounded() / 100, (d.y * 100).rounded() / 100]
            }
            result.series[index].points = points
        }
        return result
    }

    /// The plot box in data units.
    static func frame(_ picture: ShapeVerifier.Picture) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let r = picture.reading
        let x0 = r.x.value(Double(picture.columns.lowerBound)), x1 = r.x.value(Double(picture.columns.upperBound))
        let y0 = r.y.value(Double(picture.rows.lowerBound)), y1 = r.y.value(Double(picture.rows.upperBound))
        return (min(x0, x1)...max(x0, x1), min(y0, y1)...max(y0, y1))
    }

    static func read(scene: FigureScene, picture: ShapeVerifier.Picture) -> Markers {
        var markers = Markers()
        let bitmap = picture.bitmap
        for mark in scene.marks where mark.kind == .line && mark.seriesIndex >= 0 {
            for piece in mark.pieces {
                // The curve's own colour, when it has one: then black axes, ticks and labels are not ink at all.
                var bins = [Int](repeating: 0, count: 12), plain = 0
                for p in piece {
                    let c = Int(picture.reading.x.pixel(p[0]).rounded()), r = Int(picture.reading.y.pixel(p[1]).rounded())
                    guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                    if let bin = bitmap.hueBin(c, r) { bins[bin] += 1 } else if bitmap.isInk(c, r) { plain += 1 }
                }
                let colourBin = (0..<12).max { bins[$0] < bins[$1] }!
                let coloured = bins[colourBin] > plain
                func ink(_ c: Int, _ r: Int) -> Bool {
                    guard picture.columns.contains(c), picture.rows.contains(r) else { return false }
                    if coloured {
                        guard let bin = bitmap.hueBin(c, r) else { return false }
                        let d = abs(bin - colourBin)
                        return min(d, 12 - d) <= 1
                    }
                    return !bitmap.isBackground(c, r) && !bitmap.isGrid(c, r) && !picture.nearAxis(c, r)
                }
                // The piece in pixels, one sample per pixel, with its direction.
                var samples: [(x: Double, y: Double, tx: Double, ty: Double)] = []
                for (a, b) in zip(piece, piece.dropFirst()) {
                    let ax = picture.reading.x.pixel(a[0]), ay = picture.reading.y.pixel(a[1])
                    let bx = picture.reading.x.pixel(b[0]), by = picture.reading.y.pixel(b[1])
                    let length = hypot(bx - ax, by - ay)
                    guard length > 0, length < 4000 else { continue }
                    let steps = max(1, Int(length.rounded(.up)))
                    for k in 0..<steps {
                        let t = Double(k) / Double(steps)
                        samples.append((ax + (bx - ax) * t, ay + (by - ay) * t, (bx - ax) / length, (by - ay) / length))
                    }
                }
                guard samples.count >= 20 else { continue }
                // Ink width across the curve at each sample (0 where the curve is not on ink).
                let widths: [Double] = samples.map { s in
                    let c = Int(s.x.rounded()), r = Int(s.y.rounded())
                    guard ink(c, r) || ink(c + 1, r) || ink(c, r + 1) || ink(c - 1, r) || ink(c, r - 1) else { return 0 }
                    let nx = -s.ty, ny = s.tx
                    var width = 1
                    for side in [1.0, -1.0] {
                        var gap = 0
                        for d in 1...18 {
                            let cc = Int((s.x + nx * Double(d) * side).rounded()), rr = Int((s.y + ny * Double(d) * side).rounded())
                            if ink(cc, rr) { width += 1 + gap; gap = 0 } else { gap += 1; if gap > 1 { break } }
                        }
                    }
                    return Double(width)
                }
                let onInk = widths.filter { $0 > 0 }.sorted()
                guard onInk.count >= 20 else { continue }
                let line = onInk[onInk.count / 2]
                let threshold = max(line * 2.1, line + 4)
                if ProcessInfo.processInfo.environment["THUBAN_MARKER_DEBUG"] != nil {
                    print("MARKER piece samples \(samples.count) line \(line) max \(widths.max() ?? 0) coloured \(coloured)")
                }
                // Runs of wide ink along the curve.
                var runs: [ClosedRange<Int>] = [], start: Int?, lastWide = -10
                for (k, w) in widths.enumerated() {
                    if w >= threshold {
                        if start == nil || k - lastWide > 3 { if let s = start { runs.append(s...lastWide) }; start = k }
                        lastWide = k
                    }
                }
                if let s = start { runs.append(s...lastWide) }
                for run in runs where run.count >= 3 && run.count <= 45 {
                    let centre = run.lowerBound + run.count / 2
                    let s = samples[centre]
                    let c = Int(s.x.rounded()), r = Int(s.y.rounded())
                    guard coloured || !picture.nearAxis(c, r) else { continue }
                    let peak = run.map { widths[$0] }.max() ?? threshold
                    // Around a mark the curve enters and leaves (one or two runs of ink on a ring); a crossing has four.
                    // Wide enough to clear an arrowhead's wings, so only the curve itself crosses it.
                    let radius = peak * 0.9 + 5
                    var segments = 0, previous = false, first = false
                    for k in 0..<96 {
                        let angle = Double(k) / 96 * 2 * Double.pi
                        let on = ink(Int((s.x + cos(angle) * radius).rounded()), Int((s.y + sin(angle) * radius).rounded()))
                        if k == 0 { first = on } else if on && !previous { segments += 1 }
                        previous = on
                    }
                    if first && !previous { segments += 1 }
                    if ProcessInfo.processInfo.environment["THUBAN_MARKER_DEBUG"] != nil {
                        print("MARKER run \(run.count) peak \(peak) line \(line) segments \(segments) at \(picture.reading.data(column: s.x, row: s.y))")
                    }
                    guard segments <= 2 else { continue }
                    // From the widest point, how far the widening reaches each way along the curve: an arrowhead
                    // tapers over a long stretch to its tip and stops abruptly at its base; a dot is even.
                    let peakIndex = run.max { widths[$0] < widths[$1] } ?? centre
                    let flank = line * 1.3 + 1
                    var forward = 0, backward = 0
                    while peakIndex + forward + 1 < widths.count, widths[peakIndex + forward + 1] >= flank { forward += 1 }
                    while peakIndex - backward - 1 >= 0, widths[peakIndex - backward - 1] >= flank { backward += 1 }
                    let longer = Double(max(forward, backward)), shorter = Double(min(forward, backward))
                    let data = picture.reading.data(column: s.x, row: s.y)
                    // A bulge running into the end of the curve is its endpoint dot (one side is cut off, not tapered).
                    let atEnd = peakIndex + forward >= widths.count - 2 || peakIndex - backward <= 1
                    if !atEnd, longer - shorter >= 3, longer >= shorter * 1.6 {
                        // The tip is on the longer side: the head points that way along the curve.
                        let sign = forward > backward ? 1.0 : -1.0
                        let ahead = picture.reading.data(column: s.x + s.tx * 4 * sign, row: s.y + s.ty * 4 * sign)
                        markers.arrows[mark.seriesIndex, default: []].append([data.x, data.y, ahead.x - data.x, ahead.y - data.y])
                    } else if peak <= line * 4 + 6 {
                        markers.dots.append([data.x, data.y])
                    }
                }
                // The curve's two ends: a solid disc of ink there is an endpoint dot (the walk may start on it).
                for s in [samples[0], samples[samples.count - 1]] {
                    let disc = line * 1.1
                    var best = 0.0, at = (s.x, s.y)
                    for dy in Swift.stride(from: -6.0, through: 6.0, by: 1) { for dx in Swift.stride(from: -6.0, through: 6.0, by: 1) {
                        var on = 0, total = 0
                        for y in Swift.stride(from: -disc, through: disc, by: 1) { for x in Swift.stride(from: -disc, through: disc, by: 1) where x * x + y * y <= disc * disc {
                            total += 1
                            if ink(Int((s.x + dx + x).rounded()), Int((s.y + dy + y).rounded())) { on += 1 }
                        } }
                        let density = Double(on) / Double(max(1, total))
                        if density > best { best = density; at = (s.x + dx, s.y + dy) }
                    } }
                    if best >= 0.85 {
                        let data = picture.reading.data(column: at.0, row: at.1)
                        markers.dots.append([data.x, data.y])
                    }
                }
            }
        }
        // One dot per spot (the walk and the end test can both find it).
        var unique: [[Double]] = []
        let xSpan = picture.reading.x.range.upperBound - picture.reading.x.range.lowerBound
        let ySpan = picture.reading.y.range.upperBound - picture.reading.y.range.lowerBound
        for dot in markers.dots where !unique.contains(where: { abs($0[0] - dot[0]) < xSpan * 0.02 && abs($0[1] - dot[1]) < ySpan * 0.02 }) {
            unique.append(dot)
        }
        markers.dots = unique
        return markers
    }
}
