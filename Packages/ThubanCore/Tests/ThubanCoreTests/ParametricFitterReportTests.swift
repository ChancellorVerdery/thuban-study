import XCTest
@testable import ThubanCore

/// Development harness: fits the t-range of stored parametric charts to their pictures (`PARAMETRIC_FIXTURES` = a
/// folder of `<n>.json` charts and `<n>.png` pictures, the calc-3 fixtures) and prints the range and verdict before
/// and after. Skipped unless the folder is set.
final class ParametricFitterReportTests: XCTestCase {
    func testFitRanges() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PARAMETRIC_FIXTURES"] else { throw XCTSkip("set PARAMETRIC_FIXTURES") }
        let engine = MathEngine()
        // 086 stops short of its left branch (to (48, 16) at t = −8); 087 starts a loop early (the picture starts at
        // t = −2; past t = 5 it leaves the plot, so any end from 5 on draws the same); the rest already fit and must
        // not get worse. The time printed is a debug build's: a release build fits each in well under a second.
        let expected: [String: (lower: ClosedRange<Double>, upper: ClosedRange<Double>)] = [
            "086": (-8.4 ... -7.8, 5.2...7), "087": (-2.15 ... -1.85, 4.85...6.05),
        ]
        for name in ["086", "087", "093", "094", "107"] {
            let base = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let chart = try JSONDecoder().decode(StandardChart.self, from: Data(contentsOf: base.appendingPathExtension("json")))
            let png = try Data(contentsOf: base.appendingPathExtension("png"))
            let read = await ShapeVerifier.Picture(png: png, hints: chart)
            let picture = try XCTUnwrap(read, name)
            let start = Date()
            let fitted = await ParametricFitter.fitRange(chart, picture: picture, engine: engine)
            let elapsed = Date().timeIntervalSince(start)
            func report(_ c: StandardChart) async -> (ranges: [[Double]], score: Double, verdict: String) {
                let scene = await FigureScene.build(c, engine: engine)
                let ranges = c.series.filter { FigureScene.shape(of: $0) != .curve }.map { $0.tRange ?? [] }
                return (ranges, ShapeVerifier.fitScore(scene, picture: picture), ShapeVerifier.verify(scene: scene, picture: picture).summary)
            }
            let before = await report(chart), after = await report(fitted ?? chart)
            print(String(format: "PARAMFIT %@ %.2fs", name, elapsed) + " tRange \(before.ranges) -> \(after.ranges)" +
                  String(format: " score %.3f -> %.3f", before.score, after.score))
            print("PARAMFIT \(name) before: \(before.verdict)")
            print("PARAMFIT \(name) after:  \(after.verdict)")
            XCTAssertGreaterThanOrEqual(after.score, before.score, name)
            if let bounds = expected[name] {
                let range = try XCTUnwrap(fitted?.series.first { $0.seriesKind == .parametric }?.tRange, name)
                XCTAssertTrue(bounds.lower.contains(range[0]) && bounds.upper.contains(range[1]), "\(name): \(range)")
            }
        }
    }
}
