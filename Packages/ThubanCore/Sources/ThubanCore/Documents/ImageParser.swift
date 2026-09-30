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
        // A photographed or captured page (mostly text): watermarks off, then only its drawings become figures.
        if text.count >= Self.pageTextThreshold {
            return try await parsePage(image)
        }
        guard let png = ImageCodec.png(from: image) else {
            throw ThubanError.parse("\"\(url.lastPathComponent)\" could not be re-encoded as PNG.")
        }
        var content = DocumentContent()
        // The student imported this image on purpose, so the size gate does not apply.
        let index = content.appendFigure(pngData: png, nearbyText: String(text.prefix(600)), force: true) ?? 0
        content.blocks.append(.image(index: index))
        let paragraphs = ParserSupport.paragraphs(from: text)
        content.blocks.append(contentsOf: paragraphs.map { ContentBlock.paragraph($0) })
        if paragraphs.isEmpty { content.warnings.append("No text was recognized in \"\(url.lastPathComponent)\".") }
        return content
    }

    /// Recognized characters from which an image is a page of text rather than a picture.
    static let pageTextThreshold = 300

    private func parsePage(_ image: CGImage) async throws -> DocumentContent {
        let cleaned = (try? await ParserSupport.offloaded { WatermarkRemover.clean(image) }) ?? nil
        let page = cleaned ?? image
        let lines = try await VisionOCR.recognizeLines(in: page)
        var content = DocumentContent(pageCount: 1)
        content.blocks.append(contentsOf: ParserSupport.paragraphs(from: lines.map(\.text).joined(separator: "\n")).map { ContentBlock.paragraph($0) })
        if let png = ImageCodec.png(from: page, maxDimension: PDFParser.pageImageDimension) { content.pageImages[1] = png }
        guard let bitmap = PageBitmap(page) else { return content }
        let found = try await ParserSupport.offloaded { PageFigureFinder.figures(in: bitmap, lines: lines) }
        for figure in found {
            guard let crop = page.cropping(to: figure.rect), let png = ImageCodec.png(from: crop) else { continue }
            let above = lines.filter { $0.rect.maxY <= figure.rect.minY + 4 && $0.rect.maxY >= figure.rect.minY - 260 }.map(\.text)
            let nearby = ([figure.caption].compactMap { $0 } + above).joined(separator: "\n")
            guard let index = content.appendFigure(page: 1, pngData: png, nearbyText: String(nearby.prefix(600)), force: true) else { continue }
            content.blocks.append(.image(index: index))
        }
        return content
    }
}
