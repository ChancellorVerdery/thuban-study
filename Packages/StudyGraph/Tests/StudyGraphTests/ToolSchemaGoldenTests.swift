import Foundation
import ThubanCore
import XCTest

/// The tutor's tool names, parameter schemas and `required` lists must stay byte-identical to what Study shipped
/// with Desmos (STUDY_INTEGRATION.md §6): the golden files were recorded from `main` before the engine switch.
/// Re-record only for an intended schema change: `STUDYGRAPH_RECORD_GOLDEN=1 swift test --filter ToolSchemaGolden`.
final class ToolSchemaGoldenTests: XCTestCase {
    private static var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden", isDirectory: true)
    }

    static func encode(_ specs: [ToolSpec]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(specs)
        data.append(0x0A)
        return data
    }

    private func check(mayEditGraph: Bool, file: String) throws {
        let url = Self.goldenDirectory.appendingPathComponent(file)
        let actual = try Self.encode(TutorTools.specs(mayEditGraph: mayEditGraph))
        if ProcessInfo.processInfo.environment["STUDYGRAPH_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            try actual.write(to: url)
            throw XCTSkip("recorded \(file)")
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: actual, as: UTF8.self), String(decoding: expected, as: UTF8.self),
                       "TutorTools.specs(mayEditGraph: \(mayEditGraph)) changed; the tutor's tool schemas must stay byte-identical")
    }

    func testToolSchemasWithGraphEditingMatchGolden() throws {
        try check(mayEditGraph: true, file: "tool-specs-edit.json")
    }

    func testToolSchemasWithoutGraphEditingMatchGolden() throws {
        try check(mayEditGraph: false, file: "tool-specs-no-edit.json")
    }

    func testEveryGraphToolIsExecutedByStudyGraph() {
        let names = Set(TutorTools.specs.map(\.name))
        XCTAssertEqual(names.count, 8)
        XCTAssertTrue(TutorTools.graphEditingTools.isSubset(of: names))
        XCTAssertEqual(names.subtracting([TutorTools.showCalculator, TutorTools.getStudentWork]).count, 6)
    }
}
