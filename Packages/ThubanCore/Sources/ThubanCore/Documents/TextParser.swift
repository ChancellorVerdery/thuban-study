import Foundation

/// Plain text: paragraphs split on blank lines; form feeds (`\f`) become page breaks.
public struct TextParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.text]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let text = ParserSupport.decodeText(try ParserSupport.readData(url))
        return try Self.parse(text: text)
    }

    /// Parses already-loaded text.
    public static func parse(text: String) throws -> DocumentContent {
        let pages = text.components(separatedBy: "\u{0C}")
        var content = DocumentContent()
        for (offset, pageText) in pages.enumerated() {
            try ParserSupport.checkCancellation()
            if pages.count > 1 { content.blocks.append(.pageBreak(offset + 1)) }
            content.blocks.append(contentsOf: ParserSupport.paragraphs(from: pageText).map { ContentBlock.paragraph($0) })
        }
        if pages.count > 1 { content.pageCount = pages.count }
        return content
    }
}
