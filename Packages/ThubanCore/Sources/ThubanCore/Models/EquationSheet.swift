import Foundation

// MARK: - Identifiers

public struct EquationGroupID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct EquationEntryID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

// MARK: - Groups and entries

/// A named section of a class's equation sheet ("Derivatives", "Series tests"). Groups are ordered by `position`
/// within their class.
public struct EquationGroup: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: EquationGroupID
    public var classId: ClassID
    public var name: String
    public var position: Int
    public var createdAt: Date

    public init(id: EquationGroupID = .new(), classId: ClassID, name: String, position: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.classId = classId
        self.name = name
        self.position = position
        self.createdAt = createdAt
    }
}

/// One named item on the sheet: a single equation (a card) or several (a named list), with an optional short
/// plain-text note ("for |r| < 1"). Entries are ordered by `position` within their group. The student curates the
/// sheet; imports only suggest entries (`EquationSuggestion`), which join it when the student approves them.
public struct EquationEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: EquationEntryID
    public var groupId: EquationGroupID
    public var name: String
    /// LaTeX, one string per equation, in display order. Stored as a JSON array.
    public var equations: [String]
    public var note: String?
    public var position: Int
    public var createdAt: Date

    public init(
        id: EquationEntryID = .new(),
        groupId: EquationGroupID,
        name: String,
        equations: [String],
        note: String? = nil,
        position: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.equations = equations
        self.note = note
        self.position = position
        self.createdAt = createdAt
    }

    /// True when the entry shows several equations (a named list rather than a single card).
    public var isList: Bool { equations.count > 1 }

    /// The equations with blank ones removed and surrounding whitespace trimmed (what is saved).
    public static func cleaned(_ equations: [String]) -> [String] {
        equations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - The sheet

/// A class's whole equation sheet: its groups in order, each with its entries in order.
public struct EquationSheet: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public var group: EquationGroup
        public var entries: [EquationEntry]
        public var id: EquationGroupID { group.id }

        public init(group: EquationGroup, entries: [EquationEntry]) {
            self.group = group
            self.entries = entries
        }
    }

    public var classId: ClassID
    public var sections: [Section]

    public init(classId: ClassID, sections: [Section] = []) {
        self.classId = classId
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var entryCount: Int { sections.reduce(0) { $0 + $1.entries.count } }
    public var groups: [EquationGroup] { sections.map(\.group) }

    public func entry(_ id: EquationEntryID) -> EquationEntry? {
        for section in sections {
            if let entry = section.entries.first(where: { $0.id == id }) { return entry }
        }
        return nil
    }

    public func group(_ id: EquationGroupID) -> EquationGroup? {
        sections.first { $0.group.id == id }?.group
    }

    /// The sheet narrowed to entries whose name, note or LaTeX contains every word of `query` (case- and
    /// diacritic-insensitive; LaTeX is also matched with its backslashes, braces and spaces removed, so "frac"
    /// and "\frac{" both find a fraction). A group whose own name matches keeps all its entries. Groups left
    /// without entries are dropped. A blank query returns the sheet unchanged.
    public func filtered(by query: String) -> EquationSheet {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { Self.fold(String($0)) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return self }
        var result = EquationSheet(classId: classId)
        for section in sections {
            let groupName = Self.fold(section.group.name)
            if words.allSatisfy({ groupName.contains($0) }) {
                result.sections.append(section)
                continue
            }
            let entries = section.entries.filter { entry in
                let haystack = Self.searchText(for: entry)
                return words.allSatisfy { haystack.contains($0) || haystack.contains(Self.stripLatex($0)) }
            }
            if !entries.isEmpty {
                result.sections.append(Section(group: section.group, entries: entries))
            }
        }
        return result
    }

    static func searchText(for entry: EquationEntry) -> String {
        var parts = [entry.name, entry.note ?? ""]
        parts += entry.equations
        parts += entry.equations.map(stripLatex)
        return fold(parts.joined(separator: "\n"))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// LaTeX without the characters that make it awkward to type in a search field.
    static func stripLatex(_ latex: String) -> String {
        String(latex.unicodeScalars.filter { !"\\{} ".unicodeScalars.contains($0) }.map(Character.init))
    }
}
