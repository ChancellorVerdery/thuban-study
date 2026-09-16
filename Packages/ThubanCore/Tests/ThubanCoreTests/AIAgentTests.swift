import Foundation
import XCTest
@testable import ThubanCore

/// Agents: prompts, tutor tool loop, transcript conversion, import pipeline, figure analysis.
final class AIAgentTests: XCTestCase {

    private let classId = ClassID(raw: "class-1")
    private let documentId = DocumentID(raw: "doc-1")

    // MARK: Prompts

    func testTutorPromptStatesTheSolutionRule() {
        let prompt = Prompts.tutorSystem(className: "Calculus II", style: .directHints, questionContext: "Question: Find $\\int x\\,dx$.", mayEditGraph: false)
        XCTAssertTrue(prompt.contains("Calculus II"))
        XCTAssertTrue(prompt.contains(Prompts.solutionRequestMarker))
        XCTAssertTrue(prompt.contains("CURRENT message"))
        XCTAssertTrue(prompt.contains("NEVER"))
        XCTAssertTrue(prompt.contains("does not carry over"))
        XCTAssertTrue(prompt.contains(TutorStyle.directHints.promptHint))
        XCTAssertTrue(prompt.contains("turned off graph editing"))
        XCTAssertTrue(prompt.contains("Find $\\int x\\,dx$."))
        let editing = Prompts.tutorSystem(className: "C", style: .socratic, questionContext: "", mayEditGraph: true)
        XCTAssertTrue(editing.contains("say in your reply exactly what you did"))
    }

    func testTutorToolSpecsAndSummaries() {
        XCTAssertEqual(TutorTools.specs.map(\.name), [
            "show_graph", "hide_graph", "graph_add_expression", "graph_remove_expression",
            "graph_clear", "graph_set_viewport", "show_calculator", "get_student_work",
        ])
        XCTAssertEqual(TutorTools.specs(mayEditGraph: false).map(\.name), ["show_graph", "hide_graph", "show_calculator", "get_student_work"])
        XCTAssertEqual(TutorTools.summary(name: "graph_add_expression", input: ["id": "f", "latex": "y=2x+1", "dashed": true]), "Added $y=2x+1$ to the graph (dashed)")
        XCTAssertEqual(TutorTools.summary(name: "graph_set_viewport", input: ["xmin": -5, "xmax": 5, "ymin": -2.5, "ymax": 10]), "Zoomed the graph to x: -5 to 5, y: -2.5 to 10")
    }

    // MARK: Transcript conversion

    func testTranscriptConversionFlagsSolutionRequest() {
        let transcript = [
            TutorMessage(classId: classId, role: .tutor, content: "Hi! Where are you stuck?"),
            TutorMessage(classId: classId, role: .student, content: "Part a"),
            TutorMessage(classId: classId, role: .system, content: "Added y=x to the graph"),
            TutorMessage(classId: classId, role: .tutor, content: "What is the derivative rule for $x^n$?"),
            TutorMessage(classId: classId, role: .tutor, content: "Take your time."),
            TutorMessage(classId: classId, role: .student, content: "Just give it to me", solutionRequested: true),
            TutorMessage(classId: classId, role: .tutor, content: "Here is the full solution…"),
        ]
        let messages = TutorAgent.chatMessages(transcript: transcript, student: "Now part b?", solutionRequested: false)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user", "assistant", "user"], "leading assistant dropped, system skipped, consecutive merged")
        XCTAssertEqual(messages[0].content, [.text("Part a")])
        XCTAssertEqual(messages[1].content, [.text("What is the derivative rule for $x^n$?\n\nTake your time.")])
        XCTAssertEqual(messages[2].content, [.text(Prompts.solutionRequestMarker + "\nJust give it to me")])
        XCTAssertEqual(messages[4].content, [.text("Now part b?")])

        let flagged = TutorAgent.chatMessages(transcript: [], student: "Solve it", solutionRequested: true)
        XCTAssertEqual(flagged, [ChatMessage.user(Prompts.solutionRequestMarker + "\nSolve it")])
    }

    // MARK: Tutor tool loop

    func testTutorAgentRunsToolLoop() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(text: "Let me sketch that. ", id: "toolu_1", name: "graph_add_expression", input: ["id": "f", "latex": "y=x^2"])),
            .sse(SSE.text("I added $y=x^2$ to the graph. What happens at $x=0$?")),
        ])
        let agent = TutorAgent(client: .mock(transport))
        let handler = RecordingToolHandler(result: ["ok": true, "count": 1])
        let instance = QuestionInstance(
            questionId: QuestionID(raw: "q1"), seed: "0000abcd", stem: "Let $f(x)=x^2$.",
            parts: [InstancePart(id: "a", prompt: "Find $f'(0)$.", answerLatex: "0", answerKind: .numeric)]
        )
        let context = TutorContext(className: "Calc", instance: instance, inputs: ["a": "1"], verdicts: ["a": Verdict(outcome: .incorrect, message: "Not quite.")])

        var text = ""
        var toolEvents: [ToolEvent] = []
        var usage: Usage?
        for try await event in agent.respond(context: context, transcript: [], student: "Can you show me?", solutionRequested: false, tools: handler) {
            switch event {
            case .textDelta(let t): text += t
            case .toolEvent(let e): toolEvents.append(e)
            case .done(let u): usage = u
            }
        }

        XCTAssertEqual(text, "Let me sketch that. I added $y=x^2$ to the graph. What happens at $x=0$?")
        XCTAssertEqual(toolEvents.count, 1)
        XCTAssertEqual(toolEvents.first?.id, "toolu_1")
        XCTAssertEqual(toolEvents.first?.name, "graph_add_expression")
        XCTAssertEqual(toolEvents.first?.summary, "Added $y=x^2$ to the graph")
        XCTAssertEqual(handler.calls.count, 1)
        XCTAssertEqual(handler.calls.first?.input["latex"], "y=x^2")
        XCTAssertEqual(usage, Usage(inputTokens: 24, outputTokens: 40))

        XCTAssertEqual(transport.requests.count, 2)
        let first = try transport.body(0)
        XCTAssertEqual(first["tools"]?.arrayValue?.count, 8)
        XCTAssertTrue(first["system"]?.stringValue?.contains("Reference answer") ?? false)
        XCTAssertTrue(first["system"]?.stringValue?.contains("Last verdict: incorrect") ?? false)

        let second = try transport.body(1)
        let messages = try XCTUnwrap(second["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"]?[0]?["type"], "text")
        XCTAssertEqual(messages[1]["content"]?[1]?["type"], "tool_use")
        XCTAssertEqual(messages[1]["content"]?[1]?["id"], "toolu_1")
        XCTAssertEqual(messages[2]["content"]?[0]?["type"], "tool_result")
        XCTAssertEqual(messages[2]["content"]?[0]?["tool_use_id"], "toolu_1")
        XCTAssertEqual(messages[2]["content"]?[0]?["content"], .string((["ok": true, "count": 1] as JSONValue).jsonString()))
    }

    func testTutorAgentWithoutGraphEditingOffersFewerTools() async throws {
        let transport = MockTransport([.sse(SSE.text("Think about the power rule."))])
        let agent = TutorAgent(client: .mock(transport))
        let context = TutorContext(className: "Calc", mayEditGraph: false)
        var text = ""
        for try await event in agent.respond(context: context, transcript: [], student: "hint?", solutionRequested: false, tools: RecordingToolHandler()) {
            if case .textDelta(let t) = event { text += t }
        }
        XCTAssertEqual(text, "Think about the power rule.")
        XCTAssertEqual(try transport.body(0)["tools"]?.arrayValue?.count, 4)
    }

    // MARK: Import

    private func draftJSON(sourceRef: String, seedNote: String, withTemplate: Bool = true) -> JSONValue {
        var draft: JSONValue = [
            "sourceRef": .string(sourceRef),
            "kind": withTemplate ? "mathTemplate" : "numeric",
            "stem": "Let $f(x) = 3x^2 + 1$.",
            "parts": [[
                "id": "a", "prompt": "Find $f'(x)$.", "answerKind": "math",
                "answer": ["latex": "6x"], "conditions": ["simplified": true],
            ]],
            "tags": ["derivatives"],
            "difficulty": 2,
        ]
        if withTemplate {
            draft["template"] = [
                "params": [["name": "a", "kind": ["type": "int", "min": 2, "max": 9]]],
                "constraints": [],
                "stem": "Let $f(x) = {a}x^2 + 1$.",
                "parts": [["id": "a", "prompt": "Find $f'(x)$.", "answerExpr": "2ax"]],
                "seedNote": .string(seedNote),
            ]
        }
        return draft
    }

    private var sampleContent: DocumentContent {
        DocumentContent(
            blocks: [
                .heading("Homework 4", level: 1),
                .pageBreak(1),
                .paragraph("1. Let f(x) = 3x^2 + 1. Find f'(x)."),
                .image(index: 0),
                .paragraph("2. Evaluate the integral of 2x from 0 to 3."),
            ],
            figures: [ExtractedFigure(index: 0, page: 1, pngData: Data([1, 2, 3]), nearbyText: "Graph of f")],
            pageCount: 1
        )
    }

    private var sampleDocument: ImportedDocument {
        ImportedDocument(id: documentId, classId: classId, filename: "hw4.pdf", kind: .pdf, storedPath: "hw4.pdf")
    }

    func testImportAgentEscalatesToOpusAndRerunsChunk() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "existingQuestions", "reasoning": "Numbered problems."])),
            .sse(SSE.toolUse(id: "e1", name: "escalate_model", input: ["reason": "Dense multi-step derivations."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Homework 4 · Q1", seedNote: "ok")]])),
            .sse(SSE.text("Done.")),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in [] })
        let log = ProgressLog()

        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "Calculus I",
            policy: ModelPolicy(defaultModel: .sonnet, allowEscalation: true), progress: { log.record($0) }
        )

        XCTAssertEqual(result.classification, .existingQuestions)
        XCTAssertEqual(result.modelUsed, .opus)
        XCTAssertEqual(result.escalationReason, "Dense multi-step derivations.")
        XCTAssertEqual(result.questions.count, 1)
        XCTAssertEqual(result.questions.first?.kind, .mathTemplate)
        XCTAssertEqual(result.questions.first?.sourceRef, "Homework 4 · Q1")
        XCTAssertEqual(result.questions.first?.classId, classId)
        XCTAssertEqual(result.questions.first?.documentId, documentId)
        XCTAssertNotNil(result.questions.first?.template)
        XCTAssertEqual(result.figures.count, 1)
        XCTAssertEqual(result.usage.inputTokens, 12 * 4)

        XCTAssertEqual(log.all, [
            .classifying, .chunk(index: 0, count: 1), .generating(model: .sonnet),
            .escalated(reason: "Dense multi-step derivations."), .generating(model: .opus), .figures(count: 1), .done,
        ])

        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(try transport.body(0)["tool_choice"], ["type": "tool", "name": "classify_document"])
        XCTAssertEqual(try transport.body(1)["model"], "claude-sonnet-5")
        XCTAssertEqual(try transport.body(2)["model"], "claude-opus-5")
        XCTAssertEqual(try transport.body(3)["model"], "claude-opus-5")
        XCTAssertTrue(try transport.body(2)["system"]?.stringValue?.contains("existing questions") ?? false)
        XCTAssertTrue(try transport.body(2)["messages"]?[0]?["content"]?[0]?["text"]?.stringValue?.contains("[figure 0: Graph of f]") ?? false)
        // The rerun starts a fresh conversation for the chunk.
        XCTAssertEqual(try transport.body(2)["messages"]?.arrayValue?.count, 1)
        // The tool result for emit_questions is fed back before the model finishes.
        XCTAssertEqual(try transport.body(3)["messages"]?[2]?["content"]?[0]?["content"], "Recorded 1 question.")
    }

    func testImportAgentDoesNotEscalateWhenPolicyForbidsIt() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "reading_material", "reasoning": "Prose."])),
            .sse(SSE.toolUse(id: "e1", name: "escalate_model", input: ["reason": "Too hard."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "§1", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("Done.")),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in ["should not be called"] })
        let log = ProgressLog()
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "",
            policy: ModelPolicy(defaultModel: .sonnet, allowEscalation: false), progress: { log.record($0) }
        )
        XCTAssertEqual(result.classification, .readingMaterial)
        XCTAssertEqual(result.modelUsed, .sonnet)
        XCTAssertNil(result.escalationReason)
        XCTAssertEqual(result.questions.map(\.kind), [.numeric])
        XCTAssertFalse(log.all.contains { if case .escalated = $0 { return true } else { return false } })
        let reply = try transport.body(2)["messages"]?[2]?["content"]?[0]?["content"]?.stringValue ?? ""
        XCTAssertTrue(reply.contains("not available"))
    }

    func testImportAgentRepairsOneTemplateAndDowngradesTheOther() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "mixed", "reasoning": "Both."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [
                draftJSON(sourceRef: "Q1", seedNote: "broken"),
                draftJSON(sourceRef: "Q2", seedNote: "broken"),
            ]])),
            .sse(SSE.text("Done.")),
            .sse(SSE.toolUse(id: "r1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q1", seedNote: "fixed")]])),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { template in
            template.seedNote == "fixed" ? [] : ["answerExpr 'x' uses an unknown parameter"]
        })
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "Calc",
            policy: ModelPolicy(pinned: .sonnet), progress: { _ in }
        )

        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions[0].kind, .mathTemplate)
        XCTAssertEqual(result.questions[0].template?.seedNote, "fixed")
        XCTAssertEqual(result.questions[1].kind, .shortAnswer, "unrepaired template is stored as a static question")
        XCTAssertNil(result.questions[1].template)
        XCTAssertEqual(result.questions[1].parts.first?.answer.latex, "6x")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Q2"))

        XCTAssertEqual(transport.requests.count, 4)
        let repair = try transport.body(3)
        XCTAssertEqual(repair["tool_choice"], ["type": "tool", "name": "emit_questions"])
        let lastUser = try XCTUnwrap(repair["messages"]?.arrayValue?.last)
        XCTAssertEqual(lastUser["role"], "user")
        let repairText = lastUser["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
        XCTAssertTrue(repairText.contains("unknown parameter"))
        XCTAssertTrue(repairText.contains("2 questions"))
    }

    func testImportChunkerSplitsByBudgetAndTracksPagesAndFigures() {
        var blocks: [ContentBlock] = []
        for page in 1...4 {
            blocks.append(.pageBreak(page))
            blocks.append(.paragraph(String(repeating: "word ", count: 400)))
            if page == 2 { blocks.append(.image(index: 7)) }
        }
        let content = DocumentContent(blocks: blocks, figures: [ExtractedFigure(index: 7, page: 2, pngData: Data([0]), nearbyText: "")])
        let chunks = ImportChunker.chunks(content, tokenBudget: 1200)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.index), [0, 1])
        XCTAssertEqual(chunks[0].pages, 1...2)
        XCTAssertEqual(chunks[0].figureIndices, [7])
        XCTAssertEqual(chunks[1].pages, 3...4)
        XCTAssertEqual(chunks[1].figureIndices, [])
        XCTAssertTrue(chunks[0].text.contains("[figure 7]"))
        XCTAssertEqual(ImportChunker.chunks(DocumentContent(blocks: []), tokenBudget: 1000), [])
    }

    func testQuestionDraftConversionAndDowngrade() throws {
        let decoded = try JSONDecoder().decode(QuestionDraft.self, from: try draftJSON(sourceRef: "Q9", seedNote: "n").data())
        let question = decoded.toQuestion(classId: classId, documentId: nil)
        XCTAssertEqual(question.kind, .mathTemplate)
        XCTAssertEqual(question.template?.params.first?.name, "a")
        XCTAssertEqual(question.parts.first?.conditions.simplified, true)
        XCTAssertEqual(question.difficulty, 2)
        XCTAssertNil(question.documentId)

        let downgraded = decoded.downgradedToStatic()
        XCTAssertNil(downgraded.template)
        XCTAssertEqual(downgraded.kind, .shortAnswer)
        let orphan = QuestionDraft(kind: .mathTemplate, stem: "s", parts: [QuestionPart(id: "a", prompt: "p", answerKind: .choice, choices: ["x", "y"])])
        XCTAssertEqual(orphan.toQuestion(classId: classId, documentId: nil).kind, .multipleChoice)

        let minimal = try JSONDecoder().decode(QuestionDraft.self, from: Data(#"{"stem":"Define a limit.","parts":[{"id":"a","prompt":"Define it."}]}"#.utf8))
        XCTAssertEqual(minimal.kind, .shortAnswer)
        XCTAssertEqual(minimal.difficulty, 3)
        XCTAssertTrue(minimal.isUsable)
        XCTAssertFalse(QuestionDraft(kind: .numeric, stem: "", parts: []).isUsable)
    }

    // MARK: Figure

    func testFigureAgentDecodesChart() async throws {
        let transport = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figure", input: [
            "kind": "chart",
            "caption": "Velocity against time.",
            "chart": [
                "chartType": "line", "xLabel": "t (s)", "yLabel": "v (m/s)",
                "series": [["name": "v", "points": [[0, 0], [1, 2], [2, 4]]]],
                "xRange": [0, 2], "yRange": [0, 4], "confidence": 0.8,
            ],
        ]))])
        let agent = FigureAgent(client: .mock(transport))
        let analysis = try await agent.analyze(png: Data([0x89, 0x50, 0x4E, 0x47]), nearbyText: "Figure 2: velocity")
        XCTAssertEqual(analysis.kind, .chart)
        XCTAssertEqual(analysis.caption, "Velocity against time.")
        XCTAssertEqual(analysis.chart?.chartType, "line")
        XCTAssertEqual(analysis.chart?.series.first?.points, [[0, 0], [1, 2], [2, 4]])
        XCTAssertEqual(analysis.chart?.confidence, 0.8)

        let body = try transport.body(0)
        XCTAssertEqual(body["tool_choice"], ["type": "tool", "name": "describe_figure"])
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["source"]?["data"], .string(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()))
        XCTAssertTrue(body["messages"]?[0]?["content"]?[1]?["text"]?.stringValue?.contains("Figure 2: velocity") ?? false)

        XCTAssertEqual(FigureAgent.analysis(from: ["kind": "photo", "caption": "", "chart": ["chartType": "bar"]]), FigureAnalysis(kind: .photo))
        await XCTAssertThrowsErrorAsync(try await agent.analyze(png: Data(), nearbyText: ""))
    }
}
