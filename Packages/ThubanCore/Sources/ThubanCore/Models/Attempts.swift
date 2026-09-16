import Foundation

/// The MathEngine's judgement of one part.
public struct Verdict: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case correct, incorrect, equivalentButConditionFailed, unparseable, needsTutor
    }

    public var outcome: Outcome
    /// Student-facing, e.g. "Equivalent, but this part requires a rationalized denominator."
    public var message: String
    /// Simplified LaTeX for display/debug.
    public var canonicalStudent: String?
    public var canonicalExpected: String?
    /// Machine names: "rationalizedDenominator", "exactForm", …
    public var failedConditions: [String]

    public init(
        outcome: Outcome,
        message: String = "",
        canonicalStudent: String? = nil,
        canonicalExpected: String? = nil,
        failedConditions: [String] = []
    ) {
        self.outcome = outcome
        self.message = message
        self.canonicalStudent = canonicalStudent
        self.canonicalExpected = canonicalExpected
        self.failedConditions = failedConditions
    }

    /// Full credit for the part.
    public var isCorrect: Bool { outcome == .correct }

    private enum CodingKeys: String, CodingKey {
        case outcome, message, canonicalStudent, canonicalExpected, failedConditions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        canonicalStudent = try c.decodeIfPresent(String.self, forKey: .canonicalStudent)
        canonicalExpected = try c.decodeIfPresent(String.self, forKey: .canonicalExpected)
        failedConditions = try c.decodeIfPresent([String].self, forKey: .failedConditions) ?? []
    }
}

/// One submission of a question instance.
public struct Attempt: Codable, Identifiable, Sendable, Equatable {
    public var id: AttemptID
    public var questionId: QuestionID
    public var seed: String
    /// partId → latex/text
    public var responses: [String: String]
    /// partId → verdict
    public var verdicts: [String: Verdict]
    /// Fraction of parts correct, 0…1.
    public var score: Double
    public var createdAt: Date

    public init(
        id: AttemptID = .new(),
        questionId: QuestionID,
        seed: String,
        responses: [String: String] = [:],
        verdicts: [String: Verdict] = [:],
        score: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.questionId = questionId
        self.seed = seed
        self.responses = responses
        self.verdicts = verdicts
        self.score = score
        self.createdAt = createdAt
    }

    /// True when every graded part is correct (and at least one part was graded).
    public var isFullyCorrect: Bool {
        !verdicts.isEmpty && verdicts.values.allSatisfy(\.isCorrect)
    }
}

/// Mastery state of one question for the Study ordering and progress bar.
public struct QuestionProgress: Codable, Sendable, Equatable {
    public var questionId: QuestionID
    public var status: ProgressStatus
    /// Consecutive first-try correct attempts.
    public var streak: Int
    public var lastAttemptAt: Date?
    public var lastScore: Double?

    public init(
        questionId: QuestionID,
        status: ProgressStatus = .new,
        streak: Int = 0,
        lastAttemptAt: Date? = nil,
        lastScore: Double? = nil
    ) {
        self.questionId = questionId
        self.status = status
        self.streak = streak
        self.lastAttemptAt = lastAttemptAt
        self.lastScore = lastScore
    }
}
