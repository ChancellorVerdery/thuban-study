import Foundation
import Observation
import ThubanCore
import os

/// A card being written or edited.
struct FlashcardDraft: Identifiable, Equatable {
    /// The card being edited; nil for a new card.
    var cardId: FlashcardID?
    var front: String
    var back: String
    var id: String { cardId?.raw ?? "new" }

    init(new: Void = ()) {
        cardId = nil
        front = ""
        back = ""
    }

    init(card: Flashcard) {
        cardId = card.id
        front = card.front
        back = card.back
    }
}

/// A class's flashcards: the deck, the review session, and the section's UI state. Kept per class in
/// `ClassSession.flashcards` (sessions cannot gain stored properties in an extension).
@MainActor
@Observable
final class FlashcardsState {
    enum Mode: String, CaseIterable { case review, bank }

    /// A review run: the cards in the order drawn, missed ones appended again until they are got.
    struct Review: Equatable {
        var ids: [FlashcardID]
        var index = 0
        var missed: Set<FlashcardID> = []
        var flipped = false
        /// Practice runs every card and schedules nothing.
        var practice: Bool
        var isFinished: Bool { index >= ids.count }
    }

    private(set) var cards: [Flashcard] = []
    var isLoaded = false
    var mode: Mode = .review
    var review: Review?
    var editing: FlashcardDraft?
    var pendingDelete: Flashcard?
    var isGenerating = false
    var error: String?

    let reviewPage = FlashcardDeckWebView.Controller(name: "flashcards-review")
    let bankPage = FlashcardDeckWebView.Controller(name: "flashcards-bank")

    func setCards(_ cards: [Flashcard]) { self.cards = cards }

    var today: String { FlashcardSchedule.day() }
    var dueCards: [Flashcard] { FlashcardSchedule.due(cards, today: today) }
    var nextDue: String? { FlashcardSchedule.nextDue(cards, today: today) }

    var currentCard: Flashcard? {
        guard let review, !review.isFinished else { return nil }
        return cards.first { $0.id == review.ids[review.index] }
    }

    /// "Oct 3" for a "yyyy-MM-dd" day.
    static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension ClassSession {
    private static var flashcardStates: [ClassID: FlashcardsState] = [:]

    /// The flashcards state of this class (created on first access, wired to its pages).
    var flashcards: FlashcardsState {
        if let existing = Self.flashcardStates[classId] { return existing }
        let state = FlashcardsState()
        Self.flashcardStates[classId] = state
        let live = Set(app.classes.map(\.id))
        Self.flashcardStates = Self.flashcardStates.filter { live.contains($0.key) || $0.key == classId }
        state.reviewPage.onFlip = { [weak self] in self?.flipFlashcard() }
        state.reviewPage.onKey = { [weak self] key in self?.handleReviewKey(key) }
        state.bankPage.onEdit = { [weak self] id in
            guard let self, let card = self.flashcards.cards.first(where: { $0.id == id }) else { return }
            self.flashcards.editing = FlashcardDraft(card: card)
        }
        state.bankPage.onDelete = { [weak self] id in
            guard let self else { return }
            self.flashcards.pendingDelete = self.flashcards.cards.first { $0.id == id }
        }
        return state
    }

    func loadFlashcards() async {
        do {
            flashcards.setCards(try await store.flashcards(in: classId))
            flashcards.isLoaded = true
            flashcards.error = nil
        } catch {
            flashcards.error = error.localizedDescription
            Self.logger.error("load flashcards failed: \(error.localizedDescription, privacy: .public)")
        }
        pushFlashcards()
    }

    // MARK: Pages

    func pushFlashcards() {
        let state = flashcards
        let today = state.today
        let rows = state.cards.map { card -> FlashcardDeckWebView.BankRow in
            let (chip, kind): (String, FlashcardDeckWebView.BankRow.Chip)
            if card.due == nil { (chip, kind) = ("New", .new) }
            else if card.isDue(on: today) { (chip, kind) = ("Due now", .due) }
            else { (chip, kind) = ("Due " + FlashcardsState.shortDay(card.due ?? today), .later) }
            return .init(id: card.id, front: card.front, back: card.back, chip: chip, chipKind: kind)
        }
        state.bankPage.showBank(rows, emptyMessage: "No cards yet. Add one, or generate cards from your notes.")
        if let card = state.currentCard, let review = state.review {
            state.reviewPage.showCard(
                side: review.flipped ? "back" : "front",
                text: review.flipped ? card.back : card.front,
                hint: review.flipped ? "Click to see the question again" : "Click or press Space to show the answer"
            )
        }
    }

    // MARK: Review

    func startFlashcardReview(practice: Bool) {
        let state = flashcards
        let pool = practice ? state.cards : state.dueCards
        guard !pool.isEmpty else { return }
        state.review = FlashcardsState.Review(ids: pool.map(\.id).shuffled(), practice: practice)
        pushFlashcards()
        state.reviewPage.focus()
    }

    func flipFlashcard() {
        guard var review = flashcards.review, !review.isFinished else { return }
        review.flipped.toggle()
        flashcards.review = review
        pushFlashcards()
    }

    /// Missed → the card drops to tomorrow and comes round again this session; got it → it climbs the ladder, unless
    /// it was missed earlier in this session (the miss already scheduled it).
    func gradeFlashcard(got: Bool) async {
        let state = flashcards
        guard var review = state.review, review.flipped, let card = state.currentCard else { return }
        if !review.practice, !got || !review.missed.contains(card.id) {
            let graded = FlashcardSchedule.graded(card, correct: got, today: state.today)
            do {
                try await store.updateFlashcard(graded)
                state.setCards(state.cards.map { $0.id == graded.id ? graded : $0 })
            } catch {
                state.error = error.localizedDescription
            }
        }
        if !got {
            review.missed.insert(card.id)
            review.ids.append(card.id)
        }
        review.index += 1
        review.flipped = false
        // A card deleted mid-session is skipped.
        while !review.isFinished, !state.cards.contains(where: { $0.id == review.ids[review.index] }) { review.index += 1 }
        state.review = review
        pushFlashcards()
        state.reviewPage.focus()
    }

    func endFlashcardReview() {
        flashcards.review = nil
    }

    private func handleReviewKey(_ key: String) {
        guard let review = flashcards.review, !review.isFinished else { return }
        switch key {
        case " ": flipFlashcard()
        case "1" where review.flipped: Task { await gradeFlashcard(got: false) }
        case "2" where review.flipped: Task { await gradeFlashcard(got: true) }
        case "Escape": endFlashcardReview()
        default: break
        }
    }

    // MARK: Editing

    func saveFlashcard(_ draft: FlashcardDraft) async -> Bool {
        let front = draft.front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = draft.back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty else { return false }
        do {
            if let id = draft.cardId, var card = flashcards.cards.first(where: { $0.id == id }) {
                card.front = front
                card.back = back
                try await store.updateFlashcard(card)
            } else {
                try await store.addFlashcards([Flashcard(classId: classId, front: front, back: back)])
            }
            await loadFlashcards()
            return true
        } catch {
            flashcards.error = error.localizedDescription
            return false
        }
    }

    func addFlashcards(_ cards: [(front: String, back: String)]) async {
        let new = cards.map { Flashcard(classId: classId, front: $0.front, back: $0.back) }
        do {
            try await store.addFlashcards(new)
        } catch {
            flashcards.error = error.localizedDescription
        }
        await loadFlashcards()
    }

    func deleteFlashcard(_ id: FlashcardID) async {
        do {
            try await store.deleteFlashcard(id)
        } catch {
            flashcards.error = error.localizedDescription
        }
        await loadFlashcards()
    }
}
