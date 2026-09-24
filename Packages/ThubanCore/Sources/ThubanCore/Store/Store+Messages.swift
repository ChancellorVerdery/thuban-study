import Foundation
import GRDB

extension Store: MessageRepository {
    public func messages(for classId: ClassID, question: QuestionID?) async throws -> [TutorMessage] {
        try await read { db in
            try Store.threadRequest(classId: classId, question: question)
                .order(Col.createdAt, Column.rowID)
                .fetchAll(db)
        }
    }

    /// One set of numbers' thread of a question: messages recorded with `seed` (`nil` = those without a seed).
    public func messages(for classId: ClassID, question: QuestionID, seed: String?) async throws -> [TutorMessage] {
        try await read { db in
            try Store.threadRequest(classId: classId, question: question, seed: seed)
                .order(Col.createdAt, Column.rowID)
                .fetchAll(db)
        }
    }

    public func clear(for classId: ClassID, question: QuestionID, seed: String?) async throws {
        try await write { db in
            _ = try Store.threadRequest(classId: classId, question: question, seed: seed).deleteAll(db)
        }
    }

    public func append(_ message: TutorMessage) async throws {
        try await write { db in try message.insert(db) }
    }

    public func clear(for classId: ClassID, question: QuestionID?) async throws {
        try await write { db in
            _ = try Store.threadRequest(classId: classId, question: question).deleteAll(db)
        }
    }

    /// Removes every message of the class, in every thread.
    public func clearAllMessages(for classId: ClassID) async throws {
        try await write { db in
            _ = try TutorMessage.filter(Col.classId == classId).deleteAll(db)
        }
    }

    private static func threadRequest(classId: ClassID, question: QuestionID, seed: String?) -> QueryInterfaceRequest<TutorMessage> {
        let base = TutorMessage.filter(Col.classId == classId).filter(Col.questionId == question)
        return base.filter(Column("seed") == seed)
    }

    /// Messages of one thread: the class-level thread when `question` is `nil`.
    private static func threadRequest(classId: ClassID, question: QuestionID?) -> QueryInterfaceRequest<TutorMessage> {
        let base = TutorMessage.filter(Col.classId == classId)
        guard let question else { return base.filter(Col.questionId == nil) }
        return base.filter(Col.questionId == question)
    }
}
