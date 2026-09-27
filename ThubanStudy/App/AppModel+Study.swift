import Foundation
import ThubanCore

extension AppModel {
    /// The model the tutor talks with (the pinned one, else the policy default).
    var tutorModel: ClaudeModel { modelPolicy.effectiveModel }

    /// A tutor agent on the shared Messages client. Cheap to create; one per reply.
    func makeTutorAgent() -> TutorAgent {
        TutorAgent(client: claudeClient)
    }
}
