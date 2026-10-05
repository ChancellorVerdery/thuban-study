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
        guard !chart.isSlopeField, !chart.isPhaseLine, !chart.hasPanels,
              chart.series.contains(where: { [.curve, .parametric].contains($0.seriesKind) && (($0.latex ?? "").isEmpty == false || $0.xt != nil || ($0.points?.count ?? 0) >= 2) }),
              let picture = await ShapeVerifier.Picture(png: png, hints: chart) else { return chart }
        var result = chart
        // A numbered plot shows its whole frame: a window cut to the curve's own extent clips it at the edges.
        if picture.reading.isCalibratedFromLabels {
            let box = frame(picture)
            if let x = result.xRange, x.count == 2 { result.xRange = [min(x[0], box.x.lowerBound), max(x[1], box.x.upperBound)] }
            if let y = result.yRange, y.count == 2 { result.yRange = [min(y[0], box.y.lowerBound), max(y[1], box.y.upperBound)] }
        }
        let scene = await FigureScene.build(result, engine: engine)
        let markers = read(scene: scene, picture: picture)
        for (index, arrows) in markers.arrows where result.series.indices.contains(index) && !arrows.isEmpty {
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
                    let radius = peak / 2 + 4
                    var segments = 0, previous = false, first = false
                    for k in 0..<96 {
                        let angle = Double(k) / 96 * 2 * Double.pi
                        let on = ink(Int((s.x + cos(angle) * radius).rounded()), Int((s.y + sin(angle) * radius).rounded()))
                        if k == 0 { first = on } else if on && !previous { segments += 1 }
                        previous = on
                    }
                    if first && !previous { segments += 1 }
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
            }
        }
        return markers
    }
}
