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

    public init(id: String = UUID().uuidString, name: String, summary: String, input: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.input = input
    }

    private enum CodingKeys: String, CodingKey { case id, name, summary, input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
    }
}

/// One line of the tutor transcript.
public struct TutorMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: MessageID
    public var classId: ClassID
    public var questionId: QuestionID?
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
        role: ChatRole,
        content: String,
        toolEvents: [ToolEvent] = [],
        solutionRequested: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.classId = classId
        self.questionId = questionId
        self.role = role
        self.content = content
        self.toolEvents = toolEvents
        self.solutionRequested = solutionRequested
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, classId, questionId, role, content, toolEvents, solutionRequested, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MessageID.self, forKey: .id)
        classId = try c.decode(ClassID.self, forKey: .classId)
        questionId = try c.decodeIfPresent(QuestionID.self, forKey: .questionId)
        role = try c.decode(ChatRole.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolEvents = try c.decodeIfPresent([ToolEvent].self, forKey: .toolEvents) ?? []
        solutionRequested = try c.decodeIfPresent(Bool.self, forKey: .solutionRequested) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
