import Foundation
import ThubanCore
import os

extension AppModel {
    private static let suggestionLogger = Logger(subsystem: "com.thuban.study", category: "equation-suggestions")
    /// One suggestion pass at a time per class, so files imported together never suggest the same equation twice.
    @MainActor private static var suggestionChains: [ClassID: Task<Int, Never>] = [:]

    /// Asks the equation suggester which general equations, rules and constants `questions` need that the class's
    /// sheet lacks, and stores them as pending suggestions. Returns how many were added (0 on any failure: a
    /// suggestion is a convenience, never a reason for an import to fail).
    @MainActor
    @discardableResult
    func suggestEquations(for questions: [Question], in classId: ClassID, documentId: DocumentID?) async -> Int {
        guard !questions.isEmpty, isConnected else { return 0 }
        let previous = Self.suggestionChains[classId]
        let task = Task { @MainActor [store, claudeClient] () -> Int in
            _ = await previous?.value
            do {
                let sheet = try await store.equationSheet(for: classId)
                let earlier = try await store.equationSuggestions(in: classId)
                let suggester = EquationSuggester(client: claudeClient)
                let found = try await suggester.suggest(for: questions, classId: classId, classContext: self.classContext(for: classId),
                                                        sheet: sheet, earlier: earlier, documentId: documentId)
                try await store.addEquationSuggestions(found)
                return found.count
            } catch {
                Self.suggestionLogger.error("equation suggestions failed: \(error.localizedDescription, privacy: .public)")
                return 0
            }
        }
        Self.suggestionChains[classId] = task
        let added = await task.value
        if added > 0 { await sessions[classId]?.loadEquationSuggestions() }
        return added
    }
}
