import Foundation
import ThubanCore

/// "Sketch the processes on p–V coordinates" parts imported before diagrams existed were free response; once, they
/// are converted to gradable diagram parts where the sketch is states joined by processes (`DiagramConverter`).
extension AppModel {
    /// Settings flag: every class's sketch parts were offered to the converter once.
    static let diagramsConvertedKey = SettingsKey("diagrams.converted")

    func convertSketchPartsOnce() async {
        guard !isConvertingDiagrams, connection.isConnected,
              (try? await store.get(Self.diagramsConvertedKey, as: Bool.self)) != true else { return }
        isConvertingDiagrams = true
        defer { isConvertingDiagrams = false }
        var allDone = true
        let converter = DiagramConverter(client: claudeClient)
        for studyClass in classes {
            guard let all = try? await store.questions(in: studyClass.id, filter: nil) else { allDone = false; continue }
            var changed = false
            for question in all where question.parts.contains(where: DiagramConverter.isCandidate) {
                var updated = question
                for index in updated.parts.indices where DiagramConverter.isCandidate(updated.parts[index]) {
                    do {
                        guard let spec = try await converter.convert(updated.parts[index], of: question) else { continue }
                        updated.parts[index].answerKind = .diagram
                        updated.parts[index].answer.diagram = spec
                        Self.logger.info("diagram part \(updated.parts[index].id, privacy: .public) in \(question.sourceRef ?? question.id.raw, privacy: .public)")
                    } catch {
                        allDone = false
                        Self.logger.error("diagram conversion failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                guard updated != question else { continue }
                do {
                    try await store.update(updated)
                    changed = true
                } catch {
                    allDone = false
                }
            }
            if changed, let session = sessions[studyClass.id] { await session.reloadAfterTemplateChange() }
        }
        if allDone { try? await store.set(Self.diagramsConvertedKey, true) }
    }
}
