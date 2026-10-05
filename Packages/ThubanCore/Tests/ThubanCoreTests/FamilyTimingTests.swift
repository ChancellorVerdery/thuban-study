import XCTest
@testable import ThubanCore

/// Every standard family evaluates through the compiled path (fast enough to try them all on every picture).
final class FamilyTimingTests: XCTestCase {
    func testEveryFamilyIsFast() async throws {
        let engine = MathEngine()
        let points: [[Double]] = (0..<2000).map { (k: Int) -> [Double] in
            let x: Double = Double(k % 40) / 4 - 4.987
            let y: Double = Double(k / 40) / 5 - 4.983
            return [x, y]
        }
        for f in FamilyRecognizer.library {
            let start = Date()
            let rows = try await engine.values(of: [f], variables: ["x", "y"], at: points)
            let elapsed = Date().timeIntervalSince(start)
            let defined = rows.first??.compactMap { $0 }.count ?? -1
            print(String(format: "FAMILY %@ %.3fs defined %d", f, elapsed, defined))
            XCTAssertLessThan(elapsed, 0.2, f)
        }
    }
}
