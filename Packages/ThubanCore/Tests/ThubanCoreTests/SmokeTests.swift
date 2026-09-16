import XCTest
@testable import ThubanCore

final class SmokeTests: XCTestCase {
    func testVersion() { XCTAssertEqual(ThubanCoreInfo.version, "0.1.0") }
    func testComputeEngineResourcePresent() {
        XCTAssertNotNil(Bundle.module.url(forResource: "compute-engine.umd", withExtension: "cjs"))
    }
}
