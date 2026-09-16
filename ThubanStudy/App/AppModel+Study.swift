import Foundation
import ThubanCore

extension AppModel {
    /// The model the tutor talks with (the pinned one, else the policy default).
    var tutorModel: ClaudeModel { modelPolicy.effectiveModel }

    /// A tutor agent on the shared Messages client. Cheap to create; one per reply.
    func makeTutorAgent() -> TutorAgent {
        TutorAgent(client: claudeClient)
    }

    /// True when the grapher can load Desmos (a key is configured in Settings › Grapher or Secrets.plist).
    var hasDesmosKey: Bool {
        !desmosKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
