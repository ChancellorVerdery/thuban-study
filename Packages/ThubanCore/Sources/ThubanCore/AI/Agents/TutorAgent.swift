import Foundation
import os

/// Everything the tutor needs to know about the student's current situation.
public struct TutorContext: Sendable {
    public var className: String
    public var style: TutorStyle
    /// The question the student is looking at, if any.
    public var instance: QuestionInstance?
    public var sourceRef: String?
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
    case done(usage: Usage)
}

/// Runs one tutor turn: streams the reply, executes tool calls through the app's `TutorToolHandler`, feeds the
/// results back and continues until the model stops (at most `maxRounds` tool rounds).
public actor TutorAgent {
    public static let defaultMaxRounds = 6

    private let client: ClaudeClient
    private let maxRounds: Int
    private let maxTokens: Int
    private let thinking: Bool
    private let logger = Logger(subsystem: "com.thuban.study", category: "TutorAgent")

    public init(client: ClaudeClient, maxRounds: Int = TutorAgent.defaultMaxRounds, maxTokens: Int = 1500, thinking: Bool = false) {
        self.client = client
        self.maxRounds = max(1, maxRounds)
        self.maxTokens = maxTokens
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
    /// assistant, system lines dropped, consecutive same-role messages merged, leading assistant turns dropped.
    /// A message with `solutionRequested` is prefixed with `Prompts.solutionRequestMarker`.
    public static func chatMessages(transcript: [TutorMessage], student: String, solutionRequested: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for message in transcript {
            let role: String
            switch message.role {
            case .student: role = "user"
            case .tutor: role = "assistant"
            case .system: continue
            }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let flagged = message.role == .student && message.solutionRequested
            append(role: role, text: flagged ? marked(text) : text, to: &out)
        }
        let current = student.trimmingCharacters(in: .whitespacesAndNewlines)
        append(role: "user", text: solutionRequested ? marked(current) : current, to: &out)
        while let first = out.first, first.role != "user" { out.removeFirst() }
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
            questionContext: context.renderedQuestion, mayEditGraph: context.mayEditGraph
        )
        let specs = TutorTools.specs(mayEditGraph: context.mayEditGraph)
        var messages = Self.chatMessages(transcript: transcript, student: student, solutionRequested: solutionRequested)
        var total = Usage()
        do {
            for round in 1...maxRounds {
                let outcome = try await runRound(
                    context: context, system: system, specs: specs, messages: messages, tools: tools, continuation: continuation
                )
                total += outcome.usage
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
        continuation.yield(.toolEvent(ToolEvent(id: id, name: name, summary: TutorTools.summary(name: name, input: input), input: input)))
        return .toolResult(toolUseId: id, content: output.jsonString(), isError: isError)
    }
}
