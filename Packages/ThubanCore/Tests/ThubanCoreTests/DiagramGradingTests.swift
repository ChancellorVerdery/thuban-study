import XCTest
@testable import ThubanCore

/// p–V sketches: numeric axes by value, symbolic axes by proportion under the student's own scale.
final class DiagramGradingTests: XCTestCase {
    /// Homework 2 · p2.23: 1→2 constant V at 4 m³ from 1 to 2 bar, 2→3 pV = const to 2 m³, 3→4 constant p to 1 m³.
    let p223 = DiagramSpec(
        xAxis: DiagramAxis(label: "V", unit: "m^3", max: 5),
        yAxis: DiagramAxis(label: "p", unit: "bar", max: 5),
        states: [DiagramState(id: "1", x: 4, y: 1), DiagramState(id: "2", x: 4, y: 2),
                 DiagramState(id: "3", x: 2, y: 4), DiagramState(id: "4", x: 1, y: 4)],
        processes: [DiagramProcess(from: "1", to: "2", path: .constantX),
                    DiagramProcess(from: "2", to: "3", path: .polytropic, exponent: 1),
                    DiagramProcess(from: "3", to: "4", path: .constantY)]
    )

    /// Homework 4 · p3.24: from (V₁, p₁) — 1→2 isotherm to 2p₁, 1→3 constant V to 2p₁, 1→4 constant p to 2V₁,
    /// 1→5 isotherm to 2V₁; work shaded.
    let p324 = DiagramSpec(
        xAxis: DiagramAxis(label: "V", symbol: "V_1", max: 3),
        yAxis: DiagramAxis(label: "p", symbol: "p_1", max: 3),
        states: [DiagramState(id: "1", x: 1, y: 1), DiagramState(id: "2", x: 0.5, y: 2),
                 DiagramState(id: "3", x: 1, y: 2), DiagramState(id: "4", x: 2, y: 1),
                 DiagramState(id: "5", x: 2, y: 0.5)],
        processes: [DiagramProcess(from: "1", to: "2", path: .polytropic, exponent: 1),
                    DiagramProcess(from: "1", to: "3", path: .constantX),
                    DiagramProcess(from: "1", to: "4", path: .constantY),
                    DiagramProcess(from: "1", to: "5", path: .polytropic, exponent: 1)],
        shadeWork: true
    )

    private func json(_ answer: DiagramAnswer) -> String { answer.json }

    func testNumericDiagramCorrect() {
        let answer = DiagramAnswer(
            states: [DiagramState(id: "1", x: 4, y: 1), DiagramState(id: "2", x: 4, y: 2),
                     DiagramState(id: "3", x: 2, y: 4), DiagramState(id: "4", x: 1.05, y: 4)],
            processes: [.init(from: "1", to: "2", path: "line"), .init(from: "2", to: "3", path: "curve", n: 1),
                        .init(from: "3", to: "4", path: "line")]
        )
        XCTAssertEqual(DiagramGrader.grade(student: json(answer), expected: p223).outcome, .correct)
    }

    func testNumericDiagramFlagsPositionPathAndDirection() {
        let answer = DiagramAnswer(
            states: [DiagramState(id: "1", x: 4, y: 1), DiagramState(id: "2", x: 4, y: 2.5),
                     DiagramState(id: "3", x: 2, y: 4), DiagramState(id: "4", x: 1, y: 4)],
            processes: [.init(from: "2", to: "1", path: "line"), .init(from: "2", to: "3", path: "line"),
                        .init(from: "3", to: "4", path: "line")]
        )
        let verdict = DiagramGrader.grade(student: json(answer), expected: p223)
        XCTAssertEqual(verdict.outcome, .incorrect)
        XCTAssertTrue(verdict.message.contains("State 2"), verdict.message)
        XCTAssertTrue(verdict.message.contains("points the wrong way"), verdict.message)
        XCTAssertFalse(verdict.message.contains("2 bar"), "never reveals the value")
    }

    /// The student picks where p₁ and V₁ go; 2p₁ must then be twice as far from the axis.
    func testSymbolicAxesAcceptAnyScale() {
        for (sx, sy) in [(1.0, 1.0), (1.5, 2.0), (0.75, 1.25)] {
            let answer = DiagramAnswer(
                states: [DiagramState(id: "1", x: 1 * sx, y: 1 * sy), DiagramState(id: "2", x: 0.5 * sx, y: 2 * sy),
                         DiagramState(id: "3", x: 1 * sx, y: 2 * sy), DiagramState(id: "4", x: 2 * sx, y: 1 * sy),
                         DiagramState(id: "5", x: 2 * sx, y: 0.5 * sy)],
                processes: [.init(from: "1", to: "2", path: "curve", n: 1), .init(from: "1", to: "3", path: "line"),
                            .init(from: "1", to: "4", path: "line"), .init(from: "1", to: "5", path: "curve", n: 1)],
                shaded: ["1-2", "1-4", "1-5"]
            )
            let verdict = DiagramGrader.grade(student: json(answer), expected: p324)
            XCTAssertEqual(verdict.outcome, .correct, "scale \(sx), \(sy): \(verdict.message)")
        }
    }

    func testSymbolicAxisRejectsWrongMultiple() {
        // 2p₁ drawn at 3× the height of p₁.
        let answer = DiagramAnswer(
            states: [DiagramState(id: "1", x: 1, y: 1), DiagramState(id: "2", x: 0.5, y: 2),
                     DiagramState(id: "3", x: 1, y: 3), DiagramState(id: "4", x: 2, y: 1),
                     DiagramState(id: "5", x: 2, y: 0.5)],
            processes: [.init(from: "1", to: "2", path: "curve", n: 1), .init(from: "1", to: "3", path: "line"),
                        .init(from: "1", to: "4", path: "line"), .init(from: "1", to: "5", path: "curve", n: 1)],
            shaded: ["1-2", "1-4", "1-5"]
        )
        let verdict = DiagramGrader.grade(student: json(answer), expected: p324)
        XCTAssertEqual(verdict.outcome, .incorrect)
        XCTAssertTrue(verdict.message.contains("proportion on the p axis"), verdict.message)
    }

    func testShadingAndMissingProcess() {
        let answer = DiagramAnswer(
            states: [DiagramState(id: "1", x: 1, y: 1), DiagramState(id: "2", x: 0.5, y: 2),
                     DiagramState(id: "3", x: 1, y: 2), DiagramState(id: "4", x: 2, y: 1),
                     DiagramState(id: "5", x: 2, y: 0.5)],
            processes: [.init(from: "1", to: "2", path: "curve", n: 1), .init(from: "1", to: "3", path: "line"),
                        .init(from: "1", to: "4", path: "line")],
            shaded: ["1-2", "1-3", "1-4"]
        )
        let verdict = DiagramGrader.grade(student: json(answer), expected: p324)
        XCTAssertTrue(verdict.message.contains("1–5 is missing"), verdict.message)
        XCTAssertTrue(verdict.message.contains("shaded work areas"), verdict.message)
    }

    /// p1.25's 4→1: pV⁻¹ = const is a straight line through the origin, drawn either way.
    func testLineThroughOriginIsPolytropicMinusOne() {
        let spec = DiagramSpec(
            xAxis: DiagramAxis(label: "V", unit: "m^3", max: 2.5), yAxis: DiagramAxis(label: "p", unit: "bar", max: 2.5),
            states: [DiagramState(id: "4", x: 1, y: 2), DiagramState(id: "1", x: 0.5, y: 1)],
            processes: [DiagramProcess(from: "4", to: "1", path: .polytropic, exponent: -1)]
        )
        let line = DiagramAnswer(states: spec.states, processes: [.init(from: "4", to: "1", path: "line")])
        XCTAssertEqual(DiagramGrader.grade(student: line.json, expected: spec).outcome, .correct)
        let curve = DiagramAnswer(states: spec.states, processes: [.init(from: "4", to: "1", path: "curve", n: -1)])
        XCTAssertEqual(DiagramGrader.grade(student: curve.json, expected: spec).outcome, .correct)
        let isotherm = DiagramAnswer(states: spec.states, processes: [.init(from: "4", to: "1", path: "curve", n: 1)])
        XCTAssertEqual(DiagramGrader.grade(student: isotherm.json, expected: spec).outcome, .incorrect)
    }

    func testSpecsMustBeSelfConsistent() {
        XCTAssertTrue(p223.isUsable, p223.problems.joined(separator: "; "))
        XCTAssertTrue(p324.isUsable, p324.problems.joined(separator: "; "))
        var broken = p223
        broken.states[2].y = 3   // (2, 3) is not on pV = 8 with (4, 2)
        XCTAssertFalse(broken.isUsable)
        XCTAssertTrue(broken.problems.contains { $0.contains("2-3") }, broken.problems.joined(separator: "; "))
        var question = Question(classId: ClassID.new(), kind: .shortAnswer, stem: "",
                                parts: [QuestionPart(id: "a", prompt: "Sketch", answerKind: .diagram, answer: AnswerSpec(rubric: "r", diagram: broken))])
        question = question.withUsableDiagrams()
        XCTAssertEqual(question.parts[0].answerKind, .freeResponse)
        XCTAssertEqual(question.parts[0].answer.rubric, "r")
    }

    func testConverterReadsUsableDiagramsOnly() throws {
        let data = try JSONEncoder().encode(p223)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(DiagramConverter.diagram(from: ["convertible": true, "diagram": value], label: "t"), p223)
        XCTAssertNil(DiagramConverter.diagram(from: ["convertible": false], label: "t"))
        let text = String(data: data, encoding: .utf8)!
        XCTAssertEqual(DiagramConverter.diagram(from: ["convertible": true, "diagram": .string(text)], label: "t"), p223)
    }

    func testCandidatesAreSketchesOnCoordinates() {
        func part(_ prompt: String) -> QuestionPart { QuestionPart(id: "a", prompt: prompt, answerKind: .freeResponse, answer: AnswerSpec(rubric: "")) }
        XCTAssertTrue(DiagramConverter.isCandidate(part("Sketch the processes in series on $p$-$V$ coordinates.")))
        XCTAssertTrue(DiagramConverter.isCandidate(part("Sketch the cycle on a $p$–$V$ diagram.")))
        XCTAssertFalse(DiagramConverter.isCandidate(part("Is the rod in equilibrium? Explain.")))
    }

    func testEmptyAnswerAsksToPlaceStatesAndSetupHidesPositions() async {
        XCTAssertEqual(DiagramGrader.grade(student: "", expected: p223).outcome, .unparseable)
        let setup = String(data: try! JSONEncoder().encode(p324.setup), encoding: .utf8)!
        XCTAssertFalse(setup.contains("\"x\""), setup)
        XCTAssertEqual(p324.setup.stateIds, ["1", "2", "3", "4", "5"])
        let verdict = await MathEngine().grade(student: "", expected: AnswerSpec(diagram: p223), conditions: .none, kind: .diagram)
        XCTAssertEqual(verdict.outcome, .unparseable)
    }
}
