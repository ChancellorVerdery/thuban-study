import Foundation

public enum QuestionKind: String, Codable, Sendable, CaseIterable {
    case mathTemplate, shortAnswer, multipleChoice, freeResponse, numeric
}

public enum ProgressStatus: String, Codable, Sendable, CaseIterable {
    case new, learning, mastered, needsReview
}

/// How a part is answered. Choices for `.choice` live on the owning `QuestionPart` / `InstancePart`.
public enum AnswerKind: String, Codable, Sendable, CaseIterable {
    case math, numeric, text, choice, freeResponse

    /// Parts the MathEngine can grade on its own; `.freeResponse` is always tutor-graded.
    public var isAutoGradable: Bool { self != .freeResponse }
}

/// The expected answer of a part. See the MathEngine grading rules.
public struct AnswerSpec: Codable, Sendable, Equatable {
    /// Canonical answer (static questions) or an engine expression for templates.
    public var latex: String?
    /// Additional accepted LaTeX forms.
    public var alternatives: [String]
    /// For `.text` / `.choice` (the correct option text).
    public var text: String?
    /// For `.freeResponse` (tutor/agent-graded, never auto-graded).
    public var rubric: String?

    public init(latex: String? = nil, alternatives: [String] = [], text: String? = nil, rubric: String? = nil) {
        self.latex = latex
        self.alternatives = alternatives
        self.text = text
        self.rubric = rubric
    }

    private enum CodingKeys: String, CodingKey { case latex, alternatives, text, rubric }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latex = try c.decodeIfPresent(String.self, forKey: .latex)
        alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text)
        rubric = try c.decodeIfPresent(String.self, forKey: .rubric)
    }
}

/// Grading conditions a question may impose. All false/nil ⇒ "any algebraically equivalent form is accepted"
/// (with exact form still required, since `roundingDecimals == nil`).
public struct AnswerConditions: Codable, Sendable, Equatable {
    /// `nil` ⇒ exact form required (decimals only if exactly equal, e.g. 0.5 == 1/2).
    public var roundingDecimals: Int?
    /// Absolute tolerance when rounding is allowed.
    public var tolerance: Double?
    /// No radicals in any denominator.
    public var rationalizedDenominator: Bool
    /// Must be in simplified form.
    public var simplified: Bool
    /// Must be fully factored.
    public var factored: Bool
    /// Must be expanded (no parenthesised products).
    public var expanded: Bool
    /// Equation must be solved for the dependent variable (y = …).
    public var explicit: Bool
    /// Implicit equations accepted (default true unless `explicit`).
    public var implicitAllowed: Bool
    /// Radicals must stay symbolic (default when `roundingDecimals == nil`).
    public var exactRadicals: Bool
    /// Required unit text, if any.
    public var units: String?
    /// Free-text conditions the import agent could not map (shown to the student, checked by the tutor).
    public var custom: [String]

    /// No extra conditions: any algebraically equivalent exact form is accepted.
    public static let none = AnswerConditions()

    public init(
        roundingDecimals: Int? = nil,
        tolerance: Double? = nil,
        rationalizedDenominator: Bool = false,
        simplified: Bool = false,
        factored: Bool = false,
        expanded: Bool = false,
        explicit: Bool = false,
        implicitAllowed: Bool? = nil,
        exactRadicals: Bool? = nil,
        units: String? = nil,
        custom: [String] = []
    ) {
        self.roundingDecimals = roundingDecimals
        self.tolerance = tolerance
        self.rationalizedDenominator = rationalizedDenominator
        self.simplified = simplified
        self.factored = factored
        self.expanded = expanded
        self.explicit = explicit
        self.implicitAllowed = implicitAllowed ?? !explicit
        self.exactRadicals = exactRadicals ?? (roundingDecimals == nil)
        self.units = units
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case roundingDecimals, tolerance, rationalizedDenominator, simplified, factored, expanded, explicit,
             implicitAllowed, exactRadicals, units, custom
    }

    /// Lenient decoding: every key is optional so agent-written JSON can omit anything that is at its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rounding = try c.decodeIfPresent(Int.self, forKey: .roundingDecimals)
        let explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        self.init(
            roundingDecimals: rounding,
            tolerance: try c.decodeIfPresent(Double.self, forKey: .tolerance),
            rationalizedDenominator: try c.decodeIfPresent(Bool.self, forKey: .rationalizedDenominator) ?? false,
            simplified: try c.decodeIfPresent(Bool.self, forKey: .simplified) ?? false,
            factored: try c.decodeIfPresent(Bool.self, forKey: .factored) ?? false,
            expanded: try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? false,
            explicit: explicit,
            implicitAllowed: try c.decodeIfPresent(Bool.self, forKey: .implicitAllowed),
            exactRadicals: try c.decodeIfPresent(Bool.self, forKey: .exactRadicals),
            units: try c.decodeIfPresent(String.self, forKey: .units),
            custom: try c.decodeIfPresent([String].self, forKey: .custom) ?? []
        )
    }

    /// True when nothing beyond "exact, equivalent form" is required.
    public var isDefault: Bool { self == .none }

    /// Student-facing lines, one per active condition.
    public var summaryItems: [String] {
        var items: [String] = []
        if let decimals = roundingDecimals {
            switch decimals {
            case 0: items.append("Round to the nearest whole number")
            case 1: items.append("Round to 1 decimal place")
            default: items.append("Round to \(decimals) decimal places")
            }
            if let tolerance = tolerance {
                items.append("Tolerance ±\(Self.format(tolerance))")
            }
            if exactRadicals { items.append("Keep radicals exact") }
        } else {
            items.append("Exact form required")
        }
        if rationalizedDenominator { items.append("Rationalized denominator") }
        if simplified { items.append("Simplified form") }
        if factored { items.append("Fully factored") }
        if expanded { items.append("Expanded form") }
        if explicit { items.append("Solved explicitly (y = …)") }
        else if !implicitAllowed { items.append("No implicit equations") }
        if let units = units, !units.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append("Include units (\(units))")
        }
        items.append(contentsOf: custom.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return items
    }

    /// Student-facing summary, e.g. "Exact form required · Rationalized denominator".
    public var summary: String { summaryItems.joined(separator: " · ") }

    private static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// A question as stored in the bank. `parts` hold the static prompt/answer; math questions additionally carry a
/// `template` that the MathEngine instantiates with fresh numbers.
public struct Question: Codable, Identifiable, Sendable, Equatable {
    public var id: QuestionID
    public var classId: ClassID
    public var documentId: DocumentID?
    /// "Homework 4 · Q3", "§14.4 p. 912"
    public var sourceRef: String?
    public var kind: QuestionKind
    /// Markdown with $…$ / $$…$$ LaTeX.
    public var stem: String
    /// At least one part.
    public var parts: [QuestionPart]
    /// Present iff `kind == .mathTemplate`.
    public var template: MathTemplate?
    public var figureIds: [FigureID]
    public var tags: [String]
    /// 1–5
    public var difficulty: Int
    public var createdAt: Date

    public init(
        id: QuestionID = .new(),
        classId: ClassID,
        documentId: DocumentID? = nil,
        sourceRef: String? = nil,
        kind: QuestionKind,
        stem: String,
        parts: [QuestionPart],
        template: MathTemplate? = nil,
        figureIds: [FigureID] = [],
        tags: [String] = [],
        difficulty: Int = 3,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.classId = classId
        self.documentId = documentId
        self.sourceRef = sourceRef
        self.kind = kind
        self.stem = stem
        self.parts = parts
        self.template = template
        self.figureIds = figureIds
        self.tags = tags
        self.difficulty = difficulty
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, classId, documentId, sourceRef, kind, stem, parts, template, figureIds, tags, difficulty, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(QuestionID.self, forKey: .id)
        classId = try c.decode(ClassID.self, forKey: .classId)
        documentId = try c.decodeIfPresent(DocumentID.self, forKey: .documentId)
        sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
        kind = try c.decode(QuestionKind.self, forKey: .kind)
        stem = try c.decode(String.self, forKey: .stem)
        parts = try c.decodeIfPresent([QuestionPart].self, forKey: .parts) ?? []
        template = try c.decodeIfPresent(MathTemplate.self, forKey: .template)
        figureIds = try c.decodeIfPresent([FigureID].self, forKey: .figureIds) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        difficulty = try c.decodeIfPresent(Int.self, forKey: .difficulty) ?? 3
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct QuestionPart: Codable, Identifiable, Sendable, Equatable {
    /// "a", "b", …
    public var id: String
    /// Markdown + LaTeX.
    public var prompt: String
    public var answerKind: AnswerKind
    public var answer: AnswerSpec
    /// For `.choice`.
    public var choices: [String]?
    public var conditions: AnswerConditions

    public init(
        id: String,
        prompt: String,
        answerKind: AnswerKind = .math,
        answer: AnswerSpec = AnswerSpec(),
        choices: [String]? = nil,
        conditions: AnswerConditions = .none
    ) {
        self.id = id
        self.prompt = prompt
        self.answerKind = answerKind
        self.answer = answer
        self.choices = choices
        self.conditions = conditions
    }

    private enum CodingKeys: String, CodingKey { case id, prompt, answerKind, answer, choices, conditions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        answerKind = try c.decodeIfPresent(AnswerKind.self, forKey: .answerKind) ?? .math
        answer = try c.decodeIfPresent(AnswerSpec.self, forKey: .answer) ?? AnswerSpec()
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        conditions = try c.decodeIfPresent(AnswerConditions.self, forKey: .conditions) ?? .none
    }
}

// MARK: - Templates

/// A sampled parameter of a `MathTemplate`.
public struct TemplateParam: Codable, Sendable, Equatable {
    /// How a parameter is drawn. Encoded with a `type` discriminator:
    /// `{"type":"int","min":1,"max":9}`, `{"type":"real","min":0,"max":1,"decimals":2}`, `{"type":"choice","options":["x","y"]}`.
    public enum Kind: Codable, Sendable, Equatable {
        case int(min: Int, max: Int)
        case real(min: Double, max: Double, decimals: Int)
        case choice([String])

        private enum CodingKeys: String, CodingKey { case type, min, max, decimals, options }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "int":
                self = .int(
                    min: try c.decodeIfPresent(Int.self, forKey: .min) ?? 1,
                    max: try c.decodeIfPresent(Int.self, forKey: .max) ?? 9
                )
            case "real":
                self = .real(
                    min: try c.decodeIfPresent(Double.self, forKey: .min) ?? 0,
                    max: try c.decodeIfPresent(Double.self, forKey: .max) ?? 1,
                    decimals: try c.decodeIfPresent(Int.self, forKey: .decimals) ?? 2
                )
            case "choice":
                self = .choice(try c.decodeIfPresent([String].self, forKey: .options) ?? [])
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: c, debugDescription: "Unknown template parameter type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .int(min, max):
                try c.encode("int", forKey: .type)
                try c.encode(min, forKey: .min)
                try c.encode(max, forKey: .max)
            case let .real(min, max, decimals):
                try c.encode("real", forKey: .type)
                try c.encode(min, forKey: .min)
                try c.encode(max, forKey: .max)
                try c.encode(decimals, forKey: .decimals)
            case let .choice(options):
                try c.encode("choice", forKey: .type)
                try c.encode(options, forKey: .options)
            }
        }
    }

    public var name: String
    public var kind: Kind
    /// Values never drawn (e.g. 0 for a divisor).
    public var exclude: [Double]

    public init(name: String, kind: Kind, exclude: [Double] = []) {
        self.name = name
        self.kind = kind
        self.exclude = exclude
    }

    private enum CodingKeys: String, CodingKey { case name, kind, exclude }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        exclude = try c.decodeIfPresent([Double].self, forKey: .exclude) ?? []
    }
}

/// One part of a template: prompt with `{name}` placeholders and an engine-evaluated answer expression.
public struct TemplatePart: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    /// Prompt with placeholders.
    public var prompt: String
    /// LaTeX, engine-evaluated after substitution.
    public var answerExpr: String
    public var answerKind: AnswerKind
    /// For `.choice`; may contain placeholders.
    public var choices: [String]?
    public var conditions: AnswerConditions

    public init(
        id: String,
        prompt: String,
        answerExpr: String,
        answerKind: AnswerKind = .math,
        choices: [String]? = nil,
        conditions: AnswerConditions = .none
    ) {
        self.id = id
        self.prompt = prompt
        self.answerExpr = answerExpr
        self.answerKind = answerKind
        self.choices = choices
        self.conditions = conditions
    }

    private enum CodingKeys: String, CodingKey { case id, prompt, answerExpr, answerKind, choices, conditions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        answerExpr = try c.decodeIfPresent(String.self, forKey: .answerExpr) ?? ""
        answerKind = try c.decodeIfPresent(AnswerKind.self, forKey: .answerKind) ?? .math
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        conditions = try c.decodeIfPresent(AnswerConditions.self, forKey: .conditions) ?? .none
    }
}

/// Math-engine template. `params` are sampled, `constraints` filtered, then every `{name}` in stem/prompts/answers
/// is substituted and answer expressions are evaluated by the engine.
public struct MathTemplate: Codable, Sendable, Equatable {
    public var params: [TemplateParam]
    /// Engine boolean expressions in LaTeX with params, e.g. "a \\ne b", "a^2 - 4b > 0".
    public var constraints: [String]
    /// With `{a}`, `{b}` placeholders.
    public var stem: String
    public var parts: [TemplatePart]
    /// Agent's note on what varies.
    public var seedNote: String?

    public init(
        params: [TemplateParam],
        constraints: [String] = [],
        stem: String,
        parts: [TemplatePart],
        seedNote: String? = nil
    ) {
        self.params = params
        self.constraints = constraints
        self.stem = stem
        self.parts = parts
        self.seedNote = seedNote
    }

    private enum CodingKeys: String, CodingKey { case params, constraints, stem, parts, seedNote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        params = try c.decodeIfPresent([TemplateParam].self, forKey: .params) ?? []
        constraints = try c.decodeIfPresent([String].self, forKey: .constraints) ?? []
        stem = try c.decodeIfPresent(String.self, forKey: .stem) ?? ""
        parts = try c.decodeIfPresent([TemplatePart].self, forKey: .parts) ?? []
        seedNote = try c.decodeIfPresent(String.self, forKey: .seedNote)
    }
}

// MARK: - Instances

/// One resolved part of a `QuestionInstance`. `answerLatex` is kept in memory for grading and never shown.
public struct InstancePart: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var answerLatex: String
    public var answerKind: AnswerKind
    public var choices: [String]?
    public var conditions: AnswerConditions

    public init(
        id: String,
        prompt: String,
        answerLatex: String,
        answerKind: AnswerKind = .math,
        choices: [String]? = nil,
        conditions: AnswerConditions = .none
    ) {
        self.id = id
        self.prompt = prompt
        self.answerLatex = answerLatex
        self.answerKind = answerKind
        self.choices = choices
        self.conditions = conditions
    }
}

/// What the student sees: a question with concrete numbers.
public struct QuestionInstance: Codable, Sendable, Equatable {
    public var questionId: QuestionID
    /// 8 hex chars.
    public var seed: String
    public var stem: String
    public var parts: [InstancePart]
    /// Parameter name → rendered value.
    public var params: [String: String]

    public init(
        questionId: QuestionID,
        seed: String,
        stem: String,
        parts: [InstancePart],
        params: [String: String] = [:]
    ) {
        self.questionId = questionId
        self.seed = seed
        self.stem = stem
        self.parts = parts
        self.params = params
    }

    /// Builds the instance for a static (non-template) question: prompts and answers copied verbatim.
    public init(static question: Question, seed: String = "00000000") {
        self.questionId = question.id
        self.seed = seed
        self.stem = question.stem
        self.parts = question.parts.map { part in
            InstancePart(
                id: part.id,
                prompt: part.prompt,
                answerLatex: part.answer.latex ?? part.answer.text ?? "",
                answerKind: part.answerKind,
                choices: part.choices,
                conditions: part.conditions
            )
        }
        self.params = [:]
    }
}
