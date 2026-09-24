import Foundation
import ThubanCore

/// Problem types come from `QuestionCategorizer` (one model for every class), never from the agent that wrote the
/// questions: new questions are categorized before they enter the bank, and at launch any question still without a
/// type is categorized in the background.
extension AppModel {
    /// Settings flag: the types written by the import agents were cleared once so the categorizer could name them all.
    static let categoriesResetKey = SettingsKey("categories.resetForCategorizer")
    /// Settings flag: every class's types were consolidated once (later, a class is consolidated after it gains types).
    static let categoriesConsolidatedKey = SettingsKey("categories.consolidated.v2")

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
        let consolidatedOnce = (try? await store.get(Self.categoriesConsolidatedKey, as: Bool.self)) == true
        var allConsolidated = true
        for studyClass in classes {
            guard let all = try? await store.questions(in: studyClass.id, filter: nil) else { allConsolidated = false; continue }
            let unclassified = all.filter { $0.type.isEmpty }
            guard !unclassified.isEmpty || !consolidatedOnce else { continue }
            categorizingClass = studyClass.id
            defer { categoriesChanged &+= 1 }
            if !unclassified.isEmpty {
                await categorize(unclassified, of: studyClass)
            }
            if await !consolidate(studyClass) { allConsolidated = false }
            if let session = sessions[studyClass.id] { await session.loadQuestions() }
        }
        if !consolidatedOnce, allConsolidated { try? await store.set(Self.categoriesConsolidatedKey, true) }
        categorizingClass = nil
    }

    /// Folds together the class's types that name the same kind of problem. False when it could not run.
    private func consolidate(_ studyClass: StudyClass) async -> Bool {
        guard let types = try? await store.questionTypes(in: studyClass.id) else { return false }
        do {
            let map = try await QuestionCategorizer(client: claudeClient).consolidate(types, classContext: classContext(for: studyClass.id))
            try await store.renameTypes(map, in: studyClass.id)
            Self.logger.info("merged \(map.count, privacy: .public) types in \(studyClass.name, privacy: .public)")
            return true
        } catch {
            Self.logger.error("consolidate \(studyClass.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func categorize(_ unclassified: [Question], of studyClass: StudyClass) async {
        let existing = (try? await store.questionTypes(in: studyClass.id))?.map(\.type) ?? []
        do {
            let types = try await QuestionCategorizer(client: claudeClient)
                .categorize(unclassified, existing: existing, classContext: classContext(for: studyClass.id))
            try await store.setTypes(types)
            Self.logger.info("categorized \(types.count, privacy: .public) of \(unclassified.count, privacy: .public) in \(studyClass.name, privacy: .public)")
        } catch {
            Self.logger.error("categorize \(studyClass.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
