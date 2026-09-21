import XCTest
@testable import ThubanCore

/// Development harness: re-runs the figure workflow over every figure of the documents in the app's own
/// database (`$THUBAN_REANALYSE_DOC` = a document id, or "all"), using the app's stored credentials, and prints
/// the outcome per figure. It writes to the live database. Skipped unless the variable is set.
final class FigureReanalysisReportTests: XCTestCase {
    func testReanalyseStoredDocuments() async throws {
        guard let selector = ProcessInfo.processInfo.environment["THUBAN_REANALYSE_DOC"] else {
            throw XCTSkip("set THUBAN_REANALYSE_DOC to a document id or 'all'")
        }
        let store = try Store.open()
        let credentials = CredentialStore()
        let client = ClaudeClient(authProvider: { try await credentials.currentAuth() })
        let agent = FigureAgent(client: client)
        let engine = MathEngine()
        var documents: [ImportedDocument] = []
        for classId in try await store.allClasses().map(\.id) {
            documents += try await store.documents(in: classId).filter { selector == "all" || $0.id.raw.lowercased() == selector.lowercased() }
        }
        XCTAssertFalse(documents.isEmpty, "no document matched \(selector)")
        var lines: [String] = []
        let started = Date()
        for document in documents {
            print("REANALYSE \(document.filename)")
            let outcomes = try await FigureWorkflow.reanalyse(document: document, store: store, agent: agent, engine: engine) { done, total in
                print("  figure \(done) of \(total)")
            }
            for o in outcomes {
                let v = o.verification.map { ($0.passed ? "PASS " : "FAIL ") + $0.summary } ?? (o.isFigure ? "no chart" : "not a figure")
                lines.append("#\(o.index + 1) \(o.kind.rawValue) \(v)\n     def: \(o.definition ?? "-")\n     caption: \(o.caption ?? "-")")
            }
        }
        let report = lines.joined(separator: "\n")
        print("REANALYSIS REPORT (\(Int(Date().timeIntervalSince(started))) s)\n" + report)
        let out = ProcessInfo.processInfo.environment["THUBAN_REANALYSE_REPORT"] ?? NSTemporaryDirectory() + "reanalysis-report.txt"
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
