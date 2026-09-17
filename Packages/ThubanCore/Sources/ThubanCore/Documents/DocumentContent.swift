import Foundation

/// One structural unit of a parsed document, in reading order.
///
/// Parsers emit a flat list of blocks; `pageBreak` marks the start of a page (1-based) and `image` refers to an
/// entry in `DocumentContent.figures` by index so the chunker can keep figures next to the text that mentions them.
public enum ContentBlock: Sendable, Equatable {
    case heading(String, level: Int)
    case paragraph(String)
    case list([String])
    case table([[String]])
    case code(String)
    /// Start of page `n` (1-based).
    case pageBreak(Int)
    /// A figure, referenced by its index into `DocumentContent.figures`.
    case image(index: Int)

    /// The block's text with no markup. Empty for page breaks and images.
    public var plainText: String {
        switch self {
        case .heading(let text, _): return text
        case .paragraph(let text): return text
        case .list(let items): return items.joined(separator: "\n")
        case .table(let rows): return rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .code(let code): return code
        case .pageBreak, .image: return ""
        }
    }

    /// True when the block carries readable text.
    public var isTextual: Bool {
        switch self {
        case .pageBreak, .image: return false
        default: return !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// An image pulled out of a document, always re-encoded as PNG.
public struct ExtractedFigure: Sendable, Equatable {
    /// Position in `DocumentContent.figures`; matches `ContentBlock.image(index:)`.
    public var index: Int
    /// 1-based page (PDF) or slide (PPTX) the figure came from, when known.
    public var page: Int?
    public var pngData: Data
    /// Text surrounding the figure (caption, previous paragraph, OCR), used as context for figure analysis.
    public var nearbyText: String

    public init(index: Int, page: Int? = nil, pngData: Data, nearbyText: String = "") {
        self.index = index
        self.page = page
        self.pngData = pngData
        self.nearbyText = nearbyText
    }
}

/// The parser output for one document: ordered blocks plus the figures they reference.
public struct DocumentContent: Sendable, Equatable {
    public var blocks: [ContentBlock]
    public var figures: [ExtractedFigure]
    /// Number of pages (PDF) or slides (PPTX); `nil` for unpaged formats.
    public var pageCount: Int?
    /// Non-fatal problems met while parsing, e.g. an image that could not be decoded.
    public var warnings: [String]
    /// Images the `FigureGate` turned away (glyphs, icons, equation renders), by reason.
    public var rejectedImages: [FigureGate.Rejection: Int] = [:]

    public init(blocks: [ContentBlock] = [], figures: [ExtractedFigure] = [], pageCount: Int? = nil, warnings: [String] = []) {
        self.blocks = blocks
        self.figures = figures
        self.pageCount = pageCount
        self.warnings = warnings
    }

    public var rejectedImageCount: Int { rejectedImages.values.reduce(0, +) }

    /// One line for the import log, e.g. "93 images were not figures (glyphs or icons) and were left out."
    public var rejectedImagesNote: String? {
        let count = rejectedImageCount
        guard count > 0 else { return nil }
        return "\(count) image\(count == 1 ? " was" : "s were") not a figure (symbols, equation renders or page icons) and \(count == 1 ? "was" : "were") left out."
    }

    public mutating func noteRejected(_ reason: FigureGate.Rejection) {
        rejectedImages[reason, default: 0] += 1
    }

    /// All textual blocks joined by blank lines, in order. Page breaks and images are omitted.
    public var fullText: String {
        blocks.compactMap { block -> String? in
            let text = block.plainText
            return text.isEmpty ? nil : text
        }.joined(separator: "\n\n")
    }

    /// Total characters of readable text; the chunker's token estimate is derived from it.
    public var characterCount: Int { blocks.reduce(0) { $0 + $1.plainText.count } }

    /// True when no block carries text and no figure was extracted.
    public var isEmpty: Bool { figures.isEmpty && !blocks.contains { $0.isTextual } }

    /// Appends a figure and returns its index so the caller can emit the matching `image` block, or nil when the
    /// `FigureGate` rejects the image on size (counted in `rejectedImages`). `force` bypasses the gate for images
    /// the student imported as a document in their own right.
    @discardableResult
    public mutating func appendFigure(page: Int? = nil, pngData: Data, nearbyText: String, force: Bool = false) -> Int? {
        if !force, let rejection = FigureGate.verdict(imageData: pngData) {
            noteRejected(rejection)
            return nil
        }
        let index = figures.count
        figures.append(ExtractedFigure(index: index, page: page, pngData: pngData, nearbyText: nearbyText))
        return index
    }
}
