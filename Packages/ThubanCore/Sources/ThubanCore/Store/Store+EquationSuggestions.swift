import Foundation
import GRDB

extension Store {
    /// A class's suggestions, oldest first; `status` nil for all of them.
    public func equationSuggestions(in classId: ClassID, status: EquationSuggestion.Status? = nil) async throws -> [EquationSuggestion] {
        try await read { db in
            var request = EquationSuggestion.filter(Column("classId") == classId)
            if let status { request = request.filter(Column("status") == status.rawValue) }
            return try request.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    public func addEquationSuggestions(_ suggestions: [EquationSuggestion]) async throws {
        guard !suggestions.isEmpty else { return }
        try await write { db in
            for suggestion in suggestions { try suggestion.insert(db) }
        }
    }

    public func setEquationSuggestionStatus(_ id: EquationSuggestionID, to status: EquationSuggestion.Status) async throws {
        try await write { db in
            guard var suggestion = try EquationSuggestion.fetchOne(db, id: id) else {
                throw ThubanError.store("No equation suggestion \(id.raw)")
            }
            suggestion.status = status
            try suggestion.update(db)
        }
    }

    /// Approves a suggestion: adds it to the class's sheet as an entry at the end of its group (created at the end of
    /// the sheet when missing, matched by name ignoring case) and marks it approved. Returns the new entry.
    @discardableResult
    public func approveEquationSuggestion(_ id: EquationSuggestionID) async throws -> EquationEntry {
        guard let suggestion = try await read({ db in try EquationSuggestion.fetchOne(db, id: id) }) else {
            throw ThubanError.store("No equation suggestion \(id.raw)")
        }
        let sheet = try await equationSheet(for: suggestion.classId)
        let wanted = suggestion.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = wanted.isEmpty ? "Suggested" : wanted
        let group = try await sheet.groups.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            .asyncOr { try await addEquationGroup(named: name, to: suggestion.classId) }
        let entry = try await addEquationEntry(EquationEntry(groupId: group.id, name: suggestion.name,
                                                             equations: EquationEntry.cleaned(suggestion.equations),
                                                             note: suggestion.note), at: nil)
        try await setEquationSuggestionStatus(id, to: .approved)
        return entry
    }
}

private extension Optional {
    func asyncOr(_ make: () async throws -> Wrapped) async rethrows -> Wrapped {
        if let value = self { return value }
        return try await make()
    }
}
