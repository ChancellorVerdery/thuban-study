import Foundation

/// Makes flashcards from study material: pasted notes and the text (and page pictures) of documents. Each card is
/// one fact, definition, formula or step, with math as `$…$` / `$$…$$` LaTeX so it renders on the card. The student
/// reviews the list before anything joins the deck.
public struct FlashcardGenerator: Sendable {
    public static let model: ClaudeModel = .sonnet
    /// Characters of material sent in one call.
    public static let maxCharacters = 60_000
    /// Page pictures sent in one call (tables and formulas that the text layer garbles).
    public static let maxImages = 8

    public struct Card: Sendable, Equatable {
        public var front: String
        public var back: String
    }

    public struct Material: Sendable {
        public var title: String
        public var text: String
        public var images: [Data]

        public init(title: String, text: String, images: [Data] = []) {
            self.title = title
            self.text = text
            self.images = images
        }
    }

    static let toolName = "emit_cards"

    static let spec = ToolSpec(
        name: toolName,
        description: "Record the flashcards made from the material.",
        inputSchema: [
            "type": "object",
            "properties": [
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "front": ["type": "string", "description": "The prompt: a question, term or formula to recall. Markdown with $…$ LaTeX."],
                            "back": ["type": "string", "description": "The answer. Markdown with $…$ or $$…$$ LaTeX."],
                        ],
                        "required": ["front", "back"],
                    ],
                ],
            ],
            "required": ["cards"],
        ]
    )

    static func system(classContext: String) -> String {
        """
        You write flashcards for a student in \(classContext). Make cards from the material only — its definitions, \
        laws and formulas (what each symbol means and when it applies), units and conversions, key facts, named \
        methods and their steps, and common distinctions. Each card tests one thing: a short, specific front that has \
        exactly one right answer, and a back that answers it completely but briefly. Write every formula, symbol, \
        variable and unit expression in LaTeX: inline as $…$ (e.g. $\\Delta U = Q - W$, $c_p$, $\\mathrm{kJ/kg}$), \
        a longer formula on its own as $$…$$. Never leave math as plain text or Unicode. Use Markdown only for \
        emphasis or a short list. Skip anything already on the student's existing cards, examples that are only \
        numbers, and administrative content (due dates, grading, page numbers). Call emit_cards once with every card.
        """
    }

    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// Cards for `material`, avoiding the fronts already in the deck. `target` is a rough number to aim for.
    public func generate(from material: [Material], classContext: String, existingFronts: [String], target: Int?) async throws -> [Card] {
        var content: [ContentPart] = []
        var budget = Self.maxCharacters
        var images = 0
        for item in material {
            let text = String(item.text.prefix(max(0, budget)))
            budget -= text.count
            content.append(.text("Material: \(item.title)\n\n\(text)"))
            for image in item.images where images < Self.maxImages {
                content.append(.image(mediaType: "image/png", base64: image.base64EncodedString()))
                images += 1
            }
            if budget <= 0 { break }
        }
        var ask = "Make flashcards from the material above"
        if let target { ask += ", about \(target) cards" }
        ask += "."
        if !existingFronts.isEmpty {
            ask += "\n\nCards the student already has (do not repeat them):\n" + existingFronts.prefix(200).map { "- \($0)" }.joined(separator: "\n")
        }
        content.append(.text(ask))
        let response = try await client.complete(
            model: Self.model,
            system: Self.system(classContext: classContext),
            messages: [ChatMessage.user(content)],
            tools: [Self.spec],
            maxTokens: 16_000,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("No cards came back.")
        }
        return Self.cards(from: call.input)
    }

    /// Reads the tool call (also when the array arrives wrapped in a JSON string); blank or duplicate cards are dropped.
    static func cards(from input: JSONValue) -> [Card] {
        guard let items = QuestionCategorizer.unwrapArray(input, key: "cards") else { return [] }
        var seen = Set<String>()
        var cards: [Card] = []
        for item in items {
            guard case .object(let entry) = item, case .string(let front)? = entry["front"], case .string(let back)? = entry["back"] else { continue }
            let f = front.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !f.isEmpty, !b.isEmpty, seen.insert(f.lowercased()).inserted else { continue }
            cards.append(Card(front: f, back: b))
        }
        return cards
    }
}
