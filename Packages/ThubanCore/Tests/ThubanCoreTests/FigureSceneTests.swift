import XCTest
@testable import ThubanCore

/// The native figure renderer's geometry: window, ticks, field arrows and every kind of curve.
final class FigureSceneTests: XCTestCase {
    static let engine = MathEngine()

    func testNiceStepsAndTicks() {
        XCTAssertEqual(FigureScene.niceStep(6), 1)
        XCTAssertEqual(FigureScene.niceStep(20), 2)
        XCTAssertEqual(FigureScene.niceStep(40), 5)
        XCTAssertEqual(FigureScene.niceStep(0.8), 0.1, accuracy: 1e-12)
        XCTAssertEqual(FigureScene.ticks(in: -3.25...3.25, step: 1), [-3, -2, -1, 0, 1, 2, 3])
        XCTAssertEqual(FigureScene.ticks(in: 0.1...0.35, step: 0.1), [0.1, 0.2, 0.3])
        XCTAssertTrue(FigureScene.ticks(in: 0...1, step: 0).isEmpty)
    }

    func testAFieldWithASolutionCurve() async throws {
        let chart = StandardChart(chartType: "slopeField", series: [ChartSeries(name: "y(0) = 1", through: [0, 1], style: "dashed")],
                                  xRange: [-3, 3], yRange: [-3, 3], confidence: 0.9, slope: "x-y", arrows: true,
                                  xStep: 1, yStep: 1, fieldColumns: 12, fieldRows: 10)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        XCTAssertEqual(scene.window, FigureScene.Window(x: -3...3, y: -3...3))
        XCTAssertEqual(scene.xStep, 1)
        XCTAssertEqual(scene.arrows.count, 120, "12 × 10 arrows, as measured from the original")
        XCTAssertTrue(scene.arrowheads)
        for arrow in scene.arrows { XCTAssertEqual(arrow.slope ?? .nan, arrow.x - arrow.y, accuracy: 1e-9) }
        XCTAssertEqual(scene.arrows.first?.x ?? 0, -3 + 0.25, accuracy: 1e-9, "arrows at cell centres")
        let mark = try XCTUnwrap(scene.marks.first)
        XCTAssertEqual(mark.kind, .line)
        XCTAssertEqual(mark.style, .dashed)
        let points = mark.pieces.flatMap { $0 }
        XCTAssertGreaterThan(points.count, 100)
        for p in points where abs(p[0]) < 2.5 { XCTAssertEqual(p[1], p[0] - 1 + 2 * exp(-p[0]), accuracy: 1e-3) }
    }

    func testExplicitFunctionsBreakAtAsymptotes() async throws {
        let chart = StandardChart(chartType: "function", series: [ChartSeries(name: "f", latex: "\\frac{1}{x}")], xRange: [-4, 4], yRange: [-4, 4], confidence: 1)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        let mark = try XCTUnwrap(scene.marks.first)
        XCTAssertGreaterThanOrEqual(mark.pieces.count, 2, "no line drawn across the asymptote")
        for piece in mark.pieces { for p in piece { XCTAssertEqual(p[1], 1 / p[0], accuracy: 1e-9) } }
        XCTAssertTrue(scene.arrows.isEmpty)
    }

    func testImplicitRelationsAreContoured() async throws {
        let chart = StandardChart(chartType: "function", series: [ChartSeries(name: "circle", latex: "x^2+y^2=4")], xRange: [-3, 3], yRange: [-3, 3], confidence: 1)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        let pieces = try XCTUnwrap(scene.marks.first).pieces
        XCTAssertEqual(pieces.count, 1, "the circle is one chained loop (a dashed style dashes along it, not per segment)")
        XCTAssertGreaterThan(pieces[0].count, 100)
        XCTAssertEqual(pieces[0].first?[0] ?? 0, pieces[0].last?[0] ?? 1, accuracy: 1e-9, "closed")
        for piece in pieces { for p in piece { XCTAssertEqual((p[0] * p[0] + p[1] * p[1]).squareRoot(), 2, accuracy: 0.05) } }
    }

    func testPointsDotsAndBars() async throws {
        let traced = StandardChart(chartType: "line", series: [ChartSeries(name: "t", points: [[0, 0], [1, 1], [2, 0]])], confidence: 0.5)
        let lineScene = await FigureScene.build(traced, engine: Self.engine)
        XCTAssertGreaterThan(lineScene.marks.first?.pieces.first?.count ?? 0, 3, "traced points are smoothed")
        XCTAssertEqual(lineScene.window.x.lowerBound, -1, accuracy: 1e-9, "window from the points, padded")

        let scatter = StandardChart(chartType: "scatter", series: [ChartSeries(name: "s", points: [[0, 1], [1, 2]])], confidence: 0.5)
        let scatterScene = await FigureScene.build(scatter, engine: Self.engine)
        XCTAssertEqual(scatterScene.marks.first?.kind, .dots)
        let bars = StandardChart(chartType: "bar", series: [ChartSeries(name: "b", points: [[0, 3], [1, 5]], color: "#FF0000")], confidence: 0.5)
        let barScene = await FigureScene.build(bars, engine: Self.engine)
        XCTAssertEqual(barScene.marks.first?.kind, .bars)
        XCTAssertEqual(barScene.marks.first?.color, "#FF0000")
    }

    func testSegmentsAnglesAndLabels() async throws {
        var side = ChartSeries(name: "AB", points: [[0, 0], [4, 0], [4, 3]])
        side.kind = "segment"
        side.label = "c"
        side.ticks = 2
        var corner = ChartSeries(name: "C", points: [[4, 0], [0, 0], [4, 3]])
        corner.kind = "angle"
        corner.rightAngle = true
        corner.labels = ["90°"]
        var u = ChartSeries(name: "u", points: [[0, 0], [1, 2]])
        u.kind = "vector"
        u.label = "u"
        var chart = StandardChart(chartType: "line", series: [side, corner, u], xRange: [-1, 5], yRange: [-1, 4], confidence: 1)
        chart.showAxes = false
        chart.yReversed = true
        chart.tintedPlot = true
        chart.annotations = [ChartAnnotation(text: "|u| = 2", x: 1, y: 1), ChartAnnotation(text: "", x: 0, y: 0)]
        let scene = await FigureScene.build(chart, engine: Self.engine)

        XCTAssertFalse(scene.showAxes)
        XCTAssertTrue(scene.yReversed)
        XCTAssertFalse(scene.xReversed)
        XCTAssertTrue(scene.tintedPlot)
        XCTAssertEqual(scene.annotations, [ChartAnnotation(text: "|u| = 2", x: 1, y: 1)], "blank annotations are dropped")

        let segment = try XCTUnwrap(scene.marks.first { $0.seriesIndex == 0 })
        XCTAssertEqual(segment.kind, .line, "a segment is a line, so the picture check measures it")
        XCTAssertTrue(segment.isSegment)
        XCTAssertEqual(segment.pieces, [[[0, 0], [4, 0], [4, 3]]], "drawn through the points as given, not smoothed")
        XCTAssertEqual(segment.label, "c")
        XCTAssertEqual(segment.ticks, 2)

        let angle = try XCTUnwrap(scene.marks.first { $0.seriesIndex == 1 })
        XCTAssertEqual(angle.kind, .angle)
        XCTAssertEqual(angle.pieces, [[[4, 0]], [[0, 0]], [[4, 3]]], "vertex, then a point on each ray")
        XCTAssertTrue(angle.rightAngle)
        XCTAssertEqual(angle.label, "90°")
        XCTAssertTrue(angle.inInk)

        let vector = try XCTUnwrap(scene.marks.first { $0.seriesIndex == 2 })
        XCTAssertEqual(vector.kind, .vector)
        XCTAssertEqual(vector.label, "u")
    }

    func testAShownChartKeepsItsAxesAndTheOrigin() async {
        let chart = StandardChart(chartType: "line", series: [ChartSeries(name: "t", points: [[1, 2], [3, 4]])], confidence: 1)
        let scene = await FigureScene.build(chart, engine: Self.engine)
        XCTAssertTrue(scene.showAxes)
        XCTAssertFalse(scene.yReversed || scene.xReversed || scene.tintedPlot)
        XCTAssertLessThan(scene.window.y.lowerBound, 0, "a chart's window keeps the x-axis in view")
        var diagram = chart
        diagram.showAxes = false
        let diagramScene = await FigureScene.build(diagram, engine: Self.engine)
        XCTAssertEqual(diagramScene.window.y.lowerBound, 1, accuracy: 1e-9, "a diagram's window fits its points only")
    }

    func testColoursByRole() async throws {
        var position = ChartSeries(name: "r")
        position.kind = "parametric"
        position.xt = "t"
        position.yt = "t^2"
        position.tRange = [-2, 2]
        position.markAt = 1
        position.positionVector = true
        position.tangentVector = true
        position.label = "C"
        var a = ChartSeries(name: "a", points: [[0, 0], [1, 1]])
        a.kind = "vector"
        var p = ChartSeries(name: "P", points: [[1, 1]])
        p.kind = "point"
        let line = ChartSeries(name: "line", latex: "2x-1")
        var chart = StandardChart(chartType: "function", series: [position, a, p, line], xRange: [-3, 3], yRange: [-1, 5], confidence: 1)
        let scene = await FigureScene.build(chart, engine: Self.engine)

        // Two curves take the first two colours; the three vectors the next three, never a curve's.
        let curves = scene.marks.filter { $0.kind == .line }
        XCTAssertEqual(curves.map(\.paletteIndex), [0, 1])
        XCTAssertEqual(curves.first?.label, "C", "the name goes on the curve, not on its vectors")
        let vectors = scene.marks.filter { $0.kind == .vector }
        XCTAssertEqual(vectors.map(\.paletteIndex), [2, 3, 4])
        XCTAssertTrue(vectors.allSatisfy { $0.label == nil })
        let dots = scene.marks.filter { $0.kind == .dots }
        XCTAssertEqual(dots.count, 2, "the marked point r(1) and the point series")
        XCTAssertTrue(dots.allSatisfy(\.inInk), "marked points are drawn in ink")
        let markedPoint = try XCTUnwrap(dots.first).pieces.flatMap { $0 }
        XCTAssertEqual(markedPoint.first?[0] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(markedPoint.first?[1] ?? 0, 1, accuracy: 1e-9)

        chart.monochrome = true
        let mono = await FigureScene.build(chart, engine: Self.engine)
        XCTAssertTrue(mono.marks.allSatisfy { $0.paletteIndex == 0 }, "a one-colour original is redrawn in one colour")
        XCTAssertTrue(mono.marks.filter { $0.kind == .dots }.allSatisfy(\.inInk))
    }
}
