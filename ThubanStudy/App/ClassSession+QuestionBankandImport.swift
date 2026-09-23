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

    /// Reloads the queue from the store (the whole bank), restarts it at the first question and switches to Study.
    func studyAll() async {
        setQueueScope(nil)
        await loadQuestions()
        if let first = questions.first {
            await select(question: first)
        } else {
            section = .study
        }
    }

    /// Studies just these questions: the queue is limited to them (in the usual mastery order) until "Study all".
    func study(selection: [Question]) async {
        guard !selection.isEmpty else { return }
        if selection.count == 1, let only = selection.first {
            await study(question: only)
            return
        }
        setQueueScope(Set(selection.map(\.id)))
        await loadQuestions()
        if let first = questions.first { await select(question: first) } else { section = .study }
    }

    /// Opens one question in Study over the whole bank (reloading the queue first so the bank and the queue agree).
    func study(question: Question) async {
        let scopeChanged = queueScope != nil
        setQueueScope(nil)
        // A question the study filter would hide: the filter goes, so the chosen question is what shows.
        if isStudyFiltered, !matchesStudyFilter(question) { await setStudyFilter(QuestionFilter()) }
        if scopeChanged || !questions.contains(where: { $0.id == question.id }) {
            await loadQuestions()
        }
        await select(question: question)
    }

    /// Leaves a selection-only queue and studies the whole bank again, keeping the current question.
    func clearStudySelection() async {
        guard queueScope != nil else { return }
        setQueueScope(nil)
        await loadQuestions()
    }

    /// Saves an edited question and refreshes the queue (re-instantiating it when it is the current one).
    func save(question: Question) async throws {
        try await store.update(question)
        let wasCurrent = currentQuestion?.id == question.id
        await loadQuestions()
        if wasCurrent { await instantiate(question, seed: nil) }
    }

    /// Saves several edited questions (a batch edit) and refreshes the queue.
    func save(questions edited: [Question]) async throws {
        for question in edited { try await store.update(question) }
        let current = currentQuestion?.id
        await loadQuestions()
        if let current, let question = edited.first(where: { $0.id == current }) { await instantiate(question, seed: nil) }
    }

    /// Forgets the attempts and progress of a question.
    func resetProgress(of question: Question) async throws {
        try await resetProgress(of: [question])
    }

    /// Forgets the attempts and progress of several questions.
    func resetProgress(of questions: [Question]) async throws {
        for question in questions { try await store.resetProgress(for: question.id) }
        await loadQuestions()
    }

    /// Removes a question from the bank.
    func delete(question: Question) async throws {
        try await delete(questions: [question])
    }

    /// Removes several questions from the bank.
    func delete(questions: [Question]) async throws {
        for question in questions { try await store.delete(question.id) }
        await loadQuestions()
    }

    /// Starts the import of every queued document with the app's current model policy.
    func startImport() {
        importPipeline.start(documents: importQueue, policy: app.modelPolicy, concurrency: app.questionBankSettings.defaults.parallelImports)
    }

    /// Queued documents waiting for "Add to class".
    var queuedDocuments: [ImportedDocument] { importQueue.filter { $0.status == .queued } }
}
