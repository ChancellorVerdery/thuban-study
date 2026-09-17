import Foundation

// MARK: - Repository protocols (architecture contract)

/// Classes: the top-level containers.
public protocol ClassRepository: Sendable {
    /// Every class, ordered by `sortOrder` then creation date.
    func allClasses() async throws -> [StudyClass]
    func insert(_ studyClass: StudyClass) async throws
    /// Fails with `ThubanError.store` when the class does not exist.
    func update(_ studyClass: StudyClass) async throws
    /// Removes the class and, through cascading foreign keys, its documents, questions, figures, attempts,
    /// progress and messages. With `deleteFiles`, the stored document and figure files are removed as well.
    func delete(_ id: ClassID, deleteFiles: Bool) async throws
}

/// Imported source files.
public protocol DocumentRepository: Sendable {
    /// Documents of a class, newest import first.
    func documents(in classId: ClassID) async throws -> [ImportedDocument]
    func insert(_ document: ImportedDocument) async throws
    /// Updates the import pipeline state of one document.
    func update(status: ImportStatus, detail: String?, model: String?, for id: DocumentID) async throws
    /// Removes the document row and, through cascading foreign keys, its figures and generated questions.
    func delete(_ id: DocumentID) async throws
}

/// The question bank.
public protocol QuestionRepository: Sendable {
    /// Questions of a class matching `filter` (all when `nil`), oldest first.
    func questions(in classId: ClassID, filter: QuestionFilter?) async throws -> [Question]
    /// Inserts every question in one transaction.
    func insert(_ questions: [Question]) async throws
    func update(_ question: Question) async throws
    func delete(_ id: QuestionID) async throws
    func question(id: QuestionID) async throws -> Question?
}

/// Figures extracted from documents.
public protocol FigureRepository: Sendable {
    /// Figures of a document ordered by page/index.
    func figures(for documentId: DocumentID) async throws -> [Figure]
    func insert(_ figure: Figure) async throws
    func update(_ figure: Figure) async throws
}

/// Attempts and the derived per-question progress.
public protocol AttemptRepository: Sendable {
    /// Stores the attempt and updates the question's progress in the same transaction.
    func record(_ attempt: Attempt) async throws
    /// Progress rows of every attempted question in the class.
    func progress(in classId: ClassID) async throws -> [QuestionProgress]
    /// Attempts on a question, oldest first.
    func attempts(for questionId: QuestionID) async throws -> [Attempt]
}

/// The tutor transcript. `question == nil` addresses the class-level thread.
public protocol MessageRepository: Sendable {
    func messages(for classId: ClassID, question: QuestionID?) async throws -> [TutorMessage]
    func append(_ message: TutorMessage) async throws
    func clear(for classId: ClassID, question: QuestionID?) async throws
}

/// Key/value settings with JSON-encoded values.
public protocol SettingsRepository: Sendable {
    func get<T: Codable>(_ key: SettingsKey, as type: T.Type) async throws -> T?
    func set<T: Codable>(_ key: SettingsKey, _ value: T) async throws
}

// MARK: - QuestionFilter

/// Narrows `QuestionRepository.questions(in:filter:)`. Empty sets mean "no restriction"; the search text matches
/// the stem, source reference and tags case-insensitively.
public struct QuestionFilter: Sendable, Equatable {
    public var kinds: Set<QuestionKind>
    public var statuses: Set<ProgressStatus>
    public var documentIds: Set<DocumentID>
    public var search: String?

    public init(
        kinds: Set<QuestionKind> = [],
        statuses: Set<ProgressStatus> = [],
        documentIds: Set<DocumentID> = [],
        search: String? = nil
    ) {
        self.kinds = kinds
        self.statuses = statuses
        self.documentIds = documentIds
        self.search = search
    }

    /// Matches every question.
    public static let all = QuestionFilter()

    /// The search text with surrounding whitespace removed, or `nil` when blank.
    public var normalizedSearch: String? {
        guard let search else { return nil }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when the filter imposes no restriction.
    public var isEmpty: Bool {
        kinds.isEmpty && statuses.isEmpty && documentIds.isEmpty && normalizedSearch == nil
    }
}

// MARK: - ProgressRules

/// How an attempt moves a question through `ProgressStatus`:
/// - a fully correct attempt on the first try of an instance extends the streak; two in a row ⇒ `.mastered`;
/// - any correct attempt on a question that is not mastered ⇒ `.learning`;
/// - a wrong attempt resets the streak; after `.mastered` (or while in `.needsReview`) ⇒ `.needsReview`, otherwise
///   the question stays in `.learning`.
public enum ProgressRules {
    /// Default consecutive first-try correct attempts needed for mastery (Settings › Question bank can override).
    public static let masteryStreak = 2
    /// Attempts scoring at least this much count as correct.
    public static let passingScore = 1.0

    /// Returns the progress after an attempt with `verdictScore` (0…1). `isFirstTry` is false when the student
    /// re-submits the same instance after an earlier attempt; such retries never extend the streak.
    /// `masteryStreak` is the streak needed for `.mastered` (clamped to ≥ 1).
    public static func apply(
        current: QuestionProgress,
        verdictScore: Double,
        isFirstTry: Bool = true,
        masteryStreak: Int = ProgressRules.masteryStreak,
        at date: Date = Date()
    ) -> QuestionProgress {
        var next = current
        next.lastAttemptAt = date
        next.lastScore = verdictScore
        if verdictScore >= passingScore {
            if isFirstTry { next.streak += 1 }
            next.status = (current.status == .mastered || next.streak >= max(1, masteryStreak)) ? .mastered : .learning
        } else {
            next.streak = 0
            next.status = (current.status == .mastered || current.status == .needsReview) ? .needsReview : .learning
        }
        return next
    }
}
