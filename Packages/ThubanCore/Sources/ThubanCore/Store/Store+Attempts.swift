import Foundation
import GRDB

extension Store: AttemptRepository {
    public func record(_ attempt: Attempt) async throws {
        try await write { db in
            guard let classId = try ClassID.fetchOne(
                db, sql: "SELECT classId FROM questions WHERE id = ?", arguments: [attempt.questionId]
            ) else {
                throw ThubanError.store("Cannot record an attempt: no question with id \(attempt.questionId)")
            }
            let earlierOnSameInstance = try Attempt
                .filter(Col.questionId == attempt.questionId && Col.seed == attempt.seed)
                .fetchCount(db)
            try attempt.insert(db)

            let current = try ProgressRecord.fetchOne(db, key: attempt.questionId)?.progress
                ?? QuestionProgress(questionId: attempt.questionId)
            let next = ProgressRules.apply(
                current: current,
                verdictScore: attempt.score,
                isFirstTry: earlierOnSameInstance == 0,
                at: attempt.createdAt
            )
            try ProgressRecord(next, classId: classId).save(db)
        }
    }

    public func progress(in classId: ClassID) async throws -> [QuestionProgress] {
        try await read { db in
            try ProgressRecord
                .filter(Col.classId == classId)
                .order(Col.questionId)
                .fetchAll(db)
                .map(\.progress)
        }
    }

    /// Progress of one question; `.new` with no attempts when it has never been attempted.
    public func progress(for questionId: QuestionID) async throws -> QuestionProgress {
        try await read { db in
            try ProgressRecord.fetchOne(db, key: questionId)?.progress ?? QuestionProgress(questionId: questionId)
        }
    }

    public func attempts(for questionId: QuestionID) async throws -> [Attempt] {
        try await read { db in
            try Attempt
                .filter(Col.questionId == questionId)
                .order(Col.createdAt, Col.id)
                .fetchAll(db)
        }
    }

    /// Forgets every attempt and the progress of a question, returning it to `.new`.
    public func resetProgress(for questionId: QuestionID) async throws {
        try await write { db in
            _ = try Attempt.filter(Col.questionId == questionId).deleteAll(db)
            _ = try ProgressRecord.deleteOne(db, key: questionId)
        }
    }
}
