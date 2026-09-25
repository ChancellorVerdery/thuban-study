import Foundation
import GRDB

// MARK: - Identifiers and enums as SQLite values

extension DatabaseValueConvertible where Self: ThubanIdentifier {
    public var databaseValue: DatabaseValue { raw.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
        String.fromDatabaseValue(dbValue).map(Self.init(raw:))
    }
}

extension ClassID: DatabaseValueConvertible {}
extension DocumentID: DatabaseValueConvertible {}
extension QuestionID: DatabaseValueConvertible {}
extension FigureID: DatabaseValueConvertible {}
extension AttemptID: DatabaseValueConvertible {}
extension MessageID: DatabaseValueConvertible {}
extension EquationGroupID: DatabaseValueConvertible {}
extension EquationEntryID: DatabaseValueConvertible {}

extension TutorStyle: DatabaseValueConvertible {}
extension DocumentKind: DatabaseValueConvertible {}
extension ImportStatus: DatabaseValueConvertible {}
extension DocumentClassification: DatabaseValueConvertible {}
extension QuestionKind: DatabaseValueConvertible {}
extension ProgressStatus: DatabaseValueConvertible {}
extension FigureKind: DatabaseValueConvertible {}
extension FigureStatus: DatabaseValueConvertible {}
extension ChatRole: DatabaseValueConvertible {}

// MARK: - Model tables
//
// The domain structs are stored directly through GRDB's Codable support: scalar properties map to columns of the
// same name, identifiers and enums to their raw strings (above), and nested values (`parts`, `template`,
// `figureIds`, `tags`, `chart`, `responses`, `verdicts`, `toolEvents`) to JSON text columns.

extension StudyClass: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "classes"
}

extension ImportedDocument: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "documents"
}

extension Question: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "questions"
}

extension Figure: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "figures"
}

extension Attempt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attempts"
}

extension TutorMessage: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"
}

extension EquationGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "equation_groups"
}

extension EquationEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "equation_entries"
}

// MARK: - Internal rows

/// The `progress` table: `QuestionProgress` plus the owning class for indexed per-class reads.
struct ProgressRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "progress"

    var questionId: QuestionID
    var classId: ClassID
    var status: ProgressStatus
    var streak: Int
    var lastAttemptAt: Date?
    var lastScore: Double?

    init(_ progress: QuestionProgress, classId: ClassID) {
        questionId = progress.questionId
        self.classId = classId
        status = progress.status
        streak = progress.streak
        lastAttemptAt = progress.lastAttemptAt
        lastScore = progress.lastScore
    }

    var progress: QuestionProgress {
        QuestionProgress(
            questionId: questionId,
            status: status,
            streak: streak,
            lastAttemptAt: lastAttemptAt,
            lastScore: lastScore
        )
    }
}

/// The `settings` table: one JSON envelope per key.
struct SettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "settings"

    var key: String
    var value: String
}

/// Column names shared by the repository extensions.
enum Col {
    static let id = Column("id")
    static let key = Column("key")
    static let classId = Column("classId")
    static let documentId = Column("documentId")
    static let questionId = Column("questionId")
    static let seed = Column("seed")
    static let kind = Column("kind")
    static let stem = Column("stem")
    static let sourceRef = Column("sourceRef")
    static let tags = Column("tags")
    static let type = Column("type")
    static let status = Column("status")
    static let statusDetail = Column("statusDetail")
    static let modelUsed = Column("modelUsed")
    static let sortOrder = Column("sortOrder")
    static let createdAt = Column("createdAt")
    static let importedAt = Column("importedAt")
    static let pageOrIndex = Column("pageOrIndex")
    static let storedPath = Column("storedPath")
    static let originalPath = Column("originalPath")
    static let groupId = Column("groupId")
    static let position = Column("position")
}
