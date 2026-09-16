import Foundation

/// Markdown: ATX and setext headings, paragraphs, bullet/numbered lists, fenced code, pipe tables, block quotes
/// and images (`![alt](path)`, data URIs or paths relative to the file).
public struct MarkdownParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.markdown]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let text = ParserSupport.decodeText(try ParserSupport.readData(url))
        return try Self.parse(text: text, baseURL: url.deletingLastPathComponent())
    }

    /// Parses Markdown text; relative image paths resolve against `baseURL`.
    public static func parse(text: String, baseURL: URL? = nil) throws -> DocumentContent {
        var scanner = MarkdownScanner(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"),
                                      baseURL: baseURL)
        try scanner.run()
        return scanner.content
    }
}

/// Line-oriented Markdown block scanner.
private struct MarkdownScanner {
    let lines: [String]
    let baseURL: URL?
    var content = DocumentContent()
    private var index = 0
    private var paragraph: [String] = []

    init(lines: [String], baseURL: URL?) {
        self.lines = lines
        self.baseURL = baseURL
    }

    mutating func run() throws {
        while index < lines.count {
            if index % 500 == 0 { try ParserSupport.checkCancellation() }
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = MarkdownSyntax.fence(trimmed) {
                flushParagraph()
                scanCodeFence(fence)
            } else if let heading = MarkdownSyntax.atxHeading(trimmed) {
                flushParagraph()
                content.blocks.append(.heading(heading.text, level: heading.level))
                index += 1
            } else if MarkdownSyntax.isSetextUnderline(trimmed), paragraph.count == 1, let title = paragraph.first {
                paragraph.removeAll()
                content.blocks.append(.heading(inline(title), level: trimmed.hasPrefix("=") ? 1 : 2))
                index += 1
            } else if MarkdownSyntax.listItem(line) != nil {
                flushParagraph()
                scanList()
            } else if MarkdownSyntax.isTableRow(trimmed), index + 1 < lines.count,
                      MarkdownSyntax.isTableSeparator(lines[index + 1]) {
                flushParagraph()
                scanTable()
            } else if MarkdownSyntax.isThematicBreak(trimmed) {
                flushParagraph()
                index += 1
            } else if let image = MarkdownSyntax.standaloneImage(trimmed) {
                flushParagraph()
                emitImage(alt: image.alt, source: image.source)
                index += 1
            } else {
                paragraph.append(trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed)
                index += 1
            }
        }
        flushParagraph()
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        let text = inline(paragraph.joined(separator: "\n"))
        paragraph.removeAll()
        if !text.isEmpty { content.blocks.append(.paragraph(text)) }
    }

    /// Extracts inline images into figures and strips light emphasis markup.
    private mutating func inline(_ text: String) -> String {
        var result = text
        for image in MarkdownSyntax.inlineImages(in: text) {
            let index = emitImage(alt: image.alt, source: image.source)
            let marker = index.map { "[Figure \($0 + 1)]" } ?? image.alt
            result = result.replacingOccurrences(of: image.match, with: marker)
        }
        return MarkdownSyntax.stripEmphasis(result)
    }

    @discardableResult
    private mutating func emitImage(alt: String, source: String) -> Int? {
        guard let data = MarkdownSyntax.imageData(source: source, baseURL: baseURL) else {
            content.warnings.append("Image \"\(source)\" could not be loaded.")
            return nil
        }
        guard let png = ImageCodec.pngData(fromImageData: data) else {
            content.warnings.append("Image \"\(source)\" could not be decoded.")
            return nil
        }
        let nearby = [alt, ParserSupport.nearbyText(before: content.blocks)].filter { !$0.isEmpty }.joined(separator: "\n")
        let index = content.appendFigure(pngData: png, nearbyText: nearby)
        content.blocks.append(.image(index: index))
        return index
    }

    private mutating func scanCodeFence(_ fence: String) {
        index += 1
        var code: [String] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
            code.append(line)
        }
        content.blocks.append(.code(code.joined(separator: "\n")))
    }

    private mutating func scanList() {
        var items: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let item = MarkdownSyntax.listItem(line) {
                items.append(item)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless another item follows.
                if index + 1 < lines.count, MarkdownSyntax.listItem(lines[index + 1]) != nil { index += 1 } else { break }
            } else if line.hasPrefix("  ") || line.hasPrefix("\t"), !items.isEmpty {
                items[items.count - 1] += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        content.blocks.append(.list(items.map { inline($0) }))
    }

    private mutating func scanTable() {
        var rows: [[String]] = []
        rows.append(MarkdownSyntax.tableCells(lines[index]))
        index += 2
        while index < lines.count, MarkdownSyntax.isTableRow(lines[index].trimmingCharacters(in: .whitespaces)) {
            rows.append(MarkdownSyntax.tableCells(lines[index]))
            index += 1
        }
        content.blocks.append(.table(rows.map { $0.map { inline($0) } }))
    }
}

/// Pattern helpers for the scanner.
enum MarkdownSyntax {
    struct Image { let match: String; let alt: String; let source: String }

    static func fence(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    static func atxHeading(_ line: String) -> (text: String, level: Int)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " || rest.isEmpty else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (stripEmphasis(text.trimmingCharacters(in: .whitespaces)), hashes.count)
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        line.count >= 2 && (line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" })
    }

    static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" } || compact.allSatisfy { $0 == "-" })
    }

    /// Returns the item text (marker removed) for `- `, `* `, `+ `, `1. ` and `1) ` items, else nil.
    static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") { return String(trimmed.dropFirst(6)) }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return digits + ". " + rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.count > 1
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func standaloneImage(_ line: String) -> Image? {
        let images = inlineImages(in: line)
        guard images.count == 1, let image = images.first, image.match == line else { return nil }
        return image
    }

    /// Every `![alt](source "title")` occurrence.
    static func inlineImages(in text: String) -> [Image] {
        var images: [Image] = []
        var searchRange = text.startIndex..<text.endIndex
        while let start = text.range(of: "![", range: searchRange) {
            guard let altEnd = text.range(of: "](", range: start.upperBound..<text.endIndex),
                  let end = text[altEnd.upperBound...].firstIndex(of: ")") else { break }
            let alt = String(text[start.upperBound..<altEnd.lowerBound])
            var source = String(text[altEnd.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
            if source.hasPrefix("<"), source.hasSuffix(">") { source = String(source.dropFirst().dropLast()) }
            images.append(Image(match: String(text[start.lowerBound...end]), alt: alt, source: source))
            searchRange = text.index(after: end)..<text.endIndex
        }
        return images
    }

    /// Loads an image from a data URI or a path relative to `baseURL` (or absolute).
    static func imageData(source: String, baseURL: URL?) -> Data? {
        if source.lowercased().hasPrefix("data:") { return DataURI.decode(source)?.data }
        guard !source.lowercased().hasPrefix("http") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let candidate: URL?
        if decoded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: decoded)
        } else if let base = baseURL {
            candidate = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
        } else {
            candidate = nil
        }
        guard let url = candidate else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Removes `**`, `__`, `*`, `_` and backtick markers around words; leaves math (`$…$`) untouched.
    static func stripEmphasis(_ text: String) -> String {
        var result = text
        for marker in ["**", "__"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }
}

/// `data:` URI decoding shared by the Markdown and HTML parsers.
enum DataURI {
    /// Splits a `data:[mediatype][;base64],payload` URI into its media type and bytes.
    static func decode(_ uri: String) -> (mediaType: String, data: Data)? {
        guard uri.lowercased().hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(uri[uri.index(after: comma)...])
        let parts = header.split(separator: ";").map(String.init)
        let mediaType = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "text/plain"
        if parts.contains("base64") {
            let cleaned = payload.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else { return nil }
            return (mediaType, data)
        }
        guard let text = payload.removingPercentEncoding, let data = text.data(using: .utf8) else { return nil }
        return (mediaType, data)
    }
}
