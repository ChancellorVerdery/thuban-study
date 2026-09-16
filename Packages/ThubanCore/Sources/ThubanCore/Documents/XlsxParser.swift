import Foundation
import CoreXLSX

/// Excel workbooks (.xlsx): every sheet becomes a heading (the sheet name) followed by one table block. Shared and
/// inline strings are resolved; numbers and formula results are kept as their stored text.
public struct XlsxParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.xlsx]

    /// Rows and columns beyond these limits are dropped with a warning.
    public static let maxRows = 20_000
    public static let maxColumns = 256

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        guard let file = XLSXFile(filepath: url.path) else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is not an Excel workbook.")
        }
        var content = DocumentContent()
        let sharedStrings: SharedStrings?
        let sheets: [(name: String?, path: String)]
        do {
            sharedStrings = try file.parseSharedStrings()
            sheets = try file.parseWorkbooks().flatMap { try file.parseWorksheetPathsAndNames(workbook: $0) }
        } catch {
            throw ThubanError.parse("Could not read the workbook structure of \"\(url.lastPathComponent)\": \(error)")
        }
        guard !sheets.isEmpty else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" has no worksheets.")
        }
        for (offset, sheet) in sheets.enumerated() {
            try ParserSupport.checkCancellation()
            let worksheet: Worksheet
            do {
                worksheet = try file.parseWorksheet(at: sheet.path)
            } catch {
                content.warnings.append("Sheet \(sheet.name ?? "\(offset + 1)") could not be read: \(error)")
                continue
            }
            let table = Self.grid(from: worksheet, sharedStrings: sharedStrings, warnings: &content.warnings)
            content.blocks.append(.heading(sheet.name ?? "Sheet \(offset + 1)", level: 2))
            if !table.isEmpty { content.blocks.append(.table(table)) }
        }
        return content
    }

    /// Lays out the sparse cells into a dense grid, trimming empty trailing rows and columns.
    static func grid(from worksheet: Worksheet, sharedStrings: SharedStrings?, warnings: inout [String]) -> [[String]] {
        let rows = worksheet.data?.rows ?? []
        guard !rows.isEmpty else { return [] }
        let origin = ColumnReference("A") ?? rows[0].cells.first?.reference.column
        var grid: [[String]] = []
        var truncatedColumns = false
        for row in rows.prefix(maxRows) {
            var values: [String] = []
            for cell in row.cells {
                guard let origin else { continue }
                let column = origin.distance(to: cell.reference.column)
                guard column >= 0 else { continue }
                if column >= maxColumns {
                    truncatedColumns = true
                    continue
                }
                while values.count <= column { values.append("") }
                values[column] = value(of: cell, sharedStrings: sharedStrings)
            }
            grid.append(values)
        }
        if rows.count > maxRows { warnings.append("Only the first \(maxRows) of \(rows.count) rows were kept.") }
        if truncatedColumns { warnings.append("Columns beyond \(maxColumns) were dropped.") }
        return normalize(grid)
    }

    /// The display text for a cell.
    static func value(of cell: Cell, sharedStrings: SharedStrings?) -> String {
        switch cell.type {
        case .sharedString:
            if let shared = sharedStrings, let index = cell.value.flatMap(Int.init), shared.items.indices.contains(index) {
                let item = shared.items[index]
                return item.text ?? item.richText.compactMap(\.text).joined()
            }
            return cell.value ?? ""
        case .inlineStr:
            return cell.inlineString?.text ?? cell.value ?? ""
        case .bool:
            return cell.value == "1" ? "TRUE" : "FALSE"
        default:
            return cell.value ?? ""
        }
    }

    /// Pads rows to a common width and drops empty rows/columns at the edges.
    private static func normalize(_ grid: [[String]]) -> [[String]] {
        var rows = grid
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        let width = rows.map(\.count).max() ?? 0
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        var trimmedWidth = width
        while trimmedWidth > 0, rows.allSatisfy({ $0[trimmedWidth - 1].isEmpty }) { trimmedWidth -= 1 }
        return rows.map { Array($0.prefix(trimmedWidth)) }
    }
}
