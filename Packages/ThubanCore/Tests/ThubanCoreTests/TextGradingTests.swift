import XCTest
@testable import ThubanCore

/// Text answers match the forms the key offers, and lists match in any spacing and order.
final class TextGradingTests: XCTestCase {
    private func grade(_ student: String, _ key: String, loose: Bool = true) -> Verdict.Outcome {
        GradingRules.gradeText(student: student, expected: AnswerSpec(text: key), loose: loose).outcome
    }

    func testParentheticalAlternatives() {
        let key = "size (energy level / principal energy shell)"
        XCTAssertEqual(grade("size", key), .correct)
        XCTAssertEqual(grade("Energy level", key), .correct)
        XCTAssertEqual(grade("the principal energy shell", key), .correct)
        XCTAssertEqual(grade(key, key), .correct)
        XCTAssertEqual(grade("shape", key), .incorrect)
    }

    func testListsIgnoreSpacingAndOrder() {
        XCTAssertEqual(grade("0,1,2,3", "0, 1, 2, 3"), .correct)
        XCTAssertEqual(grade("3, 2, 1, 0", "0, 1, 2, 3"), .correct)
        XCTAssertEqual(grade("0, 1, 2 and 3", "0, 1, 2, 3"), .correct)
        XCTAssertEqual(grade("{0,1,2,3}", "0, 1, 2, 3"), .correct)
        XCTAssertEqual(grade("0,1,2", "0, 1, 2, 3"), .incorrect)
        XCTAssertEqual(grade("0,1,2,4", "0, 1, 2, 3"), .incorrect)
    }

    func testOrOutsideParenthesesIsOneAnswer() {
        XCTAssertEqual(grade("increases", "increases or decreases"), .incorrect)
        XCTAssertEqual(grade("spin (up or down)", "spin (up or down)"), .correct)
        XCTAssertEqual(grade("up", "spin (up or down)"), .correct)
    }

    func testChoicesStayStrict() {
        XCTAssertEqual(grade("size", "size (energy level)", loose: false), .incorrect)
        XCTAssertEqual(grade("Size (energy level).", "size (energy level)", loose: false), .correct)
    }
}
