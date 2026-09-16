import Foundation
import UniformTypeIdentifiers

/// A parser that turns one file format into `DocumentContent`.
///
/// Implementations are value types, safe to share, and do all work inside `parse(url:)`. They throw
/// `ThubanError.unsupportedDocument` when the file is not what its extension claims and `ThubanError.parse` for
/// everything else; `ThubanError.cancelled` when the surrounding task is cancelled.
public protocol DocumentParser: Sendable {
    /// The document kinds this parser handles.
    static var kinds: [DocumentKind] { get }
    /// Parses the file at `url`. Long inputs are checked for cancellation between pages and blocks.
    func parse(url: URL) async throws -> DocumentContent
}

/// Picks the right `DocumentParser` for a file, by extension first and by uniform type as a fallback.
public enum DocumentParserRegistry {
    /// Every parser the app ships, in lookup order.
    public static let allParsers: [any DocumentParser] = [
        PDFParser(), DocxParser(), PptxParser(), XlsxParser(), CsvParser(),
        HtmlParser(), MhtmlParser(), MarkdownParser(), TextParser(), ImageParser(),
    ]

    /// The parser for `url`, or `nil` when the kind is `.other`.
    public static func parser(for url: URL) -> DocumentParser? {
        parser(for: kind(for: url))
    }

    /// The parser for a known kind, or `nil` for `.other`.
    public static func parser(for kind: DocumentKind) -> DocumentParser? {
        allParsers.first { type(of: $0).kinds.contains(kind) }
    }

    /// The document kind for `url`, derived from its extension, then from its uniform type (declared or on-disk).
    public static func kind(for url: URL) -> DocumentKind {
        let ext = url.pathExtension.lowercased()
        if let kind = kindsByExtension[ext] { return kind }
        if let type = UTType(filenameExtension: ext), let kind = kind(for: type) { return kind }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, let kind = kind(for: type) {
            return kind
        }
        return .other
    }

    /// The document kind for a uniform type, by conformance.
    public static func kind(for type: UTType) -> DocumentKind? {
        for (candidate, kind) in typeConformances where type.conforms(to: candidate) {
            return kind
        }
        return nil
    }

    /// Convenience: detects the kind, picks the parser and parses.
    public static func parse(url: URL) async throws -> DocumentContent {
        guard let parser = parser(for: url) else {
            throw ThubanError.unsupportedDocument("No parser for \"\(url.lastPathComponent)\".")
        }
        return try await parser.parse(url: url)
    }

    /// File extensions the app accepts, lowercase, without the dot.
    public static var supportedExtensions: [String] { kindsByExtension.keys.sorted() }

    static let kindsByExtension: [String: DocumentKind] = [
        "pdf": .pdf,
        "docx": .docx, "docm": .docx,
        "pptx": .pptx, "pptm": .pptx,
        "xlsx": .xlsx, "xlsm": .xlsx,
        "csv": .csv, "tsv": .csv,
        "html": .html, "htm": .html, "xhtml": .html,
        "mhtml": .mhtml, "mht": .mhtml,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown,
        "txt": .text, "text": .text, "log": .text,
        "png": .image, "jpg": .image, "jpeg": .image, "heic": .image, "heif": .image,
        "tiff": .image, "tif": .image, "gif": .image, "bmp": .image, "webp": .image,
    ]

    /// Ordered so that specific types win over generic ones (CSV before plain text, HTML before text).
    private static let typeConformances: [(UTType, DocumentKind)] = [
        (.pdf, .pdf),
        (.commaSeparatedText, .csv), (.tabSeparatedText, .csv),
        (.html, .html),
        (.image, .image),
        (.plainText, .text),
    ]
}

/// Small helpers shared by the parsers.
enum ParserSupport {
    /// Throws `ThubanError.cancelled` when the current task is cancelled.
    static func checkCancellation() throws {
        if Task.isCancelled { throw ThubanError.cancelled }
    }

    /// Reads the whole file, mapping I/O failures to `ThubanError.parse`.
    static func readData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ThubanError.parse("Could not read \"\(url.lastPathComponent)\": \(error.localizedDescription)")
        }
    }

    /// Decodes text with a BOM-aware UTF-8 / UTF-16 attempt and a lossless Latin-1 fallback.
    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if let text = String(data: body, encoding: .utf8) { return text }
        return String(data: body, encoding: .isoLatin1) ?? String(decoding: body, as: UTF8.self)
    }

    /// Runs blocking work (PDF rendering, OCR) off the cooperative pool, propagating cancellation.
    static func offloaded<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Collapses runs of whitespace into single spaces and trims the ends.
    static func normalizeWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                while result.last == " " { result.removeLast() }
                result.append("\n")
                pendingSpace = false
            } else if CharacterSet.whitespaces.contains(scalar) || scalar == "\r" || scalar == "\u{0C}" {
                pendingSpace = !result.isEmpty && result.last != "\n"
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into paragraphs on blank lines, trimming each and dropping empties.
    static func paragraphs(from text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { paragraphs.append(joined) }
            current.removeAll()
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return paragraphs
    }

    /// The trailing text of `blocks`, for figure context.
    static func nearbyText(before blocks: [ContentBlock], limit: Int = 600) -> String {
        for block in blocks.reversed() where block.isTextual {
            return String(block.plainText.suffix(limit))
        }
        return ""
    }
}
