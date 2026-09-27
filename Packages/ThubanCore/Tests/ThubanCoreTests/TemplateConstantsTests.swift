import XCTest
@testable import ThubanCore

/// Constants found in a template are pinned at the document's value; the problem's own givens keep their ranges.
final class TemplateConstantsTests: XCTestCase {
    private func gravityQuestion() -> Question {
        let template = MathTemplate(
            params: [
                TemplateParam(name: "m", kind: .int(min: 5, max: 60), original: 15),
                TemplateParam(name: "z", kind: .int(min: 20, max: 250), original: 100),
                TemplateParam(name: "g", kind: .real(min: 9.7, max: 9.9, decimals: 1), original: 9.81),
            ],
            stem: "An object of mass ${m}$ kg is at an elevation of ${z}$ m. The acceleration of gravity is ${g}$ m/s^2.",
            parts: [TemplatePart(id: "a", prompt: "Potential energy?", answerExpr: "m g z", answerKind: .numeric)]
        )
        return Question(classId: ClassID.new(), kind: .mathTemplate, stem: "", parts: [QuestionPart(id: "a", prompt: "p", answerKind: .numeric)], template: template)
    }

    func testPinningFixesConstantsAtTheirOriginalValue() {
        let pinned = gravityQuestion().template!.pinning(["g"])
        XCTAssertEqual(pinned.params[2].kind, .real(min: 9.81, max: 9.81, decimals: 2))
        XCTAssertEqual(pinned.params[0].kind, .int(min: 5, max: 60))
        XCTAssertEqual(pinned.varyingParams.map(\.name), ["m", "z"])
        let integral = MathTemplate(params: [TemplateParam(name: "c", kind: .int(min: 1, max: 5), original: 3)], stem: "", parts: []).pinning(["c"])
        XCTAssertEqual(integral.params[0].kind, .int(min: 3, max: 3))
    }

    func testPinnedTemplateAlwaysDrawsTheConstant() async throws {
        let template = gravityQuestion().template!.pinning(["g"])
        let engine = MathEngine()
        for seed in ["00000001", "0000abcd", "ffff0000"] {
            let instance = try await engine.instantiate(template, seed: seed)
            XCTAssertTrue(instance.stem.contains("9.81"), instance.stem)
        }
    }

    func testReadsMarkedConstantsAndIgnoresUnknownNames() {
        let question = gravityQuestion()
        let input: JSONValue = ["questions": .string(#"[{"number": 1, "constants": ["{g}", "zz"]}, {"number": 5, "constants": ["m"]}]"#)]
        XCTAssertEqual(TemplateConstants.constants(from: input, batch: [question]), [question.id: ["g"]])
    }
}
