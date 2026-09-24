import Foundation
import os

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
    static let logger = Logger(subsystem: "com.thuban.study", category: "categorizer")

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

    static let mergeToolName = "merge_types"

    static let mergeSpec = ToolSpec(
        name: mergeToolName,
        description: "Record the types to fold into another type of the list.",
        inputSchema: [
            "type": "object",
            "properties": [
                "merges": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "string", "description": "A type of the list, exactly as written."],
                            "into": ["type": "string", "description": "The type it joins: one of the list, or a better name for both."],
                        ],
                        "required": ["from", "into"],
                    ],
                ],
            ],
            "required": ["merges"],
        ]
    )

    static let mergeSystem = """
    You tidy the problem types of a study app's question bank. Given a class's types with how many questions each \
    holds, fold together names that describe the same kind of problem ("Domain of functions" and "Domain and range \
    of functions"; "Polar to Cartesian coordinates" and "Cartesian equation of polar curve"), and fold a type with \
    one or two questions into a broader existing type when a student would look for those questions there. Keep \
    types that a course teaches as different techniques apart. Prefer the name already holding more questions. \
    Call merge_types once; an empty list is fine.
    """

    /// Old type → new type for the class's types that name the same kind of problem.
    public func consolidate(_ types: [(type: String, count: Int)], classContext: String) async throws -> [String: String] {
        guard types.count > 1 else { return [:] }
        let listed = types.map { "- \($0.type) (\($0.count))" }.joined(separator: "\n")
        let response = try await client.complete(
            model: Self.model,
            system: Self.mergeSystem,
            messages: [ChatMessage.user("Class: \(classContext)\nTypes:\n\(listed)")],
            tools: [Self.mergeSpec],
            maxTokens: 3000,
            toolChoice: .tool(name: Self.mergeToolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.mergeToolName }) else {
            throw ThubanError.parse("The categorizer did not return merges.")
        }
        var input = call.input
        // Some replies carry the array as a JSON string.
        if case .object(var object) = input, case .string(let text)? = object["merges"],
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            object["merges"] = parsed
            input = .object(object)
        }
        let merges = Self.merges(from: input, types: types.map(\.type))
        Self.logger.info("categorizer reply \(String(describing: call.input).prefix(600), privacy: .public) → \(merges.count, privacy: .public) merges")
        return merges
    }

    /// Reads the merge call: only types of the list are renamed, chains are followed, and nothing maps to itself.
    /// Names are matched loosely ("- Domain of functions (3)", other case or spacing) and a target that is a type of
    /// the list keeps that type's spelling.
    static func merges(from input: JSONValue, types: [String]) -> [String: String] {
        guard case .object(let object) = input, case .array(let items)? = object["merges"] else { return [:] }
        var byKey: [String: String] = [:]
        for type in types { byKey[key(cleaned(type))] = type }
        var map: [String: String] = [:]
        for item in items {
            guard case .object(let entry) = item, case .string(let rawFrom)? = entry["from"], case .string(let rawInto)? = entry["into"],
                  let from = byKey[key(cleaned(rawFrom))] else { continue }
            let cleanedInto = Question.normalizedType(cleaned(rawInto))
            let into = byKey[key(cleanedInto)] ?? cleanedInto
            guard !into.isEmpty, into != from else { continue }
            map[from] = into
        }
        // "A → B" and "B → C" make "A → C"; a cycle is dropped.
        var resolved: [String: String] = [:]
        for from in map.keys {
            var target = map[from]!
            var seen: Set<String> = [from]
            while let next = map[target], !seen.contains(target) { seen.insert(target); target = next }
            if target != from { resolved[from] = target }
        }
        return resolved
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

    /// "- Domain of functions (3)" → "Domain of functions".
    static func cleaned(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("- ") { value.removeFirst(2) }
        value = value.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespaces))
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
