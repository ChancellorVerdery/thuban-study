import Foundation
import GRDB

extension Store: FigureRepository {
    public func figures(for documentId: DocumentID) async throws -> [Figure] {
        try await read { db in
            try Figure
                .filter(Col.documentId == documentId)
                .order(Col.pageOrIndex, Col.id)
                .fetchAll(db)
        }
    }

    /// The figures with the given ids (e.g. `Question.figureIds`), in the order requested; missing ids are skipped.
    public func figures(ids: [FigureID]) async throws -> [Figure] {
        guard !ids.isEmpty else { return [] }
        let fetched = try await read { db in
            try Figure.filter(ids.contains(Col.id)).fetchAll(db)
        }
        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// One figure, or `nil` when it does not exist.
    public func figure(id: FigureID) async throws -> Figure? {
        try await read { db in try Figure.fetchOne(db, id: id) }
    }

    public func insert(_ figure: Figure) async throws {
        try await write { db in try figure.insert(db) }
    }

    public func update(_ figure: Figure) async throws {
        try await write { db in try figure.update(db) }
    }

    /// Removes the figure row and, with `deleteFile`, its PNG.
    public func delete(_ id: FigureID, deleteFile: Bool = false) async throws {
        let paths = try await write { db -> [String] in
            let paths = deleteFile
                ? try String.fetchAll(db, sql: "SELECT originalPath FROM figures WHERE id = ?", arguments: [id])
                : []
            _ = try Figure.deleteOne(db, id: id)
            return paths
        }
        removeFiles(ClassFiles(documentPaths: [], figurePaths: paths))
    }

    /// Removes every figure row of a document (and, with `deleteFiles`, their PNGs), so a rerun of the import
    /// starts from a clean slate instead of duplicating figures. Returns the number of rows removed.
    @discardableResult
    public func deleteFigures(for documentId: DocumentID, deleteFiles: Bool) async throws -> Int {
        let (paths, count) = try await write { db -> ([String], Int) in
            let paths = deleteFiles
                ? try String.fetchAll(db, sql: "SELECT originalPath FROM figures WHERE documentId = ?", arguments: [documentId])
                : []
            let count = try Figure.filter(Col.documentId == documentId).deleteAll(db)
            return (paths, count)
        }
        removeFiles(ClassFiles(documentPaths: [], figurePaths: paths))
        return count
    }
}
