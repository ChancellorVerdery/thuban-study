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

    /// Messages of one thread: the class-level thread when `question` is `nil`.
    private static func threadRequest(classId: ClassID, question: QuestionID?) -> QueryInterfaceRequest<TutorMessage> {
        let base = TutorMessage.filter(Col.classId == classId)
        guard let question else { return base.filter(Col.questionId == nil) }
        return base.filter(Col.questionId == question)
    }
}
