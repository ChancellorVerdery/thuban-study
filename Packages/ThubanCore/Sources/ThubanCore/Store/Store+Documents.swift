import Foundation
import GRDB

extension Store: DocumentRepository {
    public func documents(in classId: ClassID) async throws -> [ImportedDocument] {
        try await read { db in
            try ImportedDocument
                .filter(Col.classId == classId)
                .order(Col.importedAt.desc, Col.id)
                .fetchAll(db)
        }
    }

    /// One document, or `nil` when it does not exist.
    public func document(id: DocumentID) async throws -> ImportedDocument? {
        try await read { db in try ImportedDocument.fetchOne(db, id: id) }
    }

    public func insert(_ document: ImportedDocument) async throws {
        try await write { db in try document.insert(db) }
    }

    /// Replaces every column of the document.
    public func update(_ document: ImportedDocument) async throws {
        try await write { db in try document.update(db) }
    }

    public func update(status: ImportStatus, detail: String?, model: String?, for id: DocumentID) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE documents SET status = ?, statusDetail = ?, modelUsed = ? WHERE id = ?",
                arguments: [status, detail, model, id]
            )
            guard db.changesCount > 0 else { throw ThubanError.store("No document with id \(id)") }
        }
    }

    /// Updates the classification, the counts and the warnings the import pipeline produced.
    public func update(
        classification: DocumentClassification?,
        questionCount: Int,
        figureCount: Int,
        warnings: [String] = [],
        for id: DocumentID
    ) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(warnings), as: UTF8.self)
        try await write { db in
            try db.execute(
                sql: "UPDATE documents SET classification = ?, questionCount = ?, figureCount = ?, warnings = ? WHERE id = ?",
                arguments: [classification, questionCount, figureCount, encoded, id]
            )
            guard db.changesCount > 0 else { throw ThubanError.store("No document with id \(id)") }
        }
    }

    public func delete(_ id: DocumentID) async throws {
        try await delete(id, deleteFiles: false)
    }

    /// Removes the document row (cascading to figures and questions) and, with `deleteFiles`, its stored file
    /// and figure PNGs.
    public func delete(_ id: DocumentID, deleteFiles: Bool) async throws {
        let files = try await write { db -> ClassFiles in
            let files = deleteFiles ? try ClassFiles.collect(db, documentId: id) : ClassFiles()
            _ = try ImportedDocument.deleteOne(db, id: id)
            return files
        }
        removeFiles(files)
    }
}
