import Foundation

/// A slice of a document sized for one import-agent request.
public struct DocumentChunk: Sendable, Equatable, Identifiable {
    /// 0-based position in the chunk list.
    public var index: Int
    /// The chunk's text: headings as `#` lines, lists as `- ` lines, tables as `|`-separated rows, code fenced,
    /// page starts as `[Page n]` markers and figures as `[Figure n]` markers.
    public var text: String
    /// 1-based pages covered, when the document is paged.
    public var pages: ClosedRange<Int>?
    /// Indices into `DocumentContent.figures` that belong with this text.
    public var figureIndices: [Int]

    public var id: Int { index }

    public init(index: Int, text: String, pages: ClosedRange<Int>? = nil, figureIndices: [Int] = []) {
        self.index = index
        self.text = text
        self.pages = pages
        self.figureIndices = figureIndices
    }

    /// Rough token count (~4 characters per token).
    public var estimatedTokens: Int { Chunker.estimateTokens(text) }
}

/// Splits `DocumentContent` into chunks that fit an agent's context window.
///
/// Splits prefer headings and page breaks: once a chunk is at least half full, the next heading (level ≤ 2) or page
/// break starts a new chunk. A block that would overflow the limit starts a new chunk; a single block bigger than
/// the limit is cut at paragraph, line and finally character boundaries.
public enum Chunker {
    /// Default budget per chunk, in estimated tokens.
    public static let defaultMaxTokens = 12_000
    /// The characters-per-token estimate.
    public static let charactersPerToken = 4

    /// Estimated tokens for `text` (~4 characters each, rounded up).
    public static func estimateTokens(_ text: String) -> Int {
        (text.utf8.count + charactersPerToken - 1) / charactersPerToken
    }

    /// Chunks `content` so that each chunk's estimated token count stays within `maxTokens`.
    public static func chunks(_ content: DocumentContent, maxTokens: Int = defaultMaxTokens) -> [DocumentChunk] {
        let maxChars = max(charactersPerToken * 50, maxTokens * charactersPerToken)
        var builder = ChunkBuilder(maxChars: maxChars, figures: content.figures)
        for block in content.blocks {
            builder.append(block)
        }
        return builder.finish()
    }

    /// Renders a block the way it appears inside chunk text.
    public static func render(_ block: ContentBlock) -> String {
        switch block {
        case .heading(let text, let level):
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + text
        case .paragraph(let text):
            return text
        case .list(let items):
            return items.map { "- " + $0 }.joined(separator: "\n")
        case .table(let rows):
            return rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        case .code(let code):
            return "```\n" + code + "\n```"
        case .pageBreak(let page):
            return "[Page \(page)]"
        case .image(let index):
            return "[Figure \(index + 1)]"
        }
    }
}

/// Accumulates rendered blocks into chunks, tracking pages and figures.
private struct ChunkBuilder {
    let maxChars: Int
    let figuresByPage: [Int: [Int]]

    private var chunks: [DocumentChunk] = []
    private var segments: [String] = []
    private var length = 0
    private var firstPage: Int?
    private var lastPage: Int?
    private var currentPage: Int?
    private var figureIndices: [Int] = []

    init(maxChars: Int, figures: [ExtractedFigure]) {
        self.maxChars = maxChars
        var byPage: [Int: [Int]] = [:]
        for figure in figures {
            if let page = figure.page { byPage[page, default: []].append(figure.index) }
        }
        figuresByPage = byPage
    }

    mutating func append(_ block: ContentBlock) {
        switch block {
        case .pageBreak(let page):
            if shouldSplitSoftly { flush() }
            currentPage = page
            add(Chunker.render(block))
        case .heading(_, let level):
            if level <= 2, shouldSplitSoftly { flush() }
            add(Chunker.render(block))
        case .image(let index):
            add(Chunker.render(block))
            noteFigure(index)
        default:
            add(Chunker.render(block))
        }
    }

    mutating func finish() -> [DocumentChunk] {
        flush()
        return chunks
    }

    private var shouldSplitSoftly: Bool { length >= maxChars / 2 }

    private mutating func add(_ text: String) {
        guard !text.isEmpty else { return }
        let cost = text.utf8.count + (segments.isEmpty ? 0 : 2)
        if length + cost > maxChars, !segments.isEmpty {
            flush()
        }
        if text.utf8.count > maxChars {
            for piece in ChunkBuilder.split(text, maxChars: maxChars) {
                add(piece)
            }
            return
        }
        segments.append(text)
        length += text.utf8.count + (segments.count > 1 ? 2 : 0)
        if firstPage == nil { firstPage = currentPage }
        lastPage = currentPage
    }

    private mutating func noteFigure(_ index: Int) {
        if !figureIndices.contains(index) { figureIndices.append(index) }
    }

    private mutating func flush() {
        guard !segments.isEmpty else { return }
        let pages = firstPage.flatMap { first in lastPage.map { first...max(first, $0) } }
        var figures = figureIndices
        if let pages {
            for page in pages {
                for index in figuresByPage[page] ?? [] where !figures.contains(index) { figures.append(index) }
            }
        }
        chunks.append(DocumentChunk(
            index: chunks.count,
            text: segments.joined(separator: "\n\n"),
            pages: pages,
            figureIndices: figures.sorted()
        ))
        segments.removeAll()
        length = 0
        firstPage = nil
        lastPage = nil
        figureIndices.removeAll()
    }

    /// Cuts an oversized block at paragraph, then line, then character boundaries.
    static func split(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for unit in units(of: text) {
            if unit.utf8.count > maxChars {
                flush()
                pieces.append(contentsOf: hardSplit(unit, maxChars: maxChars))
                continue
            }
            let separator = current.isEmpty ? "" : "\n"
            if current.utf8.count + separator.utf8.count + unit.utf8.count > maxChars { flush() }
            current += (current.isEmpty ? "" : "\n") + unit
        }
        flush()
        return pieces
    }

    /// Paragraphs when the text has blank lines, otherwise lines.
    private static func units(of text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        if paragraphs.count > 1 { return paragraphs }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private static func hardSplit(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if current.utf8.count + character.utf8.count > maxChars {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
