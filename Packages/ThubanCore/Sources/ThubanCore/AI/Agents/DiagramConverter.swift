import Foundation
import os

/// Turns a free-response "sketch the processes on p–V coordinates" part into a gradable `diagram` part: the model
/// reads the question and the part's rubric and writes the axes, states and processes. The result is used only when
/// it is self-consistent (`DiagramSpec.isUsable`); anything else stays free response.
public struct DiagramConverter: Sendable {
    public static let model: ClaudeModel = .sonnet
    static let toolName = "make_diagram"
    static let logger = Logger(subsystem: "com.thuban.study", category: "diagrams")

    static let spec = ToolSpec(
        name: toolName,
        description: "Give the expected diagram for the sketch part, or say it cannot be one.",
        inputSchema: [
            "type": "object",
            "properties": [
                "convertible": ["type": "boolean", "description": "False when the sketch is not states joined by processes on two linear axes."],
                "diagram": ImportTools.diagramSchema,
            ],
            "required": ["convertible"],
        ]
    )

    static let system = """
    A study app grades "sketch the processes on p–V coordinates" answers as diagrams: numbered states placed on two \
    axes and joined by processes. Write the expected diagram for the part you are given, from the question and the \
    part's rubric. x is the horizontal axis (V on a p–V diagram, v on T–v). Each process path is constantX \
    (vertical), constantY (horizontal), line, or polytropic with exponent n of y·xⁿ = const (pV = const is n = 1, \
    pV⁻¹ = const is n = −1). Work out every state's coordinates from the data (use the rubric's values). Numeric axes \
    carry the unit and a range about 30 % above the largest value, starting at 0. When states are given only as \
    multiples of a reference (p₂ = 2p₁), make the axis symbolic: symbol "p_1", values in multiples (state 1 at 1), \
    max about 1.5 × the largest multiple. Set shadeWork when the part asks to show work as areas. Answer \
    convertible = false for sketches that need a vapor dome or saturation curve, curves with no stated relation, \
    temperature profiles, regions, or anything that is not states joined by processes.
    """

    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// Parts worth trying: free response, asking for a sketch on coordinates or a diagram.
    public static func isCandidate(_ part: QuestionPart) -> Bool {
        guard part.answerKind == .freeResponse else { return false }
        let text = (part.prompt + " " + (part.answer.rubric ?? "")).lowercased()
        let asksToDraw = ["sketch", "plot", "draw", "show the process", "show the cycle"].contains { text.contains($0) }
        let onAxes = ["p-v", "p–v", "p-$v", "$p$-$v", "$p$–$v", "t-v", "t–v", "$t$-$v", "$t$–$v", "t-s", "coordinates", "diagram"].contains { text.contains($0) }
        return asksToDraw && onAxes
    }

    /// The diagram for `part` of `question`, or nil when it cannot be one (or the model's diagram is not usable).
    public func convert(_ part: QuestionPart, of question: Question) async throws -> DiagramSpec? {
        var lines = ["Question: \(question.stem)"]
        for other in question.parts where other.id != part.id {
            lines.append("(\(other.id)) \(other.prompt)")
        }
        lines.append("")
        lines.append("Sketch part (\(part.id)): \(part.prompt)")
        if let rubric = part.answer.rubric, !rubric.isEmpty { lines.append("Rubric: \(rubric)") }
        let response = try await client.complete(
            model: Self.model,
            system: Self.system,
            messages: [ChatMessage.user(lines.joined(separator: "\n"))],
            tools: [Self.spec],
            maxTokens: 3000,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The diagram converter did not answer.")
        }
        return Self.diagram(from: call.input, label: question.sourceRef ?? question.id.raw)
    }

    static func diagram(from input: JSONValue, label: String) -> DiagramSpec? {
        guard case .object(let object) = input else { return nil }
        if case .bool(false)? = object["convertible"] { return nil }
        var value = object["diagram"]
        if case .string(let text)? = value { value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        guard let value, let data = try? JSONEncoder().encode(value),
              let spec = try? JSONDecoder().decode(DiagramSpec.self, from: data) else { return nil }
        guard spec.isUsable else {
            logger.info("diagram for \(label, privacy: .public) rejected: \(spec.problems.joined(separator: "; "), privacy: .public)")
            return nil
        }
        return spec
    }
}
