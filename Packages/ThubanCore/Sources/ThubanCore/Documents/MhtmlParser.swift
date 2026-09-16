import Foundation

/// MHTML / `.mht` web archives: a MIME multipart message whose `text/html` part is parsed by `HtmlParser` with the
/// image parts served by `Content-Location` / `Content-ID`.
public struct MhtmlParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.mhtml]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let raw = try ParserSupport.readData(url)
        return try Self.parse(data: raw)
    }

    /// Parses MHTML bytes.
    public static func parse(data: Data) throws -> DocumentContent {
        // Latin-1 keeps every byte, so encoded bodies round-trip to Data exactly.
        let text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let message = MimeMessage.parse(text)
        let parts = message.flattenedParts()
        guard let htmlPart = parts.first(where: { $0.contentType.hasPrefix("text/html") }) else {
            throw ThubanError.unsupportedDocument("The web archive has no HTML part.")
        }
        let html = htmlPart.decodedText()
        let images = MimeImageStore(parts: parts.filter { !$0.contentType.hasPrefix("text/") && !$0.contentType.hasPrefix("multipart/") },
                                    baseLocation: htmlPart.headers["content-location"])
        let resolver: HtmlImageResolver = { source in images.data(for: source) }
        return try HtmlParser.parse(html: html, baseURL: nil, resolver: resolver)
    }
}

/// Image parts keyed by location and content id, with relative-URL resolution against the HTML part's location.
private struct MimeImageStore: Sendable {
    private var byKey: [String: Data] = [:]
    private var byBasename: [String: Data] = [:]
    private let baseURL: URL?

    init(parts: [MimePart], baseLocation: String?) {
        baseURL = baseLocation.flatMap(URL.init(string:))
        for part in parts {
            let data = part.decodedBody()
            guard !data.isEmpty else { continue }
            if let location = part.headers["content-location"] {
                byKey[location] = data
                byBasename[Self.basename(location)] = data
            }
            if let id = part.headers["content-id"] {
                let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                byKey["cid:" + bare] = data
                byKey[bare] = data
            }
        }
    }

    func data(for source: String) -> Data? {
        if let data = byKey[source] { return data }
        if let base = baseURL, let resolved = URL(string: source, relativeTo: base)?.absoluteString, let data = byKey[resolved] {
            return data
        }
        return byBasename[Self.basename(source)]
    }

    private static func basename(_ location: String) -> String {
        let withoutQuery = location.split(separator: "?", maxSplits: 1).first.map(String.init) ?? location
        return withoutQuery.split(separator: "/").last.map(String.init) ?? withoutQuery
    }
}

/// One MIME entity: lowercase-keyed headers and the raw (still transfer-encoded) body.
struct MimePart {
    var headers: [String: String]
    var body: String
    var children: [MimePart] = []

    var contentType: String {
        (headers["content-type"] ?? "text/plain").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    /// A parameter of the Content-Type header, e.g. `boundary` or `charset`.
    func contentTypeParameter(_ name: String) -> String? {
        guard let header = headers["content-type"] else { return nil }
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == name.lowercased() else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Body bytes after undoing the transfer encoding.
    func decodedBody() -> Data {
        let encoding = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        switch encoding {
        case "base64":
            return Data(base64Encoded: body.filter { !$0.isWhitespace }, options: [.ignoreUnknownCharacters]) ?? Data()
        case "quoted-printable":
            return MimeDecoding.quotedPrintable(body)
        default:
            return body.data(using: .isoLatin1) ?? Data()
        }
    }

    /// Body text decoded with the declared charset (UTF-8 by default).
    func decodedText() -> String {
        let data = decodedBody()
        let charset = contentTypeParameter("charset")?.lowercased() ?? "utf-8"
        if let text = String(data: data, encoding: MimeDecoding.encoding(forCharset: charset)) { return text }
        return ParserSupport.decodeText(data)
    }

    /// Leaf parts in document order (multipart containers are expanded).
    func flattenedParts() -> [MimePart] {
        children.isEmpty ? [self] : children.flatMap { $0.flattenedParts() }
    }
}

/// A minimal RFC 2045/2046 reader: header folding, boundaries, nested multiparts.
enum MimeMessage {
    static func parse(_ text: String) -> MimePart {
        let (headers, body) = splitHeaders(text)
        var part = MimePart(headers: headers, body: body)
        if part.contentType.hasPrefix("multipart/"), let boundary = part.contentTypeParameter("boundary") {
            part.children = splitMultipart(body, boundary: boundary).map { parse($0) }
        }
        return part
    }

    /// Splits at the first blank line; folded header continuations are joined.
    static func splitHeaders(_ text: String) -> (headers: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let headerEnd = normalized.range(of: "\n\n")
        let headerText = headerEnd.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let body = headerEnd.map { String(normalized[$0.upperBound...]) } ?? ""
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in headerText.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                currentKey = key
            }
        }
        return (headers, body)
    }

    /// The entity texts between `--boundary` delimiters, excluding the preamble and epilogue.
    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var remainder = body[...]
        guard let firstDelimiter = remainder.range(of: delimiter) else { return [] }
        remainder = remainder[firstDelimiter.upperBound...]
        while true {
            guard let lineEnd = remainder.firstIndex(of: "\n") else { break }
            let marker = remainder[..<lineEnd]
            if marker.hasPrefix("--") { break }
            remainder = remainder[remainder.index(after: lineEnd)...]
            guard let next = remainder.range(of: delimiter) else {
                parts.append(String(remainder))
                break
            }
            var entity = remainder[..<next.lowerBound]
            if entity.hasSuffix("\n") { entity = entity.dropLast() }
            parts.append(String(entity))
            remainder = remainder[next.upperBound...]
        }
        return parts
    }
}

enum MimeDecoding {
    /// Decodes quoted-printable text: `=XX` hex escapes and `=` soft line breaks.
    static func quotedPrintable(_ text: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        let source = [UInt8](text.replacingOccurrences(of: "\r\n", with: "\n").data(using: .isoLatin1) ?? Data())
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "=") {
                if index + 1 < source.count, source[index + 1] == UInt8(ascii: "\n") {
                    index += 2
                    continue
                }
                if index + 2 < source.count, let value = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    index += 3
                    continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return Data(bytes)
    }

    static func encoding(forCharset charset: String) -> String.Encoding {
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "utf-16", "utf16": return .utf16
        case "us-ascii", "ascii": return .ascii
        case "shift_jis", "shift-jis": return .shiftJIS
        default: return .utf8
        }
    }
}
