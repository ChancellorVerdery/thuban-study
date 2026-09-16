import Foundation
import ThubanCore

/// Import-related helpers on the root model.
extension AppModel {
    /// One-line description of a class for the import agent's prompt.
    func classContext(for classId: ClassID) -> String {
        guard let studyClass = classes.first(where: { $0.id == classId }) else { return "an unnamed class" }
        var parts = [studyClass.name]
        if let code = studyClass.courseCode, !code.isEmpty { parts.append(code) }
        if let term = studyClass.term, !term.isEmpty { parts.append(term) }
        return parts.joined(separator: " · ")
    }

    /// Flips the "agent may escalate to Opus" switch of the persisted policy.
    func setAllowEscalation(_ allowed: Bool) {
        var policy = modelPolicy
        policy.allowEscalation = allowed
        setModelPolicy(policy)
    }

    /// The model the import agent starts with, and the one it may escalate to (nil when escalation is off).
    var importModels: (defaultModel: ClaudeModel, escalation: ClaudeModel?) {
        (modelPolicy.effectiveModel, modelPolicy.escalationModel)
    }
}
