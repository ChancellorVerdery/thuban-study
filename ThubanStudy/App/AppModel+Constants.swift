import Foundation
import ThubanCore

/// Physical constants (g, R, c, standard pressure, table values) in regenerated questions never change: new templates
/// are checked as they are imported, and the bank was checked once, each constant pinned at the document's value.
extension AppModel {
    /// Settings flag: every class's templates were checked for constants once.
    static let constantsPinnedKey = SettingsKey("templates.constantsPinned.v2")

    /// `questions` with the constants of their templates pinned. On failure (no sign-in) they come back unchanged.
    func pinningConstants(in questions: [Question]) async -> [Question] {
        guard questions.contains(where: { $0.template != nil }) else { return questions }
        do {
            let marked = try await TemplateConstants(client: claudeClient).constants(in: questions)
            return questions.map { question in
                guard let names = marked[question.id], let template = question.template else { return question }
                var question = question
                question.template = template.pinning(names)
                return question
            }
        } catch {
            Self.logger.error("constants check failed: \(error.localizedDescription, privacy: .public)")
            return questions
        }
    }

    /// At launch, once: checks every class's templates and pins the constants found.
    func pinConstantsInBankOnce() async {
        guard !isPinningConstants, connection.isConnected,
              (try? await store.get(Self.constantsPinnedKey, as: Bool.self)) != true else { return }
        isPinningConstants = true
        defer { isPinningConstants = false }
        var allChecked = true
        for studyClass in classes {
            guard let all = try? await store.questions(in: studyClass.id, filter: nil) else { allChecked = false; continue }
            let templates = all.filter { $0.template != nil }
            guard !templates.isEmpty else { continue }
            do {
                let marked = try await TemplateConstants(client: claudeClient).constants(in: templates)
                for question in templates {
                    guard let names = marked[question.id], let template = question.template else { continue }
                    var updated = question
                    updated.template = template.pinning(names)
                    guard updated.template != template else { continue }
                    try await store.update(updated)
                    Self.logger.info("pinned \(names.sorted().joined(separator: ","), privacy: .public) in \(question.sourceRef ?? question.id.raw, privacy: .public)")
                }
                if let session = sessions[studyClass.id] { await session.reloadAfterTemplateChange() }
            } catch {
                allChecked = false
                Self.logger.error("constants check \(studyClass.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if allChecked { try? await store.set(Self.constantsPinnedKey, true) }
    }
}
