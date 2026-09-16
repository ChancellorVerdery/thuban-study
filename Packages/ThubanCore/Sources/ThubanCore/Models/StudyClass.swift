import Foundation

/// A course the student is studying. Owns documents, questions, attempts and the tutor transcript.
public struct StudyClass: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: ClassID
    public var name: String
    public var courseCode: String?
    public var term: String?
    /// Optional hex override for the tab dot; `nil` means "use the scheme accent".
    public var tint: String?
    public var tutorStyle: TutorStyle
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: ClassID = .new(),
        name: String,
        courseCode: String? = nil,
        term: String? = nil,
        tint: String? = nil,
        tutorStyle: TutorStyle = .socratic,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.courseCode = courseCode
        self.term = term
        self.tint = tint
        self.tutorStyle = tutorStyle
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, courseCode, term, tint, tutorStyle, sortOrder, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ClassID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        courseCode = try c.decodeIfPresent(String.self, forKey: .courseCode)
        term = try c.decodeIfPresent(String.self, forKey: .term)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        tutorStyle = try c.decodeIfPresent(TutorStyle.self, forKey: .tutorStyle) ?? .socratic
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
