import Foundation

public struct EquationSuggestionID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// A general equation, rule or constant an import found the class's questions need and its equation sheet lacks
/// (`EquationSuggester`). The student approves it (it joins the sheet under `groupName`) or denies it (it is kept,
/// so it is never suggested again).
public struct EquationSuggestion: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied }
    public enum Kind: String, Codable, Sendable { case equation, rule, constant }

    public var id: EquationSuggestionID
    public var classId: ClassID
    /// The sheet group it belongs in ("Ideal gas", "Derivatives"); created on approval when the sheet lacks it.
    public var groupName: String
    public var name: String
    /// LaTeX, one string per equation (a constant: "R_u = 8.314\ \mathrm{kJ/(kmol\cdot K)}").
    public var equations: [String]
    /// A short plain-text condition or meaning, as on a sheet entry ("for an ideal gas").
    public var note: String?
    /// Which imported questions need it, in a sentence.
    public var reason: String?
    public var kind: Kind
    public var status: Status
    /// The document whose questions prompted it.
    public var documentId: DocumentID?
    public var createdAt: Date

    public init(
        id: EquationSuggestionID = .new(),
        classId: ClassID,
        groupName: String,
        name: String,
        equations: [String],
        note: String? = nil,
        reason: String? = nil,
        kind: Kind = .equation,
        status: Status = .pending,
        documentId: DocumentID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.classId = classId
        self.groupName = groupName
        self.name = name
        self.equations = equations
        self.note = note
        self.reason = reason
        self.kind = kind
        self.status = status
        self.documentId = documentId
        self.createdAt = createdAt
    }
}
