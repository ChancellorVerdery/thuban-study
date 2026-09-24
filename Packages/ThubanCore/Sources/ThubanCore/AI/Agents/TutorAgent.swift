import Foundation
import os

/// Everything the tutor needs to know about the student's current situation.
public struct TutorContext: Sendable {
    public var className: String
    public var style: TutorStyle
    /// The question the student is looking at, if any.
    public var instance: QuestionInstance?
    public var sourceRef: String?
    /// The question's problem type ("Separation of variables"), so the tutor can name the technique in play.
    public var questionType: String?
    /// partId → the student's current input (LaTeX or text).
    public var inputs: [String: String]
    /// partId → latest verdict, if checked.
    public var verdicts: [String: Verdict]
    /// LaTeX of the expressions currently on the graph.
    public var graphExpressions: [String]
    /// Whether the tutor may add/remove graph expressions (Settings toggle).
    public var mayEditGraph: Bool
    public var model: ClaudeModel
    /// Include the reference answers (marked "never reveal") so the tutor can judge the student's steps.
    public var includeReferenceAnswers: Bool

    public init(
        className: String,
        style: TutorStyle = .socratic,
        instance: QuestionInstance? = nil,
        sourceRef: String? = nil,
        questionType: String? = nil,
        inputs: [String: String] = [:],
        verdicts: [String: Verdict] = [:],
        graphExpressions: [String] = [],
        mayEditGraph: Bool = true,
        model: ClaudeModel = .sonnet,
        includeReferenceAnswers: Bool = true
    ) {
        self.className = className
        self.style = style
        self.instance = instance
        self.sourceRef = sourceRef
        self.questionType = questionType
        self.inputs = inputs
        self.verdicts = verdicts
        self.graphExpressions = graphExpressions
        self.mayEditGraph = mayEditGraph
        self.model = model
        self.includeReferenceAnswers = includeReferenceAnswers
    }

    /// The question, the student's inputs and verdicts rendered for the system prompt.
    public var renderedQuestion: String {
        guard let instance else { return "" }
        var lines: [String] = []
        if let sourceRef, !sourceRef.isEmpty { lines.append("Source: \(sourceRef)") }
        if let questionType, !questionType.isEmpty { lines.append("Type: \(questionType)") }
        lines.append("Question: \(instance.stem)")
        for part in instance.parts {
            lines.append("")
            lines.append("Part (\(part.id)): \(part.prompt)")
            if let choices = part.choices, !choices.isEmpty {
                lines.append("  Choices: " + choices.joined(separator: " | "))
            }
            let conditions = part.conditions.summaryItems
            if !conditions.isEmpty { lines.append("  Requirements: " + conditions.joined(separator: "; ")) }
            if let input = inputs[part.id], !input.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("  Student's current input: \(input)")
            } else {
                lines.append("  Student's current input: (empty)")
            }
            if let verdict = verdicts[part.id] {
                var line = "  Last verdict: \(verdict.outcome.rawValue)"
                if !verdict.message.isEmpty { line += " — \(verdict.message)" }
                if !verdict.failedConditions.isEmpty { line += " (failed: \(verdict.failedConditions.joined(separator: ", ")))" }
                lines.append(line)
            }
            if includeReferenceAnswers, !part.answerLatex.isEmpty {
                lines.append("  Reference answer (for your eyes only — NEVER reveal or confirm it): \(part.answerLatex)")
            }
        }
        if !graphExpressions.isEmpty {
            lines.append("")
            lines.append("On the graph now: " + graphExpressions.joined(separator: " ; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// What `TutorAgent.respond` streams to the chat pane.
public enum TutorEvent: Sendable {
    case textDelta(String)
    case toolEvent(ToolEvent)
    /// The model stopped at the output-token limit: the reply so far is incomplete.
    case truncated
    case done(usage: Usage)
}

/// Runs one tutor turn: streams the reply, executes tool calls through the app's `TutorToolHandler`, feeds the
/// results back and continues until the model stops (at most `maxRounds` tool rounds).
public actor TutorAgent {
    public static let defaultMaxRounds = 6

    /// Output budget for an ordinary (guiding) reply. The model reasons before it answers and that reasoning counts
    /// here, so the budget is generous even though the visible reply is a few sentences (1 500 left nothing).
    public static let defaultMaxTokens = 16_000
    /// Output budget for a turn with `solutionRequested`: a worked solution needs far more room than a hint.
    public static let defaultSolutionMaxTokens = 32_000

    private let client: ClaudeClient
    private let maxRounds: Int
    private let maxTokens: Int
    private let solutionMaxTokens: Int
    private let thinking: Bool
    private let logger = Logger(subsystem: "com.thuban.study", category: "TutorAgent")

    public init(
        client: ClaudeClient,
        maxRounds: Int = TutorAgent.defaultMaxRounds,
        maxTokens: Int = TutorAgent.defaultMaxTokens,
        solutionMaxTokens: Int = TutorAgent.defaultSolutionMaxTokens,
        thinking: Bool = false
    ) {
        self.client = client
        self.maxRounds = max(1, maxRounds)
        self.maxTokens = maxTokens
        self.solutionMaxTokens = max(maxTokens, solutionMaxTokens)
        self.thinking = thinking
    }

    /// Streams the tutor's reply to `student`. Ends with `.done` or throws a `ThubanError`.
    public nonisolated func respond(
        context: TutorContext,
        transcript: [TutorMessage],
        student: String,
        solutionRequested: Bool,
        tools: TutorToolHandler
    ) -> AsyncThrowingStream<TutorEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(
                    context: context, transcript: transcript, student: student,
                    solutionRequested: solutionRequested, tools: tools, continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transcript conversion

    /// Converts the stored transcript plus the new student message into API messages. Student → user, tutor →
    /// assistant, system lines dropped, consecutive same-role history merged, leading assistant turns dropped.
    ///
    /// The solution licence is granted by `Prompts.solutionRequestMarker` at the head of the *current* message only:
    /// - the current message is always its own user turn (a neutral assistant placeholder is inserted when the
    ///   history ends with an unanswered student message), so it can neither inherit a stale marker from an earlier
    ///   message nor lose its own marker behind one;
    /// - earlier flagged messages get `Prompts.solutionRequestHistoryNote` instead of the marker;
    /// - any copy of the marker the student typed themselves is redacted.
    public static func chatMessages(transcript: [TutorMessage], student: String, solutionRequested: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for message in transcript {
            let role: String
            switch message.role {
            case .student: role = "user"
            case .tutor: role = "assistant"
            case .system: continue
            }
            var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if message.role == .student {
                text = sanitizedStudentText(text)
                if message.solutionRequested { text = Prompts.solutionRequestHistoryNote + "\n" + text }
            }
            append(role: role, text: text, to: &out)
        }
        let current = sanitizedStudentText(student.trimmingCharacters(in: .whitespacesAndNewlines))
        if let last = out.last, last.role == "user" {
            out.append(ChatMessage(role: "assistant", content: [.text(unansweredPlaceholder)]))
        }
        out.append(ChatMessage(role: "user", content: [.text(solutionRequested ? marked(current) : current)]))
        while let first = out.first, first.role != "user" { out.removeFirst() }
        return out
    }

    /// Assistant turn stood in for a reply that never arrived (failed, cancelled or empty), so the current student
    /// message stays a separate user turn.
    static let unansweredPlaceholder = "(The tutor did not reply to that message.)"

    /// Removes any copy of the app's bracketed markers from text the student typed, so pasting the marker cannot
    /// impersonate the "Ask for the solution" flow.
    static func sanitizedStudentText(_ text: String) -> String {
        var out = text
        for marker in [Prompts.solutionRequestMarker, Prompts.solutionRequestHistoryNote] where out.contains(marker) {
            out = out.replacingOccurrences(of: marker, with: Prompts.solutionRequestMarkerRedaction)
        }
        return out
    }

    private static func marked(_ text: String) -> String {
        text.isEmpty ? Prompts.solutionRequestMarker : Prompts.solutionRequestMarker + "\n" + text
    }

    private static func append(role: String, text: String, to messages: inout [ChatMessage]) {
        if let last = messages.last, last.role == role, let existing = last.content.first?.textValue {
            messages[messages.count - 1] = ChatMessage(role: role, content: [.text(existing + "\n\n" + text)])
        } else {
            messages.append(ChatMessage(role: role, content: [.text(text)]))
        }
    }

    // MARK: Tool loop

    private func run(
        context: TutorContext,
        transcript: [TutorMessage],
        student: String,
        solutionRequested: Bool,
        tools: TutorToolHandler,
        continuation: AsyncThrowingStream<TutorEvent, Error>.Continuation
    ) async {
        let system = Prompts.tutorSystem(
            className: context.className, style: context.style,
            questionContext: context.renderedQuestion, mayEditGraph: context.mayEditGraph,
            solutionRequested: solutionRequested
        )
        let specs = TutorTools.specs(mayEditGraph: context.mayEditGraph)
        var messages = Self.chatMessages(transcript: transcript, student: student, solutionRequested: solutionRequested)
        let budget = solutionRequested ? solutionMaxTokens : maxTokens
        var total = Usage()
        do {
            for round in 1...maxRounds {
                let outcome = try await runRound(
                    context: context, system: system, specs: specs, messages: messages, maxTokens: budget,
                    tools: tools, continuation: continuation
                )
                total += outcome.usage
                if outcome.stopReason == "max_tokens" {
                    logger.notice("Tutor reply hit the output-token limit (\(budget, privacy: .public))")
                    continuation.yield(.truncated)
                    break
                }
                guard outcome.stopReason == "tool_use", !outcome.toolResults.isEmpty else { break }
                messages.append(.assistant(outcome.assistantParts))
                messages.append(.user(outcome.toolResults))
                if round == maxRounds { logger.notice("Tutor tool loop hit the round limit") }
            }
            continuation.yield(.done(usage: total))
            continuation.finish()
        } catch {
            continuation.finish(throwing: ClaudeClient.normalize(error))
        }
    }

    private struct RoundOutcome {
        var assistantParts: [ContentPart]
        var toolResults: [ContentPart]
        var stopReason: String
        var usage: Usage
    }

    private func runRound(
        context: TutorContext,
        system: String,
        specs: [ToolSpec],
        messages: [ChatMessage],
        maxTokens: Int,
        tools: TutorToolHandler,
        continuation: AsyncThrowingStream<TutorEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        var collector = PartsCollector()
        var results: [ContentPart] = []
        var stopReason = "end_turn"
        var usage = Usage()
        let events = client.stream(
            model: context.model, system: system, messages: messages, tools: specs,
            maxTokens: maxTokens, thinking: thinking
        )
        for try await event in events {
            switch event {
            case .textDelta(let text):
                collector.appendText(text)
                continuation.yield(.textDelta(text))
            case .toolUseEnd(let id, let name, let input):
                collector.appendToolUse(id: id, name: name, input: input)
                results.append(try await execute(id: id, name: name, input: input, tools: tools, continuation: continuation))
            case .messageEnd(let reason, let u):
                stopReason = reason
                usage = u
            case .toolUseStart, .toolInputDelta, .error:
                break
            }
        }
        return RoundOutcome(assistantParts: collector.nonEmptyParts, toolResults: results, stopReason: stopReason, usage: usage)
    }

    private func execute(
        id: String,
        name: String,
        input: JSONValue,
        tools: TutorToolHandler,
        continuation: AsyncThrowingStream<TutorEvent, Error>.Continuation
    ) async throws -> ContentPart {
        try Task.checkCancellation()
        let output = await tools.handle(name: name, input: input)
        let isError = output["error"].map { !$0.isNull } ?? false
        let summary = isError
            ? TutorTools.failureSummary(name: name, input: input, reason: output["error"]?.stringValue)
            : TutorTools.summary(name: name, input: input)
        continuation.yield(.toolEvent(ToolEvent(id: id, name: name, summary: summary, input: input, isError: isError)))
        return .toolResult(toolUseId: id, content: output.jsonString(), isError: isError)
    }
}
