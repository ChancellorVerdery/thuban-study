import XCTest
import CoreGraphics
@testable import ThubanCore

final class DocumentsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try DocumentsFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - Registry

    func testRegistryDetectsKindsByExtension() {
        let expectations: [(String, DocumentKind)] = [
            ("notes.pdf", .pdf), ("Homework.DOCX", .docx), ("deck.pptx", .pptx), ("grades.xlsx", .xlsx),
            ("data.csv", .csv), ("data.tsv", .csv), ("page.html", .html), ("page.htm", .html),
            ("saved.mhtml", .mhtml), ("saved.mht", .mhtml), ("readme.md", .markdown), ("notes.txt", .text),
            ("scan.png", .image), ("photo.jpeg", .image), ("photo.heic", .image), ("archive.zip", .other),
        ]
        for (name, kind) in expectations {
            XCTAssertEqual(DocumentParserRegistry.kind(for: URL(fileURLWithPath: "/tmp/\(name)")), kind, name)
        }
        XCTAssertNil(DocumentParserRegistry.parser(for: URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertTrue(DocumentParserRegistry.parser(for: URL(fileURLWithPath: "/tmp/a.pdf")) is PDFParser)
        XCTAssertTrue(DocumentParserRegistry.parser(for: URL(fileURLWithPath: "/tmp/a.mht")) is MhtmlParser)
        XCTAssertTrue(DocumentParserRegistry.parser(for: .image) is ImageParser)
        for kind in DocumentKind.allCases where kind != .other {
            XCTAssertNotNil(DocumentParserRegistry.parser(for: kind), "\(kind) has no parser")
        }
    }

    func testRegistryFallsBackToUniformType() {
        XCTAssertEqual(DocumentParserRegistry.kind(for: URL(fileURLWithPath: "/tmp/photo.jp2")), .image)
        XCTAssertEqual(DocumentParserRegistry.kind(for: URL(fileURLWithPath: "/tmp/notes.rtf")), .other)
    }

    func testUnsupportedFileThrowsThubanError() async {
        let url = file("garbage.pdf")
        try? Data("not a pdf".utf8).write(to: url)
        do {
            _ = try await PDFParser().parse(url: url)
            XCTFail("expected an error")
        } catch let error as ThubanError {
            guard case .unsupportedDocument = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("not a ThubanError: \(error)")
        }
        let docx = file("garbage.docx")
        try? Data("still not a zip".utf8).write(to: docx)
        do {
            _ = try await DocxParser().parse(url: docx)
            XCTFail("expected an error")
        } catch let error as ThubanError {
            guard case .unsupportedDocument = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("not a ThubanError: \(error)")
        }
    }

    // MARK: - PDF

    func testPDFExtractsTextPagesAndEmbeddedImage() async throws {
        let url = file("worksheet.pdf")
        try DocumentsFixtures.writePDF(to: url, pages: [
            .init(lines: ["Quadratic functions review", "1. Solve x^2 - 5x + 6 = 0"], image: DocumentsFixtures.image()),
            .init(lines: ["2. Find the vertex of y = x^2 + 4x + 1"], image: nil),
        ])
        let content = try await PDFParser().parse(url: url)

        XCTAssertEqual(content.pageCount, 2)
        XCTAssertTrue(content.fullText.contains("Quadratic functions review"), content.fullText)
        XCTAssertTrue(content.fullText.contains("vertex"), content.fullText)
        XCTAssertEqual(content.blocks.filter { if case .pageBreak = $0 { return true } else { return false } }.count, 2)
        XCTAssertGreaterThanOrEqual(content.figures.count, 1, "expected the embedded image as a figure")
        let figure = try XCTUnwrap(content.figures.first)
        XCTAssertEqual(figure.page, 1)
        XCTAssertTrue(figure.nearbyText.contains("Quadratic"))
        let decoded = try XCTUnwrap(ImageCodec.image(from: figure.pngData))
        // Drawn at 240×180 points and rendered at 2x.
        XCTAssertEqual(decoded.width, 480, accuracy: 4)
        XCTAssertEqual(decoded.height, 360, accuracy: 4)
        XCTAssertTrue(content.blocks.contains(.image(index: 0)))
        // The image block belongs to page 1 (appears before the second page break).
        let imagePosition = try XCTUnwrap(content.blocks.firstIndex(of: .image(index: 0)))
        let secondPage = try XCTUnwrap(content.blocks.firstIndex(of: .pageBreak(2)))
        XCTAssertLessThan(imagePosition, secondPage)
    }

    func testPDFScannedPageBecomesFullPageFigureAndIsOCRed() async throws {
        let url = file("scan.pdf")
        // A page with no text objects at all, only a big drawn "image" of text.
        let canvas = ImageCodec.rgbaContext(width: 1200, height: 400)!
        DocumentsFixtures.drawText("PHOTOSYNTHESIS", in: canvas, at: CGPoint(x: 60, y: 150), size: 110)
        let scan = canvas.makeImage()!
        try DocumentsFixtures.writePDF(to: url, pages: [.init(lines: [], image: scan)])

        let content = try await PDFParser(ocrEnabled: true).parse(url: url)
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertEqual(content.figures.first?.page, 1)
        XCTAssertTrue(content.fullText.uppercased().contains("PHOTOSYNTHESIS"), "OCR text: \(content.fullText)")
    }

    func testPDFParsingHonoursCancellation() async throws {
        let url = file("many.pdf")
        try DocumentsFixtures.writePDF(to: url, pages: (1...6).map { .init(lines: ["Page \($0)"], image: nil) })
        let task = Task { try await PDFParser().parse(url: url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ThubanError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - DOCX / PPTX / XLSX

    func testDocxHeadingsParagraphsListsTablesAndFigures() async throws {
        let url = file("review.docx")
        try DocumentsFixtures.writeDocx(to: url)
        let content = try await DocxParser().parse(url: url)

        XCTAssertEqual(content.blocks[0], .heading("Chapter 3 Review", level: 1))
        XCTAssertEqual(content.blocks[1], .paragraph("Solve for x in 2x + 3 = 7."))
        XCTAssertEqual(content.blocks[2], .heading("Practice", level: 2))
        XCTAssertEqual(content.blocks[3], .list(["First item", "Second item"]))
        XCTAssertEqual(content.blocks[4], .table([["x", "y"], ["1", "4"]]))
        XCTAssertEqual(content.blocks[5], .paragraph("See the graph below."))
        XCTAssertEqual(content.blocks[6], .image(index: 0))
        // Equation-editor math (OMML) survives as inline LaTeX instead of vanishing.
        XCTAssertEqual(content.blocks[7], .paragraph("Solve $\\frac{x}{2}+{y}^{2}=\\sqrt{3}$ for x."))
        XCTAssertEqual(content.blocks[8], .paragraph("$\\sum_{k=1}^{n} {a}_{k}=\\left(1+n\\right)/2$"))
        XCTAssertEqual(content.blocks.count, 9)
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertEqual(content.figures[0].nearbyText, "See the graph below.")
        XCTAssertNotNil(ImageCodec.image(from: content.figures[0].pngData))
        XCTAssertTrue(content.warnings.isEmpty, content.warnings.joined(separator: "; "))
    }

    func testPptxSlidesInOrderWithTitlesBodyAndPictures() async throws {
        let url = file("lecture.pptx")
        try DocumentsFixtures.writePptx(to: url)
        let content = try await PptxParser().parse(url: url)

        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.blocks[0], .pageBreak(1))
        XCTAssertEqual(content.blocks[1], .heading("Kinematics", level: 1))
        XCTAssertEqual(content.blocks[2], .list(["Velocity is the rate of change of position.", "Acceleration is the rate of change of velocity."]))
        XCTAssertEqual(content.blocks[3], .pageBreak(2))
        XCTAssertEqual(content.blocks[4], .heading("Position graph", level: 1))
        XCTAssertEqual(content.blocks[5], .paragraph("Read the slope."))
        XCTAssertEqual(content.blocks[6], .image(index: 0))
        XCTAssertEqual(content.figures.first?.page, 2)
        XCTAssertEqual(content.figures.first?.nearbyText, "Read the slope.")
    }

    func testXlsxSheetBecomesTable() async throws {
        let url = file("grades.xlsx")
        try DocumentsFixtures.writeXlsx(to: url)
        let content = try await XlsxParser().parse(url: url)

        XCTAssertEqual(content.blocks.first, .heading("Scores", level: 2))
        XCTAssertEqual(content.blocks.dropFirst().first, .table([
            ["Name", "Score", "Grade"],
            ["Ada", "91.5", "A"],
            ["Grace", "", "TRUE"],
        ]))
        XCTAssertTrue(content.warnings.isEmpty, content.warnings.joined(separator: "; "))
    }

    // MARK: - CSV / text / markdown

    func testCsvHandlesQuotesEmbeddedNewlinesAndCRLF() async throws {
        let url = file("data.csv")
        let csv = "question,answer,notes\r\n\"What is 2, plus 2?\",4,\"multi\nline\"\r\n\"She said \"\"hi\"\"\",ok,\r\n"
        try Data(csv.utf8).write(to: url)
        let content = try await CsvParser().parse(url: url)
        XCTAssertEqual(content.blocks, [.table([
            ["question", "answer", "notes"],
            ["What is 2, plus 2?", "4", "multi\nline"],
            ["She said \"hi\"", "ok", ""],
        ])])
        XCTAssertEqual(CsvParser.sniffDelimiter("a;b;c\n1;2;3"), ";")
        XCTAssertEqual(CsvParser.sniffDelimiter("a\tb\n"), "\t")
    }

    func testTextParagraphsAndFormFeedPages() async throws {
        let url = file("notes.txt")
        try Data("First paragraph\nstill first.\n\nSecond paragraph.\u{0C}Third on page two.".utf8).write(to: url)
        let content = try await TextParser().parse(url: url)
        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.blocks, [
            .pageBreak(1), .paragraph("First paragraph\nstill first."), .paragraph("Second paragraph."),
            .pageBreak(2), .paragraph("Third on page two."),
        ])
        XCTAssertEqual(content.fullText, "First paragraph\nstill first.\n\nSecond paragraph.\n\nThird on page two.")
    }

    func testMarkdownBlocksAndRelativeImage() async throws {
        try DocumentsFixtures.pngData().write(to: file("graph.png"))
        let markdown = """
        # Unit 4: Exponents

        Rules for **exponents** and a table:

        | rule | example |
        |------|---------|
        | product | $a^m a^n = a^{m+n}$ |

        Setext heading
        --------------

        - first item
        - second item
        1. numbered

        ```python
        print(2 ** 10)
        ```

        ![the graph](graph.png)

        > quoted line
        """
        try Data(markdown.utf8).write(to: file("unit4.md"))
        let content = try await MarkdownParser().parse(url: file("unit4.md"))

        XCTAssertEqual(content.blocks[0], .heading("Unit 4: Exponents", level: 1))
        XCTAssertEqual(content.blocks[1], .paragraph("Rules for exponents and a table:"))
        XCTAssertEqual(content.blocks[2], .table([["rule", "example"], ["product", "$a^m a^n = a^{m+n}$"]]))
        XCTAssertEqual(content.blocks[3], .heading("Setext heading", level: 2))
        XCTAssertEqual(content.blocks[4], .list(["first item", "second item", "1. numbered"]))
        XCTAssertEqual(content.blocks[5], .code("print(2 ** 10)"))
        XCTAssertEqual(content.blocks[6], .image(index: 0))
        XCTAssertEqual(content.blocks[7], .paragraph("quoted line"))
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertTrue(content.figures[0].nearbyText.hasPrefix("the graph"))
    }

    // MARK: - HTML / MHTML

    func testHtmlBlocksAndDataURIImage() async throws {
        let png = DocumentsFixtures.pngData().base64EncodedString()
        let html = """
        <html><head><title>Ignored when h1 exists</title><style>p{color:red}</style></head>
        <body>
        <h1>Chapter 5</h1>
        <p>Intro <b>bold</b> text<br>second line</p>
        <script>alert(1)</script>
        <ul><li>alpha</li><li>beta</li></ul>
        <table><tr><th>n</th><th>n²</th></tr><tr><td>2</td><td>4</td></tr></table>
        <pre>x = 1
        y = 2</pre>
        <div>Loose <i>inline</i> text
        <img src="data:image/png;base64,\(png)" alt="parabola">
        </div>
        </body></html>
        """
        try Data(html.utf8).write(to: file("page.html"))
        let content = try await HtmlParser().parse(url: file("page.html"))

        XCTAssertEqual(content.blocks[0], .heading("Chapter 5", level: 1))
        XCTAssertEqual(content.blocks[1], .paragraph("Intro bold text\nsecond line"))
        XCTAssertEqual(content.blocks[2], .list(["alpha", "beta"]))
        XCTAssertEqual(content.blocks[3], .table([["n", "n²"], ["2", "4"]]))
        XCTAssertEqual(content.blocks[4], .code("x = 1\ny = 2"))
        XCTAssertEqual(content.blocks[5], .paragraph("Loose inline text"))
        XCTAssertEqual(content.blocks[6], .image(index: 0))
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertTrue(content.figures[0].nearbyText.contains("parabola"))
        XCTAssertFalse(content.fullText.contains("alert"))
        XCTAssertFalse(content.fullText.contains("color:red"))
    }

    func testMhtmlDecodesHtmlPartAndImagePart() async throws {
        let html = "<html><body><h1>Quiz</h1><p>What is 2 + 2?</p><img src=\"https://example.com/quiz/fig.png\" alt=\"figure\"></body></html>"
        let text = DocumentsFixtures.mhtml(html: html, imageLocation: "https://example.com/quiz/fig.png", png: DocumentsFixtures.pngData())
        try Data(text.utf8).write(to: file("quiz.mhtml"))
        let content = try await MhtmlParser().parse(url: file("quiz.mhtml"))

        XCTAssertEqual(content.blocks[0], .heading("Quiz", level: 1))
        XCTAssertEqual(content.blocks[1], .paragraph("What is 2 + 2?"))
        XCTAssertEqual(content.blocks[2], .image(index: 0))
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertNotNil(ImageCodec.image(from: content.figures[0].pngData))
        XCTAssertTrue(content.warnings.isEmpty, content.warnings.joined(separator: "; "))
    }

    func testMhtmlResolvesRelativeImageSources() async throws {
        let html = "<html><body><p>Relative</p><img src=\"fig.png\"></body></html>"
        let text = DocumentsFixtures.mhtml(html: html, imageLocation: "https://example.com/quiz/fig.png", png: DocumentsFixtures.pngData())
        let content = try MhtmlParser.parse(data: Data(text.utf8))
        XCTAssertEqual(content.figures.count, 1)
    }

    func testQuotedPrintableAndDataURIDecoding() {
        XCTAssertEqual(String(decoding: MimeDecoding.quotedPrintable("a=3Db=\r\nc =E2=82=AC"), as: UTF8.self), "a=bc €")
        let uri = "data:text/plain;base64," + Data("hello".utf8).base64EncodedString()
        XCTAssertEqual(DataURI.decode(uri).map { String(decoding: $0.data, as: UTF8.self) }, "hello")
        XCTAssertEqual(DataURI.decode(uri)?.mediaType, "text/plain")
        XCTAssertEqual(DataURI.decode("data:,a%20b").map { String(decoding: $0.data, as: UTF8.self) }, "a b")
    }

    // MARK: - Images

    func testImageParserReturnsFigureAndOCRText() async throws {
        let url = file("board.png")
        try DocumentsFixtures.textImagePNG("MITOCHONDRIA 42").write(to: url)
        let content = try await ImageParser().parse(url: url)
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertEqual(content.blocks.first, .image(index: 0))
        XCTAssertTrue(content.fullText.uppercased().contains("MITOCHONDRIA"), "OCR text: \(content.fullText)")
    }

    // MARK: - Content helpers and chunker

    func testPlainTextAndFullText() {
        let content = DocumentContent(blocks: [
            .heading("Title", level: 1), .pageBreak(1), .paragraph("Body"), .list(["a", "b"]),
            .table([["1", "2"], ["3", "4"]]), .code("let x = 1"), .image(index: 0),
        ])
        XCTAssertEqual(ContentBlock.list(["a", "b"]).plainText, "a\nb")
        XCTAssertEqual(ContentBlock.table([["1", "2"], ["3", "4"]]).plainText, "1 | 2\n3 | 4")
        XCTAssertEqual(ContentBlock.pageBreak(3).plainText, "")
        XCTAssertFalse(ContentBlock.image(index: 0).isTextual)
        XCTAssertEqual(content.fullText, "Title\n\nBody\n\na\nb\n\n1 | 2\n3 | 4\n\nlet x = 1")
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(DocumentContent().isEmpty)
    }

    func testChunkerRespectsMaxTokensAndCarriesPagesAndFigures() {
        var content = DocumentContent(pageCount: 12)
        let sentence = String(repeating: "The mitochondria is the powerhouse of the cell. ", count: 25)   // ~1200 chars
        for page in 1...12 {
            content.blocks.append(.pageBreak(page))
            content.blocks.append(.heading("Section \(page)", level: 2))
            for _ in 0..<3 { content.blocks.append(.paragraph(sentence + "Page \(page) marker.")) }
            if page % 4 == 0 {
                let index = content.appendFigure(page: page, pngData: Data([0x89, 0x50]), nearbyText: "fig")
                content.blocks.append(.image(index: index))
            }
        }
        let maxTokens = 2_000
        let chunks = Chunker.chunks(content, maxTokens: maxTokens)

        XCTAssertGreaterThan(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.estimatedTokens, maxTokens, "chunk \(chunk.index) too big")
            XCTAssertNotNil(chunk.pages)
        }
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        // Every page's marker text survives somewhere, in order.
        let joined = chunks.map(\.text).joined(separator: "\n")
        for page in 1...12 { XCTAssertTrue(joined.contains("Page \(page) marker."), "page \(page) missing") }
        // Page ranges are contiguous and non-decreasing.
        var previousEnd = 0
        for chunk in chunks {
            let pages = chunk.pages!
            XCTAssertGreaterThanOrEqual(pages.lowerBound, previousEnd)
            previousEnd = pages.upperBound
        }
        XCTAssertEqual(chunks.first?.pages?.lowerBound, 1)
        XCTAssertEqual(chunks.last?.pages?.upperBound, 12)
        // Figures ride with the chunk whose text has their marker, and never appear twice.
        let allFigureIndices = chunks.flatMap(\.figureIndices)
        XCTAssertEqual(allFigureIndices.sorted(), [0, 1, 2])
        for chunk in chunks where !chunk.figureIndices.isEmpty {
            for index in chunk.figureIndices {
                XCTAssertTrue(chunk.text.contains("[Figure \(index + 1)]"))
            }
        }
    }

    func testChunkerSplitsOversizedBlockAndPrefersHeadings() {
        let huge = (1...400).map { "Line \($0) of a very long paragraph without any blank lines in it." }.joined(separator: "\n")
        let content = DocumentContent(blocks: [.heading("Big", level: 1), .paragraph(huge), .heading("Next", level: 1), .paragraph("Short tail.")])
        let chunks = Chunker.chunks(content, maxTokens: 500)   // 2000 chars
        XCTAssertGreaterThan(chunks.count, 5)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.text.utf8.count, 2000) }
        XCTAssertTrue(chunks.map(\.text).joined(separator: "\n").contains("Line 400 of"))
        XCTAssertNil(chunks[0].pages)
        // A small document is a single chunk.
        let small = DocumentContent(blocks: [.heading("A", level: 1), .paragraph("Just a bit of text.")])
        let single = Chunker.chunks(small)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].text, "# A\n\nJust a bit of text.")
        XCTAssertEqual(Chunker.chunks(DocumentContent()).count, 0)
    }
}
