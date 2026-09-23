import AppKit
import ThubanCore
import os

/// Development harness driven by `THUBAN_IMPORT=<file>|<file>…` (and `THUBAN_IMPORT_CLASS=<class name>`): adds the
/// files to that class (created when missing) and imports them exactly as "Add to class" does, waits for the run to
/// finish, prints each document's outcome and quits. Point `THUBAN_HOME` at a copy of the data: it writes there.
@MainActor
enum ImportHarness {
    static let variable = "THUBAN_IMPORT"

    static func startIfEnabled(app: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment[variable], !raw.isEmpty else { return }
        let urls = raw.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        let className = ProcessInfo.processInfo.environment["THUBAN_IMPORT_CLASS"] ?? "Import test"
        Task { @MainActor in
            await run(app: app, urls: urls, className: className)
            NSApp.terminate(nil)
        }
    }

    private static func run(app: AppModel, urls: [URL], className: String) async {
        do {
            let existing = try await app.store.allClasses().first { $0.name == className }
            let studyClass: StudyClass
            if let existing { studyClass = existing } else { studyClass = try await app.createClass(name: className) }
            let session = app.session(for: studyClass.id)
            await session.loadDocuments()
            let queued = await session.enqueue(urls: urls)
            print("IMPORT queued \(queued.map(\.filename))")
            session.startImport()
            for _ in 0..<100 where !session.importPipeline.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            var last = ""
            while session.importPipeline.isRunning {
                let line = session.importPipeline.activities.map { "\($0.filename.prefix(20)): \($0.detail)" }.joined(separator: " | ")
                if line != last { print("IMPORT \(line)"); last = line }
                try await Task.sleep(for: .seconds(5))
            }
            await session.loadDocuments()
            for document in session.importQueue where queued.contains(where: { $0.id == document.id }) {
                print("IMPORT done \(document.filename): status=\(document.status.rawValue) questions=\(document.questionCount) figures=\(document.figureCount) \(document.statusDetail ?? "")")
                for warning in document.warnings { print("IMPORT warning \(document.filename): \(warning)") }
            }
        } catch {
            print("IMPORT error \(error.localizedDescription)")
        }
    }
}
