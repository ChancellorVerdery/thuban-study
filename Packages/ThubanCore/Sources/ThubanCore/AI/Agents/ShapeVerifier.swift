import Foundation

/// The picture check for charts with shapes (`ChartShapes`): shaded regions, level-curve families and parametric
/// curves. The reconciler's colour-cluster curves cannot represent those (a region is an area, a contour map has
/// many closed curves, a parametric curve loops back over itself), so the chart is drawn and compared with the
/// picture directly, through the axes `GraphReader` finds:
/// - a region's predicted inside against the picture's shading (a tint or hatching), sampled away from the
///   boundary;
/// - the drawn lines against the picture's curves, both ways: the share of drawn points with ink nearby
///   (coverage — nothing drawn where the picture has no curve) and the share of the picture's curve ink with a
///   drawn line nearby (recall — no curve of the picture left out).
public enum ShapeVerifier {
    /// A region passes when its inside agrees with the picture's shading at this share of the sampled points.
    static let regionAgreement = 0.85
    /// Lines pass when this share of their points has ink nearby, and this share of the picture's curves has a
    /// drawn line nearby.
    static let lineCoverage = 0.8
    static let lineRecall = 0.8

    /// The chart has a series the reconciler cannot check (a region, level curves or a parametric curve).
    public static func hasShapes(_ chart: StandardChart) -> Bool {
        chart.series.contains { FigureScene.shape(of: $0) != .curve }
    }

    /// The picture as the comparisons see it: its pixels, its axes, the plot box and the separate curves in it.
    struct Picture {
        let bitmap: GraphReader.Bitmap
        private(set) var reading: GraphReading
        let columns: ClosedRange<Int>
        let rows: ClosedRange<Int>
        let radius: Int
        let axisColumn: Double
        let axisRow: Double
        let curves: [[(Int, Int)]]

        init?(png: Data, hints: StandardChart) async {
            guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image),
                  let reading = await GraphReader.read(png: png, hints: hints) else { return nil }
            self.init(bitmap: bitmap, reading: reading)
        }

        /// A diagram without axes (vectors in the plane, a triangle of vectors): the drawing's own coordinates laid
        /// on the picture by matching their extents to the extent of its ink (text left out), at equal scale on both
        /// axes. Nil when the picture or the drawing is empty.
        static func diagram(png: Data, chart: StandardChart, engine: MathEngine) async -> Picture? {
            guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image) else { return nil }
            let scene = await FigureScene.build(chart, engine: engine)
            let drawn = scene.marks.filter { [.line, .vector, .dots].contains($0.kind) }.flatMap(\.pieces).flatMap { $0 }.filter { $0.count >= 2 }
            guard let minX = drawn.map({ $0[0] }).min(), let maxX = drawn.map({ $0[0] }).max(),
                  let minY = drawn.map({ $0[1] }).min(), let maxY = drawn.map({ $0[1] }).max(), maxX > minX || maxY > minY else { return nil }
            let words = await PictureText.words(in: png)
            func inText(_ c: Int, _ r: Int) -> Bool { words.contains { $0.rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: c, y: r)) } }
            var c0 = Int.max, c1 = Int.min, r0 = Int.max, r1 = Int.min
            for r in Swift.stride(from: 0, to: bitmap.height, by: 1) { for c in Swift.stride(from: 0, to: bitmap.width, by: 1) {
                guard bitmap.isInk(c, r) || bitmap.hueBin(c, r) != nil, !inText(c, r) else { continue }
                c0 = min(c0, c); c1 = max(c1, c); r0 = min(r0, r); r1 = max(r1, r)
            } }
            guard c1 > c0 || r1 > r0 else { return nil }
            let spanX = maxX - minX, spanY = maxY - minY
            let scales = [spanX > 0 ? Double(c1 - c0) / spanX : nil, spanY > 0 ? Double(r1 - r0) / spanY : nil].compactMap { $0 }
            let k = scales.reduce(0, +) / Double(scales.count)
            let cx = Double(c0 + c1) / 2, cy = Double(r0 + r1) / 2
            let x = GraphReading.AxisMap(origin: cx - k * (minX + maxX) / 2, scale: k, labelCount: 0, extent: 0...Double(bitmap.width - 1))
            let y = GraphReading.AxisMap(origin: cy + k * (minY + maxY) / 2, scale: -k, labelCount: 0, extent: 0...Double(bitmap.height - 1))
            return Picture(bitmap: bitmap, reading: GraphReading(width: bitmap.width, height: bitmap.height, x: x, y: y, curves: []), axes: false)
        }

        init?(bitmap: GraphReader.Bitmap, reading: GraphReading, axes: Bool = true) {
            let columns = max(0, Int(reading.x.extent.lowerBound))...min(bitmap.width - 1, Int(reading.x.extent.upperBound))
            let r0 = Int(min(reading.y.extent.lowerBound, reading.y.extent.upperBound)), r1 = Int(max(reading.y.extent.lowerBound, reading.y.extent.upperBound))
            guard columns.count > 20, r1 - r0 > 20 else { return nil }
            let rows = max(0, r0)...min(bitmap.height - 1, r1)
            self.bitmap = bitmap
            self.reading = reading
            self.columns = columns
            self.rows = rows
            radius = max(3, Int((Double(min(columns.count, rows.count)) * 0.015).rounded()))
            // A diagram has no axes: nothing is set aside as one.
            let axisColumn = axes ? reading.x.pixel(0) : -1e9, axisRow = axes ? reading.y.pixel(0) : -1e9
            self.axisColumn = axisColumn
            self.axisRow = axisRow
            curves = PictureInk.curves(bitmap, columns: columns, rows: rows) { c, r in
                abs(Double(c) - axisColumn) <= 2 || abs(Double(r) - axisRow) <= 2
            }
        }

        /// The same picture with its pixels read in other units (`FamilyRecognizer.axisMaps` × `scale`), so a chart
        /// drawn in those units is compared where it belongs.
        func reading(in maps: (x: GraphReading.AxisMap, y: GraphReading.AxisMap), scale: Double) -> Picture {
            var copy = self
            copy.reading.x = GraphReading.AxisMap(origin: maps.x.origin, scale: maps.x.scale / scale, labelCount: maps.x.labelCount, extent: maps.x.extent)
            copy.reading.y = GraphReading.AxisMap(origin: maps.y.origin, scale: maps.y.scale / scale, labelCount: maps.y.labelCount, extent: maps.y.extent)
            return copy
        }

        /// The axes are ink everywhere along them: a curve point on an axis proves nothing.
        func nearAxis(_ c: Int, _ r: Int) -> Bool { abs(Double(c) - axisColumn) <= 2 || abs(Double(r) - axisRow) <= 2 }

        func pixel(_ p: [Double]) -> (Int, Int)? {
            let c = Int(reading.x.pixel(p[0]).rounded()), r = Int(reading.y.pixel(p[1]).rounded())
            return columns.contains(c) && rows.contains(r) ? (c, r) : nil
        }

        func isInk(_ c: Int, _ r: Int) -> Bool {
            guard c >= 0, r >= 0, c < bitmap.width, r < bitmap.height else { return false }
            return !bitmap.isBackground(c, r) && !bitmap.isGrid(c, r)
        }

        func inkNear(_ c: Int, _ r: Int) -> Bool {
            for dr in -radius...radius { for dc in -radius...radius {
                let cc = c + dc, rr = r + dr
                guard columns.contains(cc), rows.contains(rr), !nearAxis(cc, rr) else { continue }
                if isInk(cc, rr) { return true }
            } }
            return false
        }
    }

    /// How well the scene's lines match the picture's curves: coverage and recall (nil when either has too little
    /// to measure).
    static func lineScore(_ scene: FigureScene, picture: Picture) -> (coverage: Double?, recall: Double?, sampled: Int) {
        let w = picture.columns.count, h = picture.rows.count
        var drawn = [Bool](repeating: false, count: w * h)
        var sampled = 0, covered = 0
        for mark in scene.marks where mark.kind == .line || mark.kind == .vector {
            for piece in mark.pieces {
                var last: (Int, Int)?
                for (a, b) in zip(piece, piece.dropFirst()) {
                    // Every pixel along the segment, stamped into the drawn mask; every ~4 px a coverage sample.
                    let pa = (picture.reading.x.pixel(a[0]), picture.reading.y.pixel(a[1]))
                    let pb = (picture.reading.x.pixel(b[0]), picture.reading.y.pixel(b[1]))
                    let steps = max(1, Int(max(abs(pb.0 - pa.0), abs(pb.1 - pa.1)).rounded(.up)))
                    guard steps < 4000 else { continue }
                    for k in 0...steps {
                        let t = Double(k) / Double(steps)
                        let c = Int((pa.0 + (pb.0 - pa.0) * t).rounded()), r = Int((pa.1 + (pb.1 - pa.1) * t).rounded())
                        guard picture.columns.contains(c), picture.rows.contains(r) else { continue }
                        let rad = picture.radius
                        for dr in -rad...rad { for dc in -rad...rad {
                            let cc = c - picture.columns.lowerBound + dc, rr = r - picture.rows.lowerBound + dr
                            if cc >= 0, cc < w, rr >= 0, rr < h { drawn[rr * w + cc] = true }
                        } }
                        guard !picture.nearAxis(c, r) else { continue }
                        if let l = last, hypot(Double(c - l.0), Double(r - l.1)) < 4 { continue }
                        last = (c, r)
                        sampled += 1
                        if picture.inkNear(c, r) { covered += 1 }
                    }
                }
            }
        }
        var inkTotal = 0, inkHit = 0
        for curve in picture.curves {
            let stride = max(1, curve.count / 60)
            for k in Swift.stride(from: 0, to: curve.count, by: stride) {
                let (c, r) = curve[k]
                inkTotal += 1
                if drawn[(r - picture.rows.lowerBound) * w + (c - picture.columns.lowerBound)] { inkHit += 1 }
            }
        }
        return (sampled >= 8 ? Double(covered) / Double(sampled) : nil, inkTotal >= 30 ? Double(inkHit) / Double(inkTotal) : nil, sampled)
    }

    /// One number for choosing between candidate drawings: the harmonic mean of coverage and recall.
    static func fitScore(_ scene: FigureScene, picture: Picture) -> Double {
        let score = lineScore(scene, picture: picture)
        guard let coverage = score.coverage else { return 0 }
        let recall = score.recall ?? coverage
        return coverage + recall > 0 ? 2 * coverage * recall / (coverage + recall) : 0
    }

    public static func verify(_ chart: StandardChart, png: Data, engine: MathEngine) async -> ChartVerification? {
        let found: Picture?
        if chart.axesHidden { found = await Picture.diagram(png: png, chart: chart, engine: engine) }
        else { found = await Picture(png: png, hints: chart) }
        guard let picture = found else {
            return ChartVerification(passed: false, summary: "Unverified: the picture's axes could not be read, so the shading and curves could not be compared with it.")
        }
        let scene = await FigureScene.build(chart, engine: engine)
        return verify(scene: scene, picture: picture)
    }

    static func verify(scene: FigureScene, picture: Picture) -> ChartVerification {
        let bitmap = picture.bitmap, reading = picture.reading, columns = picture.columns, rows = picture.rows
        var notes: [String] = [], passed = true, anyCheck = false

        // Regions.
        let fills = scene.marks.filter { $0.kind == .fill }
        if !fills.isEmpty {
            // Shaded: a solid tint (most pixels not paper) or hatching / dense colour (enough dark or coloured pixels).
            let half = max(4, picture.radius + 1)
            func shaded(_ c: Int, _ r: Int) -> Bool {
                var any = 0, strong = 0, total = 0
                for dr in Swift.stride(from: -half, through: half, by: 2) { for dc in Swift.stride(from: -half, through: half, by: 2) {
                    let cc = c + dc, rr = r + dr
                    guard columns.contains(cc), rows.contains(rr) else { continue }
                    total += 1
                    if !bitmap.isBackground(cc, rr) { any += 1 }
                    if bitmap.isInk(cc, rr) || bitmap.hueBin(cc, rr) != nil { strong += 1 }
                } }
                guard total > 0 else { return false }
                return Double(any) / Double(total) >= 0.55 || Double(strong) / Double(total) >= 0.18
            }
            let boundaries = scene.marks.filter { $0.kind == .line }.flatMap(\.pieces).flatMap { $0 }.compactMap(picture.pixel)
            func nearBoundary(_ c: Int, _ r: Int) -> Bool {
                let reach = Double(half * 2 + 2)
                return boundaries.contains { hypot(Double($0.0 - c), Double($0.1 - r)) < reach }
            }
            func predictedInside(_ x: Double, _ y: Double) -> Bool {
                fills.contains { mark in mark.pieces.contains { $0.count == 2 && x >= $0[0][0] && x <= $0[1][0] && y >= $0[0][1] && y <= $0[1][1] } }
            }
            var agree = 0, total = 0, shadedCount = 0
            // Each sample's colour (a small neighbourhood's mean) and the predicted side, for the two-tone test below.
            var samples: [(inside: Bool, colour: (Double, Double, Double))] = []
            let steps = 48
            for j in 0..<steps { for i in 0..<steps {
                let c = columns.lowerBound + (columns.count - 1) * (2 * i + 1) / (2 * steps)
                let r = rows.lowerBound + (rows.count - 1) * (2 * j + 1) / (2 * steps)
                guard !picture.nearAxis(c, r), !nearBoundary(c, r) else { continue }
                let p = reading.data(column: Double(c), row: Double(r))
                let inside = predictedInside(p.x, p.y), seen = shaded(c, r)
                total += 1
                if inside == seen { agree += 1 }
                if seen { shadedCount += 1 }
                var sum = (0.0, 0.0, 0.0), n = 0.0
                for dr in -2...2 { for dc in -2...2 where columns.contains(c + dc) && rows.contains(r + dr) {
                    let q = bitmap.rgb(c + dc, r + dr)
                    sum.0 += Double(q.r); sum.1 += Double(q.g); sum.2 += Double(q.b); n += 1
                } }
                samples.append((inside, (sum.0 / n, sum.1 / n, sum.2 / n)))
            } }
            // A picture shaded on both sides (grey on one, tan on the other): which side is which is told by colour,
            // not by paper versus tint. Each sample is nearer its own side's mean colour when the region is right.
            let ins = samples.filter(\.inside), outs = samples.filter { !$0.inside }
            func mean(_ list: [(inside: Bool, colour: (Double, Double, Double))]) -> (Double, Double, Double) {
                let n = Double(max(1, list.count))
                return (list.reduce(0) { $0 + $1.colour.0 } / n, list.reduce(0) { $0 + $1.colour.1 } / n, list.reduce(0) { $0 + $1.colour.2 } / n)
            }
            let mi = mean(ins), mo = mean(outs)
            func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { hypot(hypot(a.0 - b.0, a.1 - b.1), a.2 - b.2) }
            if shadedCount * 10 >= total * 9, !ins.isEmpty, !outs.isEmpty, distance(mi, mo) >= 25 {
                agree = samples.filter { distance($0.colour, $0.inside ? mi : mo) <= distance($0.colour, $0.inside ? mo : mi) }.count
            }
            if total >= 30, shadedCount * 50 >= total {
                anyCheck = true
                let share = Double(agree) / Double(total)
                let ok = share >= regionAgreement
                passed = passed && ok
                notes.append("the shaded region matches the picture's shading at \(Int((share * 100).rounded()))% of \(total) sampled points" + (ok ? "" : " (needs \(Int(regionAgreement * 100))%)"))
            } else if total >= 30 {
                notes.append("the picture shows no shading to compare (only the boundary was checked)")
            }
        }

        // Plotted points: each must sit on a drawn dot (a solid blob of ink), not just near a line.
        let dots = scene.marks.filter { $0.kind == .dots }.flatMap(\.pieces).flatMap { $0 }
        if !dots.isEmpty {
            var found = 0, inside = 0
            for p in dots {
                let c = Int(reading.x.pixel(p[0]).rounded()), r = Int(reading.y.pixel(p[1]).rounded())
                guard columns.contains(c), rows.contains(r) else { continue }
                inside += 1
                // The densest small disc within reach of where the point should be.
                var best = 0.0
                let reach = picture.radius + 2
                for dr in Swift.stride(from: -reach, through: reach, by: 2) { for dc in Swift.stride(from: -reach, through: reach, by: 2) {
                    var on = 0, total = 0
                    // A solid disc a line through the spot cannot fill (a drawn dot, not a curve passing by).
                    for y in -4...4 { for x in -4...4 where x * x + y * y <= 16 {
                        total += 1
                        if picture.isInk(c + dc + x, r + dr + y) { on += 1 }
                    } }
                    best = max(best, Double(on) / Double(total))
                } }
                if best >= 0.88 { found += 1 }
            }
            if inside > 0 {
                anyCheck = true
                let ok = Double(found) / Double(inside) >= 0.8
                passed = passed && ok
                notes.append("\(found) of \(inside) plotted point\(inside == 1 ? "" : "s") sit on a drawn dot")
            } else {
                passed = false
                notes.append("the plotted points fall outside the picture's axes")
            }
        }

        // Lines, both ways.
        let score = lineScore(scene, picture: picture)
        if let coverage = score.coverage {
            anyCheck = true
            let ok = coverage >= lineCoverage
            passed = passed && ok
            notes.append("\(Int((coverage * 100).rounded()))% of the drawn curves lie on the picture's ink" + (ok ? "" : " (needs \(Int(lineCoverage * 100))%)"))
        }
        // Recall only for line drawings: a region's own shading is not a curve to cover.
        if fills.isEmpty, let recall = score.recall {
            let ok = recall >= lineRecall
            passed = passed && ok
            notes.append("\(Int((recall * 100).rounded()))% of the picture's curves are drawn" + (ok ? "" : " (needs \(Int(lineRecall * 100))%; some curves are missing or misplaced)"))
        }

        guard anyCheck else {
            return ChartVerification(passed: false, summary: "Unverified: nothing the chart draws falls inside the picture's axes.")
        }
        let calibration = reading.isCalibratedFromLabels ? "" : " (axes not labelled; scale fitted)"
        var summary = (passed ? "Verified against the picture: " : "Mismatch with the picture: ") + notes.joined(separator: "; ") + calibration + "."
        // On a mismatch, where the picture's curves actually run (in the picture's own numbers), for the retry.
        if !passed, reading.isCalibratedFromLabels, !picture.curves.isEmpty {
            let measured = picture.curves.sorted { $0.count > $1.count }.prefix(3).flatMap { curve -> [String] in
                let sorted = curve.sorted { $0.0 < $1.0 }
                return [0.1, 0.5, 0.9].map { f in
                    let (c, r) = sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))]
                    let p = reading.data(column: Double(c), row: Double(r))
                    return "(\(ChartGeometry.number((p.x * 100).rounded() / 100)), \(ChartGeometry.number((p.y * 100).rounded() / 100)))"
                }
            }
            summary += " The picture's curves pass through " + measured.joined(separator: ", ") + "."
        }
        return ChartVerification(passed: passed, summary: summary)
    }
}
