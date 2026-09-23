import XCTest
import CoreGraphics
import CoreText
@testable import ThubanCore

/// The graph reader on plots drawn here: black axes with numeric tick labels, curves in colour.
final class GraphReaderTests: XCTestCase {
    static let engine = MathEngine()

    /// A 400×400 plot of the window −4…4 with unit ticks and labels every unit, and the given curves drawn as
    /// 2-px lines in colour. `xLabels`/`yLabels` false leaves that axis unlabelled.
    static func plot(curves: [(color: CGColor, points: [(Double, Double)])], xLabels: Bool = true, yLabels: Bool = true, frame: Bool = false) -> Data {
        let size = 400
        let context = ImageCodec.rgbaContext(width: size, height: size)!
        // Pixel of a data point: 45 px per unit, origin at (200, 200); CoreGraphics' origin is bottom-left.
        func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 200 + 45 * x, y: 200 + 45 * y) }
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(2)
        context.move(to: px(-4.2, 0)); context.addLine(to: px(4.2, 0)); context.strokePath()
        context.move(to: px(0, -4.2)); context.addLine(to: px(0, 4.2)); context.strokePath()
        if frame {
            context.stroke(CGRect(x: px(-4.2, -4.2).x, y: px(-4.2, -4.2).y, width: 45 * 8.4, height: 45 * 8.4))
        }
        for v in [-3.0, -2, -1, 1, 2, 3] {
            context.move(to: px(v, -0.1)); context.addLine(to: px(v, 0.1)); context.strokePath()
            context.move(to: px(-0.1, v)); context.addLine(to: px(0.1, v)); context.strokePath()
            if xLabels { draw(text: label(v), at: CGPoint(x: px(v, 0).x - 6, y: px(v, 0).y - 20), in: context) }
            if yLabels { draw(text: label(v), at: CGPoint(x: px(0, v).x - 26, y: px(0, v).y - 5), in: context) }
        }
        for curve in curves {
            context.setStrokeColor(curve.color)
            context.setLineWidth(2)
            var first = true
            for (x, y) in curve.points where abs(y) <= 4.2 {
                let p = px(x, y)
                if first { context.move(to: p); first = false } else { context.addLine(to: p) }
            }
            context.strokePath()
        }
        return ImageCodec.png(from: context.makeImage()!)!
    }

    static func label(_ v: Double) -> String { v < 0 ? "−\(Int(-v))" : "\(Int(v))" }

    static func draw(text: String, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static let blue = CGColor(red: 0.1, green: 0.45, blue: 0.9, alpha: 1)
    static let red = CGColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1)

    static func samples(_ f: (Double) -> Double, from a: Double = -4, to b: Double = 4) -> [(Double, Double)] {
        stride(from: a, through: b, by: 0.02).map { ($0, f($0)) }
    }

    func testCalibratesFromLabelsAndExtractsColouredCurves() async throws {
        let png = Self.plot(curves: [(Self.blue, Self.samples { $0 * $0 / 4 - 1 }), (Self.red, Self.samples { -0.5 * $0 + 1 })])
        let readingOptional = await GraphReader.read(png: png)
        let reading = try XCTUnwrap(readingOptional)
        XCTAssertTrue(reading.isCalibratedFromLabels)
        XCTAssertGreaterThanOrEqual(reading.x.labelCount, 4)
        XCTAssertGreaterThanOrEqual(reading.y.labelCount, 4)
        XCTAssertEqual(reading.originColumn, 200, accuracy: 2.5)
        XCTAssertEqual(reading.originRow, 200, accuracy: 2.5)
        XCTAssertEqual(reading.x.scale, 45, accuracy: 1.5)
        XCTAssertEqual(reading.y.scale, -45, accuracy: 1.5)
        XCTAssertEqual(reading.x.range.lowerBound, -4.2, accuracy: 0.15)
        XCTAssertEqual(reading.x.range.upperBound, 4.2, accuracy: 0.15)

        XCTAssertEqual(reading.curves.count, 2)
        let blue = try XCTUnwrap(reading.curves.first { $0.color == "blue" })
        let red = try XCTUnwrap(reading.curves.first { $0.color == "red" })
        // The polylines follow the functions they were drawn from.
        for point in blue.points where abs(point[0]) < 3.8 {
            XCTAssertEqual(point[1], point[0] * point[0] / 4 - 1, accuracy: 0.2, "blue at x = \(point[0])")
        }
        for point in red.points where abs(point[0]) < 3.8 {
            XCTAssertEqual(point[1], -0.5 * point[0] + 1, accuracy: 0.12, "red at x = \(point[0])")
        }
        // Matching: the right function fits its curve, the wrong one does not.
        let parabola = Self.samples { $0 * $0 / 4 - 1 }.map { [$0.0, $0.1] }
        let line = Self.samples { -0.5 * $0 + 1 }.map { [$0.0, $0.1] }
        let good = GraphReader.match(parabola, to: blue, in: reading)
        XCTAssertGreaterThan(good.fit, 0.9); XCTAssertGreaterThan(good.coverage, 0.9)
        let bad = GraphReader.match(line, to: blue, in: reading)
        XCTAssertLessThan(bad.fit, 0.3)
    }

    func testAnUnlabelledAxisTakesTheOtherAxisScale() async throws {
        let png = Self.plot(curves: [(Self.blue, Self.samples { sin($0) })], xLabels: false)
        let readingOptional = await GraphReader.read(png: png)
        let reading = try XCTUnwrap(readingOptional)
        XCTAssertEqual(reading.x.labelCount, 0)
        XCTAssertGreaterThanOrEqual(reading.y.labelCount, 4)
        XCTAssertEqual(reading.x.scale, 45, accuracy: 1.5, "x borrows y's pixels per unit")
        XCTAssertEqual(reading.originColumn, 200, accuracy: 2.5)
        let curve = try XCTUnwrap(reading.curves.first)
        for point in curve.points where abs(point[0]) < 3.8 { XCTAssertEqual(point[1], sin(point[0]), accuracy: 0.12) }
    }

    func testAFramedPlotStillFindsTheAxes() async throws {
        let png = Self.plot(curves: [(Self.red, Self.samples { 0.25 * $0 })], frame: true)
        let readingOptional = await GraphReader.read(png: png)
        let reading = try XCTUnwrap(readingOptional)
        XCTAssertEqual(reading.originColumn, 200, accuracy: 2.5)
        XCTAssertEqual(reading.originRow, 200, accuracy: 2.5)
        XCTAssertEqual(reading.curves.count, 1)
    }

    func testAFieldsArrowGridIsCounted() async throws {
        // Grey ticks on a 12 × 9 grid inside the −4…4 window (the axes and labels as usual).
        let png: Data = {
            let size = 400
            let context = ImageCodec.rgbaContext(width: size, height: size)!
            func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 200 + 45 * x, y: 200 + 45 * y) }
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(2)
            context.move(to: px(-4.2, 0)); context.addLine(to: px(4.2, 0)); context.strokePath()
            context.move(to: px(0, -4.2)); context.addLine(to: px(0, 4.2)); context.strokePath()
            for v in [-3.0, -2, -1, 1, 2, 3] {
                context.move(to: px(v, -0.1)); context.addLine(to: px(v, 0.1)); context.strokePath()
                context.move(to: px(-0.1, v)); context.addLine(to: px(0.1, v)); context.strokePath()
                Self.draw(text: Self.label(v), at: CGPoint(x: px(v, 0).x - 6, y: px(v, 0).y - 20), in: context)
                Self.draw(text: Self.label(v), at: CGPoint(x: px(0, v).x - 26, y: px(0, v).y - 5), in: context)
            }
            context.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.setLineWidth(1.5)
            for i in 0..<12 {
                for j in 0..<9 {
                    let x = -4.0 + (Double(i) + 0.5) * 8.0 / 12, y = -4.0 + (Double(j) + 0.5) * 8.0 / 9
                    let m = x - y, d = 1 / (1 + m * m).squareRoot()
                    context.move(to: px(x - 0.2 * d, y - 0.2 * m * d)); context.addLine(to: px(x + 0.2 * d, y + 0.2 * m * d)); context.strokePath()
                }
            }
            return ImageCodec.png(from: context.makeImage()!)!
        }()
        let readingOptional = await GraphReader.read(png: png)
        let reading = try XCTUnwrap(readingOptional)
        XCTAssertEqual(reading.fieldColumns, 12)
        XCTAssertEqual(reading.fieldRows, 9)
        XCTAssertTrue(reading.curves.isEmpty, "grey ticks are not curves")

        // The reconciler carries the count into the chart.
        let chart = StandardChart(chartType: "slopeField", series: [], xRange: [-4, 4], yRange: [-4, 4], confidence: 0.8, slope: "x-y",
                                  fieldColumns: 30, fieldRows: 30, provenance: StandardChart.stated)
        let resultOptional = await FigureReconciler.reconcile(chart, png: png, engine: Self.engine)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(result.fieldColumns, 12)
        XCTAssertEqual(result.fieldRows, 9)

        // A plain plot has no field.
        let plainOptional = await GraphReader.read(png: Self.plot(curves: [(Self.blue, Self.samples { sin($0) })]))
        XCTAssertNil(try XCTUnwrap(plainOptional).fieldColumns)
    }

    func testASteepCurveIsTracedWithoutZigzags() async throws {
        // A cubic that climbs almost vertically near x = 2.5: its polyline must keep moving in one direction
        // through the steep stretch, never back up a column.
        let png = Self.plot(curves: [(Self.blue, Self.samples { 0.4 * pow($0 - 2.2, 3) - 1.5 })])
        let readingOptional = await GraphReader.read(png: png)
        let reading = try XCTUnwrap(readingOptional)
        let curve = try XCTUnwrap(reading.curves.first)
        let ys = curve.points.map { $0[1] }
        var reversals = 0
        for i in 2..<ys.count where (ys[i] - ys[i - 1]) * (ys[i - 1] - ys[i - 2]) < -0.01 { reversals += 1 }
        XCTAssertLessThanOrEqual(reversals, 1, "a monotone curve has at most a stray reversal, not a zigzag: \(ys.suffix(12))")
        for point in curve.points where abs(point[0]) < 3.5 && abs(point[1]) < 3.8 {
            XCTAssertEqual(point[1], 0.4 * pow(point[0] - 2.2, 3) - 1.5, accuracy: 0.35, "at x = \(point[0])")
        }
    }

    func testNothingToReadGivesNil() async {
        let blank = ImageCodec.png(from: ImageCodec.rgbaContext(width: 120, height: 120)!.makeImage()!)!
        let reading = await GraphReader.read(png: blank)
        XCTAssertNil(reading)
        XCTAssertNil(GraphReader.numeric("c"))
        XCTAssertEqual(GraphReader.numeric("−2.2"), -2.2)
        XCTAssertEqual(GraphReader.numeric("12"), 12)
        XCTAssertEqual(GraphReader.numeric("O"), 0)
        XCTAssertNil(GraphReader.numeric("1.2.3"))
    }

    func testReconcilerPicksTheInitialConditionThatMatchesTheDrawnCurve() async throws {
        // dy/dx = x − y through (0, 1): y = x − 1 + 2e^{−x}. Drawn in blue; the question offers three conditions.
        let png = Self.plot(curves: [(Self.blue, Self.samples { $0 - 1 + 2 * exp(-$0) })])
        let chart = StandardChart(
            chartType: "slopeField", series: [ChartSeries(name: "y(0) = -1", through: [0, -1])], xRange: [-4, 4], yRange: [-4, 4],
            confidence: 0.8, slope: "x-y", provenance: StandardChart.stated, definition: "part (b) y(0) = -1",
            candidates: [ChartCandidate(label: "part (a) y(0) = 1", x: 0, y: 1), ChartCandidate(label: "part (b) y(0) = -1", x: 0, y: -1),
                         ChartCandidate(label: "part (c) y(2) = 0", x: 2, y: 0)]
        )
        let resultOptional = await FigureReconciler.reconcile(chart, png: png, engine: Self.engine)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series.first?.through, [0, 1], "the picture, not the agent, decides")
        XCTAssertEqual(result.definition, "part (a) y(0) = 1")
        XCTAssertEqual(result.provenance, StandardChart.stated)
        XCTAssertEqual(result.verification?.passed, true)
        XCTAssertTrue(result.verification?.summary.contains("part (a) y(0) = 1") ?? false, result.verification?.summary ?? "")
        XCTAssertEqual(result.xRange?[0] ?? 0, -4.2, accuracy: 0.15, "the window comes from the axes")

        // No candidate fits: the curve's own point is used and the chart is marked traced.
        var none = chart
        none.candidates = [ChartCandidate(label: "part (c) y(2) = 0", x: 2, y: 0)]
        none.series = [ChartSeries(name: "y(2) = 0", through: [2, 0])]
        let ownOptional = await FigureReconciler.reconcile(none, png: png, engine: Self.engine)
        let own = try XCTUnwrap(ownOptional)
        XCTAssertEqual(own.provenance, StandardChart.traced)
        let through = try XCTUnwrap(own.series.first?.throughPoint)
        XCTAssertEqual(through.y, through.x - 1 + 2 * exp(-through.x), accuracy: 0.15, "anchored on the drawn curve")
        XCTAssertEqual(own.verification?.passed, true)

        // A bare field (no curve drawn) with no claimed curve verifies as such.
        let bare = Self.plot(curves: [])
        var field = chart
        field.series = []
        let bareResultOptional = await FigureReconciler.reconcile(field, png: bare, engine: Self.engine)
        let bareResult = try XCTUnwrap(bareResultOptional)
        XCTAssertTrue(bareResult.series.isEmpty)
        XCTAssertEqual(bareResult.verification?.passed, true)
    }

    func testReconcilerChecksStatedFunctionsAndTracesTheRest() async throws {
        let png = Self.plot(curves: [(Self.blue, Self.samples { $0 * $0 / 4 - 1 }), (Self.red, Self.samples { -0.5 * $0 + 1 })])
        // The agent stated the parabola correctly, the line wrongly, and missed nothing.
        let chart = StandardChart(
            chartType: "function", series: [ChartSeries(name: "f", latex: "\\frac{x^2}{4}-1"), ChartSeries(name: "g", latex: "0.5x+1")],
            xRange: [-4, 4], yRange: [-4, 4], confidence: 0.8, provenance: StandardChart.stated
        )
        let resultOptional = await FigureReconciler.reconcile(chart, png: png, engine: Self.engine)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(result.series.count, 2)
        XCTAssertEqual(result.series[0].latex, "\\frac{x^2}{4}-1", "a stated function that matches is kept")
        XCTAssertNil(result.series[1].latex, "a stated function the picture does not show gives way to the drawn curve")
        XCTAssertGreaterThan(result.series[1].points?.count ?? 0, 10)
        XCTAssertEqual(result.verification?.passed, true, "the corrected chart matches the picture")
        let summary = result.verification?.summary ?? ""
        XCTAssertTrue(summary.contains("y = 0.5x+1 is not what is drawn; removed"), summary)
        XCTAssertTrue(summary.contains("1 curve traced from the picture"), summary)
        let printed = Set(result.xAxisLabels?.map(\.text) ?? [])
        XCTAssertTrue(Set(["−2", "−1", "1", "2"]).isSubset(of: printed), "the labels the picture prints: \(printed)")
        XCTAssertFalse(printed.contains("−4") || printed.contains("4"), "no label where the picture prints none")

        // A traced chart: the agent's rough points are replaced by the pixels, and a curve it missed is added.
        let rough = StandardChart(chartType: "line", series: [ChartSeries(name: "sketch", points: [[-4, 3], [-2, 0], [0, -1], [2, 0], [4, 3]])],
                                  xRange: [-4, 4], yRange: [-4, 4], confidence: 0.5, provenance: StandardChart.traced)
        let tracedOptional = await FigureReconciler.reconcile(rough, png: png, engine: Self.engine)
        let traced = try XCTUnwrap(tracedOptional)
        XCTAssertEqual(traced.series.count, 2)
        XCTAssertEqual(traced.series[0].name, "sketch")
        XCTAssertGreaterThan(traced.series[0].points?.count ?? 0, 30, "re-read from the picture")
        for point in traced.series[0].points ?? [] where abs(point[0]) < 3.8 { XCTAssertEqual(point[1], point[0] * point[0] / 4 - 1, accuracy: 0.2) }
        XCTAssertEqual(traced.series[1].name, "red curve")
        XCTAssertEqual(traced.verification?.passed, true)
    }
}
