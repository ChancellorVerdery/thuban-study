import Foundation

/// The picture check for charts with shapes (`ChartShapes`): shaded regions, level-curve families and parametric
/// curves. The reconciler's colour-cluster curves cannot represent those (a region is an area, a contour map has
/// many closed curves, a parametric curve loops back over itself), so the chart is drawn and compared with the
/// picture directly, through the axes `GraphReader` finds:
/// - a region's predicted inside against the picture's shading (a tint or hatching), sampled away from the
///   boundary;
/// - every drawn line (boundaries, level curves, parametric curves, other curves) against the picture's ink: the
///   share of points along it with ink nearby.
public enum ShapeVerifier {
    /// A region passes when its inside agrees with the picture's shading at this share of the sampled points.
    static let regionAgreement = 0.85
    /// Lines pass when this share of their points has ink nearby.
    static let lineCoverage = 0.8

    /// The chart has a series the reconciler cannot check (a region, level curves or a parametric curve).
    public static func hasShapes(_ chart: StandardChart) -> Bool {
        chart.series.contains { FigureScene.shape(of: $0) != .curve }
    }

    public static func verify(_ chart: StandardChart, png: Data, engine: MathEngine) async -> ChartVerification? {
        guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image),
              let reading = await GraphReader.read(png: png, hints: chart) else {
            return ChartVerification(passed: false, summary: "Unverified: the picture's axes could not be read, so the shading and curves could not be compared with it.")
        }
        let scene = await FigureScene.build(chart, engine: engine)
        return verify(scene: scene, chart: chart, reading: reading, bitmap: bitmap)
    }

    static func verify(scene: FigureScene, chart: StandardChart, reading: GraphReading, bitmap: GraphReader.Bitmap) -> ChartVerification {
        let columns = max(0, Int(reading.x.extent.lowerBound))...min(bitmap.width - 1, Int(reading.x.extent.upperBound))
        let rows = max(0, Int(min(reading.y.extent.lowerBound, reading.y.extent.upperBound)))...min(bitmap.height - 1, Int(max(reading.y.extent.lowerBound, reading.y.extent.upperBound)))
        guard columns.count > 20, rows.count > 20 else {
            return ChartVerification(passed: false, summary: "Unverified: the picture's plot area is too small to compare.")
        }
        let radius = max(3, Int((Double(min(columns.count, rows.count)) * 0.015).rounded()))
        func pixel(_ p: [Double]) -> (Int, Int)? {
            let c = Int(reading.x.pixel(p[0]).rounded()), r = Int(reading.y.pixel(p[1]).rounded())
            return columns.contains(c) && rows.contains(r) ? (c, r) : nil
        }
        // Ink: anything darker or more coloured than paper and a pale gridline.
        func isInk(_ c: Int, _ r: Int) -> Bool { !bitmap.isBackground(c, r) && !bitmap.isGrid(c, r) }
        func inkNear(_ c: Int, _ r: Int) -> Bool {
            for dr in -radius...radius { for dc in -radius...radius {
                let cc = c + dc, rr = r + dr
                guard columns.contains(cc), rows.contains(rr), !nearAxis(cc, rr) else { continue }
                if isInk(cc, rr) { return true }
            } }
            return false
        }
        let axisColumn = reading.x.pixel(0), axisRow = reading.y.pixel(0)
        // The axes are ink everywhere along them: a curve point on an axis proves nothing.
        func nearAxis(_ c: Int, _ r: Int) -> Bool { abs(Double(c) - axisColumn) <= 2 || abs(Double(r) - axisRow) <= 2 }

        var notes: [String] = [], passed = true, anyCheck = false

        // Regions.
        let fills = scene.marks.filter { $0.kind == .fill }
        if !fills.isEmpty {
            // Shaded: a solid tint (most pixels not paper) or hatching / dense colour (enough dark or coloured pixels).
            let half = max(4, radius + 1)
            func shaded(_ c: Int, _ r: Int) -> Bool {
                var any = 0, strong = 0, total = 0
                for dr in stride(from: -half, through: half, by: 2) { for dc in stride(from: -half, through: half, by: 2) {
                    let cc = c + dc, rr = r + dr
                    guard columns.contains(cc), rows.contains(rr) else { continue }
                    total += 1
                    if !bitmap.isBackground(cc, rr) { any += 1 }
                    if bitmap.isInk(cc, rr) || bitmap.hueBin(cc, rr) != nil { strong += 1 }
                } }
                guard total > 0 else { return false }
                return Double(any) / Double(total) >= 0.55 || Double(strong) / Double(total) >= 0.18
            }
            let boundaries = scene.marks.filter { $0.kind == .line }.flatMap(\.pieces).flatMap { $0 }.compactMap(pixel)
            func nearBoundary(_ c: Int, _ r: Int) -> Bool {
                let reach = Double(half * 2 + 2)
                return boundaries.contains { hypot(Double($0.0 - c), Double($0.1 - r)) < reach }
            }
            func predictedInside(_ x: Double, _ y: Double) -> Bool {
                fills.contains { mark in mark.pieces.contains { $0.count == 2 && x >= $0[0][0] && x <= $0[1][0] && y >= $0[0][1] && y <= $0[1][1] } }
            }
            var agree = 0, total = 0, shadedCount = 0, insideCount = 0
            let steps = 48
            for j in 0..<steps { for i in 0..<steps {
                let c = columns.lowerBound + (columns.count - 1) * (2 * i + 1) / (2 * steps)
                let r = rows.lowerBound + (rows.count - 1) * (2 * j + 1) / (2 * steps)
                guard !nearAxis(c, r), !nearBoundary(c, r) else { continue }
                let p = reading.data(column: Double(c), row: Double(r))
                let inside = predictedInside(p.x, p.y), seen = shaded(c, r)
                total += 1
                if inside == seen { agree += 1 }
                if seen { shadedCount += 1 }
                if inside { insideCount += 1 }
            } }
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

        // Lines: every boundary, level curve and parametric curve the chart draws.
        var sampled = 0, covered = 0
        for mark in scene.marks where mark.kind == .line {
            for piece in mark.pieces {
                // About every 4 pixels along the piece.
                var last: (Int, Int)?
                for p in piece {
                    guard let at = pixel(p), !nearAxis(at.0, at.1) else { continue }
                    if let last, hypot(Double(at.0 - last.0), Double(at.1 - last.1)) < 4 { continue }
                    last = at
                    sampled += 1
                    if inkNear(at.0, at.1) { covered += 1 }
                }
            }
        }
        if sampled >= 20 {
            anyCheck = true
            let share = Double(covered) / Double(sampled)
            let ok = share >= lineCoverage
            passed = passed && ok
            notes.append("\(Int((share * 100).rounded()))% of the drawn curves lie on the picture's ink" + (ok ? "" : " (needs \(Int(lineCoverage * 100))%)"))
        }

        guard anyCheck else {
            return ChartVerification(passed: false, summary: "Unverified: nothing the chart draws falls inside the picture's axes.")
        }
        let calibration = reading.isCalibratedFromLabels ? "" : " (axes not labelled; scale approximate)"
        return ChartVerification(passed: passed, summary: (passed ? "Verified against the picture: " : "Mismatch with the picture: ")
                                 + notes.joined(separator: "; ") + calibration + ".")
    }
}
