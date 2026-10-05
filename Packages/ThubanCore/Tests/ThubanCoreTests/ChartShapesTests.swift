import XCTest
@testable import ThubanCore

/// Shaded regions, level-curve families and parametric curves: parsing, geometry and build time.
final class ChartShapesTests: XCTestCase {
    static let engine = MathEngine()
    let window = FigureScene.Window(x: -8...8, y: -8...8)

    func testInequalitiesBecomeConditions() {
        XCTAssertEqual(ChartShapes.conditions("x^2+y^2\\le 49, x\\ge 0")?.count, 2)
        XCTAssertEqual(ChartShapes.conditions("-1\\le x+y\\le 1")?.count, 2, "a chain is one condition per link")
        XCTAssertEqual(ChartShapes.conditions("y > x^2 \\text{ and } y<4")?.count, 2)
        XCTAssertEqual(ChartShapes.conditions("x ≥ 0; y ≤ 2")?.count, 2)
        XCTAssertNil(ChartShapes.conditions("x^2+y^2=49, x\\le 0"), "an equation is a boundary, not a region")
        XCTAssertNil(ChartShapes.conditions("y=\\left(x+1\\right)^2"), "\\left is not \\le")
        XCTAssertNil(ChartShapes.conditions("2x+1"))
    }

    func testPlainTextFormulasAreNormalised() {
        XCTAssertEqual(ChartShapes.normalised("2-sqrt(x)"), "2-\\sqrt{x}")
        XCTAssertEqual(ChartShapes.normalised("asin(x+y)"), "\\arcsin(x+y)")
        XCTAssertEqual(ChartShapes.normalised("\\sin(x)+cos(y)"), "\\sin(x)+\\cos(y)")
    }

    func testParametricPairs() throws {
        let pair = try XCTUnwrap(ChartShapes.parametricPair("x=\\cos(5t), y=\\sin(2t)"))
        XCTAssertEqual(pair.x, "\\cos(5t)")
        XCTAssertEqual(pair.y, "\\sin(2t)")
        XCTAssertNil(ChartShapes.parametricPair("x=2, y=3"), "no t: two lines, not a curve")
        XCTAssertNil(ChartShapes.parametricPair("y=\\tan(x)"))
    }

    func testAHalfDiskIsShadedAndBounded() async throws {
        let series = ChartSeries(name: "D", latex: "x^2+y^2\\le 49, x\\ge 0")
        XCTAssertEqual(FigureScene.shape(of: series), .region("x^2+y^2\\le 49, x\\ge 0"), "an inequality without a kind is a region")
        let built = await ChartShapes.region("x^2+y^2\\le 49, x\\ge 0", window: window, engine: Self.engine)
        let region = try XCTUnwrap(built)
        let area = region.fill.reduce(0.0) { $0 + ($1[1][0] - $1[0][0]) * ($1[1][1] - $1[0][1]) }
        XCTAssertEqual(area, Double.pi * 49 / 2, accuracy: 1.5, "the half-disk's area")
        for rect in region.fill { XCTAssertGreaterThanOrEqual(rect[0][0], -0.1, "nothing left of the y-axis") }
        let boundary = region.boundary.flatMap { $0 }
        XCTAssertGreaterThan(boundary.count, 100)
        for p in boundary where p[0] > 0.2 { XCTAssertEqual(hypot(p[0], p[1]), 7, accuracy: 0.1) }
    }

    func testLevelCurvesAreOneLoopPerLevel() async throws {
        let built = await ChartShapes.levelCurves("f(x,y)=x^2+y^2", levels: [1, 4, 9], window: FigureScene.Window(x: -4...4, y: -4...4), engine: Self.engine)
        let curves = try XCTUnwrap(built)
        XCTAssertEqual(curves.count, 3)
        for (curve, radius) in zip(curves, [1.0, 2, 3]) {
            XCTAssertEqual(curve.count, 1, "one closed loop")
            for p in curve[0] { XCTAssertEqual(hypot(p[0], p[1]), radius, accuracy: 0.03) }
        }
    }

    func testALissajousCurveIsDrawnQuicklyWithArrows() async throws {
        let chart = StandardChart(chartType: "function", series: [ChartSeries(name: "d", latex: "x=\\cos(5t), y=\\sin(2t)")],
                                  xRange: [-1.2, 1.2], yRange: [-1.2, 1.2], confidence: 0.9)
        let start = Date()
        let scene = await FigureScene.build(chart, engine: Self.engine)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "compiled, not symbolic")
        let points = try XCTUnwrap(scene.marks.first { $0.kind == .line }).pieces.flatMap { $0 }
        XCTAssertGreaterThan(points.count, 1000)
        for p in points.prefix(200) { XCTAssertLessThanOrEqual(abs(p[0]), 1.0001); XCTAssertLessThanOrEqual(abs(p[1]), 1.0001) }

        var arrowed = chart
        arrowed.series[0].directionArrows = true
        let withArrows = await FigureScene.build(arrowed, engine: Self.engine)
        let arrows = try XCTUnwrap(withArrows.marks.first { $0.kind == .arrows }).pieces.flatMap { $0 }
        XCTAssertGreaterThanOrEqual(arrows.count, 2)
    }

    func testAContourMapBuildsFast() async throws {
        var series = ChartSeries(name: "f", latex: "y e^{x}")
        series.kind = "level"
        series.levels = [-3, -2, -1, 0, 1, 2, 3]
        let chart = StandardChart(chartType: "function", series: [series], xRange: [-3, 3], yRange: [-3, 3], confidence: 0.9)
        let start = Date()
        let scene = await FigureScene.build(chart, engine: Self.engine)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let pieces = try XCTUnwrap(scene.marks.first).pieces
        XCTAssertGreaterThanOrEqual(pieces.count, 7)
        for p in pieces.flatMap({ $0 }) {
            let value = p[1] * exp(p[0])
            XCTAssertLessThan(abs(value - value.rounded()), 0.05, "every point is on an integer level")
        }
    }

    func testAnArcIsAnEquationRestrictedByConditions() async throws {
        let chart = StandardChart(chartType: "function", series: [ChartSeries(name: "D", latex: "x^2+y^2=49, x\\le 0")], xRange: [-8, 8], yRange: [-8, 8], confidence: 0.9)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        let points = try XCTUnwrap(scene.marks.first).pieces.flatMap { $0 }
        XCTAssertGreaterThan(points.count, 100)
        for p in points {
            XCTAssertLessThanOrEqual(p[0], 0.05, "only the left half")
            XCTAssertEqual(hypot(p[0], p[1]), 7, accuracy: 0.05)
        }
    }

    func testPlainTextSqrtFamilyDraws() async throws {
        let chart = StandardChart(chartType: "function", series: [ChartSeries(name: "c=2", latex: "2-sqrt(x)")], xRange: [0, 10], yRange: [-3, 3], confidence: 0.9)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        let points = try XCTUnwrap(scene.marks.first).pieces.flatMap { $0 }
        XCTAssertGreaterThan(points.count, 100)
        for p in points { XCTAssertEqual(p[1], 2 - p[0].squareRoot(), accuracy: 1e-6) }
    }
}
