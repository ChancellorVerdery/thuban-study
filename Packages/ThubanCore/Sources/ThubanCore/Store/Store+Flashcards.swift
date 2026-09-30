import Foundation
import GRDB

/// A class's flashcard deck.
public protocol FlashcardRepository: Sendable {
    func flashcards(in classId: ClassID) async throws -> [Flashcard]
    /// Appends cards to the end of the deck (positions assigned in order).
    func addFlashcards(_ cards: [Flashcard]) async throws
    func updateFlashcard(_ card: Flashcard) async throws
    func deleteFlashcard(_ id: FlashcardID) async throws
}

extension Store: FlashcardRepository {
    public func flashcards(in classId: ClassID) async throws -> [Flashcard] {
        try await read { db in
            try Flashcard
                .filter(Col.classId == classId)
                .order(Col.position, Col.createdAt, Col.id)
                .fetchAll(db)
        }
    }

    public func addFlashcards(_ cards: [Flashcard]) async throws {
        guard !cards.isEmpty else { return }
        try await write { db in
            var next: [ClassID: Int] = [:]
            for var card in cards {
                if next[card.classId] == nil {
                    next[card.classId] = try Int.fetchOne(
                        db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM flashcards WHERE classId = ?", arguments: [card.classId]
                    ) ?? 0
                }
                card.position = next[card.classId]!
                next[card.classId]! += 1
                try card.insert(db)
            }
        }
    }

    public func updateFlashcard(_ card: Flashcard) async throws {
        try await write { db in try card.update(db) }
    }

    public func deleteFlashcard(_ id: FlashcardID) async throws {
        try await write { db in _ = try Flashcard.deleteOne(db, id: id) }
    }
}
