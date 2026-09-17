import Foundation
import SwiftSoup

/// Resolves an `<img src>` to raw image bytes. Used by `MhtmlParser` to serve images from MIME parts.
public typealias HtmlImageResolver = @Sendable (_ source: String) -> Data?

/// HTML (SwiftSoup): headings, paragraphs, lists, tables, `<pre>` code and images (`data:` URIs, paths relative to
/// the file, or anything a custom resolver can supply). Scripts, styles and hidden metadata are ignored.
public struct HtmlParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.html]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let html = ParserSupport.decodeText(try ParserSupport.readData(url))
        let base = url.deletingLastPathComponent()
        return try Self.parse(html: html, baseURL: base, resolver: nil)
    }

    /// Parses an HTML string. Relative image sources resolve through `resolver` first, then against `baseURL`
    /// (a directory) on disk.
    public static func parse(html: String, baseURL: URL?, resolver: HtmlImageResolver?) throws -> DocumentContent {
        let document: Document
        do {
            document = try SwiftSoup.parse(html, baseURL?.absoluteString ?? "")
        } catch {
            throw ThubanError.parse("Invalid HTML: \(error)")
        }
        var walker = HtmlWalker(baseURL: baseURL, resolver: resolver)
        if let title = try? document.title(), !title.isEmpty, !(try walker.hasTopHeading(document)) {
            walker.content.blocks.append(.heading(ParserSupport.normalizeWhitespace(title), level: 1))
        }
        guard let body = document.body() else { return walker.content }
        try walker.walkContainer(body)
        walker.flushInline()
        return walker.content
    }
}

/// Recursive DOM walk that turns block elements into `ContentBlock`s and collects inline runs into paragraphs.
private struct HtmlWalker {
    let baseURL: URL?
    let resolver: HtmlImageResolver?
    var content = DocumentContent()
    private var inline = ""
    private var visited = 0

    static let skipped: Set<String> = ["script", "style", "noscript", "template", "head", "svg", "iframe", "object", "select", "button"]
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
        "pre", "section", "summary", "table", "ul", "img", "picture", "center", "tr", "td", "th", "tbody", "thead", "tfoot",
    ]

    init(baseURL: URL?, resolver: HtmlImageResolver?) {
        self.baseURL = baseURL
        self.resolver = resolver
    }

    func hasTopHeading(_ document: Document) throws -> Bool {
        try !document.select("h1").isEmpty()
    }

    mutating func walkContainer(_ element: Element) throws {
        for node in element.getChildNodes() {
            visited += 1
            if visited % 200 == 0 { try ParserSupport.checkCancellation() }
            if let text = node as? TextNode {
                appendInline(text.getWholeText())
            } else if let child = node as? Element {
                try walk(child)
            }
        }
    }

    private mutating func walk(_ element: Element) throws {
        let tag = element.tagNameNormal()
        if Self.skipped.contains(tag) || isHidden(element) { return }
        if !Self.blockTags.contains(tag) {
            try walkInline(element)
            return
        }
        // Images decide for themselves whether to break the paragraph: a real figure does, an inline equation
        // render or glyph stays part of the sentence.
        if tag == "img" { try walkImage(element); return }
        if tag == "picture" {
            if let img = try element.select("img").first() { try walkImage(img) }
            return
        }
        flushInline()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = ParserSupport.normalizeWhitespace(try element.text())
            if !text.isEmpty { content.blocks.append(.heading(text, level: Int(String(tag.dropFirst())) ?? 1)) }
        case "p", "dt", "dd", "figcaption", "summary", "address", "center":
            try walkContainer(element)
            flushInline()
        case "ul", "ol":
            try walkList(element)
        case "table":
            try walkTable(element)
        case "pre":
            let code = try element.text(trimAndNormaliseWhitespace: false)
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.blocks.append(.code(code)) }
        case "hr":
            break
        default:
            try walkContainer(element)
            flushInline()
        }
    }

    private mutating func walkInline(_ element: Element) throws {
        switch element.tagNameNormal() {
        case "br":
            inline.append("\n")
        case "img":
            try walkImage(element)
        default:
            for node in element.getChildNodes() {
                if let text = node as? TextNode {
                    appendInline(text.getWholeText())
                } else if let child = node as? Element {
                    try walk(child)
                }
            }
        }
    }

    private mutating func walkList(_ list: Element) throws {
        var items: [String] = []
        for child in list.children() where child.tagNameNormal() == "li" {
            // Nested lists inside an item are flattened into the item's text.
            var text = ParserSupport.normalizeWhitespace(try child.text())
            if text.isEmpty { continue }
            if let images = try? child.select("img"), !images.isEmpty() {
                for img in images { try walkImage(img) }
            }
            text = text.replacingOccurrences(of: "\n", with: " ")
            items.append(text)
        }
        if !items.isEmpty { content.blocks.append(.list(items)) }
    }

    private mutating func walkTable(_ table: Element) throws {
        var rows: [[String]] = []
        for row in try table.select("tr") {
            let cells = row.children().filter { ["td", "th"].contains($0.tagNameNormal()) }
            let texts = try cells.map { ParserSupport.normalizeWhitespace(try $0.text()) }
            if !texts.isEmpty { rows.append(texts) }
        }
        if !rows.isEmpty { content.blocks.append(.table(rows)) }
        for img in try table.select("img") { try walkImage(img) }
    }

    private mutating func walkImage(_ img: Element) throws {
        let source = try img.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = ParserSupport.normalizeWhitespace((try? img.attr("alt")) ?? "")
        guard !source.isEmpty else { return }
        // Equation renders, editor sprites and status marks are never figures; their alt text (if any) still
        // reads as part of the sentence.
        if let rejection = FigureGate.verdict(
            source: source, cssClass: (try? img.attr("class")) ?? "", alt: alt, style: (try? img.attr("style")) ?? ""
        ) {
            content.noteRejected(rejection)
            if !alt.isEmpty, rejection == .mathRenderer || rejection == .inlineGlyph { appendInline(alt) }
            return
        }
        guard let data = loadImage(source) else {
            content.warnings.append("Image \"\(source.prefix(80))\" could not be loaded.")
            return
        }
        guard let png = ImageCodec.pngData(fromImageData: data) else {
            content.warnings.append("Image \"\(source.prefix(80))\" could not be decoded.")
            return
        }
        if let rejection = FigureGate.verdict(imageData: png) {
            content.noteRejected(rejection)
            if !alt.isEmpty { appendInline(alt) }
            return
        }
        flushInline()
        let nearby = [alt, ParserSupport.nearbyText(before: content.blocks)].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let index = content.appendFigure(pngData: png, nearbyText: nearby) else { return }
        content.blocks.append(.image(index: index))
    }

    private func loadImage(_ source: String) -> Data? {
        if source.lowercased().hasPrefix("data:") { return DataURI.decode(source)?.data }
        if let resolver, let data = resolver(source) { return data }
        return MarkdownSyntax.imageData(source: source, baseURL: baseURL)
    }

    private func isHidden(_ element: Element) -> Bool {
        guard let style = try? element.attr("style").lowercased() else { return false }
        return element.hasAttr("hidden") || style.replacingOccurrences(of: " ", with: "").contains("display:none")
    }

    private mutating func appendInline(_ text: String) {
        inline.append(text)
    }

    mutating func flushInline() {
        let text = ParserSupport.normalizeWhitespace(inline)
        inline = ""
        if !text.isEmpty { content.blocks.append(.paragraph(text)) }
    }
}
