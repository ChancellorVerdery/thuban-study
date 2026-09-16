import Foundation

/// The Claude models the app can call. Raw values are the API model ids.
public enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case sonnet = "claude-sonnet-5"
    case opus = "claude-opus-5"
    case haiku = "claude-haiku-4-5-20251001"

    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Sonnet"
        case .opus: return "Claude Opus"
        case .haiku: return "Claude Haiku"
        }
    }

    /// Short label for chips ("Sonnet").
    public var shortName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        }
    }

    /// Looks up a model by its API id (e.g. a stored `ImportedDocument.modelUsed`).
    public init?(modelId: String) {
        self.init(rawValue: modelId)
    }
}

/// How the tutor talks to the student.
public enum TutorStyle: String, Codable, CaseIterable, Sendable {
    case socratic, directHints, exam

    public var displayName: String {
        switch self {
        case .socratic: return "Socratic"
        case .directHints: return "Direct hints"
        case .exam: return "Exam mode"
        }
    }

    /// One-line description for the settings picker.
    public var summary: String {
        switch self {
        case .socratic: return "Asks guiding questions and checks your reasoning step by step."
        case .directHints: return "Points straight at the idea or formula you need next."
        case .exam: return "Stays quiet until you check your answers, then reviews what went wrong."
        }
    }

    /// Text appended to the tutor system prompt.
    public var promptHint: String {
        switch self {
        case .socratic:
            return "Style: Socratic. Guide with one question at a time; make the student do each step; confirm or gently " +
                "correct their reasoning before moving on."
        case .directHints:
            return "Style: direct hints. Name the relevant concept, formula or next step plainly, then let the student " +
                "carry it out; still never complete the part for them."
        case .exam:
            return "Style: exam. Do not offer hints or feedback until the student has submitted an answer; after " +
                "submission, review the mistakes and explain what to study, still without completing the part."
        }
    }
}

/// Which model the agents use, and whether the import pipeline may escalate to Opus.
public struct ModelPolicy: Codable, Sendable, Equatable {
    public var defaultModel: ClaudeModel
    /// The import agent may call `escalate_model` and rerun a chunk with Opus.
    public var allowEscalation: Bool
    /// When set, every call uses this model and escalation is ignored (e.g. "Use Sonnet anyway" for one run).
    public var pinned: ClaudeModel?

    public static let `default` = ModelPolicy()

    public init(defaultModel: ClaudeModel = .sonnet, allowEscalation: Bool = true, pinned: ClaudeModel? = nil) {
        self.defaultModel = defaultModel
        self.allowEscalation = allowEscalation
        self.pinned = pinned
    }

    /// The model a call should actually use.
    public var effectiveModel: ClaudeModel { pinned ?? defaultModel }

    /// The model to use when an agent asks to escalate, or `nil` when escalation is not permitted.
    public var escalationModel: ClaudeModel? {
        guard pinned == nil, allowEscalation, effectiveModel != .opus else { return nil }
        return .opus
    }

    private enum CodingKeys: String, CodingKey { case defaultModel, allowEscalation, pinned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = try c.decodeIfPresent(ClaudeModel.self, forKey: .defaultModel) ?? .sonnet
        allowEscalation = try c.decodeIfPresent(Bool.self, forKey: .allowEscalation) ?? true
        pinned = try c.decodeIfPresent(ClaudeModel.self, forKey: .pinned)
    }
}
