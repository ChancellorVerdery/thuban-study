import Foundation
import ThubanCore

/// Problem types come from `QuestionCategorizer` (one model for every class), never from the agent that wrote the
/// questions: new questions are categorized before they enter the bank, and at launch any question still without a
/// type is categorized in the background.
extension AppModel {
    /// Settings flag: the types written by the import agents were cleared once so the categorizer could name them all.
    static let categoriesResetKey = SettingsKey("categories.resetForCategorizer")

    /// `questions` with their problem types, reusing the class's existing types. Without a sign-in (or on failure)
    /// they come back unclassified and are categorized at a later launch.
    func categorized(_ questions: [Question], in classId: ClassID) async -> [Question] {
        guard !questions.isEmpty else { return questions }
        let existing = (try? await store.questionTypes(in: classId))?.map(\.type) ?? []
        do {
            let types = try await QuestionCategorizer(client: claudeClient)
                .categorize(questions, existing: existing, classContext: classContext(for: classId))
            return questions.map { question in
                var question = question
                question.type = types[question.id] ?? ""
                return question
            }
        } catch {
            Self.logger.error("categorize failed: \(error.localizedDescription, privacy: .public)")
            return questions.map { question in
                var question = question
                question.type = ""
                return question
            }
        }
    }

    /// At launch: clears the import agents' types once, then categorizes every unclassified question, class by class.
    func categorizeUnclassifiedQuestions() async {
        guard !isCategorizing else { return }
        isCategorizing = true
        defer { isCategorizing = false }
        do {
            if try await store.get(Self.categoriesResetKey, as: Bool.self) != true {
                try await store.clearAllTypes()
                try await store.set(Self.categoriesResetKey, true)
            }
        } catch {
            Self.logger.error("clearing types failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard connection.isConnected else { return }
        for studyClass in classes {
            guard let all = try? await store.questions(in: studyClass.id, filter: nil) else { continue }
            let unclassified = all.filter { $0.type.isEmpty }
            guard !unclassified.isEmpty else { continue }
            categorizingClass = studyClass.id
            let existing = (try? await store.questionTypes(in: studyClass.id))?.map(\.type) ?? []
            do {
                let types = try await QuestionCategorizer(client: claudeClient)
                    .categorize(unclassified, existing: existing, classContext: classContext(for: studyClass.id))
                try await store.setTypes(types)
                Self.logger.info("categorized \(types.count, privacy: .public) of \(unclassified.count, privacy: .public) in \(studyClass.name, privacy: .public)")
            } catch {
                Self.logger.error("categorize \(studyClass.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            if let session = sessions[studyClass.id] { await session.loadQuestions() }
            categoriesChanged &+= 1
        }
        categorizingClass = nil
    }
}
