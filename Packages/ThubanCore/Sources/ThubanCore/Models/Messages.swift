import Foundation

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case student, tutor, system
}

/// A tool the tutor used while answering (graph edits etc.), shown as a system line in the transcript.
public struct ToolEvent: Codable, Identifiable, Sendable, Equatable {
    /// The tool-use id from the API.
    public var id: String
    /// Tool name, e.g. "graph_add_expression".
    public var name: String
    /// Student-facing one-liner, e.g. "Added y = 2x + 1 to the graph".
    public var summary: String
    public var input: JSONValue?
    /// True when the tool handler rejected the call (the summary then describes the failure, not an edit).
    public var isError: Bool

    public init(id: String = UUID().uuidString, name: String, summary: String, input: JSONValue? = nil, isError: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.input = input
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey { case id, name, summary, input, isError }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(input, forKey: .input)
        if isError { try c.encode(isError, forKey: .isError) }
    }
}

/// One line of the tutor transcript.
public struct TutorMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: MessageID
    public var classId: ClassID
    public var questionId: QuestionID?
    /// The instance seed of a regenerated (template) question the message is about: each set of numbers has its own
    /// thread. `nil` for the class thread, static questions and messages from before seeds were recorded.
    public var seed: String?
    public var role: ChatRole
    /// Markdown + LaTeX.
    public var content: String
    /// Graph edits etc. shown as system lines.
    public var toolEvents: [ToolEvent]
    /// The student explicitly asked for the solution with this message.
    public var solutionRequested: Bool
    public var createdAt: Date

    public init(
        id: MessageID = .new(),
        classId: ClassID,
        questionId: QuestionID? = nil,
        seed: String? = nil,
        role: ChatRole,
        content: String,
        toolEvents: [ToolEvent] = [],
        solutionRequested: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.classId = classId
        self.questionId = questionId
        self.seed = seed
        self.role = role
        self.content = content
        self.toolEvents = toolEvents
        self.solutionRequested = solutionRequested
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, classId, questionId, seed, role, content, toolEvents, solutionRequested, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MessageID.self, forKey: .id)
        classId = try c.decode(ClassID.self, forKey: .classId)
        questionId = try c.decodeIfPresent(QuestionID.self, forKey: .questionId)
        seed = try c.decodeIfPresent(String.self, forKey: .seed)
        role = try c.decode(ChatRole.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolEvents = try c.decodeIfPresent([ToolEvent].self, forKey: .toolEvents) ?? []
        solutionRequested = try c.decodeIfPresent(Bool.self, forKey: .solutionRequested) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
