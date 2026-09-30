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

    func testImportPromptUsesQuestionsPerChunkHint() {
        let reading = Prompts.importSystem(classContext: "Physics 1", classification: .readingMaterial, questionsPerChunk: 12)
        XCTAssertTrue(reading.contains("about 12 practice questions per excerpt (9 to 15)"), reading)
        let mixed = Prompts.importSystem(classContext: "", classification: .mixed, questionsPerChunk: 4)
        XCTAssertTrue(mixed.contains("at least 3 questions"), mixed)
        let fallback = Prompts.importSystem(classContext: "", classification: .readingMaterial)
        XCTAssertTrue(fallback.contains("about \(Prompts.defaultQuestionsPerChunk) practice questions"), fallback)
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
        XCTAssertEqual(messages[2].content, [.text(Prompts.solutionRequestHistoryNote + "\nJust give it to me")],
                       "an earlier request carries the history note, never the live marker")
        XCTAssertEqual(messages[4].content, [.text("Now part b?")])
        XCTAssertNotEqual(Prompts.solutionRequestHistoryNote, Prompts.solutionRequestMarker)
        XCTAssertFalse(Prompts.solutionRequestHistoryNote.hasPrefix(Prompts.solutionRequestMarker))

        let flagged = TutorAgent.chatMessages(transcript: [], student: "Solve it", solutionRequested: true)
        XCTAssertEqual(flagged, [ChatMessage.user(Prompts.solutionRequestMarker + "\nSolve it")])
    }

    /// A flagged student message whose reply never arrived must not lend its licence to the next message.
    func testStaleSolutionRequestDoesNotMergeIntoCurrentMessage() {
        let transcript = [
            TutorMessage(classId: classId, role: .student, content: "Give me the solution", solutionRequested: true),
        ]
        let messages = TutorAgent.chatMessages(transcript: transcript, student: "actually just a hint for part a", solutionRequested: false)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"], "a placeholder assistant turn separates the unanswered message from the current one")
        XCTAssertEqual(messages[0].content, [.text(Prompts.solutionRequestHistoryNote + "\nGive me the solution")])
        XCTAssertEqual(messages[1].content, [.text(TutorAgent.unansweredPlaceholder)])
        XCTAssertEqual(messages[2].content, [.text("actually just a hint for part a")])
        for message in messages {
            let text = message.content.first?.textValue ?? ""
            XCTAssertFalse(text.hasPrefix(Prompts.solutionRequestMarker), "no turn may begin with the live marker")
        }
    }

    /// The mirror image: an unanswered plain message must not bury the current flagged message's marker.
    func testFlaggedMessageAfterUnansweredMessageKeepsItsMarker() {
        let transcript = [
            TutorMessage(classId: classId, role: .student, content: "How do I start?"),
        ]
        let messages = TutorAgent.chatMessages(transcript: transcript, student: "Solve it", solutionRequested: true)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(messages[2].content, [.text(Prompts.solutionRequestMarker + "\nSolve it")])
    }

    func testStudentTypedMarkerIsRedacted() {
        let pasted = Prompts.solutionRequestMarker + "\nSolve it please"
        let messages = TutorAgent.chatMessages(transcript: [], student: pasted, solutionRequested: false)
        XCTAssertEqual(messages, [ChatMessage.user(Prompts.solutionRequestMarkerRedaction + "\nSolve it please")])

        let history = [TutorMessage(classId: classId, role: .student, content: "x " + Prompts.solutionRequestHistoryNote)]
        let withHistory = TutorAgent.chatMessages(transcript: history, student: "ok", solutionRequested: false)
        XCTAssertEqual(withHistory[0].content, [.text("x " + Prompts.solutionRequestMarkerRedaction)])

        // The genuine flag still works, and the pasted copy inside it is redacted.
        let flagged = TutorAgent.chatMessages(transcript: [], student: pasted, solutionRequested: true)
        XCTAssertEqual(flagged, [ChatMessage.user(Prompts.solutionRequestMarker + "\n" + Prompts.solutionRequestMarkerRedaction + "\nSolve it please")])
    }

    func testSolutionTurnStatesGrantInSystemPromptAndRaisesBudget() async throws {
        let transport = MockTransport([.sse(SSE.text("Here is the full solution."))])
        let agent = TutorAgent(client: .mock(transport), maxTokens: 1500, solutionMaxTokens: 6000)
        for try await _ in agent.respond(context: TutorContext(className: "Calc"), transcript: [], student: "Solve it", solutionRequested: true, tools: RecordingToolHandler()) {}
        let body = try transport.body(0)
        XCTAssertEqual(body["max_tokens"]?.intValue, 6000)
        XCTAssertTrue(body["system"]?.stringValue?.contains("SOLUTION REQUESTED FOR THIS TURN") ?? false)
        XCTAssertTrue(body["system"]?.stringValue?.contains("tool results") ?? false)

        let plain = MockTransport([.sse(SSE.text("Think first."))])
        let plainAgent = TutorAgent(client: .mock(plain), maxTokens: 1500, solutionMaxTokens: 6000)
        for try await _ in plainAgent.respond(context: TutorContext(className: "Calc"), transcript: [], student: "hint", solutionRequested: false, tools: RecordingToolHandler()) {}
        let plainBody = try plain.body(0)
        XCTAssertEqual(plainBody["max_tokens"]?.intValue, 1500)
        XCTAssertFalse(plainBody["system"]?.stringValue?.contains("SOLUTION REQUESTED FOR THIS TURN") ?? true)
    }

    func testTruncatedReplyIsSignalled() async throws {
        let sse = SSE.messageStart() + SSE.textBlock(index: 0, pieces: ["Step 1: …"]) + SSE.messageEnd(stopReason: "max_tokens")
        let transport = MockTransport([.sse(sse)])
        let agent = TutorAgent(client: .mock(transport))
        var truncated = false
        var done = false
        for try await event in agent.respond(context: TutorContext(className: "Calc"), transcript: [], student: "Solve it", solutionRequested: true, tools: RecordingToolHandler()) {
            if case .truncated = event { truncated = true }
            if case .done = event { done = true }
        }
        XCTAssertTrue(truncated)
        XCTAssertTrue(done)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRejectedToolCallYieldsFailureEvent() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "toolu_1", name: "graph_remove_expression", input: ["id": "foo"])),
            .sse(SSE.text("Never mind.")),
        ])
        let agent = TutorAgent(client: .mock(transport))
        let handler = RecordingToolHandler(result: ["error": "No expression with id 'foo'."])
        var events: [ToolEvent] = []
        for try await event in agent.respond(context: TutorContext(className: "Calc"), transcript: [], student: "?", solutionRequested: false, tools: handler) {
            if case .toolEvent(let e) = event { events.append(e) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isError)
        XCTAssertEqual(events[0].summary, "Could not remove foo from the graph: No expression with id 'foo'.")
        let second = try transport.body(1)
        XCTAssertEqual(second["messages"]?[2]?["content"]?[0]?["is_error"], true)
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
            case .truncated: XCTFail("reply should not be truncated")
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

    /// Terms, definitions and equations the material states come back as flashcards; questions stay questions.
    func testImportAgentRoutesStatedTermsToFlashcards() async throws {
        let cards: JSONValue = [
            ["front": "First law for a closed system", "back": "$\\Delta E = Q - W$"],
            ["front": "Quality", "back": "$x = \\frac{m_g}{m}$"],
        ]
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "mixed", "reasoning": "Notes and exercises."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: [
                "questions": [draftJSON(sourceRef: "Exercise 1", seedNote: "ok", withTemplate: false)],
                "cards": cards,
            ])),
            // A later call with only cards (one repeats a term): accepted, and the repeat is merged.
            .sse(SSE.toolUse(id: "q2", name: "emit_questions", input: [
                "cards": [["front": "first law for a closed system", "back": "dup"], ["front": "Ideal gas law", "back": "$pV = mRT$"]],
            ])),
            .sse(SSE.text("Done.")),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in [] }, checksCompleteness: false)
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "Thermodynamics",
            policy: ModelPolicy(defaultModel: .sonnet, allowEscalation: false), progress: { _ in }
        )
        XCTAssertEqual(result.questions.map(\.sourceRef), ["Exercise 1"])
        XCTAssertEqual(result.cards.map(\.front), ["First law for a closed system", "Quality", "Ideal gas law"])
        XCTAssertEqual(result.cards[0].back, "$\\Delta E = Q - W$")
        XCTAssertEqual(try transport.body(2)["messages"]?[2]?["content"]?[0]?["content"], "Recorded 1 question and 2 cards.")
        XCTAssertTrue(try transport.body(1)["system"]?.stringValue?.contains("go to the student's flashcards") ?? false)
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

    func testImportAgentMatchesRepairedQuestionsByKeyNotPosition() async throws {
        // The model re-emits only the question it could fix (the second one): it must land on Q2, not on Q1.
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "mixed", "reasoning": "Both."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [
                draftJSON(sourceRef: "Q1", seedNote: "broken"),
                draftJSON(sourceRef: "Q2", seedNote: "broken"),
            ]])),
            .sse(SSE.text("Done.")),
            .sse(SSE.toolUse(id: "r1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q2", seedNote: "fixed")]])),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { template in
            template.seedNote == "fixed" ? [] : ["answerExpr uses an unknown parameter"]
        })
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "Calc",
            policy: ModelPolicy(pinned: .sonnet), progress: { _ in }
        )
        XCTAssertEqual(result.questions.map(\.sourceRef), ["Q1", "Q2"])
        XCTAssertEqual(result.questions[0].kind, .shortAnswer, "Q1 was not re-emitted, so it is stored static")
        XCTAssertNil(result.questions[0].template)
        XCTAssertEqual(result.questions[1].kind, .mathTemplate)
        XCTAssertEqual(result.questions[1].template?.seedNote, "fixed")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Q1"))

        // Positional matching only when there is one re-emitted draft per failing question and no key matches.
        let a = QuestionDraft(sourceRef: "A", kind: .mathTemplate, stem: "Stem A", parts: [])
        XCTAssertEqual(a.type, "", "a draft without a type is unclassified")
        let b = QuestionDraft(sourceRef: "B", kind: .mathTemplate, stem: "Stem B", parts: [])
        let renamed = QuestionDraft(sourceRef: nil, kind: .mathTemplate, stem: "Stem  b", parts: [])
        XCTAssertEqual(ImportAgent.matchRepair(for: b, in: [a, renamed], position: 1), 1, "stem match ignores case and spacing")
        XCTAssertEqual(ImportAgent.matchRepair(for: b, in: [renamed, a], position: nil), 0)
        XCTAssertNil(ImportAgent.matchRepair(for: b, in: [a], position: nil))
        let unlabelled = QuestionDraft(kind: .numeric, stem: "Other", parts: [])
        XCTAssertEqual(ImportAgent.matchRepair(for: b, in: [a, unlabelled], position: 1), 1, "positional fallback when counts match")
        XCTAssertNil(ImportAgent.matchRepair(for: b, in: [a, nil], position: 1), "a claimed slot is not reused")
        let conflicting = QuestionDraft(sourceRef: "Z", kind: .numeric, stem: "Stem B", parts: [])
        XCTAssertNil(ImportAgent.matchRepair(for: b, in: [a, conflicting], position: 1), "a contradicting sourceRef blocks stem and positional matches")
    }

    func testImportAgentKeepsEarlierChunksWhenALaterChunkFails() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "readingMaterial", "reasoning": "Prose."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "§1", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("Done.")),
            .json(#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#, status: 400),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in [] }, chunkTokenBudget: 500)
        let log = ProgressLog()
        let result = try await agent.run(
            document: sampleDocument, content: twoChunkContent, classContext: "",
            policy: ModelPolicy(pinned: .sonnet), progress: { log.record($0) }
        )
        XCTAssertEqual(result.questions.map(\.sourceRef), ["§1"], "chunk 1's questions survive chunk 2's failure")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Part 2 of 2"), result.warnings[0])
        XCTAssertTrue(result.warnings[0].contains("prompt is too long"), result.warnings[0])
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertTrue(log.all.contains(.chunk(index: 1, count: 2)))
        XCTAssertEqual(log.all.last, .done)

        // Every chunk failing is still a failure of the document …
        let failing = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "mixed", "reasoning": "?"])),
            .json(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#, status: 400),
        ])
        let failingAgent = ImportAgent(client: .mock(failing), validator: { _ in [] })
        do {
            _ = try await failingAgent.run(document: sampleDocument, content: sampleContent, classContext: "", policy: ModelPolicy(pinned: .sonnet), progress: { _ in })
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ThubanError, .api(status: 400, message: "bad"))
        }

        // … and a credential problem ends the run at once, whatever the chunk.
        let unauthorized = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "mixed", "reasoning": "?"])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "§1", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("Done.")),
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401),
        ])
        let authAgent = ImportAgent(client: .mock(unauthorized), validator: { _ in [] }, chunkTokenBudget: 500)
        do {
            _ = try await authAgent.run(document: sampleDocument, content: twoChunkContent, classContext: "", policy: ModelPolicy(pinned: .sonnet), progress: { _ in })
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ThubanError, .api(status: 401, message: "invalid x-api-key"))
        }
    }

    func testImportAgentAsksOnceForQuestionsItLeftOut() async throws {
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "existingQuestions", "reasoning": "Numbered."])),
            .sse(SSE.toolUse(id: "q1", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q1", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("That is all for now.")),
            .sse(SSE.toolUse(id: "q2", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q2", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("DONE")),
            // The key check (the excerpt has a figure) re-emits Q1 corrected: it replaces the earlier Q1.
            .sse(SSE.toolUse(id: "q3", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q1", seedNote: "fixed", withTemplate: false)]])),
            .sse(SSE.text("CHECKED")),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in [] }, checksCompleteness: true)
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "",
            policy: ModelPolicy(pinned: .sonnet), progress: { _ in }
        )
        XCTAssertEqual(result.questions.map(\.sourceRef), ["Q1", "Q2"])
        let check = try transport.body(3)
        let messages = try XCTUnwrap(check["messages"]?.arrayValue)
        let note = messages.last?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
        XCTAssertTrue(note.contains("Recorded so far: Q1"), note)
    }

    func testImportAgentAsksForSmallerBatchesWhenEmitIsCutOff() async throws {
        let cutOff = SSE.messageStart()
            + SSE.toolUseBlock(index: 0, id: "q1", name: "emit_questions", partials: [#"{"questions":[{"sourceRef":"Q1","stem":"Let $f"#])
            + SSE.messageEnd(stopReason: "max_tokens")
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "c1", name: "classify_document", input: ["classification": "existingQuestions", "reasoning": "Numbered."])),
            .sse(cutOff),
            .sse(SSE.toolUse(id: "q2", name: "emit_questions", input: ["questions": [draftJSON(sourceRef: "Q1", seedNote: "ok", withTemplate: false)]])),
            .sse(SSE.text("Done.")),
        ])
        let agent = ImportAgent(client: .mock(transport), validator: { _ in [] })
        let result = try await agent.run(
            document: sampleDocument, content: sampleContent, classContext: "",
            policy: ModelPolicy(pinned: .sonnet), progress: { _ in }
        )
        XCTAssertEqual(result.questions.map(\.sourceRef), ["Q1"])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(transport.requests.count, 4)
        let retry = try transport.body(2)
        XCTAssertEqual(retry["max_tokens"]?.intValue, 32_768)
        let messages = try XCTUnwrap(retry["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 3, "excerpt, the cut-off turn, the follow-up")
        let note = messages[2]["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
        XCTAssertTrue(note.contains("cut off"), note)
        XCTAssertTrue(note.contains("at most 4 questions"), note)
    }

    private var twoChunkContent: DocumentContent {
        DocumentContent(
            blocks: [
                .paragraph(String(repeating: "Limits describe the value a function approaches. ", count: 30)),
                .paragraph(String(repeating: "Derivatives measure instantaneous rates of change. ", count: 30)),
            ],
            figures: [],
            pageCount: 2
        )
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

    func testQuestionDraftCarriesAgentTypeAndChunkPromptListsKnownTypes() throws {
        let typed = try JSONDecoder().decode(QuestionDraft.self, from: Data(
            #"{"kind":"shortAnswer","type":" Initial  value problems ","stem":"Solve $y'=y$, $y(0)=2$.","parts":[{"id":"a","prompt":"Find $y$."}]}"#.utf8))
        XCTAssertEqual(typed.type, "Initial value problems")
        XCTAssertEqual(typed.toQuestion(classId: classId, documentId: nil).type, "Initial value problems")

        let minimal = try JSONDecoder().decode(QuestionDraft.self, from: Data(#"{"stem":"s","parts":[{"id":"a","prompt":"p"}]}"#.utf8))
        XCTAssertEqual(minimal.type, "")
        XCTAssertEqual(minimal.toQuestion(classId: classId, documentId: nil).typeLabel, "Unclassified")

        // Types are named by QuestionCategorizer, not the import agent.
        XCTAssertEqual(ImportTools.questionSchema["required"]?.arrayValue?.compactMap(\.stringValue).contains("type"), false)
        XCTAssertNil(ImportTools.questionSchema["properties"]?.objectValue?["type"])

        let chunk = ImportChunk(index: 0, text: "Body", pages: nil, figureIndices: [])
        let primed = ImportAgent.chunkPrompt(chunk, knownTypes: ["Separation of variables", "Initial value problems"])
        XCTAssertFalse(primed.contains("already in this class"))
        XCTAssertTrue(primed.hasSuffix("Excerpt 1:\n\nBody"))
    }

    func testCategorizerMergesFollowChainsAndIgnoreUnknownTypes() {
        let input: JSONValue = ["merges": [
            ["from": "Domain and range of functions", "into": "Domain of functions"],
            ["from": "Domain of functions", "into": "Domains"],
            ["from": "Not a type here", "into": "Dot product"],
            ["from": "Dot product", "into": "Dot product"],
            ["from": "- polar to cartesian coordinates (2)", "into": "Cartesian equation of polar curve (6)"],
        ]]
        let merges = QuestionCategorizer.merges(from: input, types: ["Domain and range of functions", "Domain of functions", "Dot product",
                                                                     "Polar to Cartesian coordinates", "Cartesian equation of polar curve"])
        XCTAssertEqual(merges, ["Domain and range of functions": "Domains", "Domain of functions": "Domains",
                                "Polar to Cartesian coordinates": "Cartesian equation of polar curve"])
    }

    func testCategorizerReadsMergesWrappedInAString() {
        let wrapped: JSONValue = ["merges": .string(#"{"merges": [{"from": "Unit conversion", "into": "Unit conversions"}]}"#)]
        XCTAssertEqual(QuestionCategorizer.merges(from: wrapped, types: ["Unit conversion", "Unit conversions"]), ["Unit conversion": "Unit conversions"])
        let bare: JSONValue = ["merges": .string(#"[{"from": "Unit conversion", "into": "Unit conversions"}]"#)]
        XCTAssertEqual(QuestionCategorizer.merges(from: bare, types: ["Unit conversion", "Unit conversions"]), ["Unit conversion": "Unit conversions"])
    }

    func testCategorizerReusesExistingTypeNames() {
        let classId = ClassID.new()
        let questions = (0..<3).map { Question(classId: classId, kind: .shortAnswer, stem: "q\($0)", parts: [QuestionPart(id: "a", prompt: "p", answerKind: .text)]) }
        let input: JSONValue = ["assignments": [
            ["number": 1, "type": "initial value problems"],
            ["number": 2, "type": "Related  rates"],
            ["number": 3, "type": "Related rates"],
            ["number": 9, "type": "Out of range"],
        ]]
        let types = QuestionCategorizer.assignments(from: input, batch: questions, known: ["Initial value problems"])
        XCTAssertEqual(types[questions[0].id], "Initial value problems")
        XCTAssertEqual(types[questions[1].id], "Related rates")
        XCTAssertEqual(types[questions[2].id], "Related rates")
        XCTAssertEqual(types.count, 3)
    }

    // MARK: Figure

    func testFigureAnalysisKeepsAFieldWithoutSolutionCurves() throws {
        let field: JSONValue = try JSONValue(jsonString: #"{"isFigure":true,"kind":"chart","caption":"Field","chart":{"chartType":"slopeField","slope":"x^2-y^2","series":[],"confidence":0.8}}"#)
        XCTAssertEqual(FigureAgent.analysis(from: field).chart?.slope, "x^2-y^2", "a field with no curve on it is still a chart")
        let emptyField: JSONValue = try JSONValue(jsonString: #"{"isFigure":true,"kind":"chart","caption":"?","chart":{"chartType":"slopeField","series":[],"confidence":0.2}}"#)
        XCTAssertNil(FigureAgent.analysis(from: emptyField).chart, "a field without an equation has nothing to draw")
        let emptyLine: JSONValue = try JSONValue(jsonString: #"{"isFigure":true,"kind":"chart","caption":"?","chart":{"chartType":"line","series":[],"confidence":0.2}}"#)
        XCTAssertNil(FigureAgent.analysis(from: emptyLine).chart)
    }

    func testFigureAgentDecodesChart() async throws {
        let transport = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figures", input: ["figures": [[
            "image": 1,
            "kind": "chart",
            "caption": "Velocity against time.",
            "chart": [
                "chartType": "line", "xLabel": "t (s)", "yLabel": "v (m/s)",
                "series": [["name": "v", "points": [[0, 0], [1, 2], [2, 4]]]],
                "xRange": [0, 2], "yRange": [0, 4], "confidence": 0.8,
            ],
        ]]]))])
        let agent = FigureAgent(client: .mock(transport))
        let analysis = try await agent.analyze(png: Data([0x89, 0x50, 0x4E, 0x47]), nearbyText: "Figure 2: velocity")
        XCTAssertEqual(analysis.kind, .chart)
        XCTAssertEqual(analysis.caption, "Velocity against time.")
        XCTAssertEqual(analysis.chart?.chartType, "line")
        XCTAssertEqual(analysis.chart?.series.first?.points, [[0, 0], [1, 2], [2, 4]])
        XCTAssertEqual(analysis.chart?.confidence, 0.8)
        XCTAssertEqual(analysis.chart?.provenance, StandardChart.traced, "points and no equation: traced by default")

        let body = try transport.body(0)
        XCTAssertEqual(body["tool_choice"], ["type": "tool", "name": "describe_figures"])
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["source"]?["data"], .string(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()))
        XCTAssertTrue(body["messages"]?[0]?["content"]?[1]?["text"]?.stringValue?.contains("Figure 2: velocity") ?? false)
        XCTAssertFalse(body["messages"]?[0]?["content"]?[1]?["text"]?.stringValue?.contains("Attached are") ?? true, "one image needs no numbering note")

        XCTAssertEqual(FigureAgent.analysis(from: ["kind": "photo", "caption": "", "chart": ["chartType": "bar"]]), FigureAnalysis(kind: .photo))
        XCTAssertEqual(FigureAgent.analysis(from: ["kind": "chart", "caption": "", "chart": ["chartType": "function", "series": [["name": "f", "latex": "x^2"]], "confidence": 1]]).chart?.provenance, StandardChart.stated)
        await XCTAssertThrowsErrorAsync(try await agent.analyze(png: Data(), nearbyText: ""))

        // The richer context puts the citing questions first, then the surrounding text, then any earlier caption.
        let context = FigureAgent.FigureContext(
            nearbyText: "Before [figure here] after", questionTexts: ["Solve $y' = x - y$, $y(0) = 1$.", ""], previousCaption: "A field."
        )
        let rendered = context.rendered
        XCTAssertTrue(rendered.hasPrefix("The question(s) the figure belongs to"))
        XCTAssertTrue(rendered.contains("Question 1:\nSolve $y' = x - y$"))
        XCTAssertFalse(rendered.contains("Question 2:"), "blank question texts are dropped")
        XCTAssertTrue(rendered.contains("Text around the figure"))
        XCTAssertTrue(rendered.hasSuffix("An earlier description of this image: A field."))
        XCTAssertEqual(FigureAgent.FigureContext().rendered, "There is no surrounding text.")
        let uncited = FigureAgent.FigureContext(otherQuestionTexts: ["Consider $y' = x^2 - y^2$.", " "], positionNote: "This is image 2 of 8 the question refers to, in document order.")
        XCTAssertTrue(uncited.rendered.hasPrefix("This is image 2 of 8"))
        XCTAssertTrue(uncited.rendered.contains("Other problems in the same document"))
        XCTAssertTrue(uncited.rendered.contains("• Consider $y' = x^2 - y^2$."))
    }

    func testFigureAgentDescribesAQuestionsFiguresTogether() async throws {
        // Three images under one question: the field, a sketch, and an equation render that is not a figure.
        // The agent answers out of order and leaves nothing out.
        let transport = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figures", input: ["figures": [
            ["image": 3, "isFigure": false, "kind": "unknown", "caption": "A rendered equation."],
            ["image": 1, "isFigure": true, "kind": "chart", "caption": "The direction field of dy/dx = x − y.",
             "chart": ["chartType": "slopeField", "slope": "x-y", "series": [], "confidence": 0.9, "provenance": "stated",
                       "definition": "stem: dy/dx = x - y", "checks": [[0, 0, 0], [1, 0, 1]]]],
            ["image": 2, "isFigure": true, "kind": "chart", "caption": "The solution with y(0) = 2, part (c).",
             "chart": ["chartType": "slopeField", "slope": "x-y", "series": [["name": "y(0) = 2", "through": [0, 2]]], "confidence": 0.8,
                       "provenance": "stated", "definition": "part (c): y(0) = 2"]],
        ]]))])
        let agent = FigureAgent(client: .mock(transport))
        let pngs = [Data([1]), Data([2]), Data([3])]
        let context = FigureAgent.FigureContext(nearbyText: "Around image 1:\nfield", questionTexts: ["Consider $dy/dx = x - y$. (c) $y(0) = 2$"])
        let results = try await agent.analyze(pngs: pngs, context: context)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[3]?.isFigure, false)
        XCTAssertEqual(results[1]?.chart?.slope, "x-y")
        XCTAssertEqual(results[1]?.chart?.definition, "stem: dy/dx = x - y")
        XCTAssertEqual(results[1]?.chart?.checks, [[0, 0, 0], [1, 0, 1]])
        XCTAssertEqual(results[2]?.chart?.series.first?.through, [0, 2])
        XCTAssertNil(results[2]?.chart?.verification, "analyze alone does not verify")

        // Every image goes in the one message, numbered, with the text after them.
        let content = try XCTUnwrap(transport.body(0)["messages"]?[0]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 7)
        XCTAssertEqual(content[0]["text"], "Image 1:")
        XCTAssertEqual(content[1]["source"]?["data"], .string(Data([1]).base64EncodedString()))
        XCTAssertEqual(content[4]["text"], "Image 3:")
        let text = try XCTUnwrap(content[6]["text"]?.stringValue)
        XCTAssertTrue(text.hasPrefix("Attached are 3 images: every figure under this question"))
        XCTAssertTrue(text.contains("Describe every image, one entry each"))
        XCTAssertTrue(text.contains("look here first for the function or slope field"))

        // Focus and verification feedback are spelled out.
        var retry = context
        retry.imageCount = 3
        retry.focus = [2]
        retry.verificationFeedback = "Image 2: Mismatch: 2 of 3 points disagree with dy/dx = x-y."
        XCTAssertTrue(retry.rendered.contains("Describe only image 2; the others are attached"))
        XCTAssertTrue(retry.rendered.contains("it did not match:\nImage 2: Mismatch"))
        XCTAssertTrue(retry.rendered.hasSuffix("give the curve as 12–40 `points` instead of an equation."))

        // Lenient decoding: out-of-range or duplicate image numbers are ignored, a missing number means "in order".
        let decoded = FigureAgent.analyses(from: ["figures": [
            ["image": 9, "kind": "photo", "caption": "x"], ["kind": "table", "caption": "y"], ["image": 2, "kind": "photo", "caption": "z"],
        ]], imageCount: 2)
        XCTAssertEqual(decoded.keys.sorted(), [2])
        XCTAssertEqual(decoded[2]?.kind, .table, "the unnumbered entry took slot 2 in order; the later explicit 2 is a duplicate")
        XCTAssertEqual(FigureAgent.analyses(from: ["figures": [["kind": "table", "caption": "y"]]], imageCount: 1)[1]?.kind, .table)
        await XCTAssertThrowsErrorAsync(try await agent.analyze(pngs: Array(repeating: Data([1]), count: 9), context: context))
    }

    func testDescribeInSequenceSendsOneImageAtATimeWithTheEarlierOnesSummarised() async throws {
        // Three sketches of the same field: each call carries one image, and each later call is told what the
        // earlier images turned out to be so no two sketches take the same part.
        func sketch(_ part: String, through: [Double], checks: [[Double]]) -> JSONValue {
            let start = JSONValue.array(through.map { .number($0) })
            let read = JSONValue.array(checks.map { .array($0.map { .number($0) }) })
            let definition = JSONValue.string("part \(part): y(\(Int(through[0]))) = \(Int(through[1]))")
            return ["figures": [["image": 1, "isFigure": true, "kind": "chart", "caption": .string("Solution for part \(part)."),
                "chart": ["chartType": "slopeField", "slope": "x-y", "series": [["name": .string(part), "through": start]], "xRange": [-3, 3], "yRange": [-3, 3],
                          "confidence": 0.9, "provenance": "stated", "definition": definition, "checks": read]]]]
        }
        // y = x − 1 + 2e^{−x} through (0, 1); y = x − 1 + e^{−x} through (0, 0).
        let transport = MockTransport([
            .sse(SSE.toolUse(id: "f1", name: "describe_figures", input: sketch("(a)", through: [0, 1], checks: [[0, 1], [2, 1.27], [-1, 3.44]]))),
            .sse(SSE.toolUse(id: "f2", name: "describe_figures", input: ["figures": [["image": 1, "isFigure": false, "kind": "unknown", "caption": "An equation."]]])),
            .sse(SSE.toolUse(id: "f3", name: "describe_figures", input: sketch("(d)", through: [0, 0], checks: [[0, 0], [2, 1.135], [-1, 0.72]]))),
        ])
        let agent = FigureAgent(client: .mock(transport))
        var seen: [Int] = []
        let results = try await agent.describeInSequence(pngs: [Data([1]), Data([2]), Data([3])], context: FigureAgent.FigureContext(questionTexts: ["dy/dx = x - y"]),
                                                         engine: MathEngine()) { seen.append($0) }
        XCTAssertEqual(seen, [1, 2, 3])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[1]?.chart?.series.first?.through, [0, 1])
        XCTAssertEqual(results[1]?.chart?.verification?.passed, true)
        XCTAssertEqual(results[2]?.isFigure, false)
        XCTAssertEqual(results[3]?.chart?.verification?.passed, true)
        XCTAssertEqual(transport.requests.count, 3, "one call per image, none needed a retry")

        for index in 0..<3 {
            let content = try XCTUnwrap(transport.body(index)["messages"]?[0]?["content"]?.arrayValue)
            XCTAssertEqual(content.count, 2, "one image and one text block")
            XCTAssertEqual(content[0]["source"]?["data"], .string(Data([UInt8(index + 1)]).base64EncodedString()))
            let text = try XCTUnwrap(content[1]["text"]?.stringValue)
            XCTAssertTrue(text.contains("This is image \(index + 1) of 3 under this question, in document order."), text)
            XCTAssertFalse(text.contains("Attached are"))
        }
        let second = try XCTUnwrap(transport.body(1)["messages"]?[0]?["content"]?[1]?["text"]?.stringValue)
        XCTAssertTrue(second.contains("The other figures under this question, and what they turned out to be:\n• Image 1 of 3: Solution for part (a). — part (a): y(0) = 1 — solution through (0, 1)"), second)
        XCTAssertTrue(second.contains("do not give this image a part, choice or initial condition already taken"))
        let third = try XCTUnwrap(transport.body(2)["messages"]?[0]?["content"]?[1]?["text"]?.stringValue)
        XCTAssertTrue(third.contains("• Image 1 of 3:"), third)
        XCTAssertFalse(third.contains("• Image 2 of 3"), "a non-figure is not listed")
        let first = try transport.body(0)["messages"]?[0]?["content"]?[1]?["text"]?.stringValue
        XCTAssertFalse(first?.contains("other figures") ?? true, "nothing described yet before the first")

        XCTAssertNil(FigureAgent.siblingNote(FigureAnalysis(kind: .unknown, isFigure: false), image: 1, of: 2))
        let traced = FigureAnalysis(kind: .chart, chart: StandardChart(chartType: "line", series: [ChartSeries(name: "f", points: [[0, 0]])], confidence: 0.5, provenance: StandardChart.traced), caption: "A sketch.")
        XCTAssertEqual(FigureAgent.siblingNote(traced, image: 2, of: 2), "Image 2 of 2: A sketch. — traced from points (no definition in the question)")
    }

    func testAnalyzeVerifiedRetriesAMismatchedDefinitionOnce() async throws {
        // First pass: the agent claims y = x² − 1 but reads points from y = x² + 1. The app rejects it and asks
        // again; the second pass picks the right candidate and passes.
        let wrong: JSONValue = ["figures": [["image": 1, "isFigure": true, "kind": "chart", "caption": "The graph of part (a).",
            "chart": ["chartType": "function", "series": [["name": "f", "latex": "x^2-1"]], "xRange": [-3, 3], "yRange": [-2, 10], "confidence": 0.9,
                      "provenance": "stated", "definition": "part (a): y = x^2 - 1", "checks": [[-2, 5], [0, 1], [2, 5]]]]]]
        let right: JSONValue = ["figures": [["image": 1, "isFigure": true, "kind": "chart", "caption": "The graph of part (b).",
            "chart": ["chartType": "function", "series": [["name": "f", "latex": "x^2+1"]], "xRange": [-3, 3], "yRange": [-2, 10], "confidence": 0.9,
                      "provenance": "stated", "definition": "part (b): y = x^2 + 1", "checks": [[-2, 5], [0, 1], [2, 5]]]]]]
        let transport = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figures", input: wrong)),
                                       .sse(SSE.toolUse(id: "f2", name: "describe_figures", input: right))])
        let agent = FigureAgent(client: .mock(transport))
        let engine = MathEngine()
        let results = try await agent.analyzeVerified(pngs: [Data([1])], context: FigureAgent.FigureContext(questionTexts: ["(a) y = x^2 - 1 (b) y = x^2 + 1"]), engine: engine)
        let chart = try XCTUnwrap(results[1]?.chart)
        XCTAssertEqual(chart.series.first?.latex, "x^2+1")
        XCTAssertEqual(chart.verification?.passed, true)
        XCTAssertTrue(chart.verification?.summary.hasPrefix("Verified: 3 of 3") ?? false)
        XCTAssertEqual(transport.requests.count, 2)
        let secondText = try XCTUnwrap(transport.body(1)["messages"]?[0]?["content"]?[1]?["text"]?.stringValue)
        XCTAssertTrue(secondText.contains("it did not match:\nMismatch: 3 of 3 points disagree with y = x^2-1"), secondText)
        XCTAssertFalse(secondText.contains("Describe only image"), "a single image has no focus note")

        // A definition that still fails after the retry is kept, flagged as unverified, so the review page can say so.
        let stubborn = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figures", input: wrong)),
                                      .sse(SSE.toolUse(id: "f2", name: "describe_figures", input: wrong))])
        let stubbornResults = try await FigureAgent(client: .mock(stubborn)).analyzeVerified(pngs: [Data([1])], context: FigureAgent.FigureContext(), engine: engine)
        XCTAssertEqual(stubbornResults[1]?.chart?.series.first?.latex, "x^2-1")
        XCTAssertEqual(stubbornResults[1]?.chart?.verification?.passed, false)
        XCTAssertEqual(stubborn.requests.count, 2, "one retry, not a loop")

        // Nothing to verify: one call.
        let traced = MockTransport([.sse(SSE.toolUse(id: "f1", name: "describe_figures", input: ["figures": [["image": 1, "isFigure": true, "kind": "chart", "caption": "Sketch.",
            "chart": ["chartType": "line", "series": [["name": "f", "points": [[0, 0], [1, 1]]]], "confidence": 0.5, "provenance": "traced"]]]]))])
        let tracedResults = try await FigureAgent(client: .mock(traced)).analyzeVerified(pngs: [Data([1])], context: FigureAgent.FigureContext(), engine: engine)
        XCTAssertNil(tracedResults[1]?.chart?.verification)
        XCTAssertEqual(traced.requests.count, 1)
    }
}
