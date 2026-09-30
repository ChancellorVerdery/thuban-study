import Foundation

public struct FlashcardID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// One card of a class's deck. Front and back are Markdown with `$…$` / `$$…$$` LaTeX. Scheduling follows
/// `FlashcardSchedule`: `box` is the rung of the ladder the card has climbed to, `due` the calendar day it comes
/// back (`nil` = new, due now).
public struct Flashcard: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: FlashcardID
    public var classId: ClassID
    public var front: String
    public var back: String
    public var box: Int
    /// "yyyy-MM-dd" in the student's calendar; nil for a card never reviewed.
    public var due: String?
    public var position: Int
    public var createdAt: Date

    public init(
        id: FlashcardID = .new(),
        classId: ClassID,
        front: String,
        back: String,
        box: Int = 0,
        due: String? = nil,
        position: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.classId = classId
        self.front = front
        self.back = back
        self.box = box
        self.due = due
        self.position = position
        self.createdAt = createdAt
    }

    public func isDue(on today: String) -> Bool {
        guard let due, !due.isEmpty else { return true }
        return due <= today
    }
}

/// Spaced repetition on a graduated ladder (Atlas's): a miss comes back tomorrow at the bottom rung; each correct
/// answer climbs one rung and waits that many days — 1, 3, 7, 14, then 21 days at most. The 21-day cap keeps every
/// card at four or more spaced retrievals across a semester, where expanding schedules beat uniform ones.
public enum FlashcardSchedule {
    public static let ladder = [1, 3, 7, 14, 21]

    /// The student's calendar day, "yyyy-MM-dd".
    public static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `day` moved by `days` calendar days.
    public static func add(_ days: Int, to day: String, calendar: Calendar = .current) -> String {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3,
              let start = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return day }
        return Self.day(moved, calendar: calendar)
    }

    /// The card after a review: missed → bottom rung, back tomorrow; correct → one rung up, back after that rung's
    /// wait. A recovery later in the same session after a miss must not be graded again (the miss already demoted it).
    public static func graded(_ card: Flashcard, correct: Bool, today: String) -> Flashcard {
        var card = card
        if correct {
            card.box = min(max(card.box, 0) + 1, ladder.count - 1)
            card.due = add(ladder[card.box], to: today)
        } else {
            card.box = 0
            card.due = add(1, to: today)
        }
        return card
    }

    /// Cards due today or earlier (new cards included), in deck order.
    public static func due(_ cards: [Flashcard], today: String) -> [Flashcard] {
        cards.filter { $0.isDue(on: today) }
    }

    /// The earliest future due day, for "next on …".
    public static func nextDue(_ cards: [Flashcard], today: String) -> String? {
        cards.compactMap(\.due).filter { $0 > today }.min()
    }
}
