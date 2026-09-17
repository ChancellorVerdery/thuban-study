import XCTest
@testable import ThubanCore

/// Template instantiation and validation through the MathEngine actor.
final class MathEngineTemplateTests: XCTestCase {
    static let engine = MathEngine()

    private var quadratic: MathTemplate {
        MathTemplate(
            params: [
                TemplateParam(name: "a", kind: .int(min: -5, max: 5), exclude: [0]),
                TemplateParam(name: "b", kind: .int(min: -9, max: 9)),
                TemplateParam(name: "c", kind: .real(min: 0.5, max: 4, decimals: 1)),
                TemplateParam(name: "v", kind: .choice(["x", "t"])),
            ],
            constraints: ["a \\ne b", "b^2 - 4ac > 0"],
            stem: "Let $f({v}) = {a}{v}^2 + {b}{v} + {c}$.",
            parts: [
                TemplatePart(id: "a", prompt: "Find $f'({v})$.", answerExpr: "2a v + b"),
                TemplatePart(id: "b", prompt: "Evaluate $f(1)$.", answerExpr: "a + b + c", conditions: AnswerConditions(roundingDecimals: 1)),
            ]
        )
    }

    // MARK: - Determinism

    func testSameSeedGivesSameInstance() async throws {
        let first = try await Self.engine.instantiate(quadratic, seed: "0badf00d")
        let second = try await Self.engine.instantiate(quadratic, seed: "0badf00d")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.seed, "0badf00d")
    }

    func testDifferentSeedsGiveDifferentInstances() async throws {
        var stems: Set<String> = []
        for seed in ["00000001", "00000002", "deadbeef", "cafebabe", "12345678", "0badf00d"] {
            let instance = try await Self.engine.instantiate(quadratic, seed: seed)
            stems.insert(instance.stem)
        }
        XCTAssertGreaterThan(stems.count, 1)
    }

    func testNilSeedGeneratesAnEightHexCharacterSeed() async throws {
        let instance = try await Self.engine.instantiate(quadratic, seed: nil)
        XCTAssertEqual(instance.seed.count, 8)
        XCTAssertNotNil(UInt32(instance.seed, radix: 16))
        let replay = try await Self.engine.instantiate(quadratic, seed: instance.seed)
        XCTAssertEqual(replay, instance)
    }

    func testQuestionIdIsCarriedThrough() async throws {
        let id = QuestionID.new()
        let instance = try await Self.engine.instantiate(quadratic, seed: "00000007", questionId: id)
        XCTAssertEqual(instance.questionId, id)
    }

    // MARK: - Sampling, constraints and substitution

    func testConstraintsAndExclusionsAreSatisfied() async throws {
        for seed in ["00000001", "00000002", "00000003", "0000000a", "000000ff", "deadbeef"] {
            let instance = try await Self.engine.instantiate(quadratic, seed: seed)
            let a = try XCTUnwrap(Double(try XCTUnwrap(instance.params["a"])))
            let b = try XCTUnwrap(Double(try XCTUnwrap(instance.params["b"])))
            let c = try XCTUnwrap(Double(try XCTUnwrap(instance.params["c"])))
            XCTAssertNotEqual(a, 0, seed)
            XCTAssertNotEqual(a, b, seed)
            XCTAssertGreaterThan(b * b - 4 * a * c, 0, seed)
            XCTAssertTrue(["x", "t"].contains(instance.params["v"] ?? ""), seed)
            XCTAssertFalse(instance.stem.contains("{a}"), seed)
            XCTAssertFalse(instance.parts[0].prompt.contains("{v}"), seed)
        }
    }

    func testAnswersAreEvaluatedLatex() async throws {
        let instance = try await Self.engine.instantiate(quadratic, seed: "00000001")
        let a = try XCTUnwrap(Double(try XCTUnwrap(instance.params["a"])))
        let b = try XCTUnwrap(Double(try XCTUnwrap(instance.params["b"])))
        let v = try XCTUnwrap(instance.params["v"])
        let derivative = instance.parts[0].answerLatex
        XCTAssertTrue(derivative.contains(v), derivative)
        XCTAssertFalse(derivative.contains("a"), derivative)
        // The stored answer must grade as correct against an independently written form.
        let verdict = await Self.engine.grade(
            student: "\(TemplateFormatting.render(2 * a, decimals: 0))\(v) + \(TemplateFormatting.render(b, decimals: 0))",
            expected: AnswerSpec(latex: derivative),
            conditions: .none,
            kind: .math
        )
        XCTAssertEqual(verdict.outcome, .correct, "\(verdict.message) student vs \(derivative)")
    }

    func testRealParametersRespectDecimals() async throws {
        let template = MathTemplate(
            params: [TemplateParam(name: "r", kind: .real(min: 1, max: 2, decimals: 2))],
            stem: "r = {r}",
            parts: [TemplatePart(id: "a", prompt: "Double it.", answerExpr: "2r")]
        )
        for seed in ["00000001", "00000009", "00000042"] {
            let instance = try await Self.engine.instantiate(template, seed: seed)
            let rendered = try XCTUnwrap(instance.params["r"])
            let value = try XCTUnwrap(Double(rendered))
            XCTAssertTrue((1...2).contains(value))
            let fractional = rendered.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            XCTAssertLessThanOrEqual(fractional.count, 2, rendered)
        }
    }

    func testPlaceholdersInAnswerExprAreSubstituted() async throws {
        let template = MathTemplate(
            params: [TemplateParam(name: "n", kind: .int(min: 2, max: 2))],
            stem: "Compute $\\sqrt{{n}^2 + 9 \\cdot {n}}$",
            parts: [TemplatePart(id: "a", prompt: "Simplify.", answerExpr: "\\sqrt{{n}^2 + 9 \\cdot {n}}")]
        )
        let instance = try await Self.engine.instantiate(template, seed: "00000001")
        XCTAssertEqual(instance.parts[0].answerLatex, "\\sqrt{22}")
        XCTAssertEqual(instance.stem, "Compute $\\sqrt{2^2 + 9 \\cdot 2}$")
    }

    func testUnsatisfiableConstraintsThrowInvalidTemplate() async {
        let template = MathTemplate(
            params: [TemplateParam(name: "a", kind: .int(min: 1, max: 3))],
            constraints: ["a > 10"],
            stem: "{a}",
            parts: [TemplatePart(id: "a", prompt: "p", answerExpr: "a")]
        )
        do {
            _ = try await Self.engine.instantiate(template, seed: "00000001")
            XCTFail("expected invalidTemplate")
        } catch let error as ThubanError {
            guard case .invalidTemplate(let problems) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(problems.count, 1)
            XCTAssertTrue(problems[0].contains("200"), problems[0])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Validation

    func testValidTemplatePassesValidation() async {
        let errors = await Self.engine.validate(quadratic)
        XCTAssertEqual(errors, [])
    }

    func testValidateCatchesBadAnswerExpr() async {
        var template = quadratic
        template.parts[0].answerExpr = "\\frac{2a"
        let errors = await Self.engine.validate(template)
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.contains { $0.contains("Part 'a'") && $0.contains("answerExpr") }, "\(errors)")
    }

    func testValidateCatchesBadConstraintAndUnknownParameter() async {
        var template = quadratic
        template.constraints = ["\\frac{", "q > 1"]
        let errors = await Self.engine.validate(template)
        XCTAssertTrue(errors.contains { $0.contains("not valid LaTeX") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("unknown parameter") && $0.contains("q") }, "\(errors)")
    }

    func testValidateCatchesStructuralProblems() async {
        let template = MathTemplate(
            params: [
                TemplateParam(name: "a", kind: .int(min: 5, max: 1)),
                TemplateParam(name: "a", kind: .choice([])),
                TemplateParam(name: "e", kind: .int(min: 1, max: 2)),
                TemplateParam(name: "2b", kind: .int(min: 1, max: 2)),
                TemplateParam(name: "z", kind: .int(min: 1, max: 1), exclude: [1]),
            ],
            stem: "",
            parts: [
                TemplatePart(id: "a", prompt: "", answerExpr: ""),
                TemplatePart(id: "a", prompt: "", answerExpr: "a"),
            ]
        )
        let errors = await Self.engine.validate(template)
        XCTAssertTrue(errors.contains { $0.contains("min 5 is greater than max 1") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("declared twice") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("choice has no options") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("collides") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("not a valid identifier") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("excluded") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("used twice") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("answerExpr is empty") }, "\(errors)")
    }

    func testValidateHugeIntRangeDoesNotMaterialiseIt() async {
        // An agent-written "population between 1 and a billion" must validate without allocating the range.
        var template = quadratic
        template.params = [
            TemplateParam(name: "a", kind: .int(min: 1, max: 1_000_000_000), exclude: [5, 5.0, 2.5, 1e300, -3]),
            TemplateParam(name: "b", kind: .int(min: Int.min, max: Int.max)),
            TemplateParam(name: "c", kind: .int(min: 1, max: 1)),
        ]
        template.constraints = []
        let started = Date()
        let errors = await Self.engine.validate(template)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(errors.contains { $0.contains("excluded") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("'b'") && $0.contains("too wide") }, "\(errors)")
        XCTAssertFalse(errors.contains { $0.contains("'a'") && $0.contains("too wide") }, "\(errors)")
    }

    func testValidateCountsExclusionsArithmetically() async {
        var template = quadratic
        template.constraints = []
        // Duplicates and non-integers do not count; 1, 2 and 3 do.
        template.params = [TemplateParam(name: "a", kind: .int(min: 1, max: 3), exclude: [1, 1.0, 2, 3, 3.5, 0, 4]),
                           TemplateParam(name: "b", kind: .int(min: 1, max: 2)), TemplateParam(name: "c", kind: .int(min: 1, max: 2))]
        let all = await Self.engine.validate(template)
        XCTAssertTrue(all.contains { $0.contains("'a'") && $0.contains("excluded") }, "\(all)")
        template.params[0].exclude = [1, 1.0, 2, 3.5, 0, 4]
        let some = await Self.engine.validate(template)
        XCTAssertFalse(some.contains { $0.contains("excluded") }, "\(some)")
    }

    func testValidateCatchesUnsatisfiableConstraints() async {
        var template = quadratic
        template.constraints = ["a > 100"]
        let errors = await Self.engine.validate(template)
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertTrue(errors.first?.contains("No parameter draw satisfied") ?? false, "\(errors)")
    }

    func testValidateCatchesUnsubstitutableAnswerExpr() async {
        var template = quadratic
        template.parts[1].answerExpr = "\\frac{a}{0}"
        let errors = await Self.engine.validate(template)
        // Division by zero evaluates to a non-finite value; the template is still syntactically fine, so the
        // instantiation must not crash and validation must report nothing worse than a clean answer.
        XCTAssertTrue(errors.allSatisfy { !$0.contains("engine") }, "\(errors)")
    }

    // MARK: - Round trip: an instance's answer grades against itself

    func testInstanceAnswersGradeCorrectlyAgainstThemselves() async throws {
        let instance = try await Self.engine.instantiate(quadratic, seed: "c0ffee00")
        for part in instance.parts {
            let verdict = await Self.engine.grade(
                student: part.answerLatex,
                expected: AnswerSpec(latex: part.answerLatex),
                conditions: part.conditions,
                kind: part.answerKind
            )
            XCTAssertEqual(verdict.outcome, .correct, "\(part.id): \(part.answerLatex) → \(verdict.message)")
        }
    }
}
