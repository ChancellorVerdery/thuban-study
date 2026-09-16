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
        try removeFiles(files)
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

    /// Deletes stored files after their rows are gone; throws when any file could not be removed.
    func removeFiles(_ files: ClassFiles) throws {
        let failed = Store.removeFiles(files.documentPaths, under: locations.documents)
            + Store.removeFiles(files.figurePaths, under: locations.figures)
        guard failed.isEmpty else {
            throw ThubanError.store("Could not delete \(failed.count) file(s): \(failed.joined(separator: ", "))")
        }
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
