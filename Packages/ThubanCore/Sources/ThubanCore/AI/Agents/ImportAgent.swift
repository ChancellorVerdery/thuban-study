import Foundation
import os

// MARK: - Drafts

/// A question as the import agent writes it: `Question` without ids/dates, plus figure references by extraction
/// index. Decoding is lenient so agent JSON can omit anything at its default.
public struct QuestionDraft: Codable, Sendable, Equatable {
    public var sourceRef: String?
    public var kind: QuestionKind
    /// The agent's problem-type classification ("Initial value problems"); see `Question.type`.
    public var type: String
    public var stem: String
    public var parts: [QuestionPart]
    public var template: MathTemplate?
    /// `ExtractedFigure.index` values the question relies on.
    public var figureIndices: [Int]
    public var tags: [String]
    public var difficulty: Int
    /// The excerpt began inside the previous excerpt's last question: these parts belong to it.
    public var continuesPrevious: Bool

    public init(
        sourceRef: String? = nil,
        kind: QuestionKind,
        type: String = "",
        stem: String,
        parts: [QuestionPart],
        template: MathTemplate? = nil,
        figureIndices: [Int] = [],
        tags: [String] = [],
        difficulty: Int = 3,
        continuesPrevious: Bool = false
    ) {
        self.sourceRef = sourceRef
        self.kind = kind
        self.type = Question.normalizedType(type)
        self.stem = stem
        self.parts = parts
        self.template = template
        self.figureIndices = figureIndices
        self.tags = tags
        self.difficulty = min(5, max(1, difficulty))
        self.continuesPrevious = continuesPrevious
    }

    private enum CodingKeys: String, CodingKey { case sourceRef, kind, type, stem, parts, template, figureIndices, tags, difficulty, continuesPrevious }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceRef: try c.decodeIfPresent(String.self, forKey: .sourceRef),
            kind: try c.decodeIfPresent(QuestionKind.self, forKey: .kind) ?? .shortAnswer,
            type: try c.decodeIfPresent(String.self, forKey: .type) ?? "",
            stem: try c.decodeIfPresent(String.self, forKey: .stem) ?? "",
            parts: try c.decodeIfPresent([QuestionPart].self, forKey: .parts) ?? [],
            template: try c.decodeIfPresent(MathTemplate.self, forKey: .template),
            figureIndices: try c.decodeIfPresent([Int].self, forKey: .figureIndices) ?? [],
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            difficulty: try c.decodeIfPresent(Int.self, forKey: .difficulty) ?? 3,
            continuesPrevious: try c.decodeIfPresent(Bool.self, forKey: .continuesPrevious) ?? false
        )
    }

    /// Appends a continuation to this draft: a part with the letter of this draft's last part finishes that
    /// part's options (the excerpt split them); every other part is added after the last one (relettered if
    /// its letter is taken). Figures and tags are merged.
    public func appending(_ continuation: QuestionDraft) -> QuestionDraft {
        var merged = self
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        for var part in continuation.parts {
            if let last = merged.parts.indices.last, merged.parts[last].id == part.id,
               merged.parts[last].answerKind == .choice, part.answerKind == .choice {
                merged.parts[last] = Self.joiningOptions(merged.parts[last], part)
                continue
            }
            let used = Set(merged.parts.map(\.id))
            if used.contains(part.id) { part.id = letters.first { !used.contains($0) } ?? "\(merged.parts.count + 1)" }
            merged.parts.append(part)
        }
        for index in continuation.figureIndices where !merged.figureIndices.contains(index) { merged.figureIndices.append(index) }
        merged.tags += continuation.tags.filter { !merged.tags.contains($0) }
        // Its template (if any) described only part of the question: the merged question is static.
        if continuation.template != nil || merged.template != nil { merged = merged.downgradedToStatic() }
        return merged
    }

    /// A draft is usable when it has a stem and at least one part (static or template).
    public var isUsable: Bool {
        !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!parts.isEmpty || !(template?.parts.isEmpty ?? true))
    }

    /// The draft without its template, with `kind` derived from the parts' answer kinds.
    public func downgradedToStatic() -> QuestionDraft {
        var copy = self
        copy.template = nil
        copy.kind = Self.staticKind(for: parts)
        return copy
    }

    /// Builds the bank record. A template makes the question `.mathTemplate`; a `.mathTemplate` draft without a
    /// template is stored as a static question.
    public func toQuestion(classId: ClassID, documentId: DocumentID?) -> Question {
        // Figures show the original numbers: a question that relies on them never regenerates.
        if template != nil, !figureIndices.isEmpty || parts.contains(where: { !($0.choiceFigureIndices ?? []).isEmpty }) {
            return downgradedToStatic().toQuestion(classId: classId, documentId: documentId)
        }
        var kind = self.kind
        var parts = self.parts
        if let template {
            kind = .mathTemplate
            if parts.isEmpty { parts = Self.placeholderParts(from: template) }
        } else if kind == .mathTemplate {
            kind = Self.staticKind(for: parts)
        }
        return Question(
            classId: classId,
            documentId: documentId,
            sourceRef: sourceRef,
            kind: kind,
            type: type,
            stem: stem,
            parts: parts,
            template: template,
            tags: tags,
            difficulty: difficulty
        )
    }

    /// One choice part whose options were split across two excerpts. Numbered labels ("Graph 4") continue the
    /// first half's numbering; the first half's answer stands unless it had none.
    static func joiningOptions(_ first: QuestionPart, _ rest: QuestionPart) -> QuestionPart {
        var joined = first
        let firstChoices = first.choices ?? []
        let numbered = try! NSRegularExpression(pattern: #"^(.*?)(\d+)$"#)
        var renamed: [String: String] = [:]
        let extra = (rest.choices ?? []).enumerated().map { offset, label -> String in
            let range = NSRange(label.startIndex..., in: label)
            guard let match = numbered.firstMatch(in: label, range: range), let prefix = Range(match.range(at: 1), in: label) else { return label }
            let relabelled = "\(label[prefix])\(firstChoices.count + offset + 1)"
            renamed[label] = relabelled
            return relabelled
        }
        joined.choices = firstChoices + extra
        if let a = first.choiceFigureIndices, let b = rest.choiceFigureIndices { joined.choiceFigureIndices = a + b }
        if (joined.answer.text ?? "").isEmpty, let answer = rest.answer.text { joined.answer.text = renamed[answer] ?? answer }
        return joined
    }

    static func staticKind(for parts: [QuestionPart]) -> QuestionKind {
        let kinds = Set(parts.map(\.answerKind))
        if kinds == [.numeric] { return .numeric }
        if kinds == [.choice] { return .multipleChoice }
        if kinds == [.freeResponse] { return .freeResponse }
        return .shortAnswer
    }

    /// Static parts mirroring a template's parts (used only when the agent omitted the concrete instance).
    private static func placeholderParts(from template: MathTemplate) -> [QuestionPart] {
        template.parts.map { part in
            QuestionPart(
                id: part.id, prompt: part.prompt, answerKind: part.answerKind,
                answer: AnswerSpec(latex: part.answerExpr), choices: part.choices, conditions: part.conditions
            )
        }
    }
}

// MARK: - Progress & result

/// Progress reported by `ImportAgent.run`.
public enum ImportProgress: Sendable, Equatable {
    case classifying
    case chunk(index: Int, count: Int)
    case generating(model: ClaudeModel)
    case escalated(reason: String)
    case figures(count: Int)
    case done
}

/// What an import produced. Figures are returned for the app to store and hand to `FigureAgent`; once they have
/// ids, `figureIndicesByQuestion` maps each question to the extraction indices it depends on.
public struct ImportResult: Sendable {
    public var questions: [Question]
    public var figures: [ExtractedFigure]
    public var figureIndicesByQuestion: [QuestionID: [Int]]
    public var classification: DocumentClassification
    public var modelUsed: ClaudeModel
    public var escalationReason: String?
    public var warnings: [String]
    public var usage: Usage

    public init(
        questions: [Question],
        figures: [ExtractedFigure],
        figureIndicesByQuestion: [QuestionID: [Int]] = [:],
        classification: DocumentClassification,
        modelUsed: ClaudeModel,
        escalationReason: String? = nil,
        warnings: [String] = [],
        usage: Usage = .zero
    ) {
        self.questions = questions
        self.figures = figures
        self.figureIndicesByQuestion = figureIndicesByQuestion
        self.classification = classification
        self.modelUsed = modelUsed
        self.escalationReason = escalationReason
        self.warnings = warnings
        self.usage = usage
    }
}

// MARK: - Tools

/// The import agent's tools.
public enum ImportTools {
    public static let classifyName = "classify_document"
    public static let emitName = "emit_questions"
    public static let escalateName = "escalate_model"

    public static let classifyDocument = ToolSpec(
        name: classifyName,
        description: "Record what kind of document this is. Call exactly once, before extracting anything.",
        inputSchema: [
            "type": "object",
            "properties": [
                "classification": [
                    "type": "string",
                    "enum": ["existingQuestions", "readingMaterial", "mixed"],
                    "description": "existingQuestions = homework/worksheet/exam; readingMaterial = textbook/notes/slides; mixed = both.",
                ],
                "reasoning": ["type": "string", "description": "One or two sentences."],
            ],
            "required": ["classification", "reasoning"],
        ]
    )

    public static let escalateModel = ToolSpec(
        name: escalateName,
        description: "Ask for a more capable model to handle this excerpt because it is beyond you (dense proofs, unresolved notation, templates you cannot write correctly). The excerpt is then reprocessed from scratch by the stronger model. Give a specific reason.",
        inputSchema: [
            "type": "object",
            "properties": ["reason": ["type": "string"]],
            "required": ["reason"],
        ]
    )

    public static let emitQuestions = ToolSpec(
        name: emitName,
        description: """
        Record the questions extracted or written for this excerpt. You may call it several times in batches. \
        Each question has: sourceRef (original label or location), kind (mathTemplate | shortAnswer | multipleChoice | \
        freeResponse | numeric), stem (shared setup, Markdown + $…$ LaTeX; may be empty when the part prompt is the whole \
        question), parts (ids "a","b",…; each with prompt, answerKind math|numeric|text|choice|freeResponse, answer \
        {latex | text | rubric, alternatives}, optional choices (with choiceFigures when the options are pictures), \
        conditions), type, optional template (never for a question with figures), figureIndices, tags, difficulty 1–5. \
        A template regenerates the question with new numbers: params with kinds {"type":"int","min","max"} / \
        {"type":"real","min","max","decimals"} / {"type":"choice","options":[…]}, constraints as LaTeX booleans over the \
        params ("a \\\\ne b"), stem/prompts with {a} {b} placeholders, and each part's answerExpr as a closed-form LaTeX \
        expression of the params that the engine evaluates ("2ax", "\\\\frac{a}{b}"). Always also fill parts with the \
        original numbers as a concrete instance.
        Example:
        {"questions":[{"sourceRef":"Homework 4 · Q3","kind":"mathTemplate","type":"Power rule","stem":"Let $f(x) = 3x^2 + 1$.",\
        "parts":[{"id":"a","prompt":"Find $f'(x)$.","answerKind":"math","answer":{"latex":"6x"},"conditions":{"simplified":true}},\
        {"id":"b","prompt":"Evaluate $f(1)$.","answerKind":"numeric","answer":{"latex":"4"}}],\
        "template":{"params":[{"name":"a","kind":{"type":"int","min":2,"max":9}},{"name":"b","kind":{"type":"int","min":1,"max":9}}],\
        "constraints":["a \\\\ne b"],"stem":"Let $f(x) = {a}x^2 + {b}$.",\
        "parts":[{"id":"a","prompt":"Find $f'(x)$.","answerExpr":"2ax","conditions":{"simplified":true}},\
        {"id":"b","prompt":"Evaluate $f(1)$.","answerExpr":"a+b","answerKind":"numeric"}],"seedNote":"Coefficient and constant vary."},\
        "tags":["derivatives","polynomials"],"difficulty":2},\
        {"sourceRef":"§2.1","kind":"multipleChoice","type":"Chain rule","stem":"","parts":[{"id":"a","prompt":"Which rule differentiates $f(g(x))$?",\
        "answerKind":"choice","answer":{"text":"Chain rule"},"choices":["Chain rule","Product rule","Quotient rule","Power rule"]}],\
        "tags":["derivatives"],"difficulty":1}]}
        """,
        inputSchema: [
            "type": "object",
            "properties": ["questions": ["type": "array", "items": questionSchema]],
            "required": ["questions"],
        ]
    )

    /// All three specs.
    public static let specs: [ToolSpec] = [classifyDocument, emitQuestions, escalateModel]

    static let conditionsSchema: JSONValue = [
        "type": "object",
        "description": "Grading requirements. Omit everything that does not apply.",
        "properties": [
            "roundingDecimals": ["type": "integer", "description": "Decimal places when rounding is allowed; omit for exact form."],
            "tolerance": ["type": "number", "description": "Absolute tolerance when rounding is allowed."],
            "rationalizedDenominator": ["type": "boolean"],
            "simplified": ["type": "boolean"],
            "factored": ["type": "boolean"],
            "expanded": ["type": "boolean"],
            "explicit": ["type": "boolean", "description": "Equation must be solved for the dependent variable."],
            "implicitAllowed": ["type": "boolean"],
            "exactRadicals": ["type": "boolean"],
            "units": ["type": "string", "description": "The unit the answer is given in, as plain text: \"kN\", \"lbf/in^2\", \"ft·lbf/s\", \"N·m\", \"m^3/h\", \"°\". Students may answer in any convertible unit or with the bare number."],
            "significantFigures": ["type": "integer", "description": "Engineering answers: the significant figures expected (usually 3)."],
            "relativeTolerance": ["type": "number", "description": "Engineering answers: relative tolerance accepted, e.g. 0.01 for 1 %."],
            "custom": ["type": "array", "items": ["type": "string"], "description": "Requirements you could not map, as short student-facing text."],
        ],
    ]

    static let answerSchema: JSONValue = [
        "type": "object",
        "properties": [
            "latex": ["type": "string", "description": "Canonical exact answer in LaTeX (math/numeric parts)."],
            "alternatives": ["type": "array", "items": ["type": "string"], "description": "Other accepted LaTeX forms."],
            "text": ["type": "string", "description": "Correct text / the correct option text (text/choice parts)."],
            "rubric": ["type": "string", "description": "Grading rubric for freeResponse parts."],
        ],
    ]

    static let answerKindSchema: JSONValue = ["type": "string", "enum": ["math", "numeric", "text", "choice", "freeResponse"]]

    static let partSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "\"a\", \"b\", …"],
            "prompt": ["type": "string", "description": "Markdown + LaTeX."],
            "answerKind": answerKindSchema,
            "answer": answerSchema,
            "choices": ["type": "array", "items": ["type": "string"], "description": "Options for choice parts."],
            "choiceFigures": [
                "type": "array", "items": ["type": "integer"],
                "description": "Choice parts whose options are pictures: the [figure N] number of each option, in the same order as choices.",
            ],
            "conditions": conditionsSchema,
        ],
        "required": ["id", "prompt", "answerKind", "answer"],
    ]

    static let paramSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Short name used as {name} in text and as a symbol in answerExpr."],
            "kind": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "enum": ["int", "real", "choice"]],
                    "min": ["type": "number"],
                    "max": ["type": "number"],
                    "decimals": ["type": "integer"],
                    "options": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["type"],
            ],
            "exclude": ["type": "array", "items": ["type": "number"], "description": "Values never drawn, e.g. [0]."],
            "original": ["type": "number", "description": "The value in the original problem. Required for numeric params: the app checks that every answerExpr at these values reproduces the static answer."],
        ],
        "required": ["name", "kind"],
    ]

    static let templatePartSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"],
            "prompt": ["type": "string", "description": "Prompt with {name} placeholders."],
            "answerExpr": ["type": "string", "description": "Closed-form LaTeX expression of the params, evaluated by the engine."],
            "answerKind": answerKindSchema,
            "choices": ["type": "array", "items": ["type": "string"]],
            "conditions": conditionsSchema,
        ],
        "required": ["id", "prompt", "answerExpr"],
    ]

    static let templateSchema: JSONValue = [
        "type": "object",
        "properties": [
            "params": ["type": "array", "items": paramSchema],
            "constraints": ["type": "array", "items": ["type": "string"], "description": "LaTeX booleans over the params that must hold."],
            "stem": ["type": "string", "description": "Stem with {name} placeholders."],
            "parts": ["type": "array", "items": templatePartSchema],
            "seedNote": ["type": "string"],
        ],
        "required": ["params", "stem", "parts"],
    ]

    static let questionSchema: JSONValue = [
        "type": "object",
        "properties": [
            "sourceRef": ["type": "string", "description": "Original label or location, e.g. \"Homework 4 · Q3\", \"§14.4 p. 912\"."],
            "kind": ["type": "string", "enum": ["mathTemplate", "shortAnswer", "multipleChoice", "freeResponse", "numeric"]],
            "type": [
                "type": "string",
                "description": "The problem type as the course names it (the technique or problem class): \"Initial value problems\", \"Separation of variables\", \"Chain rule\". Reuse a type already in use when it fits; otherwise name a new one. 1–4 words, sentence case.",
            ],
            "stem": ["type": "string", "description": "Shared setup in Markdown + LaTeX; may be empty."],
            "parts": ["type": "array", "items": partSchema, "minItems": 1],
            "template": templateSchema,
            "figureIndices": ["type": "array", "items": ["type": "integer"], "description": "[figure N] markers this question relies on."],
            "continuesPrevious": [
                "type": "boolean",
                "description": "True when the excerpt begins with further parts of the previous excerpt's last question: give only those parts (lettered as the document letters them) and its figures; they are appended to that question.",
            ],
            "tags": ["type": "array", "items": ["type": "string"]],
            "difficulty": ["type": "integer", "minimum": 1, "maximum": 5],
        ],
        "required": ["kind", "type", "stem", "parts"],
    ]
}

// MARK: - Chunking

/// A slice of a document sized for one agent call.
struct ImportChunk: Sendable, Equatable {
    var index: Int
    var text: String
    var pages: ClosedRange<Int>?
    var figureIndices: [Int]
}

/// Splits `DocumentContent` into chunks of roughly `tokenBudget` tokens (estimated at 3.5 characters per token).
enum ImportChunker {
    static let charactersPerToken = 3.5

    static func chunks(_ content: DocumentContent, tokenBudget: Int) -> [ImportChunk] {
        let figures = Dictionary(content.figures.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let budget = Int(Double(max(500, tokenBudget)) * charactersPerToken)
        var builder = Builder(budget: budget)
        var page: Int?
        for block in content.blocks {
            switch block {
            case .heading(let text, let level):
                builder.add(String(repeating: "#", count: max(1, min(6, level))) + " " + text, page: page)
            case .paragraph(let text):
                builder.add(text, page: page)
            case .list(let items):
                builder.add(items.map { "- \($0)" }.joined(separator: "\n"), page: page)
            case .table(let rows):
                builder.add(rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"), page: page)
            case .code(let code):
                builder.add("```\n\(code)\n```", page: page)
            case .pageBreak(let number):
                page = number
                builder.markPage(number)
            case .image(let index):
                let nearby = figures[index]?.nearbyText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                builder.add(nearby.isEmpty ? "[figure \(index)]" : "[figure \(index): \(nearby.prefix(200))]", page: page, figure: index)
            }
        }
        return builder.finish()
    }

    private struct Builder {
        let budget: Int
        private var chunks: [ImportChunk] = []
        private var pieces: [String] = []
        private var length = 0
        private var pages: ClosedRange<Int>?
        private var figures: [Int] = []
        /// A `[page N]` marker waiting for the next content piece, so it lands in the same chunk as that content.
        private var pendingMarker: String?

        init(budget: Int) { self.budget = budget }

        mutating func markPage(_ number: Int) {
            pendingMarker = "[page \(number)]"
        }

        mutating func add(_ text: String, page: Int?, figure: Int? = nil) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            for piece in split(trimmed) {
                let markerLength = pendingMarker.map { $0.count + 2 } ?? 0
                if length > 0, length + markerLength + piece.count + 2 > budget { close() }
                if let marker = pendingMarker {
                    pieces.append(marker)
                    length += marker.count + 2
                    pendingMarker = nil
                }
                pieces.append(piece)
                length += piece.count + 2
                if let page { pages = pages.map { min($0.lowerBound, page)...max($0.upperBound, page) } ?? page...page }
                if let figure, !figures.contains(figure) { figures.append(figure) }
            }
        }

        /// Hard-splits a single oversized piece.
        private func split(_ text: String) -> [String] {
            guard text.count > budget else { return [text] }
            var out: [String] = []
            var rest = Substring(text)
            while !rest.isEmpty {
                let end = rest.index(rest.startIndex, offsetBy: min(budget, rest.count))
                out.append(String(rest[..<end]))
                rest = rest[end...]
            }
            return out
        }

        private mutating func close() {
            guard !pieces.isEmpty else { return }
            chunks.append(ImportChunk(index: chunks.count, text: pieces.joined(separator: "\n\n"), pages: pages, figureIndices: figures))
            pieces = []
            length = 0
            pages = nil
            figures = []
        }

        mutating func finish() -> [ImportChunk] {
            close()
            return chunks
        }
    }
}

// MARK: - Agent

/// Turns a parsed document into questions: classifies it once, then per chunk asks the model to emit questions,
/// escalating to Opus when the model asks and the policy allows, validating every template through the injected
/// validator with one repair turn before downgrading a question to static.
public actor ImportAgent {
    public typealias TemplateValidator = @Sendable (MathTemplate) async -> [String]
    /// Checks a template against its question's static parts (the app passes `MathEngine.checkOriginals`).
    public typealias OriginalsCheck = @Sendable (MathTemplate, [QuestionPart]) async -> [String]

    public static let defaultToolRounds = 4

    private let client: ClaudeClient
    private let validator: TemplateValidator
    private let originalsCheck: OriginalsCheck?
    /// After an excerpt's questions are in, ask once whether any were left out (the app turns this on).
    private let checksCompleteness: Bool
    private let chunkTokenBudget: Int
    private let maxTokens: Int
    private let maxToolRounds: Int
    private let logger = Logger(subsystem: "com.thuban.study", category: "ImportAgent")

    /// - Parameters:
    ///   - validator: returns template problems (the app passes `MathEngine.validate`); empty means valid.
    ///   - chunkTokenBudget: approximate tokens of document text per agent call.
    public init(
        client: ClaudeClient,
        validator: @escaping TemplateValidator,
        originalsCheck: OriginalsCheck? = nil,
        checksCompleteness: Bool = false,
        chunkTokenBudget: Int = 12_000,
        maxTokens: Int = 32_768,
        maxToolRounds: Int = ImportAgent.defaultToolRounds
    ) {
        self.client = client
        self.validator = validator
        self.originalsCheck = originalsCheck
        self.checksCompleteness = checksCompleteness
        self.chunkTokenBudget = chunkTokenBudget
        self.maxTokens = maxTokens
        self.maxToolRounds = max(1, maxToolRounds)
    }

    /// Runs the whole pipeline for one document. Throws `ThubanError.cancelled` when the task is cancelled.
    /// `questionsPerChunk` is the Settings › Question bank hint for readings (how many questions an excerpt yields).
    /// `existingTypes` are the class's problem types so far (most used first); the agent reuses them where they fit.
    public func run(
        document: ImportedDocument,
        content: DocumentContent,
        classContext: String,
        existingTypes: [String] = [],
        policy: ModelPolicy,
        questionsPerChunk: Int = Prompts.defaultQuestionsPerChunk,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        do {
            return try await pipeline(
                document: document, content: content, classContext: classContext, existingTypes: existingTypes,
                policy: policy, questionsPerChunk: questionsPerChunk, progress: progress
            )
        } catch {
            throw ClaudeClient.normalize(error)
        }
    }

    private struct RunState {
        var model: ClaudeModel
        var canEscalate: Bool
        var escalationReason: String?
        var usage = Usage()
        var warnings: [String]
        var drafts: [QuestionDraft] = []
        /// Types the class already has, in prompt order, plus the ones this run has created so far.
        var knownTypes: [String]
        /// Each figure's image by extraction index, sent with the excerpt that shows it.
        var images: [Int: Data] = [:]
        /// PDFs: each page's render by page number, sent with the excerpt that covers it.
        var pageImages: [Int: Data] = [:]

        mutating func noteTypes(of drafts: [QuestionDraft]) {
            for draft in drafts where !draft.type.isEmpty
                && !knownTypes.contains(where: { $0.caseInsensitiveCompare(draft.type) == .orderedSame }) {
                knownTypes.append(draft.type)
            }
        }
    }

    private func pipeline(
        document: ImportedDocument,
        content: DocumentContent,
        classContext: String,
        existingTypes: [String],
        policy: ModelPolicy,
        questionsPerChunk: Int,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        var state = RunState(
            model: policy.effectiveModel,
            canEscalate: policy.escalationModel != nil,
            warnings: content.warnings,
            knownTypes: existingTypes.map(Question.normalizedType).filter { !$0.isEmpty }
        )
        state.images = Dictionary(content.figures.map { ($0.index, $0.pngData) }, uniquingKeysWith: { first, _ in first })
        state.pageImages = content.pageImages
        let chunks = ImportChunker.chunks(content, tokenBudget: chunkTokenBudget)
        guard let first = chunks.first else {
            state.warnings.append("No readable text was found in \(document.filename).")
            progress(.done)
            return ImportResult(questions: [], figures: content.figures, classification: .mixed, modelUsed: state.model, warnings: state.warnings)
        }

        progress(.classifying)
        let classification = try await classify(first, classContext: classContext, state: &state)
        let system = Prompts.importSystem(
            classContext: classContext, classification: classification, questionsPerChunk: questionsPerChunk
        )

        var failed: [ThubanError] = []
        for chunk in chunks {
            try Task.checkCancellation()
            progress(.chunk(index: chunk.index, count: chunks.count))
            do {
                try await process(chunk, system: system, policy: policy, state: &state, progress: progress)
            } catch {
                // Cancellation and credential problems end the run; any other failure costs only this chunk, so
                // the questions already extracted from earlier chunks survive.
                let failure = ClaudeClient.normalize(error)
                if failure == .cancelled || failure.isCredentialProblem { throw failure }
                logger.error("Chunk \(chunk.index + 1) of \(chunks.count) failed: \(failure.localizedDescription, privacy: .public)")
                failed.append(failure)
                state.warnings.append("Part \(chunk.index + 1) of \(chunks.count) could not be processed: \(failure.localizedDescription)")
            }
        }
        if failed.count == chunks.count, let last = failed.last { throw last }

        progress(.figures(count: content.figures.count))
        let result = assemble(document: document, content: content, classification: classification, state: state)
        progress(.done)
        return result
    }

    // MARK: Classification

    private func classify(_ chunk: ImportChunk, classContext: String, state: inout RunState) async throws -> DocumentClassification {
        let excerpt = String(chunk.text.prefix(12_000))
        let response = try await client.complete(
            model: state.model,
            system: Prompts.importSystem(classContext: classContext, classification: nil),
            messages: [.user("Excerpt from the document:\n\n\(excerpt)")],
            tools: [ImportTools.classifyDocument],
            maxTokens: 512,
            toolChoice: .tool(name: ImportTools.classifyName)
        )
        state.usage += response.usage
        let call = response.parts.compactMap(\.toolUseValue).first { $0.name == ImportTools.classifyName }
        if let raw = call?.input["classification"]?.stringValue, let classification = Self.classification(from: raw) {
            return classification
        }
        state.warnings.append("The document could not be classified; treating it as mixed.")
        return .mixed
    }

    static func classification(from raw: String) -> DocumentClassification? {
        let key = raw.lowercased().filter { $0.isLetter }
        return DocumentClassification.allCases.first { $0.rawValue.lowercased() == key }
    }

    // MARK: Per chunk

    private func process(
        _ chunk: ImportChunk,
        system: String,
        policy: ModelPolicy,
        state: inout RunState,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws {
        progress(.generating(model: state.model))
        var outcome = try await generate(chunk, system: system, state: &state)
        if case .escalate(let reason) = outcome, let stronger = policy.escalationModel {
            logger.notice("Escalating chunk \(chunk.index) to \(stronger.rawValue, privacy: .public): \(reason, privacy: .public)")
            state.model = stronger
            state.canEscalate = false
            state.escalationReason = state.escalationReason ?? reason
            progress(.escalated(reason: reason))
            progress(.generating(model: stronger))
            outcome = try await generate(chunk, system: system, state: &state)
        }
        guard case .questions(let drafts, let conversation) = outcome else {
            state.warnings.append("Chunk \(chunk.index + 1) produced no questions.")
            return
        }
        let checked = try await validateAndRepair(drafts, conversation: conversation, system: system, state: &state)
        state.noteTypes(of: checked)
        // Parts that continue the previous excerpt's last question are appended to it (whatever order the agent
        // emitted this excerpt's questions in).
        let previousLast = state.drafts.indices.last
        for draft in checked.map({ Self.attachFigures($0, chunk: chunk) }) {
            if draft.continuesPrevious, let index = previousLast, !draft.parts.isEmpty {
                state.drafts[index] = state.drafts[index].appending(draft)
            } else {
                state.drafts.append(draft)
            }
        }
    }

    private enum ChunkOutcome {
        case questions([QuestionDraft], conversation: [ChatMessage])
        case escalate(reason: String)
    }

    private func generate(_ chunk: ImportChunk, system: String, state: inout RunState) async throws -> ChunkOutcome {
        var messages: [ChatMessage] = [.user(Self.chunkContent(Self.chunkPrompt(chunk, knownTypes: state.knownTypes, previous: state.drafts.last),
                                                               chunk: chunk, images: state.images, pageImages: state.pageImages))]
        var drafts: [QuestionDraft] = []
        var nudged = false
        for _ in 0..<maxToolRounds {
            let response = try await client.complete(
                model: state.model, system: system, messages: messages,
                tools: ImportTools.specs, maxTokens: maxTokens
            )
            state.usage += response.usage
            let calls = response.parts.compactMap(\.toolUseValue)
            let truncated = response.stopReason == "max_tokens"
            if ProcessInfo.processInfo.environment["THUBAN_IMPORT_DEBUG"] != nil {
                let text = response.parts.compactMap { part -> String? in if case .text(let t) = part { return t } else { return nil } }.joined()
                FileHandle.standardError.write(Data("IMPORTDEBUG chunk \(chunk.index + 1): round stop=\(response.stopReason ?? "-") calls=\(calls.map(\.name)) text=\(text.prefix(300))\n".utf8))
            }
            if calls.isEmpty, !truncated {
                guard !nudged, drafts.isEmpty || checksCompleteness else { break }
                nudged = true
                messages.append(.assistant(Self.assistantParts(response.parts)))
                if drafts.isEmpty {
                    messages.append(.user("Call emit_questions now with the questions for this excerpt."))
                } else {
                    // One completeness pass: questions are easily left out when they are emitted in batches.
                    messages.append(.user("Recorded so far: \(drafts.map { $0.sourceRef ?? String($0.stem.prefix(40)) }.joined(separator: "; ")). "
                        + "Check the excerpt (its text and images) against that list: if any question, problem or part is missing, "
                        + "call emit_questions with only the missing ones. Otherwise reply with the single word DONE."))
                }
                continue
            }
            messages.append(.assistant(Self.assistantParts(response.parts)))
            var results: [ContentPart] = []
            for call in calls {
                switch call.name {
                case ImportTools.emitName:
                    let decoded = Self.decodeDrafts(call.input)
                    drafts.append(contentsOf: decoded.drafts)
                    if ProcessInfo.processInfo.environment["THUBAN_IMPORT_DEBUG"] != nil {
                        let line = "IMPORTDEBUG chunk \(chunk.index + 1): emit \(call.input["questions"]?.arrayValue?.count ?? -1) → \(decoded.drafts.map { $0.sourceRef ?? "?" }) errors \(decoded.errors) stop \(response.stopReason ?? "-")\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                    results.append(Self.emitResult(call.id, decoded))
                case ImportTools.escalateName:
                    let reason = call.input["reason"]?.stringValue ?? "The model asked for a stronger model."
                    if state.canEscalate { return .escalate(reason: reason) }
                    results.append(.toolResult(
                        toolUseId: call.id,
                        content: "Escalation is not available for this run. Continue with your best effort and call emit_questions.",
                        isError: false
                    ))
                case ImportTools.classifyName:
                    results.append(.toolResult(toolUseId: call.id, content: "The classification is already recorded; continue.", isError: false))
                default:
                    results.append(.toolResult(toolUseId: call.id, content: "Unknown tool '\(call.name)'.", isError: true))
                }
            }
            if truncated {
                // The reply hit the output limit; the decoder dropped the cut-off emit_questions block.
                logger.notice("Chunk \(chunk.index + 1) reply hit the output-token limit (\(self.maxTokens, privacy: .public)); asking for smaller batches")
                results.append(.text(Self.truncationNote(recorded: drafts.count)))
                messages.append(.user(results))
                continue
            }
            messages.append(.user(results))
            if response.stopReason != "tool_use" { break }
        }
        return .questions(drafts, conversation: messages)
    }

    static func truncationNote(recorded: Int) -> String {
        let kept = recorded == 0
            ? "No questions have been recorded yet."
            : "\(recorded) question\(recorded == 1 ? " is" : "s are") already recorded; do not repeat \(recorded == 1 ? "it" : "them")."
        return "Your reply was cut off by the output limit, so the emit_questions call in it was discarded. \(kept) "
            + "Call emit_questions again for the remaining questions in batches of at most 4 questions per call, using several calls."
    }

    // MARK: Validation & repair

    private func validateAndRepair(
        _ drafts: [QuestionDraft],
        conversation: [ChatMessage],
        system: String,
        state: inout RunState
    ) async throws -> [QuestionDraft] {
        var out = drafts
        var failing: [(index: Int, errors: [String])] = []
        for (index, draft) in drafts.enumerated() {
            guard let template = draft.template else { continue }
            var errors = await validator(template)
            // A template must reproduce the question it was written for.
            if errors.isEmpty, let originalsCheck { errors = await originalsCheck(template, draft.parts) }
            if !errors.isEmpty { failing.append((index, errors)) }
        }
        guard !failing.isEmpty else { return out }

        let repaired = try await repairTurn(failing.map { (out[$0.index], $0.errors) }, conversation: conversation, system: system, state: &state)
        // Each re-emitted draft is claimed once: by sourceRef, else by stem, else by position when the model
        // returned exactly one draft per failing question (it may drop or reorder them).
        var candidates: [QuestionDraft?] = repaired
        let countsMatch = repaired.count == failing.count
        for (position, failure) in failing.enumerated() {
            let original = out[failure.index]
            if let slot = Self.matchRepair(for: original, in: candidates, position: countsMatch ? position : nil),
               let candidate = candidates[slot] {
                candidates[slot] = nil
                if let fixed = await accept(candidate) {
                    out[failure.index] = fixed
                    continue
                }
            }
            out[failure.index] = original.downgradedToStatic()
            let label = original.sourceRef ?? String(original.stem.prefix(60))
            state.warnings.append("Template rejected for \"\(label)\" (\(failure.errors.joined(separator: "; "))); stored as a static question.")
        }
        return out
    }

    private func repairTurn(
        _ failures: [(draft: QuestionDraft, errors: [String])],
        conversation: [ChatMessage],
        system: String,
        state: inout RunState
    ) async throws -> [QuestionDraft] {
        var messages = conversation
        if messages.last?.role == "user", let last = messages.popLast() {
            // Fold the repair request into the pending tool-result turn so roles keep alternating.
            messages.append(.user(last.content + [.text(Prompts.importRepair(failures.map { ($0.draft.sourceRef, $0.draft.stem, $0.errors) }))]))
        } else {
            messages.append(.user(Prompts.importRepair(failures.map { ($0.draft.sourceRef, $0.draft.stem, $0.errors) })))
        }
        let response = try await client.complete(
            model: state.model, system: system, messages: messages,
            tools: [ImportTools.emitQuestions], maxTokens: maxTokens,
            toolChoice: .tool(name: ImportTools.emitName)
        )
        state.usage += response.usage
        return response.parts.compactMap(\.toolUseValue)
            .filter { $0.name == ImportTools.emitName }
            .flatMap { Self.decodeDrafts($0.input).drafts }
    }

    /// The slot of the re-emitted draft for `original`, or `nil` when none can be attributed to it.
    static func matchRepair(for original: QuestionDraft, in candidates: [QuestionDraft?], position: Int?) -> Int? {
        let ref = normalizedKey(original.sourceRef ?? "")
        // A candidate whose sourceRef contradicts the original's is never attributed to it.
        func compatible(_ candidate: QuestionDraft) -> Bool {
            let candidateRef = normalizedKey(candidate.sourceRef ?? "")
            return ref.isEmpty || candidateRef.isEmpty || candidateRef == ref
        }
        if !ref.isEmpty, let index = candidates.firstIndex(where: { $0.map { normalizedKey($0.sourceRef ?? "") == ref } ?? false }) {
            return index
        }
        let stem = normalizedKey(original.stem)
        if !stem.isEmpty, let index = candidates.firstIndex(where: { $0.map { compatible($0) && normalizedKey($0.stem) == stem } ?? false }) {
            return index
        }
        if let position, position < candidates.count, let candidate = candidates[position], compatible(candidate) { return position }
        return nil
    }

    /// Lower-cased, whitespace-collapsed and capped, so cosmetic changes by the model still match.
    static func normalizedKey(_ text: String) -> String {
        String(text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }

    /// A repaired draft is accepted when its template now validates, or when it was resubmitted as static.
    private func accept(_ candidate: QuestionDraft) async -> QuestionDraft? {
        guard candidate.isUsable else { return nil }
        guard let template = candidate.template else {
            return candidate.kind == .mathTemplate ? nil : candidate
        }
        guard await validator(template).isEmpty else { return nil }
        if let originalsCheck, !(await originalsCheck(template, candidate.parts)).isEmpty { return nil }
        return candidate
    }

    // MARK: Assembly

    private func assemble(
        document: ImportedDocument,
        content: DocumentContent,
        classification: DocumentClassification,
        state: RunState
    ) -> ImportResult {
        var questions: [Question] = []
        var figureMap: [QuestionID: [Int]] = [:]
        let known = Set(content.figures.map(\.index))
        for draft in state.drafts where draft.isUsable {
            let question = draft.toQuestion(classId: document.classId, documentId: document.id)
            questions.append(question)
            let indices = draft.figureIndices.filter { known.contains($0) }
            if !indices.isEmpty { figureMap[question.id] = indices }
        }
        return ImportResult(
            questions: questions,
            figures: content.figures,
            figureIndicesByQuestion: figureMap,
            classification: classification,
            modelUsed: state.model,
            escalationReason: state.escalationReason,
            warnings: state.warnings,
            usage: state.usage
        )
    }

    // MARK: Helpers

    /// The excerpt, preceded by the class's problem types so far so the agent reuses them (up to 60 listed).
    static func chunkPrompt(_ chunk: ImportChunk, knownTypes: [String] = [], previous: QuestionDraft? = nil) -> String {
        var header = "Excerpt \(chunk.index + 1)"
        if let pages = chunk.pages {
            header += pages.count == 1 ? " (page \(pages.lowerBound))" : " (pages \(pages.lowerBound)–\(pages.upperBound))"
        }
        var prompt = ""
        if !knownTypes.isEmpty {
            let listed = knownTypes.prefix(60).map { "\"\($0)\"" }.joined(separator: ", ")
            prompt += "Question types already in this class (reuse when one fits, add a new type only when none does): \(listed)\n\n"
        }
        if let previous, chunk.index > 0 {
            let label = previous.sourceRef.map { "\"\($0)\"" } ?? "untitled"
            let parts = previous.parts.map { part -> String in
                guard part.answerKind == .choice, let choices = part.choices, !choices.isEmpty else { return part.id }
                return "\(part.id) (\(choices.count) option\(choices.count == 1 ? "" : "s") so far: \(choices.joined(separator: ", ")))"
            }.joined(separator: "; ")
            prompt += "The previous excerpt ended with question \(label) — parts \(parts). If this excerpt begins inside that question, "
                + "emit what continues it as one question with \"continuesPrevious\": true: new parts under their own letters, and, "
                + "when it begins among the last part's options, that part again under the same letter with only its remaining "
                + "options (numbering continued) and their [figure N]s.\n\n"
        }
        return prompt + "\(header):\n\n\(chunk.text)"
    }

    /// Most images sent with one excerpt (the rest are named only by their markers).
    static let maxImagesPerChunk = 20

    /// The excerpt's text followed by its figures' images, each labelled with its marker: problem statements,
    /// given values and dimensions are often only in an image (a pasted textbook problem, a labelled diagram).
    static func chunkContent(_ prompt: String, chunk: ImportChunk, images: [Int: Data], pageImages: [Int: Data] = [:]) -> [ContentPart] {
        var parts: [ContentPart] = [.text(prompt)]
        // The pages themselves first: tables keep their columns (empty cells included) and drawn equations their
        // layout, which the text layer above loses.
        var budget = maxImagesPerChunk
        if let pages = chunk.pages {
            let rendered = pages.filter { pageImages[$0] != nil }.prefix(budget / 2 + 2)
            if !rendered.isEmpty {
                parts.append(.text("The excerpt's pages as rendered (trust these over the extracted text for tables, empty table cells, equations and layout):"))
                for page in rendered {
                    parts.append(.text("[page \(page)]"))
                    parts.append(.image(mediaType: "image/png", base64: pageImages[page]!.base64EncodedString()))
                }
                budget -= rendered.count
            }
        }
        let shown = chunk.figureIndices.filter { images[$0] != nil }.prefix(max(0, budget))
        guard !shown.isEmpty else { return parts }
        parts.append(.text("The images in this excerpt, in order. Read problem statements, given values, dimensions and angles from them."))
        for index in shown {
            guard let png = images[index] else { continue }
            parts.append(.text("[figure \(index)]"))
            parts.append(.image(mediaType: "image/png", base64: png.base64EncodedString()))
        }
        if chunk.figureIndices.count > shown.count {
            parts.append(.text("(\(chunk.figureIndices.count - shown.count) more images in this excerpt are not shown; use their markers and nearby text.)"))
        }
        return parts
    }

    /// Keeps figure references that occur in the chunk (the agent sometimes cites indices from elsewhere).
    static func attachFigures(_ draft: QuestionDraft, chunk: ImportChunk) -> QuestionDraft {
        var copy = draft
        copy.figureIndices = draft.figureIndices.filter { chunk.figureIndices.contains($0) }
        for index in copy.parts.indices {
            guard let options = copy.parts[index].choiceFigureIndices, !options.isEmpty else { continue }
            // Options must be pictures in this excerpt, one per choice; otherwise the part stays a text choice.
            if options.allSatisfy(chunk.figureIndices.contains), options.count == (copy.parts[index].choices ?? []).count {
                for option in options where !copy.figureIndices.contains(option) { copy.figureIndices.append(option) }
            } else {
                copy.parts[index].choiceFigureIndices = nil
            }
        }
        return copy
    }

    static func assistantParts(_ parts: [ContentPart]) -> [ContentPart] {
        let kept = parts.filter { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
        return kept.isEmpty ? [.text("(no output)")] : kept
    }

    struct DecodedDrafts {
        var drafts: [QuestionDraft] = []
        var errors: [String] = []
    }

    /// Decodes `emit_questions` input item by item so one bad question does not lose the batch.
    static func decodeDrafts(_ input: JSONValue) -> DecodedDrafts {
        var out = DecodedDrafts()
        guard let items = input["questions"]?.arrayValue else {
            out.errors.append("emit_questions needs a `questions` array.")
            return out
        }
        let decoder = JSONDecoder()
        for (index, item) in items.enumerated() {
            do {
                let draft = try decoder.decode(QuestionDraft.self, from: try item.data())
                if draft.isUsable {
                    out.drafts.append(draft)
                } else {
                    out.errors.append("Question \(index + 1) has no stem or no parts.")
                }
            } catch {
                out.errors.append("Question \(index + 1) could not be read: \(Self.describe(error))")
            }
        }
        return out
    }

    private static func emitResult(_ id: String, _ decoded: DecodedDrafts) -> ContentPart {
        var text = "Recorded \(decoded.drafts.count) question\(decoded.drafts.count == 1 ? "" : "s")."
        if !decoded.errors.isEmpty {
            text += " Problems: " + decoded.errors.joined(separator: " ")
            text += " Re-emit only the problem questions if they matter."
        }
        return .toolResult(toolUseId: id, content: text, isError: decoded.drafts.isEmpty && !decoded.errors.isEmpty)
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let ctx), .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .keyNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }
}
