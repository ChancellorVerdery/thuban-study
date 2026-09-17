import Foundation
import GRDB

extension Store: QuestionRepository {
    public func questions(in classId: ClassID, filter: QuestionFilter?) async throws -> [Question] {
        let filter = filter ?? .all
        return try await read { db in
            try Store.questionRequest(in: classId, filter: filter).fetchAll(db)
        }
    }

    /// The class's agent-classified types, most used first (ties alphabetical); unclassified ("") is left out.
    public func questionTypes(in classId: ClassID) async throws -> [(type: String, count: Int)] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT type, COUNT(*) AS n FROM questions WHERE classId = ? AND type <> ''
                GROUP BY type ORDER BY n DESC, type COLLATE NOCASE ASC
                """, arguments: [classId])
            return rows.map { (type: $0["type"] as String, count: $0["n"] as Int) }
        }
    }

    /// Number of questions in a class matching `filter`.
    public func questionCount(in classId: ClassID, filter: QuestionFilter? = nil) async throws -> Int {
        let filter = filter ?? .all
        return try await read { db in
            try Store.questionRequest(in: classId, filter: filter).fetchCount(db)
        }
    }

    public func insert(_ questions: [Question]) async throws {
        guard !questions.isEmpty else { return }
        try await write { db in
            for question in questions { try question.insert(db) }
        }
    }

    public func insert(_ question: Question) async throws {
        try await insert([question])
    }

    public func update(_ question: Question) async throws {
        try await write { db in try question.update(db) }
    }

    public func delete(_ id: QuestionID) async throws {
        try await write { db in _ = try Question.deleteOne(db, id: id) }
    }

    public func question(id: QuestionID) async throws -> Question? {
        try await read { db in try Question.fetchOne(db, id: id) }
    }

    /// Builds the filtered, ordered request. Status filtering treats questions without a progress row as `.new`.
    static func questionRequest(in classId: ClassID, filter: QuestionFilter) -> QueryInterfaceRequest<Question> {
        var request = Question.filter(Col.classId == classId)
        if !filter.kinds.isEmpty {
            request = request.filter(filter.kinds.map(\.rawValue).sorted().contains(Col.kind))
        }
        if !filter.types.isEmpty {
            request = request.filter(filter.types.sorted().contains(Col.type))
        }
        if !filter.documentIds.isEmpty {
            request = request.filter(filter.documentIds.map(\.raw).sorted().contains(Col.documentId))
        }
        if !filter.statuses.isEmpty {
            let statuses = filter.statuses.map(\.rawValue).sorted()
            request = request.filter(literal: """
                COALESCE((SELECT p.status FROM progress p WHERE p.questionId = \(Col.id)), 'new') IN \(statuses)
                """)
        }
        if let search = filter.normalizedSearch {
            let pattern = "%" + Store.escapeLike(search) + "%"
            request = request.filter(
                Col.stem.like(pattern, escape: "\\")
                    || Col.sourceRef.like(pattern, escape: "\\")
                    || Col.type.like(pattern, escape: "\\")
                    || Col.tags.like(pattern, escape: "\\")
            )
        }
        return request.order(Col.createdAt, Col.id)
    }

    /// Escapes `%`, `_` and the escape character itself for a `LIKE … ESCAPE '\'` pattern.
    static func escapeLike(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character == "\\" || character == "%" || character == "_" { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
