import Foundation
import os

extension MathTemplate {
    /// The template with the named parameters fixed at their original values (min = max = original), so physical
    /// constants and reference values never change when the question is regenerated. Parameters without an original
    /// value are left as they are.
    public func pinning(_ names: Set<String>) -> MathTemplate {
        var copy = self
        copy.params = params.map { param in
            guard names.contains(param.name), let value = param.original else { return param }
            var pinned = param
            switch param.kind {
            case .int where value == value.rounded():
                pinned.kind = .int(min: Int(value), max: Int(value))
            case .int, .real:
                pinned.kind = .real(min: value, max: value, decimals: max(param.kind.decimals, TemplateConstants.decimals(of: value)))
            case .choice:
                return param
            }
            pinned.exclude = []
            return pinned
        }
        return copy
    }

    /// Numeric parameters that can take more than one value.
    var varyingParams: [TemplateParam] {
        params.filter { param in
            switch param.kind {
            case let .int(min, max): return min != max
            case let .real(min, max, _): return min != max
            case .choice: return false
            }
        }
    }
}

extension TemplateParam.Kind {
    var decimals: Int {
        if case let .real(_, _, decimals) = self { return decimals }
        return 0
    }
}

/// Finds the parameters of regenerated questions that are physical constants or standard reference values (g,
/// R, c, standard pressure, the density of water, table properties) so they can be pinned at the document's value:
/// only a problem's own givens should change between versions.
public struct TemplateConstants: Sendable {
    public static let model: ClaudeModel = .sonnet
    public static let batchSize = 20
    static let toolName = "mark_constants"
    static let logger = Logger(subsystem: "com.thuban.study", category: "constants")

    static let spec = ToolSpec(
        name: toolName,
        description: "List, for each question number, the parameters that are constants and must not vary.",
        inputSchema: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "number": ["type": "integer"],
                            "constants": ["type": "array", "items": ["type": "string"], "description": "Parameter names; empty when none."],
                        ],
                        "required": ["number", "constants"],
                    ],
                ],
            ],
            "required": ["questions"],
        ]
    )

    static let system = """
    A study app regenerates practice questions with new numbers by drawing each parameter from a range. Physical \
    constants and standard reference values must never change between versions: the acceleration of gravity \
    (9.81 m/s², 9.8 m/s², 32.2 ft/s², "local gravity" included), g_c, universal and specific gas constants, the speed \
    of light, Planck's and Boltzmann's constants, Avogadro's number, the elementary charge, standard atmospheric \
    pressure, the density and specific heat of water, unit-conversion factors, atomic masses, and any property read \
    from a table. The problem's own givens (masses, lengths, forces, temperatures, pressures of a system, times, \
    percentages, rates) may vary. For each question, list the parameters that are constants; list none when all \
    parameters are the problem's own givens. Call mark_constants once, covering every question.
    """

    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// For each template question (by id), the names of its parameters that are constants.
    public func constants(in questions: [Question]) async throws -> [QuestionID: Set<String>] {
        let templates = questions.filter { $0.template.map { !$0.varyingParams.isEmpty } ?? false }
        var result: [QuestionID: Set<String>] = [:]
        var start = 0
        while start < templates.count {
            try Task.checkCancellation()
            let batch = Array(templates[start..<min(start + Self.batchSize, templates.count)])
            for (id, names) in try await checkBatch(batch) where !names.isEmpty { result[id] = names }
            start += Self.batchSize
        }
        return result
    }

    private func checkBatch(_ batch: [Question]) async throws -> [QuestionID: Set<String>] {
        var lines: [String] = []
        for (offset, question) in batch.enumerated() {
            guard let template = question.template else { continue }
            var text = template.stem
            for part in template.parts { text += " (\(part.id)) \(part.prompt)" }
            text = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            if text.count > 700 { text = String(text.prefix(700)) + "…" }
            let params = template.varyingParams.map { param -> String in
                let original = param.original.map { " = \(TemplateConstants.format($0)) in the original" } ?? ""
                return "{\(param.name)}\(original)"
            }.joined(separator: ", ")
            lines.append("\(offset + 1). \(text)\n   Parameters: \(params)")
        }
        let response = try await client.complete(
            model: Self.model,
            system: Self.system,
            messages: [ChatMessage.user(lines.joined(separator: "\n\n"))],
            tools: [Self.spec],
            maxTokens: 3000,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The constants check did not answer.")
        }
        return Self.constants(from: call.input, batch: batch)
    }

    /// Reads the tool call (also when the array arrives wrapped in a JSON string); only real parameter names count.
    static func constants(from input: JSONValue, batch: [Question]) -> [QuestionID: Set<String>] {
        guard let items = QuestionCategorizer.unwrapArray(input, key: "questions") else { return [:] }
        var result: [QuestionID: Set<String>] = [:]
        for item in items {
            guard case .object(let entry) = item, case .number(let number)? = entry["number"],
                  case .array(let names)? = entry["constants"] else { continue }
            let index = Int(number) - 1
            guard batch.indices.contains(index), let template = batch[index].template else { continue }
            let valid = Set(template.params.map(\.name))
            let marked = Set(names.compactMap { value -> String? in
                guard case .string(let raw) = value else { return nil }
                return raw.trimmingCharacters(in: CharacterSet(charactersIn: "{}$ "))
            }).intersection(valid)
            if !marked.isEmpty { result[batch[index].id] = marked }
        }
        return result
    }

    static func decimals(of value: Double) -> Int {
        let text = format(value)
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: dot, to: text.endIndex) - 1
    }

    static func format(_ value: Double) -> String {
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
