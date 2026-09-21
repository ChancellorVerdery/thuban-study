import XCTest
@testable import ThubanCore

/// Step three of the figure workflow: the stated definition has to reproduce the points read off the picture.
final class FigureVerifierTests: XCTestCase {
    static let engine = MathEngine()

    private func curve(_ latex: String, checks: [[Double]]?, provenance: String? = StandardChart.stated, yRange: [Double]? = [-2, 4]) -> StandardChart {
        StandardChart(chartType: "function", series: [ChartSeries(name: "f", latex: latex)], xRange: [-3, 3], yRange: yRange,
                      confidence: 0.9, provenance: provenance, checks: checks)
    }

    private func verify(_ chart: StandardChart) async -> ChartVerification? {
        await FigureVerifier.verify(chart, engine: Self.engine)
    }

    func testAStatedCurveThatMatchesTheReadPointsIsVerified() async throws {
        let matched = await verify(curve("x^2-1", checks: [[-2, 3], [0, -1], [1, 0.05], [2, 2.9]]))
        let verdict = try XCTUnwrap(matched)
        XCTAssertTrue(verdict.passed)
        XCTAssertTrue(verdict.summary.hasPrefix("Verified: 4 of 4 points"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("y = x^2-1"))

        // One misread point out of four does not sink a right equation.
        let oneOff = await verify(curve("x^2-1", checks: [[-2, 3], [0, -1], [1, 0], [2, 1]]))
        XCTAssertEqual(oneOff?.passed, true)
    }

    func testAStatedCurveThatMissesThePointsFailsWithTheFirstMismatch() async throws {
        // The picture is y = x² + 1 but the agent claimed y = x² − 1.
        let result = await verify(curve("x^2-1", checks: [[-2, 5], [0, 1], [2, 5]]))
        let verdict = try XCTUnwrap(result)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.summary.hasPrefix("Mismatch: 3 of 3 points disagree"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("at x = -2 y = x^2-1 gives 3 but the picture shows 5"), verdict.summary)
    }

    func testExplicitEquationsAndImplicitRelationsAreBothChecked() async throws {
        let explicit = await verify(curve("y=2x+1", checks: [[0, 1], [1, 3], [-1, -1]], yRange: [-3, 3]))
        XCTAssertEqual(explicit?.passed, true)

        let circle = await verify(curve("x^2+y^2=4", checks: [[0, 2], [2, 0], [1.41, 1.42], [-2, 0.05]], yRange: [-2, 2]))
        let verdict = try XCTUnwrap(circle)
        XCTAssertTrue(verdict.passed, verdict.summary)

        let wrongCircle = await verify(curve("x^2+y^2=1", checks: [[0, 2], [2, 0], [1.41, 1.42]], yRange: [-2, 2]))
        let wrong = try XCTUnwrap(wrongCircle)
        XCTAssertFalse(wrong.passed)
        XCTAssertTrue(wrong.summary.contains("(0, 2) is not on x^2+y^2=1"), wrong.summary)
    }

    func testNothingToCheckGivesNoVerdict() async {
        let noPoints = await verify(curve("x^2", checks: nil))
        XCTAssertNil(noPoints, "no points read")
        let onePoint = await verify(curve("x^2", checks: [[1, 1]]))
        XCTAssertNil(onePoint, "one point is not a check")
        let traced = await verify(curve("x^2", checks: [[1, 5], [2, 9]], provenance: StandardChart.traced))
        XCTAssertNil(traced, "a traced curve has no definition to test")
        let pointsOnly = StandardChart(chartType: "line", series: [ChartSeries(name: "f", points: [[0, 0], [1, 1]])], confidence: 0.5,
                                       provenance: StandardChart.stated, checks: [[0, 0], [1, 1]])
        let noEquation = await verify(pointsOnly)
        XCTAssertNil(noEquation, "no equation to test")
        let bad = await verify(curve("\\frac{", checks: [[0, 0], [1, 1]]))
        XCTAssertEqual(bad?.passed, false)
        XCTAssertTrue(bad?.summary.contains("could not be evaluated") ?? false)
    }

    func testAFieldIsCheckedByArrowDirectionAndBySolutionCurves() async throws {
        // dy/dx = x − y: arrows [x, y, m] and two points on the solution through (0, 1), y = x − 1 + 2e^{−x}.
        let field = StandardChart(
            chartType: "slopeField", series: [ChartSeries(name: "Solution", through: [0, 1])], xRange: [-3, 3], yRange: [-3, 3],
            confidence: 0.9, slope: "x-y", provenance: StandardChart.stated,
            checks: [[0, 0, 0], [1, 0, 1], [0, 1, -1], [2, 2, 0], [2, 1.27], [-1, 3.44]]
        )
        let good = await verify(field)
        let verdict = try XCTUnwrap(good)
        XCTAssertTrue(verdict.passed, verdict.summary)
        XCTAssertTrue(verdict.summary.hasPrefix("Verified: 6 of 6 points"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("dy/dx = x-y"))

        // The wrong equation for the same arrows.
        var wrong = field
        wrong.slope = "x+y"
        let wrongResult = await verify(wrong)
        let failed = try XCTUnwrap(wrongResult)
        XCTAssertFalse(failed.passed)
        XCTAssertTrue(failed.summary.contains("at (0, 1) dy/dx = x+y gives slope 1 but the arrow shows -1"), failed.summary)

        // A solution curve read at the wrong height fails even though the arrows fit.
        var wrongCurve = field
        wrongCurve.checks = [[0, 0, 0], [1, 0, 1], [2, 2.5], [-1, 2]]
        let offResult = await verify(wrongCurve)
        let off = try XCTUnwrap(offResult)
        XCTAssertFalse(off.passed)
        XCTAssertTrue(off.summary.contains("the solution curve gives"), off.summary)

        // A field with only [x, y] checks and no solution curve has nothing testable.
        var bare = field
        bare.series = []
        bare.checks = [[0, 1], [2, 1.27]]
        let bareResult = await verify(bare)
        XCTAssertNil(bareResult)
    }

    func testVerdictAllowsAThirdOfTheChecksToDisagree() {
        XCTAssertTrue(FigureVerifier.verdict(checks: 3, failures: ["a"], subject: "s").passed)
        XCTAssertFalse(FigureVerifier.verdict(checks: 3, failures: ["a", "b"], subject: "s").passed)
        XCTAssertFalse(FigureVerifier.verdict(checks: 2, failures: ["a"], subject: "s").passed)
        XCTAssertTrue(FigureVerifier.verdict(checks: 6, failures: ["a", "b"], subject: "s").passed)
        let failed = FigureVerifier.verdict(checks: 4, failures: ["one", "two", "three"], subject: "y = x")
        XCTAssertEqual(failed.summary, "Mismatch: 3 of 4 points disagree with y = x — one; two.")
    }

    func testCurveValueInterpolates() {
        let curve: [[Double]] = [[0, 0], [1, 2], [2, 2]]
        XCTAssertEqual(FigureVerifier.value(of: curve, at: 0.5), 1)
        XCTAssertEqual(FigureVerifier.value(of: curve, at: 2), 2)
        XCTAssertEqual(FigureVerifier.value(of: curve, at: 0), 0)
        XCTAssertNil(FigureVerifier.value(of: curve, at: 3))
        XCTAssertNil(FigureVerifier.value(of: [], at: 0))
    }
}
