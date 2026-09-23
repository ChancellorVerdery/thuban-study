import XCTest
@testable import ThubanCore

final class FigureChoiceTests: XCTestCase {
    private let agentJSON = """
    {"sourceRef":"Problem 8","kind":"mathTemplate","stem":"$$\\\\frac{dy}{dx} = y^2 - y^3$$","figureIndices":[3],
     "parts":[{"id":"a","prompt":"Choose the phase portrait.","answerKind":"choice","answer":{"text":"Graph 2"},
               "choices":["Graph 1","Graph 2"],"choiceFigures":[4,5]}],
     "template":{"params":[{"name":"a","kind":{"type":"int","min":1,"max":3}}],"stem":"x","parts":[{"id":"a","prompt":"p","answerExpr":"a"}]}}
    """

    func testAgentFigureNumbersDecodeAsIndices() throws {
        let draft = try JSONDecoder().decode(QuestionDraft.self, from: Data(agentJSON.utf8))
        XCTAssertEqual(draft.parts[0].choiceFigureIndices, [4, 5])
        XCTAssertNil(draft.parts[0].choiceFigures)
    }

    func testStoredFigureIdsRoundTrip() throws {
        let part = QuestionPart(id: "a", prompt: "Pick", answerKind: .choice, answer: AnswerSpec(text: "Graph 1"),
                                choices: ["Graph 1"], choiceFigures: [FigureID(raw: "f1")])
        let decoded = try JSONDecoder().decode(QuestionPart.self, from: JSONEncoder().encode(part))
        XCTAssertEqual(decoded.choiceFigures, [FigureID(raw: "f1")])
        XCTAssertTrue(decoded.hasFigureChoices)
    }

    func testQuestionWithFiguresNeverRegenerates() throws {
        let draft = try JSONDecoder().decode(QuestionDraft.self, from: Data(agentJSON.utf8))
        let question = draft.toQuestion(classId: ClassID(raw: "c"), documentId: nil)
        XCTAssertNil(question.template)
        XCTAssertEqual(question.kind, .multipleChoice)
        XCTAssertEqual(question.parts[0].choiceFigureIndices, [4, 5])
    }

    func testContinuationPartsJoinThePreviousQuestion() {
        let first = QuestionDraft(sourceRef: "Problem 6", kind: .multipleChoice, stem: "dy/dx = y - y^3",
                                  parts: ["a", "b", "c"].map { QuestionPart(id: $0, prompt: $0) }, figureIndices: [1, 2])
        let rest = QuestionDraft(sourceRef: "Problem 6", kind: .multipleChoice, stem: "",
                                 parts: [QuestionPart(id: "d", prompt: "y0 < -1"), QuestionPart(id: "a", prompt: "extra")],
                                 figureIndices: [2, 3], continuesPrevious: true)
        let merged = first.appending(rest)
        XCTAssertEqual(merged.parts.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(merged.figureIndices, [1, 2, 3])
        XCTAssertEqual(merged.stem, "dy/dx = y - y^3")
    }

    func testSplitOptionsAreJoined() {
        let first = QuestionDraft(sourceRef: "Q6", kind: .multipleChoice, stem: "s", parts: [
            QuestionPart(id: "c", prompt: "-1 < y0 < 0", answerKind: .choice, answer: AnswerSpec(text: "Graph 1"),
                         choices: ["Graph 1", "Graph 2", "Graph 3"], choiceFigureIndices: [64, 65, 66]),
        ])
        let rest = QuestionDraft(sourceRef: "Q6", kind: .multipleChoice, stem: "", parts: [
            QuestionPart(id: "c", prompt: "-1 < y0 < 0", answerKind: .choice, answer: AnswerSpec(text: "Graph 1"),
                         choices: ["Graph 1"], choiceFigureIndices: [67]),
            QuestionPart(id: "d", prompt: "y0 < -1", answerKind: .choice, answer: AnswerSpec(text: "Graph 2"),
                         choices: ["Graph 1", "Graph 2"], choiceFigureIndices: [68, 69]),
        ], continuesPrevious: true)
        let merged = first.appending(rest)
        XCTAssertEqual(merged.parts.map(\.id), ["c", "d"])
        XCTAssertEqual(merged.parts[0].choices, ["Graph 1", "Graph 2", "Graph 3", "Graph 4"])
        XCTAssertEqual(merged.parts[0].choiceFigureIndices, [64, 65, 66, 67])
        XCTAssertEqual(merged.parts[0].answer.text, "Graph 1")
    }

    func testTemplateMustReproduceTheOriginalAnswers() async {
        let engine = MathEngine()
        let template = MathTemplate(
            params: [TemplateParam(name: "m", kind: .int(min: 100, max: 500), original: 350),
                     TemplateParam(name: "g", kind: .real(min: 1, max: 10, decimals: 2), original: 3.73)],
            stem: "Mass {m} kg, gravity {g} m/s^2.",
            parts: [TemplatePart(id: "a", prompt: "Weight?", answerExpr: "m g", answerKind: .numeric)]
        )
        let right = [QuestionPart(id: "a", prompt: "Weight?", answerKind: .numeric, answer: AnswerSpec(latex: "1305.5"))]
        let wrong = [QuestionPart(id: "a", prompt: "Weight?", answerKind: .numeric, answer: AnswerSpec(latex: "3433.5"))]
        let checkedRight = await engine.checkOriginals(template, parts: right)
        XCTAssertEqual(checkedRight, [])
        let checkedWrong = await engine.checkOriginals(template, parts: wrong)
        XCTAssertEqual(checkedWrong.count, 1)
        var missing = template
        missing.params[0].original = nil
        let checkedMissing = await engine.checkOriginals(missing, parts: right)
        XCTAssertTrue(checkedMissing.first?.contains("original") ?? false)
    }

    func testPictureOptionsMustBeInTheExcerpt() throws {
        let draft = try JSONDecoder().decode(QuestionDraft.self, from: Data(agentJSON.utf8))
        let kept = ImportAgent.attachFigures(draft, chunk: ImportChunk(index: 0, text: "", pages: nil, figureIndices: [3, 4, 5]))
        XCTAssertEqual(kept.parts[0].choiceFigureIndices, [4, 5])
        XCTAssertEqual(kept.figureIndices, [3, 4, 5])
        let dropped = ImportAgent.attachFigures(draft, chunk: ImportChunk(index: 0, text: "", pages: nil, figureIndices: [3, 4]))
        XCTAssertNil(dropped.parts[0].choiceFigureIndices)
    }
}
