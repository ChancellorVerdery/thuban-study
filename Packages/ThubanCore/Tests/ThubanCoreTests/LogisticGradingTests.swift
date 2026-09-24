import XCTest
@testable import ThubanCore

/// A logistic solution typed in its unsimplified form (3.1-2 Homework · Q8, P(0) = 2287) must grade as correct.
final class LogisticGradingTests: XCTestCase {
    static let engine = MathEngine()

    func testUnsimplifiedLogisticSolutionIsCorrect() async throws {
        let template = MathTemplate(
            params: [TemplateParam(name: "n", kind: .int(min: 2287, max: 2287))],
            stem: "P(0) = {n}",
            parts: [TemplatePart(id: "a", prompt: "P(t) =", answerExpr: "\\frac{1000000}{1 + \\left(\\frac{1000000}{n} - 1\\right)e^{-0.1t}}", answerKind: .math)]
        )
        let instance = try await Self.engine.instantiate(template, seed: "00000001")
        let expected = instance.parts[0].answerLatex
        print("EXPECTED", expected)
        let student = "\\frac{0.1e^{0.1t}\\left(\\frac{2287}{0.1-\\left(2287\\cdot10^{-7}\\right)}\\right)}{1+\\left(10^{-7}e^{0.1t}\\left(\\frac{2287}{0.1-2287\\cdot10^{-7}}\\right)\\right)}"
        let verdict = await Self.engine.grade(student: student, expected: AnswerSpec(latex: expected), conditions: AnswerConditions(implicitAllowed: true), kind: .math)
        print("VERDICT", verdict.outcome, verdict.message, verdict.canonicalStudent ?? "-", verdict.canonicalExpected ?? "-")
        XCTAssertEqual(verdict.outcome, .correct)
    }

    func testPlaceholderAsCommandArgumentKeepsItsBraces() {
        let values: [String: TemplateValue] = ["n": .int(2287), "a": .int(-3)]
        XCTAssertEqual(TemplateFormatting.substitute("\\frac{1000000}{n} - 1", values: values), "\\frac{1000000}{2287} - 1")
        XCTAssertEqual(TemplateFormatting.substitute("\\sqrt{n}", values: values), "\\sqrt{2287}")
        XCTAssertEqual(TemplateFormatting.substitute("2 \\cdot {a}", values: values), "2 \\cdot (-3)")
        XCTAssertEqual(TemplateFormatting.substitute("P(0) = {n}", values: values), "P(0) = 2287")
    }
}
