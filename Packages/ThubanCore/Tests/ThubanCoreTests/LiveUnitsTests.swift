import XCTest
@testable import ThubanCore

/// The units the question bank actually uses (3.1-2 Homework): counts, time and temperature.
final class LiveUnitsTests: XCTestCase {
    static let engine = MathEngine()

    func grade(_ student: String, _ expected: String, units: String, rounding: Int? = nil) async -> Verdict.Outcome {
        var conditions = AnswerConditions(units: units)
        conditions.roundingDecimals = rounding
        return await Self.engine.grade(student: student, expected: AnswerSpec(latex: expected), conditions: conditions, kind: .numeric).outcome
    }

    func testCountsTimesAndTemperatures() async {
        let cases: [(String, String, String, Int?)] = [
            ("23751", "23751", "persons", 0), ("23751\\text{ persons}", "23751", "persons", 0), ("23751persons", "23751", "persons", 0),
            ("7.67", "7.67", "persons/yr", 2), ("7.67\\text{ persons/yr}", "7.67", "persons/yr", 2),
            ("320", "320", "° F", nil), ("320^{\\circ}F", "320", "° F", nil), ("320°F", "320", "° F", nil), ("320\\text{ °F}", "320", "° F", nil),
            ("58.1", "58.1", "months", 1), ("58.1\\text{ months}", "58.1", "months", 1), ("58.1months", "58.1", "months", 1),
            ("99\\text{ bacteria}", "99", "bacteria", 0), ("84.9mg", "84.9", "mg", 1), ("84.9\\,\\mathrm{mg}", "84.9", "mg", 1),
            ("14300\\text{ years}", "14300", "years", nil), ("14300", "14300", "years", nil),
        ]
        for (student, expected, units, rounding) in cases {
            let outcome = await grade(student, expected, units: units, rounding: rounding)
            XCTAssertEqual(outcome, .correct, "\(student) [\(units)]")
        }
        let wrong = await grade("24000", "23751", units: "persons", rounding: 0)
        XCTAssertEqual(wrong, .incorrect)
    }
}
