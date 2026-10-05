import Foundation
import os

/// After an import: the general equations, rules and constants the new questions need that the class's equation
/// sheet does not already give. Only general forms are suggested — PV = mRT, never P₁V₁ = P₂V₂, which follows from
/// it — and nothing the sheet, an earlier suggestion or a denied one already covers. The student approves or
/// denies each (`EquationSuggestion`).
public struct EquationSuggester: Sendable {
    public static let model: ClaudeModel = .sonnet
    /// Questions per call.
    public static let batchSize = 60

    static let toolName = "suggest_equations"
    static let logger = Logger(subsystem: "com.thuban.study", category: "equation-suggester")

    static let spec = ToolSpec(
        name: toolName,
        description: "Record the general equations, rules and constants the questions need that the sheet lacks (an empty list when it has everything).",
        inputSchema: [
            "type": "object",
            "properties": [
                "suggestions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "group": ["type": "string", "description": "The sheet group it belongs in: an existing group's exact name when one fits, else a new 1–3 word name."],
                            "name": ["type": "string", "description": "What it is, 1–5 words (\"Ideal gas law\", \"Chain rule\", \"Universal gas constant\")."],
                            "equations": ["type": "array", "items": ["type": "string"], "description": "LaTeX, one string per equation, in its general form. A constant: its symbol, value and units (\"R_u = 8.314\\\\ \\\\mathrm{kJ/(kmol\\\\cdot K)}\")."],
                            "note": ["type": "string", "description": "A short plain-text condition or meaning of the symbols (\"for an ideal gas; T in kelvin\"), or empty."],
                            "kind": ["type": "string", "enum": ["equation", "rule", "constant"]],
                            "reason": ["type": "string", "description": "Which questions need it, in a short sentence (\"Q3, Q7: tank pressure after heating\")."],
                        ],
                        "required": ["group", "name", "equations", "kind", "reason"],
                    ],
                ],
            ],
            "required": ["suggestions"],
        ]
    )

    static let system = """
    You keep a student's equation sheet complete. You are given the class, the sheet as it stands (groups and their \
    equations), equations already suggested or declined, and a batch of questions just imported. List the general \
    equations, rules and constants a student needs to work these questions that the sheet does not already give, \
    by calling suggest_equations once.

    Rules:
    - General forms only. Suggest the law, not its special cases or rearrangements: PV = mRT, never P_1V_1 = P_2V_2 \
      or P = mRT/V, because those follow from it. The chain rule, not the derivative of sin(3x). The first law for a \
      closed system, not one problem's energy balance.
    - Nothing derivable from what the sheet already has (or from another suggestion in your list): if the sheet has \
      PV = mRT, do not suggest Pv = RT or the combined gas law.
    - Nothing the sheet, the earlier suggestions or the declined list already covers, even written differently.
    - Only what the questions actually need: no textbook tour, no definitions a student would never look up, no \
      problem-specific numbers or answers. Constants only when a question needs their value and does not give it \
      (universal gas constant, g, a table value used throughout), with value and units.
    - Use the class's own notation as the questions write it (v for specific volume, \\dot{m} for mass flow).
    - Put each in an existing group when one fits (use its exact name); otherwise name a new group in 1–3 words.
    - An empty list is the right answer when the sheet already covers the questions.
    """

    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// Suggestions for `questions` (unsaved, pending), given the class's `sheet` and its earlier suggestions (pending,
    /// approved or denied, which are never suggested again).
    public func suggest(for questions: [Question], classId: ClassID, classContext: String, sheet: EquationSheet,
                        earlier: [EquationSuggestion], documentId: DocumentID?) async throws -> [EquationSuggestion] {
        guard !questions.isEmpty else { return [] }
        var found: [EquationSuggestion] = []
        for start in stride(from: 0, to: questions.count, by: Self.batchSize) {
            let batch = Array(questions[start..<min(questions.count, start + Self.batchSize)])
            let message = Self.message(batch: batch, classContext: classContext, sheet: sheet, earlier: earlier + found)
            let response = try await client.complete(
                model: Self.model,
                system: Self.system,
                messages: [ChatMessage.user(message)],
                tools: [Self.spec],
                maxTokens: 4000,
                toolChoice: .tool(name: Self.toolName)
            )
            guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
                throw ThubanError.parse("The equation suggester did not answer.")
            }
            let decoded = Self.suggestions(from: call.input, classId: classId, documentId: documentId)
            found += Self.novel(decoded, sheet: sheet, earlier: earlier + found)
        }
        return found
    }

    static func message(batch: [Question], classContext: String, sheet: EquationSheet, earlier: [EquationSuggestion]) -> String {
        var lines = ["Class: \(classContext)", "", "The sheet:"]
        if sheet.sections.isEmpty { lines.append("(empty)") }
        for section in sheet.sections {
            lines.append("## \(section.group.name)")
            for entry in section.entries {
                lines.append("- \(entry.name): " + entry.equations.joined(separator: " ; ") + (entry.note.map { " (\($0))" } ?? ""))
            }
        }
        let pending = earlier.filter { $0.status != .denied }, denied = earlier.filter { $0.status == .denied }
        if !pending.isEmpty {
            lines += ["", "Already suggested (do not repeat):"] + pending.map { "- \($0.name): " + $0.equations.joined(separator: " ; ") }
        }
        if !denied.isEmpty {
            lines += ["", "Declined by the student (never suggest these or their equivalents):"] + denied.map { "- \($0.name): " + $0.equations.joined(separator: " ; ") }
        }
        lines += ["", "Questions:"]
        for (k, question) in batch.enumerated() { lines.append("\(k + 1). " + QuestionCategorizer.summary(of: question)) }
        return lines.joined(separator: "\n")
    }

    /// Lenient decoding: entries with a name and at least one equation.
    static func suggestions(from input: JSONValue, classId: ClassID, documentId: DocumentID?) -> [EquationSuggestion] {
        let items = QuestionCategorizer.unwrapArray(input, key: "suggestions") ?? []
        return items.compactMap { item -> EquationSuggestion? in
            guard case .object(let o) = item else { return nil }
            let name = (o["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var equations: [String] = []
            if case .array(let list)? = o["equations"] { equations = list.compactMap(\.stringValue) }
            else if let one = o["equations"]?.stringValue { equations = [one] }
            equations = EquationEntry.cleaned(equations)
            guard !name.isEmpty, !equations.isEmpty else { return nil }
            let note = o["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = o["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return EquationSuggestion(classId: classId,
                                      groupName: (o["group"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name, equations: equations,
                                      note: note?.isEmpty == false ? note : nil, reason: reason?.isEmpty == false ? reason : nil,
                                      kind: o["kind"]?.stringValue.flatMap(EquationSuggestion.Kind.init(rawValue:)) ?? .equation,
                                      documentId: documentId)
        }
    }

    /// Drops suggestions whose equations are already on the sheet or already suggested (same LaTeX once spaces and
    /// braces are ignored), or whose name repeats an earlier suggestion's.
    static func novel(_ suggestions: [EquationSuggestion], sheet: EquationSheet, earlier: [EquationSuggestion]) -> [EquationSuggestion] {
        func key(_ latex: String) -> String { latex.lowercased().filter { !$0.isWhitespace && $0 != "{" && $0 != "}" } }
        var seenEquations = Set(sheet.sections.flatMap(\.entries).flatMap(\.equations).map(key))
        seenEquations.formUnion(earlier.flatMap(\.equations).map(key))
        var seenNames = Set(earlier.map { $0.name.lowercased() })
        var result: [EquationSuggestion] = []
        for suggestion in suggestions {
            guard !suggestion.equations.contains(where: { seenEquations.contains(key($0)) }),
                  !seenNames.contains(suggestion.name.lowercased()) else { continue }
            seenEquations.formUnion(suggestion.equations.map(key))
            seenNames.insert(suggestion.name.lowercased())
            result.append(suggestion)
        }
        return result
    }
}
