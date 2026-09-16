import Foundation
import CoreGraphics
import CoreText
import ZIPFoundation
@testable import ThubanCore

/// In-test fixture builders: tiny PDFs, Office packages, images and zips written to a temp directory.
enum DocumentsFixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThubanDocumentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small opaque gradient image; distinct enough that PNG encoding is non-trivial.
    static func image(width: Int = 160, height: Int = 120) -> CGImage {
        let context = ImageCodec.rgbaContext(width: width, height: height)!
        for x in stride(from: 0, to: width, by: 8) {
            let fraction = CGFloat(x) / CGFloat(width)
            context.setFillColor(CGColor(red: fraction, green: 0.2, blue: 1 - fraction, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: width - 20, height: 6))
        return context.makeImage()!
    }

    static func pngData(width: Int = 160, height: Int = 120) -> Data {
        ImageCodec.png(from: image(width: width, height: height))!
    }

    /// Draws large black text on white and returns the PNG, for OCR tests.
    static func textImagePNG(_ text: String, width: Int = 900, height: Int = 220) -> Data {
        let context = ImageCodec.rgbaContext(width: width, height: height)!
        drawText(text, in: context, at: CGPoint(x: 40, y: 80), size: 72)
        return ImageCodec.png(from: context.makeImage()!)!
    }

    static func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    struct PDFPageSpec {
        var lines: [String]
        var image: CGImage?
    }

    /// Writes a Letter-size PDF; text is drawn with Core Text so PDFKit can extract it, images become XObjects.
    static func writePDF(to url: URL, pages: [PDFPageSpec]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw FixtureError.consumer }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw FixtureError.context }
        for page in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 720
            for line in page.lines {
                drawText(line, in: context, at: CGPoint(x: 72, y: y), size: 16)
                y -= 24
            }
            if let image = page.image {
                context.draw(image, in: CGRect(x: 72, y: 300, width: 240, height: 180))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Zips `entries` (path → bytes) into a new archive at `url`.
    static func writeZip(to url: URL, entries: [(path: String, data: Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = entry.data
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
    }

    static func utf8(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Office packages

    static let docxDocumentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter 3 Review</w:t></w:r></w:p>
    <w:p><w:r><w:t xml:space="preserve">Solve for </w:t></w:r><w:r><w:t>x in 2x + 3 = 7.</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Practice</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First item</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Second item</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>y</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>4</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:r><w:t>See the graph below.</w:t></w:r></w:p>
    <w:p><w:r><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
    <w:sectPr/>
    </w:body>
    </w:document>
    """

    static let docxRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
    </Relationships>
    """

    static func writeDocx(to url: URL) throws {
        try writeZip(to: url, entries: [
            ("[Content_Types].xml", utf8(contentTypesXML(overrides: ["/word/document.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"]))),
            ("_rels/.rels", utf8(packageRelsXML(officeDocument: "word/document.xml"))),
            ("word/document.xml", utf8(docxDocumentXML)),
            ("word/_rels/document.xml.rels", utf8(docxRelsXML)),
            ("word/media/image1.png", pngData()),
        ])
    }

    static let pptxPresentationXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst>
    </p:presentation>
    """

    static func pptxSlideXML(title: String, bullets: [String], imageId: String?) -> String {
        let pic = imageId.map {
            "<p:pic><p:blipFill><a:blip r:embed=\"\($0)\"/></p:blipFill></p:pic>"
        } ?? ""
        let paragraphs = bullets.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody>\(paragraphs)</p:txBody></p:sp>
        \(pic)
        </p:spTree></p:cSld>
        </p:sld>
        """
    }

    static func writePptx(to url: URL) throws {
        let presentationRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
        </Relationships>
        """
        let slide2Rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
        </Relationships>
        """
        try writeZip(to: url, entries: [
            ("[Content_Types].xml", utf8(contentTypesXML(overrides: ["/ppt/presentation.xml": "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"]))),
            ("_rels/.rels", utf8(packageRelsXML(officeDocument: "ppt/presentation.xml"))),
            ("ppt/presentation.xml", utf8(pptxPresentationXML)),
            ("ppt/_rels/presentation.xml.rels", utf8(presentationRels)),
            ("ppt/slides/slide1.xml", utf8(pptxSlideXML(title: "Kinematics", bullets: ["Velocity is the rate of change of position.", "Acceleration is the rate of change of velocity."], imageId: nil))),
            ("ppt/slides/slide2.xml", utf8(pptxSlideXML(title: "Position graph", bullets: ["Read the slope."], imageId: "rId2"))),
            ("ppt/slides/_rels/slide2.xml.rels", utf8(slide2Rels)),
            ("ppt/media/image1.png", pngData()),
        ])
    }

    static func writeXlsx(to url: URL) throws {
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Scores" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <dimension ref="A1:C3"/>
        <sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Grade</t></is></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>91.5</v></c><c r="C2" t="s"><v>3</v></c></row>
        <row r="3"><c r="A3" t="s"><v>4</v></c><c r="C3" t="b"><v>1</v></c></row>
        </sheetData>
        </worksheet>
        """
        let sharedStrings = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="5" uniqueCount="5">
        <si><t>Name</t></si><si><t>Score</t></si><si><t>Ada</t></si><si><t>A</t></si><si><t>Grace</t></si>
        </sst>
        """
        try writeZip(to: url, entries: [
            ("[Content_Types].xml", utf8(contentTypesXML(overrides: [
                "/xl/workbook.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                "/xl/worksheets/sheet1.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
                "/xl/sharedStrings.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml",
            ]))),
            ("_rels/.rels", utf8(packageRelsXML(officeDocument: "xl/workbook.xml"))),
            ("xl/workbook.xml", utf8(workbook)),
            ("xl/_rels/workbook.xml.rels", utf8(workbookRels)),
            ("xl/worksheets/sheet1.xml", utf8(sheet)),
            ("xl/sharedStrings.xml", utf8(sharedStrings)),
        ])
    }

    static func contentTypesXML(overrides: [String: String]) -> String {
        let overrideTags = overrides.map { "<Override PartName=\"\($0.key)\" ContentType=\"\($0.value)\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        \(overrideTags)
        </Types>
        """
    }

    static func packageRelsXML(officeDocument: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="\(officeDocument)"/>
        </Relationships>
        """
    }

    // MARK: - MHTML

    static func mhtml(html: String, imageLocation: String, png: Data) -> String {
        let boundary = "----MultipartBoundary--Thuban1234----"
        let quoted = html
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: "+", with: "=2B")
        let base64 = png.base64EncodedString(options: [.lineLength76Characters])
        return """
        From: <Saved by Thuban Study>
        Subject: Quiz page
        MIME-Version: 1.0
        Content-Type: multipart/related;
        \ttype="text/html";
        \tboundary="\(boundary)"

        --\(boundary)
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable
        Content-Location: https://example.com/quiz/index.html

        \(quoted)
        --\(boundary)
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-Location: \(imageLocation)

        \(base64)
        --\(boundary)--
        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    enum FixtureError: Error { case consumer, context }
}
