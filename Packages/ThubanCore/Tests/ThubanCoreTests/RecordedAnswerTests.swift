import XCTest
@testable import ThubanCore

final class RecordedAnswerTests: XCTestCase {
    func testSelectedOptionsAndGradeMarksReachTheText() throws {
        let html = """
        <html><body><p>Which is right?</p>
        <div><input type="radio" name="q" value="1"> Option A</div>
        <div><input type="radio" name="q" value="2" checked="checked"> Option B
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="Correct: Your answer is correct." width="12" height="12"></div>
        <input type="radio" name="q" checked="true" role="presentation" aria-hidden="true">
        </body></html>
        """
        let content = try HtmlParser.parse(html: html, baseURL: nil, resolver: nil)
        let text = content.blocks.map { block -> String in if case .image = block { return "[figure]" }; return block.plainText }.joined(separator: "\n")
        XCTAssertTrue(text.contains("[ ] Option A"), text)
        XCTAssertTrue(text.contains("[selected] Option B"), text)
        XCTAssertTrue(text.contains("[Correct: Your answer is correct.]"), text)
        XCTAssertEqual(text.components(separatedBy: "[selected]").count, 2, "the hidden duplicate is skipped")
    }

    /// Development: `THUBAN_PARSE_DOC=<path to a stored document>` prints how the parser renders recorded answers.
    func testReportRecordedAnswersInStoredDocument() async throws {
        guard let path = ProcessInfo.processInfo.environment["THUBAN_PARSE_DOC"] else { throw XCTSkip("set THUBAN_PARSE_DOC") }
        let content = try await DocumentParserRegistry.parse(url: URL(fileURLWithPath: path))
        let text = content.blocks.map { block -> String in if case .image(let i) = block { return "[figure \(i)]" }; return block.plainText }.joined(separator: "\n")
        // The figures chosen on the page (a figure right after "[selected]"), as 1-based extraction numbers.
        let chosen = try NSRegularExpression(pattern: #"\[selected\]\s*\[figure (\d+)\]"#)
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }.map { $0 + 1 } }
        print("CHOSEN", chosen.map(String.init).joined(separator: ","))
        let byIndex = Dictionary(content.figures.map { ($0.index + 1, $0.pngData) }, uniquingKeysWith: { a, _ in a })
        for number in chosen {
            guard let png = byIndex[number] else { continue }
            print("CHOSENHASH", number, Store.digest(png).map { String(format: "%02x", $0) }.joined())
        }
        print("SELECTED", text.components(separatedBy: "[selected]").count - 1, "UNSELECTED", text.components(separatedBy: "[ ]").count - 1,
              "MARKS", text.components(separatedBy: "[Correct").count - 1)
        var searchStart = text.startIndex
        var shown = 0
        while let range = text.range(of: "[selected]", range: searchStart..<text.endIndex), shown < 40 {
            let from = text.index(range.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
            let to = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
            print("----", text[from..<to].replacingOccurrences(of: "\n", with: " ⏎ "))
            searchStart = range.upperBound
            shown += 1
        }
    }
}
