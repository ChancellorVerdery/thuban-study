import AppKit
import ThubanCore
import os

/// Development harness driven by `THUBAN_REGENERATE=<part of a filename>`: runs the matching finished document
/// through the import agent again (`ClassSession.regenerateDocument`), exactly as the Import page's "Regenerate"
/// does, waits for the run to finish, logs the outcome and quits. It writes to the data under `THUBAN_HOME`.
@MainActor
enum RegenerateHarness {
    static let variable = "THUBAN_REGENERATE"
    private static let logger = Logger(subsystem: "com.thuban.study", category: "regenerate")

    static func startIfEnabled(app: AppModel) {
        guard let match = ProcessInfo.processInfo.environment[variable]?.lowercased(), !match.isEmpty else { return }
        Task { @MainActor in
            await run(app: app, match: match)
            NSApp.terminate(nil)
        }
    }

    private static func run(app: AppModel, match: String) async {
        do {
            for studyClass in try await app.store.allClasses() {
                let session = app.session(for: studyClass.id)
                await session.loadQuestions()
                await session.loadDocuments()
                guard let document = session.importQueue.first(where: { $0.filename.lowercased().contains(match) }) else { continue }
                logger.notice("regenerating \(document.filename, privacy: .public)")
                print("REGENERATE start \(document.filename)")
                await session.regenerateDocument(document.id)
                // Wait for the run to start and to finish.
                for _ in 0..<100 where !session.importPipeline.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                while session.importPipeline.isRunning {
                    if let detail = session.importPipeline.activity(for: document.id)?.detail { print("REGENERATE \(detail)") }
                    try await Task.sleep(for: .seconds(5))
                }
                let finished = session.importQueue.first { $0.id == document.id }
                print("REGENERATE done status=\(finished?.status.rawValue ?? "?") questions=\(finished?.questionCount ?? -1) detail=\(finished?.statusDetail ?? "")")
                for warning in finished?.warnings ?? [] { print("REGENERATE warning: \(warning)") }
                return
            }
            print("REGENERATE no document matches \(match)")
        } catch {
            print("REGENERATE error \(error.localizedDescription)")
        }
    }
}
