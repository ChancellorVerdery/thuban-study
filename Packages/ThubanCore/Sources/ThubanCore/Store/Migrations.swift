import Foundation
import GRDB

extension Store {
    /// The schema history. "v1" creates every table; later migrations are appended, never edited.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createClasses(db)
            try createDocuments(db)
            try createQuestions(db)
            try createFigures(db)
            try createAttempts(db)
            try createProgress(db)
            try createMessages(db)
            try createSettings(db)
        }
        migrator.registerMigration("v2-document-warnings") { db in
            // JSON [String]: what the import agent could not do as well as it wanted.
            try db.alter(table: "documents") { t in
                t.add(column: "warnings", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v3-question-type") { db in
            // The agent-classified problem type ("Initial value problems"); "" = unclassified.
            try db.alter(table: "questions") { t in
                t.add(column: "type", .text).notNull().defaults(to: "")
            }
            try db.create(index: "questions_on_class_type", on: "questions", columns: ["classId", "type"])
        }
        return migrator
    }

    /// Every migration identifier, in order.
    public static let migrationIdentifiers = ["v1", "v2-document-warnings", "v3-question-type"]

    /// Every table "v1" creates, in dependency order.
    public static let tableNames = [
        "classes", "documents", "questions", "figures", "attempts", "progress", "messages", "settings",
    ]

    private static func createClasses(_ db: Database) throws {
        try db.create(table: "classes") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("courseCode", .text)
            t.column("term", .text)
            t.column("tint", .text)
            t.column("tutorStyle", .text).notNull().defaults(to: TutorStyle.socratic.rawValue)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
        }
    }

    private static func createDocuments(_ db: Database) throws {
        try db.create(table: "documents") { t in
            t.primaryKey("id", .text)
            t.column("classId", .text).notNull().indexed().references("classes", onDelete: .cascade)
            t.column("filename", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("storedPath", .text).notNull()
            t.column("byteCount", .integer).notNull().defaults(to: 0)
            t.column("importedAt", .datetime).notNull()
            t.column("status", .text).notNull()
            t.column("statusDetail", .text)
            t.column("modelUsed", .text)
            t.column("classification", .text)
            t.column("questionCount", .integer).notNull().defaults(to: 0)
            t.column("figureCount", .integer).notNull().defaults(to: 0)
        }
    }

    private static func createQuestions(_ db: Database) throws {
        try db.create(table: "questions") { t in
            t.primaryKey("id", .text)
            t.column("classId", .text).notNull().indexed().references("classes", onDelete: .cascade)
            t.column("documentId", .text).indexed().references("documents", onDelete: .cascade)
            t.column("sourceRef", .text)
            t.column("kind", .text).notNull()
            t.column("stem", .text).notNull()
            t.column("parts", .text).notNull()        // JSON [QuestionPart]
            t.column("template", .text)               // JSON MathTemplate?
            t.column("figureIds", .text).notNull()    // JSON [FigureID]
            t.column("tags", .text).notNull()         // JSON [String]
            t.column("difficulty", .integer).notNull().defaults(to: 3)
            t.column("createdAt", .datetime).notNull()
        }
    }

    private static func createFigures(_ db: Database) throws {
        try db.create(table: "figures") { t in
            t.primaryKey("id", .text)
            t.column("documentId", .text).notNull().indexed().references("documents", onDelete: .cascade)
            t.column("pageOrIndex", .integer).notNull().defaults(to: 0)
            t.column("originalPath", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("chart", .text)                  // JSON StandardChart?
            t.column("status", .text).notNull()
            t.column("caption", .text)
        }
    }

    private static func createAttempts(_ db: Database) throws {
        try db.create(table: "attempts") { t in
            t.primaryKey("id", .text)
            t.column("questionId", .text).notNull().references("questions", onDelete: .cascade)
            t.column("seed", .text).notNull()
            t.column("responses", .text).notNull()    // JSON [partId: String]
            t.column("verdicts", .text).notNull()     // JSON [partId: Verdict]
            t.column("score", .double).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "attempts_on_questionId_createdAt", on: "attempts", columns: ["questionId", "createdAt"])
    }

    private static func createProgress(_ db: Database) throws {
        try db.create(table: "progress") { t in
            t.primaryKey("questionId", .text).references("questions", onDelete: .cascade)
            t.column("classId", .text).notNull().indexed().references("classes", onDelete: .cascade)
            t.column("status", .text).notNull().defaults(to: ProgressStatus.new.rawValue)
            t.column("streak", .integer).notNull().defaults(to: 0)
            t.column("lastAttemptAt", .datetime)
            t.column("lastScore", .double)
        }
    }

    private static func createMessages(_ db: Database) throws {
        try db.create(table: "messages") { t in
            t.primaryKey("id", .text)
            t.column("classId", .text).notNull().indexed().references("classes", onDelete: .cascade)
            t.column("questionId", .text).indexed().references("questions", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("toolEvents", .text).notNull()   // JSON [ToolEvent]
            t.column("solutionRequested", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
        }
    }

    private static func createSettings(_ db: Database) throws {
        try db.create(table: "settings") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()        // JSON envelope {"v": …}
        }
    }
}
