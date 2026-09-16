import Foundation
import ThubanCore

/// Question-bank and import helpers on the per-class session (computed state and actions only).
extension ClassSession {
    /// The import pipeline for this class (created lazily, kept for the app's lifetime).
    var importPipeline: ImportPipeline { ImportPipeline.pipeline(for: self) }

    /// Documents keyed by id, for source labels in the bank.
    var documentsById: [DocumentID: ImportedDocument] {
        Dictionary(importQueue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Display name of a question's source: the source reference, else the document's filename.
    func sourceLabel(for question: Question) -> String {
        if let ref = question.sourceRef, !ref.isEmpty { return ref }
        if let documentId = question.documentId, let document = documentsById[documentId] { return document.filename }
        return "Manual"
    }

    /// Reloads the queue from the store, restarts it at the first question and switches to Study.
    func studyAll() async {
        await loadQuestions()
        if let first = questions.first {
            await select(question: first)
        } else {
            section = .study
        }
    }

    /// Opens one question in Study (reloading the queue first so the bank and the queue agree).
    func study(question: Question) async {
        if !questions.contains(where: { $0.id == question.id }) {
            await loadQuestions()
        }
        await select(question: question)
    }

    /// Saves an edited question and refreshes the queue (re-instantiating it when it is the current one).
    func save(question: Question) async throws {
        try await store.update(question)
        let wasCurrent = currentQuestion?.id == question.id
        await loadQuestions()
        if wasCurrent { await instantiate(question, seed: nil) }
    }

    /// Forgets the attempts and progress of a question.
    func resetProgress(of question: Question) async throws {
        try await store.resetProgress(for: question.id)
        await loadQuestions()
    }

    /// Removes a question from the bank.
    func delete(question: Question) async throws {
        try await store.delete(question.id)
        await loadQuestions()
    }

    /// Starts the import of every queued document with the app's current model policy.
    func startImport() {
        importPipeline.start(documents: importQueue, policy: app.modelPolicy)
    }

    /// Queued documents waiting for "Add to class".
    var queuedDocuments: [ImportedDocument] { importQueue.filter { $0.status == .queued } }
}
