import Foundation

/// CSV / TSV (RFC 4180-ish): quoted fields with `""` escapes, CRLF or LF rows, delimiter sniffed from the header.
public struct CsvParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.csv]

    /// Rows beyond this are dropped with a warning; spreadsheets this large are not study material.
    public static let maxRows = 20_000

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let text = ParserSupport.decodeText(try ParserSupport.readData(url))
        let delimiter = url.pathExtension.lowercased() == "tsv" ? Character("\t") : Self.sniffDelimiter(text)
        return try Self.parse(text: text, delimiter: delimiter)
    }

    /// Parses CSV text into a single table block.
    public static func parse(text: String, delimiter: Character = ",") throws -> DocumentContent {
        var rows = try parseRows(text, delimiter: delimiter)
        var content = DocumentContent()
        if rows.count > maxRows {
            content.warnings.append("Only the first \(maxRows) of \(rows.count) rows were kept.")
            rows = Array(rows.prefix(maxRows))
        }
        if !rows.isEmpty { content.blocks.append(.table(rows)) }
        return content
    }

    /// Picks the delimiter that appears most in the first line, among comma, semicolon, tab and pipe.
    public static func sniffDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let candidates: [Character] = [",", ";", "\t", "|"]
        let counts = candidates.map { candidate in firstLine.filter { $0 == candidate }.count }
        guard let best = counts.enumerated().max(by: { $0.element < $1.element }), best.element > 0 else { return "," }
        return candidates[best.offset]
    }

    /// The RFC 4180 state machine. Empty trailing lines are skipped; a lone empty row is dropped.
    ///
    /// Works on unicode scalars rather than characters so that a CRLF pair (one grapheme cluster in Swift) is seen
    /// as a carriage return followed by a line feed.
    public static func parseRows(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        let delimiter = delimiter.unicodeScalars.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        var counter = 0

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending {
            pending = iterator.next()
            counter += 1
            if counter % 100_000 == 0 { try ParserSupport.checkCancellation() }
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                endField()
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                endRow()
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
