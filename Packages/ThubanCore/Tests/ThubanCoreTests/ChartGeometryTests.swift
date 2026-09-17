import XCTest
@testable import ThubanCore

final class ChartGeometryTests: XCTestCase {
    func testSmoothedPassesThroughPointsSortsByXAndDensifies() {
        let raw: [[Double]] = [[2, 4], [0, 0], [1, 1], [3, 9]]
        let out = ChartGeometry.smoothed(raw, samplesPerSegment: 4)
        XCTAssertEqual(out.first, [0, 0])
        XCTAssertEqual(out.last, [3, 9])
        XCTAssertEqual(out.count, 1 + 3 * 4, "one sample per segment step")
        XCTAssertTrue(out.contains([1, 1]) && out.contains([2, 4]), "the spline goes through the given points")
        XCTAssertEqual(ChartGeometry.smoothed([[1, 2]]).count, 1)
        XCTAssertEqual(ChartGeometry.smoothed([[0, 0], [1, 1]]).count, 2, "two points stay a straight segment")
        XCTAssertTrue(ChartGeometry.smoothed([[0, 0], [.nan, 1], [1, 1]]).allSatisfy { $0[0].isFinite && $0[1].isFinite })
    }

    func testRowsUseDesmosListsAndParametricDomains() throws {
        let polyline = try XCTUnwrap(ChartGeometry.polylineRow(id: "c", points: [[0, 0], [1, 2], [2, 1]]))
        XCTAssertEqual(polyline.parametricDomain, 0...1)
        XCTAssertTrue(polyline.latex.hasPrefix("\\left(\\left[0,1\\right]+t\\left(\\left[1,2\\right]-\\left[0,1\\right]\\right),"), polyline.latex)
        XCTAssertNil(ChartGeometry.polylineRow(id: "c", points: [[0, 0]]))

        let dots = try XCTUnwrap(ChartGeometry.pointsRow(id: "p", points: [[1.5, -2]]))
        XCTAssertTrue(dots.showsPoints)
        XCTAssertEqual(dots.latex, "\\left[\\left(1.5,-2\\right)\\right]")

        XCTAssertEqual(ChartGeometry.functionRow(id: "f", latex: " x^2 ")?.latex, "y=x^2")
        XCTAssertEqual(ChartGeometry.functionRow(id: "f", latex: "x^2+y^2=1")?.latex, "x^2+y^2=1")
        XCTAssertNil(ChartGeometry.functionRow(id: "f", latex: "  "))

        let bars = try XCTUnwrap(ChartGeometry.barsRow(id: "b", points: [[0, 3], [1, 5]]))
        XCTAssertEqual(bars.fillOpacity, 0.55)
        XCTAssertTrue(bars.latex.hasPrefix("\\operatorname{polygon}"))
        XCTAssertTrue(bars.latex.contains("\\left[0,1\\right]-0.4"))
    }

    func testSlopeFieldRowsDefineHelpersSegmentsAndHeads() {
        let rows = ChartGeometry.slopeFieldRows(idPrefix: "f", slope: "x-y", xRange: -3...3, yRange: -3...3, columns: 4, rows: 3)
        XCTAssertEqual(rows.map(\.id), ["f-fn", "f-h", "f-x", "f-y", "f-m", "f-d", "f-seg", "f-head"])
        XCTAssertEqual(rows[0].latex, "S_{f}\\left(x,y\\right)=x-y")
        XCTAssertTrue(rows[0].hidden && rows[1].hidden && rows[2].hidden && rows[3].hidden && rows[4].hidden && rows[5].hidden)
        XCTAssertEqual(rows[2].latex, "X_{f}=\\left[-3,-1,1,3,-3,-1,1,3,-3,-1,1,3\\right]", "x varies fastest")
        XCTAssertEqual(rows[3].latex, "Y_{f}=\\left[-3,-3,-3,-3,0,0,0,0,3,3,3,3\\right]")
        XCTAssertEqual(rows[1].latex, "H_{f}=0.8", "40 % of the 2-unit grid spacing")
        XCTAssertEqual(rows[6].parametricDomain, 0...1)
        XCTAssertEqual(rows[6].lineWidth, 1.6)
        XCTAssertFalse(rows[6].hidden)
        XCTAssertTrue(rows[7].latex.hasPrefix("\\operatorname{polygon}"))
        XCTAssertEqual(rows[7].fillOpacity, 1)

        let ticks = ChartGeometry.slopeFieldRows(idPrefix: "f", slope: "x-y", xRange: -3...3, yRange: -3...3, columns: 4, rows: 3, arrows: false)
        XCTAssertEqual(ticks.last?.id, "f-seg", "no arrowheads for a plain slope field")
        XCTAssertTrue(ChartGeometry.slopeFieldRows(idPrefix: "f", slope: "  ", xRange: -1...1, yRange: -1...1).isEmpty)
    }

    func testNumberFormatting() {
        XCTAssertEqual(ChartGeometry.number(2), "2")
        XCTAssertEqual(ChartGeometry.number(-0.5), "-0.5")
        XCTAssertEqual(ChartGeometry.number(1.0 / 3.0), "0.33333")
        XCTAssertEqual(ChartGeometry.number(0.000012), "0.00001")
        XCTAssertEqual(ChartGeometry.number(.nan), "0")
    }

    func testStandardChartDecodesSlopeFieldFields() throws {
        let json = #"{"chartType":"slopeField","series":[],"confidence":0.6,"slope":"x-y"}"#
        let chart = try JSONDecoder().decode(StandardChart.self, from: Data(json.utf8))
        XCTAssertTrue(chart.isSlopeField)
        XCTAssertEqual(chart.slope, "x-y")
        XCTAssertTrue(chart.arrows, "arrows default on")
        let legacy = try JSONDecoder().decode(StandardChart.self, from: Data(#"{"chartType":"line","series":[],"confidence":1}"#.utf8))
        XCTAssertFalse(legacy.isSlopeField)
        XCTAssertNil(legacy.slope)
    }
}
