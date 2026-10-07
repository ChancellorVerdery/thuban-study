import XCTest
@testable import ThubanCore

/// Development harness: prints what the reviewer is told about a picture's curves (`MEASURED_PNG`, with the chart
/// `MEASURED_CHART` as hints when given). Skipped unless set.
final class MeasuredCurvesReportTests: XCTestCase {
    func testMeasure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MEASURED_PNG"] else { throw XCTSkip("set MEASURED_PNG") }
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        var hints: StandardChart?
        if let chartPath = env["MEASURED_CHART"] {
            hints = try? JSONDecoder().decode(StandardChart.self, from: Data(contentsOf: URL(fileURLWithPath: chartPath)))
        }
        print("MEASURED\n" + (await FigureWorkflow.measuredCurves(png: png, hints: hints) ?? "nil"))
    }
}
