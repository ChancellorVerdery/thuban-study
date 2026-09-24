import Foundation

/// Smart grading for short text answers: when `GradingRules.gradeText` finds no literal match, the model decides
/// whether the student's wording means the same as the answer key ("size" for "size (energy level / principal energy
/// shell)", "the shell's energy" for "energy level"). It never reveals the key and never loosens a numeric answer:
/// a different value, a different term or a missing item is still wrong.
public struct TextAnswerJudge: Sendable {
    public struct Judgement: Sendable, Equatable {
        public var correct: Bool
        public var reason: String
    }

    static let toolName = "record_judgement"

    static let spec = ToolSpec(
        name: toolName,
        description: "Record whether the student's answer is correct.",
        inputSchema: [
            "type": "object",
            "properties": [
                "correct": ["type": "boolean", "description": "True when the answer means the same as the key."],
                "reason": ["type": "string", "description": "One short sentence for the student. Do not reveal the key."],
            ],
            "required": ["correct", "reason"],
        ]
    )

    static let system = """
    You grade one short answer on a study app. Decide whether the student's answer means the same thing as the answer \
    key in the context of the question. Accept synonyms, any one of the alternatives the key offers (in parentheses, \
    after a slash, or after "or"), a correct answer that is more specific than the key, different capitalization, \
    spacing, punctuation, ordering of list items, abbreviations and small spelling mistakes. Reject an answer that \
    names a different concept, a different number or value, is missing items the key lists, adds wrong items, or \
    is too vague to show understanding. Call record_judgement once.
    """

    private let client: ClaudeClient
    private let model: ClaudeModel

    public init(client: ClaudeClient, model: ClaudeModel = .sonnet) {
        self.client = client
        self.model = model
    }

    public func judge(question: String, prompt: String, key: String, alternatives: [String], student: String) async throws -> Judgement {
        var lines = ["Question: \(question)"]
        if !prompt.isEmpty, prompt != question { lines.append("Part: \(prompt)") }
        lines.append("Answer key: \(key)")
        if !alternatives.isEmpty { lines.append("Also accepted: " + alternatives.joined(separator: " | ")) }
        lines.append("Student's answer: \(student)")
        let response = try await client.complete(
            model: model,
            system: Self.system,
            messages: [ChatMessage.user([.text(lines.joined(separator: "\n"))])],
            tools: [Self.spec],
            maxTokens: 400,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }),
              case .object(let object) = call.input, case .bool(let correct)? = object["correct"] else {
            throw ThubanError.parse("The grader did not record a judgement.")
        }
        var reason = ""
        if case .string(let text)? = object["reason"] { reason = text }
        return Judgement(correct: correct, reason: reason)
    }
}
