import Foundation

public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case pdf, docx, pptx, xlsx, csv, html, mhtml, markdown, text, image, other
}

public enum ImportStatus: String, Codable, Sendable, CaseIterable {
    case queued, reading, extractingFigures, generating, escalated, done, failed

    /// True once the pipeline will not touch the document again.
    public var isTerminal: Bool { self == .done || self == .failed }
}

/// What the import agent decided the document is.
public enum DocumentClassification: String, Codable, Sendable, CaseIterable {
    case existingQuestions, readingMaterial, mixed
}

/// A file the student dropped into a class. The bytes live under `AppPaths.documents/<storedPath>`.
public struct ImportedDocument: Codable, Identifiable, Sendable, Equatable {
    public var id: DocumentID
    public var classId: ClassID
    public var filename: String
    public var kind: DocumentKind
    /// Relative path under `AppPaths.documents`.
    public var storedPath: String
    public var byteCount: Int
    public var importedAt: Date
    public var status: ImportStatus
    /// Human-readable progress, e.g. "Reading pages 4–9 of 22".
    public var statusDetail: String?
    /// Raw model id, e.g. "claude-sonnet-5" or "claude-opus-5".
    public var modelUsed: String?
    public var classification: DocumentClassification?
    public var questionCount: Int
    public var figureCount: Int

    public init(
        id: DocumentID = .new(),
        classId: ClassID,
        filename: String,
        kind: DocumentKind,
        storedPath: String,
        byteCount: Int = 0,
        importedAt: Date = Date(),
        status: ImportStatus = .queued,
        statusDetail: String? = nil,
        modelUsed: String? = nil,
        classification: DocumentClassification? = nil,
        questionCount: Int = 0,
        figureCount: Int = 0
    ) {
        self.id = id
        self.classId = classId
        self.filename = filename
        self.kind = kind
        self.storedPath = storedPath
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.status = status
        self.statusDetail = statusDetail
        self.modelUsed = modelUsed
        self.classification = classification
        self.questionCount = questionCount
        self.figureCount = figureCount
    }
}
