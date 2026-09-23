import XCTest
@testable import ThubanCore

final class CurveFitterTests: XCTestCase {
    func testStatedSlopeFromQuestionText() {
        XCTAssertEqual(CurveFitter.statedSlope(in: "Consider $$\\frac{dy}{dx} = y - y^3$$ and y(0)=1"), "y - y^3")
        XCTAssertEqual(CurveFitter.statedSlope(in: "$$\\frac{dy}{dx} = x(y-7)^2 - 2,$$ but"), "x(y-7)^2 - 2")
        XCTAssertNil(CurveFitter.statedSlope(in: "the equation $\\dfrac{dy}{dx} = f(y)$, where the graph of $f$ is given"))
        XCTAssertTrue(CurveFitter.mentionsAutonomousF("the equation $\\dfrac{dy}{dx} = f(y)$, where"))
    }

    func testGraphOfFNeedsAnFAxisOrNoSolutionContext() {
        let solutions = StandardChart(chartType: "function", xLabel: "x", yLabel: "y")
        let graph = StandardChart(chartType: "function", xLabel: "y", yLabel: "f")
        let unnamed = StandardChart(chartType: "function")
        let autonomous = "Consider $\\dfrac{dy}{dx} = f(y)$, where the graph of $f$ is given."
        XCTAssertTrue(CurveFitter.isGraphOfF(autonomous, chart: graph))
        XCTAssertFalse(CurveFitter.isGraphOfF(autonomous, chart: solutions))
        XCTAssertFalse(CurveFitter.isGraphOfF(autonomous, chart: unnamed))
        XCTAssertTrue(CurveFitter.isGraphOfF("The given figure represents the graph of $f(x)$.", chart: unnamed))
    }

    func testPolynomialIsFoundAndRounded() {
        // (x²−1)(x²−4) = x⁴ − 5x² + 4, with a little tracing noise.
        let points: [[Double]] = stride(from: -2.3, through: 2.3, by: 0.02).enumerated().map { (i: Int, x: Double) -> [Double] in
            [x, x * x * x * x - 5 * x * x + 4 + (i % 2 == 0 ? 0.01 : -0.01)]
        }
        let window = FigureScene.Window(x: -3...3, y: -3.5...4.5)
        let fit = CurveFitter.fitPolynomial(points, window: window)
        XCTAssertEqual(fit?.latex, "x^{4}-5x^{2}+4")
    }

    func testPolynomialWithLabelledZerosIsFactored() {
        // −0.5(y+2.2)(y−0.5)(y−1.7): its expanded coefficients are not round, its zeros are.
        let points: [[Double]] = stride(from: -2.5, through: 2.5, by: 0.02).map { (y: Double) -> [Double] in
            [y, -0.5 * (y + 2.2) * (y - 0.5) * (y - 1.7)]
        }
        let fit = CurveFitter.fitPolynomial(points, window: FigureScene.Window(x: -2.6...2.6, y: -3.3...3.3))
        XCTAssertEqual(fit?.latex, "-0.5\\left(x+2.2\\right)\\left(x-0.5\\right)\\left(x-1.7\\right)")
    }

    func testFlatLineBecomesTheEquilibrium() async throws {
        var chart = StandardChart(chartType: "function", xLabel: "x", yLabel: "y",
                                  series: [ChartSeries(name: "dashed", points: stride(from: -3.0, through: 3.0, by: 0.1).map { [$0, 0.992] })],
                                  xRange: [-3, 3], yRange: [-0.5, 2])
        chart.xAxisLabels = []
        let fitted = await CurveFitter.fit(chart, questionText: "$$\\frac{dy}{dx} = y - y^3$$", engine: MathEngine())
        XCTAssertEqual(try XCTUnwrap(fitted).series[0].latex, "y=1")
    }

    func testSolutionWithUnnumberedAxisGetsItsTimeScale() async throws {
        // A solution of dy/dx = y − y³ drawn with x stretched (k = 0.6), as a sketch without x numbers.
        let k = 0.6
        var y = 0.05, x = -4.0
        var points: [[Double]] = []
        while x <= 4 {
            points.append([x, y])
            for _ in 0..<20 { let h = 0.002; y += h * k * (y - y * y * y); x += h }
        }
        var chart = StandardChart(chartType: "function", xLabel: "x", yLabel: "y",
                                  series: [ChartSeries(name: "curve", points: points)], xRange: [-4, 4], yRange: [-0.5, 1.5])
        chart.xAxisLabels = []
        chart.yAxisLabels = [ChartTick(value: 1, text: "1")]
        let engine = MathEngine()
        let fitted = await CurveFitter.fit(chart, questionText: "$$\\frac{dy}{dx} = y - y^3$$", engine: engine)
        let result = try XCTUnwrap(fitted)
        XCTAssertNotNil(result.series[0].through)
        XCTAssertNil(result.series[0].points)
        XCTAssertTrue(result.odeSlope?.hasSuffix("\\left(y - y^3\\right)") ?? false, result.odeSlope ?? "nil")
        XCTAssertEqual(result.provenance, StandardChart.stated)
        // The scene draws the fitted solution over the drawn stretch, on the trace.
        let scene = await FigureScene.build(result, engine: engine)
        let drawn = try XCTUnwrap(scene.marks.first?.pieces.first)
        for p in points where abs(p[0]) < 3.5 {
            let nearest = drawn.min { abs($0[0] - p[0]) < abs($1[0] - p[0]) }!
            XCTAssertEqual(nearest[1], p[1], accuracy: 0.05, "at x = \(p[0])")
        }
    }

    func testCurveHiddenUnderAnotherIsContinued() {
        // Upper curve falls onto the x axis; the lower one rises onto it and is drawn over it from x = 1 on.
        let upper = stride(from: -8.0, through: 2.0, by: 0.1).map { [$0, 4 / (1 + exp(4 * $0))] }
        let lower = stride(from: -8.0, through: 8.0, by: 0.1).map { [$0, -4 / (1 + exp(4 * $0))] }
        let continued = FigureReconciler.continueHiddenEnds(
            [ChartSeries(name: "upper", points: upper), ChartSeries(name: "lower", points: lower)], x: -8...8, y: -5...5)
        XCTAssertEqual(continued[0].points?.last?[0] ?? 0, 8, accuracy: 0.11)
        XCTAssertEqual(continued[1].points?.count, lower.count)
        // A curve that simply ends in open space is left alone.
        let alone = FigureReconciler.continueHiddenEnds(
            [ChartSeries(name: "a", points: upper.map { [$0[0], $0[1] + 2] }), ChartSeries(name: "b", points: lower)], x: -8...8, y: -5...5)
        XCTAssertEqual(alone[0].points?.count, upper.count)
    }

    func testConfidentChartsAreAcceptedWithoutReview() {
        var chart = StandardChart(chartType: "function", confidence: 0.75)
        chart.verification = ChartVerification(passed: true, summary: "")
        var figure = Figure(documentId: nil, pageOrIndex: 0, originalPath: "x.png", kind: .chart, chart: chart, status: .reviewing)
        XCTAssertTrue(figure.acceptIfConfident())
        XCTAssertEqual(figure.status, .accepted)
        // Below the bar, a failed check, or the student's own decision: left alone.
        var low = figure; low.status = .reviewing; low.chart?.confidence = 0.74
        XCTAssertFalse(low.acceptIfConfident())
        var failed = figure; failed.status = .reviewing; failed.chart?.verification = ChartVerification(passed: false, summary: "")
        XCTAssertFalse(failed.acceptIfConfident())
        var kept = figure; kept.status = .keptOriginal
        XCTAssertFalse(kept.acceptIfConfident())
        XCTAssertEqual(kept.status, .keptOriginal)
    }

    func testCurveNoEquationFollowsStaysTraced() async {
        // A sine wave is no solution of an autonomous equation.
        let points = stride(from: -3.0, through: 3.0, by: 0.05).map { [$0, sin(2 * $0)] }
        var chart = StandardChart(chartType: "function", xLabel: "x", yLabel: "y",
                                  series: [ChartSeries(name: "wave", points: points)], xRange: [-3, 3], yRange: [-1.5, 1.5])
        chart.xAxisLabels = [ChartTick(value: 1, text: "1")]
        let fitted = await CurveFitter.fit(chart, questionText: "$$\\frac{dy}{dx} = y - y^3$$", engine: MathEngine())
        XCTAssertNil(fitted)
    }
}
