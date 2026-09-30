import XCTest
@testable import ThubanCore

/// The 1-3-7-14-21 ladder: correct climbs a rung, a miss starts over tomorrow.
final class FlashcardScheduleTests: XCTestCase {
    let classId = ClassID(raw: "c")

    func testLadderClimbsAndCaps() {
        var card = Flashcard(classId: classId, front: "f", back: "b")
        XCTAssertTrue(card.isDue(on: "2026-09-30"), "new cards are due")
        var today = "2026-09-30"
        var waits: [String] = []
        for _ in 0..<6 {
            card = FlashcardSchedule.graded(card, correct: true, today: today)
            waits.append(card.due!)
            today = card.due!
        }
        XCTAssertEqual(waits, ["2026-10-03", "2026-10-10", "2026-10-24", "2026-11-14", "2026-12-05", "2026-12-26"])
        XCTAssertEqual(card.box, 4)
    }

    func testMissGoesBackToTomorrow() {
        var card = Flashcard(classId: classId, front: "f", back: "b", box: 3, due: "2026-09-30")
        card = FlashcardSchedule.graded(card, correct: false, today: "2026-09-30")
        XCTAssertEqual(card.box, 0)
        XCTAssertEqual(card.due, "2026-10-01")
        XCTAssertFalse(card.isDue(on: "2026-09-30"))
        XCTAssertTrue(card.isDue(on: "2026-10-01"))
    }

    func testDayArithmeticCrossesMonthsAndYears() {
        XCTAssertEqual(FlashcardSchedule.add(21, to: "2026-12-20"), "2027-01-10")
        XCTAssertEqual(FlashcardSchedule.add(1, to: "2028-02-28"), "2028-02-29")
    }

    func testDeckIsStoredInOrderAndGoesWithItsClass() async throws {
        let store = try Store.inMemory()
        let studyClass = StudyClass(name: "Thermo")
        try await store.insert(studyClass)
        let cards = ["$\\Delta E = Q - W$", "$pV = mRT$", "Quality $x$"].map {
            Flashcard(classId: studyClass.id, front: $0, back: "b")
        }
        try await store.addFlashcards(cards)
        var deck = try await store.flashcards(in: studyClass.id)
        XCTAssertEqual(deck.map(\.front), cards.map(\.front))
        XCTAssertEqual(deck.map(\.position), [0, 1, 2])

        let reviewed = FlashcardSchedule.graded(deck[1], correct: true, today: "2026-09-30")
        try await store.updateFlashcard(reviewed)
        try await store.deleteFlashcard(deck[0].id)
        deck = try await store.flashcards(in: studyClass.id)
        XCTAssertEqual(deck.count, 2)
        XCTAssertEqual(deck[0].due, "2026-10-03")
        XCTAssertEqual(deck[0].box, 1)

        try await store.delete(studyClass.id, deleteFiles: false)
        let gone = try await store.flashcards(in: studyClass.id)
        XCTAssertTrue(gone.isEmpty)
    }

    func testGeneratedCardsAreReadAndDeduplicated() {
        let input: JSONValue = ["cards": .string(#"[{"front": "First law (closed system)", "back": "$\\Delta U = Q - W$"}, {"front": "first law (closed system)", "back": "dup"}, {"front": " ", "back": "blank"}, {"front": "Ideal gas law", "back": "$$pV = mRT$$"}]"#)]
        let cards = FlashcardGenerator.cards(from: input)
        XCTAssertEqual(cards.map(\.front), ["First law (closed system)", "Ideal gas law"])
        XCTAssertEqual(cards[0].back, "$\\Delta U = Q - W$")
    }

    func testDueAndNext() {
        let cards = [
            Flashcard(classId: classId, front: "a", back: "a", due: nil),
            Flashcard(classId: classId, front: "b", back: "b", due: "2026-09-29"),
            Flashcard(classId: classId, front: "c", back: "c", due: "2026-10-05"),
            Flashcard(classId: classId, front: "d", back: "d", due: "2026-10-02"),
        ]
        XCTAssertEqual(FlashcardSchedule.due(cards, today: "2026-09-30").map(\.front), ["a", "b"])
        XCTAssertEqual(FlashcardSchedule.nextDue(cards, today: "2026-09-30"), "2026-10-02")
    }
}
