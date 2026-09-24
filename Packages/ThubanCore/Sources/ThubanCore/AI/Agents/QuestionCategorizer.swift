import Foundation

/// Assigns every question its problem type ("Initial value problems", "Related rates"). One agent on one fixed
/// model does this for every class, whichever model imported the questions, so the same kind of problem always
/// gets the same name: it is shown the class's existing types and reuses them, coining a new one only when none
/// fits. Questions are sent in batches; types named in one batch are offered to the next.
public struct QuestionCategorizer: Sendable {
    /// The model that names types, independent of the import model policy.
    public static let model: ClaudeModel = .sonnet
    /// Questions per call.
    public static let batchSize = 40

    static let toolName = "assign_types"

    static let spec = ToolSpec(
        name: toolName,
        description: "Record the problem type of every question listed, by its number.",
        inputSchema: [
            "type": "object",
            "properties": [
                "assignments": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "number": ["type": "integer"],
                            "type": ["type": "string", "description": "1–4 words, sentence case."],
                        ],
                        "required": ["number", "type"],
                    ],
                ],
            ],
            "required": ["assignments"],
        ]
    )

    static let system = """
    You file the questions of a study app's question bank under problem types. A problem type is what the course \
    would call the technique or problem class a student would file the question under: "Initial value problems", \
    "Separation of variables", "Related rates", "Integration by parts", "Eigenvalues", "Molar mass", "Quantum \
    numbers", "Free-body diagrams". It is never a format ("Multiple choice", "Short answer"), never a whole chapter \
    or assignment ("Chapter 3", "Homework 2"), and never so specific that it holds a single question. \
    Consistency matters most: when a type from the class's existing list fits, use it exactly as written; name a new \
    type only when none fits, and then reuse that new name for every other question of the same kind. Names are \
    1–4 words in sentence case, singular or plural as a course would write them. Call assign_types once, with every \
    question listed.
    """

    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// Types for `questions` (by id), reusing `existing` (the class's types, most used first). Questions the model
    /// skipped are absent from the result.
    public func categorize(_ questions: [Question], existing: [String], classContext: String) async throws -> [QuestionID: String] {
        var known = existing.map(Question.normalizedType).filter { !$0.isEmpty }
        var result: [QuestionID: String] = [:]
        var start = 0
        while start < questions.count {
            try Task.checkCancellation()
            let batch = Array(questions[start..<min(start + Self.batchSize, questions.count)])
            let assigned = try await categorizeBatch(batch, known: known, classContext: classContext)
            for (id, type) in assigned {
                result[id] = type
                if !known.contains(type) { known.append(type) }
            }
            start += Self.batchSize
        }
        return result
    }

    private func categorizeBatch(_ batch: [Question], known: [String], classContext: String) async throws -> [QuestionID: String] {
        var lines = ["Class: \(classContext)"]
        if known.isEmpty {
            lines.append("Existing types: none yet.")
        } else {
            lines.append("Existing types: " + known.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        lines.append("")
        for (offset, question) in batch.enumerated() {
            lines.append("\(offset + 1). \(Self.summary(of: question))")
        }
        let response = try await client.complete(
            model: Self.model,
            system: Self.system,
            messages: [ChatMessage.user(lines.joined(separator: "\n"))],
            tools: [Self.spec],
            maxTokens: 4000,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The categorizer did not assign types.")
        }
        return Self.assignments(from: call.input, batch: batch, known: known)
    }

    /// Reads the tool call; a name that differs from an existing type only in case or spacing becomes that type.
    static func assignments(from input: JSONValue, batch: [Question], known: [String]) -> [QuestionID: String] {
        guard case .object(let object) = input, case .array(let items)? = object["assignments"] else { return [:] }
        var byKey: [String: String] = [:]
        for type in known { byKey[key(type)] = type }
        var result: [QuestionID: String] = [:]
        for item in items {
            guard case .object(let entry) = item, case .number(let number)? = entry["number"],
                  case .string(let raw)? = entry["type"] else { continue }
            let index = Int(number) - 1
            guard batch.indices.contains(index) else { continue }
            let type = Question.normalizedType(raw)
            guard !type.isEmpty else { continue }
            let canonical = byKey[key(type)] ?? type
            byKey[key(type)] = canonical
            result[batch[index].id] = canonical
        }
        return result
    }

    private static func key(_ type: String) -> String {
        type.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The question in a few hundred characters: where it came from, its setup and its parts.
    static func summary(of question: Question) -> String {
        var text = ""
        if let ref = question.sourceRef, !ref.isEmpty { text += "[\(ref)] " }
        text += question.stem
        for part in question.parts { text += " (\(part.id)) \(part.prompt)" }
        let flattened = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return flattened.count > 400 ? String(flattened.prefix(400)) + "…" : flattened
    }
}
