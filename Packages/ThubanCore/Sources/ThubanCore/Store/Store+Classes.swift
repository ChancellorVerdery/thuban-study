import Foundation
import GRDB

extension Store: ClassRepository {
    public func allClasses() async throws -> [StudyClass] {
        try await read { db in
            try StudyClass.order(Col.sortOrder, Col.createdAt, Col.id).fetchAll(db)
        }
    }

    /// One class, or `nil` when it does not exist.
    public func studyClass(id: ClassID) async throws -> StudyClass? {
        try await read { db in try StudyClass.fetchOne(db, id: id) }
    }

    public func insert(_ studyClass: StudyClass) async throws {
        try await write { db in try studyClass.insert(db) }
    }

    public func update(_ studyClass: StudyClass) async throws {
        try await write { db in try studyClass.update(db) }
    }

    public func delete(_ id: ClassID, deleteFiles: Bool) async throws {
        let files = try await write { db -> ClassFiles in
            let files = deleteFiles ? try ClassFiles.collect(db, classId: id) : ClassFiles()
            _ = try StudyClass.deleteOne(db, id: id)
            return files
        }
        removeFiles(files)
    }

    /// Persists a new ordering: `ids[i].sortOrder = i`. Unknown ids are ignored.
    public func reorderClasses(_ ids: [ClassID]) async throws {
        try await write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE classes SET sortOrder = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }
    }

    /// Deletes stored files after their rows are gone. The rows are already committed, so a file that cannot be
    /// removed (in use, permissions, an unresolvable path) is logged and returned rather than thrown: callers must
    /// see the deletion as done, or their state would keep showing rows that no longer exist.
    @discardableResult
    func removeFiles(_ files: ClassFiles) -> [String] {
        let failed = Store.removeFiles(files.documentPaths, under: locations.documents)
            + Store.removeFiles(files.figurePaths, under: locations.figures)
        if !failed.isEmpty {
            Store.logger.error("Rows deleted but \(failed.count) file(s) were left behind: \(failed.joined(separator: ", "), privacy: .public)")
        }
        return failed
    }
}

/// Relative paths of the files a set of rows point at, gathered before those rows are deleted.
struct ClassFiles: Sendable {
    var documentPaths: [String] = []
    var figurePaths: [String] = []

    static func collect(_ db: Database, classId: ClassID) throws -> ClassFiles {
        let documentIds = try DocumentID.fetchAll(db, sql: "SELECT id FROM documents WHERE classId = ?", arguments: [classId])
        var files = ClassFiles()
        files.documentPaths = try String.fetchAll(
            db, sql: "SELECT storedPath FROM documents WHERE classId = ?", arguments: [classId]
        )
        files.figurePaths = try figurePaths(db, documentIds: documentIds)
        return files
    }

    static func collect(_ db: Database, documentId: DocumentID) throws -> ClassFiles {
        var files = ClassFiles()
        files.documentPaths = try String.fetchAll(
            db, sql: "SELECT storedPath FROM documents WHERE id = ?", arguments: [documentId]
        )
        files.figurePaths = try figurePaths(db, documentIds: [documentId])
        return files
    }

    private static func figurePaths(_ db: Database, documentIds: [DocumentID]) throws -> [String] {
        guard !documentIds.isEmpty else { return [] }
        return try String.fetchAll(
            db,
            Figure.filter(documentIds.contains(Col.documentId)).select(Col.originalPath, as: String.self)
        )
    }
}
