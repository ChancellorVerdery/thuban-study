import CryptoKit
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

    /// Every figure of a class: those of its documents (document order, then page) followed by figures whose
    /// document was removed but which the class's questions still use.
    public func figures(in classId: ClassID) async throws -> [Figure] {
        try await read { db in
            let documentIds = try DocumentID.fetchAll(
                db, sql: "SELECT id FROM documents WHERE classId = ? ORDER BY importedAt DESC", arguments: [classId]
            )
            var out: [Figure] = []
            for documentId in documentIds {
                out += try Figure.filter(Col.documentId == documentId).order(Col.pageOrIndex, Col.id).fetchAll(db)
            }
            let referenced = Set(try Question.filter(Col.classId == classId).fetchAll(db).flatMap(\.figureIds))
            if !referenced.isEmpty {
                out += try Figure.filter(Col.documentId == nil && referenced.contains(Col.id)).order(Col.pageOrIndex, Col.id).fetchAll(db)
            }
            return out
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

    /// Merges figures whose image files are byte-for-byte identical (the same sketch offered under several parts
    /// or questions) into one: the earliest keeps its row and file, every question that cited a duplicate cites
    /// the kept figure instead, and the duplicates' rows and files go. Returns how many were merged.
    @discardableResult
    public func dedupeFigures(in classId: ClassID) async throws -> Int {
        let figures = try await figures(in: classId)
        var keptByHash: [Data: FigureID] = [:]
        var replacement: [FigureID: FigureID] = [:]
        for figure in figures.sorted(by: { ($0.documentId?.raw ?? "", $0.pageOrIndex, $0.id.raw) < ($1.documentId?.raw ?? "", $1.pageOrIndex, $1.id.raw) }) {
            guard let data = try? Data(contentsOf: locations.figures.appendingPathComponent(figure.originalPath)), !data.isEmpty else { continue }
            let hash = Self.digest(data)
            if let kept = keptByHash[hash] {
                // Prefer to keep a figure that has already been analysed over a pending duplicate.
                replacement[figure.id] = kept
            } else {
                keptByHash[hash] = figure.id
            }
        }
        guard !replacement.isEmpty else { return 0 }
        // A kept figure that is still pending inherits an analysed duplicate's reading.
        let byId = Dictionary(figures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (duplicate, kept) in replacement {
            guard var keptFigure = byId[kept], keptFigure.chart == nil, let duplicateFigure = byId[duplicate], duplicateFigure.chart != nil else { continue }
            keptFigure.chart = duplicateFigure.chart
            keptFigure.kind = duplicateFigure.kind
            keptFigure.caption = duplicateFigure.caption
            keptFigure.status = duplicateFigure.status
            try await update(keptFigure)
        }
        let questions = try await self.questions(in: classId, filter: nil)
        for var question in questions where question.figureIds.contains(where: { replacement[$0] != nil })
            || question.choiceFigureIds.contains(where: { replacement[$0] != nil }) {
            var seen: Set<FigureID> = []
            question.figureIds = question.figureIds.map { replacement[$0] ?? $0 }.filter { seen.insert($0).inserted }
            for p in question.parts.indices {
                question.parts[p].choiceFigures = question.parts[p].choiceFigures?.map { replacement[$0] ?? $0 }
            }
            try await update(question)
        }
        for duplicate in replacement.keys {
            try await delete(duplicate, deleteFile: true)
        }
        return replacement.count
    }

    /// SHA-256 of image bytes.
    static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
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
