import Foundation
import CoreGraphics

/// Image files (PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP): the picture becomes figure 0 and any text Vision can read
/// becomes a paragraph, so photographed worksheets import like scanned pages.
public struct ImageParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.image]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        guard let image = ImageCodec.image(at: url) else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is not a readable image.")
        }
        try ParserSupport.checkCancellation()
        let text = try await VisionOCR.recognizeText(in: image)
        guard let png = ImageCodec.png(from: image) else {
            throw ThubanError.parse("\"\(url.lastPathComponent)\" could not be re-encoded as PNG.")
        }
        var content = DocumentContent()
        let index = content.appendFigure(pngData: png, nearbyText: String(text.prefix(600)))
        content.blocks.append(.image(index: index))
        let paragraphs = ParserSupport.paragraphs(from: text)
        content.blocks.append(contentsOf: paragraphs.map { ContentBlock.paragraph($0) })
        if paragraphs.isEmpty { content.warnings.append("No text was recognized in \"\(url.lastPathComponent)\".") }
        return content
    }
}
