import Foundation
import SwiftSoup

/// Word documents (.docx): paragraphs, headings (by `Heading1…6` / `Title` styles), lists (numbered paragraphs),
/// tables and inline images from `word/media`, in document order.
public struct DocxParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.docx]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let archive = try OfficeArchive(url: url)
        let documentPath = "word/document.xml"
        guard archive.contains(documentPath) else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is not a Word document.")
        }
        let document = try archive.xml(at: documentPath)
        let relationships = try archive.relationships(for: documentPath)
        var builder = DocxBuilder(archive: archive, relationships: relationships)
        guard let body = OfficeXML.first(in: document, named: "w:body") else {
            throw ThubanError.parse("\"\(url.lastPathComponent)\" has no document body.")
        }
        try builder.walk(body)
        builder.flushList()
        return builder.content
    }
}

/// Turns the `w:body` tree into blocks, merging consecutive list paragraphs.
private struct DocxBuilder {
    let archive: OfficeArchive
    let relationships: [String: OfficeRelationship]
    var content = DocumentContent()
    private var pendingList: [String] = []
    private var lastParagraphText = ""
    private var seen = 0

    init(archive: OfficeArchive, relationships: [String: OfficeRelationship]) {
        self.archive = archive
        self.relationships = relationships
    }

    mutating func walk(_ container: Element) throws {
        for child in container.children() {
            seen += 1
            if seen % 200 == 0 { try ParserSupport.checkCancellation() }
            switch child.tagNameNormal() {
            case "w:p": try paragraph(child)
            case "w:tbl": try table(child)
            case "w:sdt":
                if let inner = OfficeXML.children(of: child, named: "w:sdtContent").first { try walk(inner) }
            case "w:sectpr": continue
            default: try walk(child)
            }
        }
    }

    private mutating func paragraph(_ element: Element) throws {
        let text = ParserSupport.normalizeWhitespace(OfficeXML.runText(of: element))
        let properties = OfficeXML.children(of: element, named: "w:pPr").first
        let style = properties.flatMap { OfficeXML.children(of: $0, named: "w:pStyle").first }.map { OfficeXML.attribute($0, "val") } ?? ""
        let isListItem = properties.map { !OfficeXML.children(of: $0, named: "w:numPr").isEmpty } ?? false

        if !text.isEmpty {
            if let level = DocxBuilder.headingLevel(forStyle: style) {
                flushList()
                content.blocks.append(.heading(text, level: level))
            } else if isListItem {
                pendingList.append(text)
            } else {
                flushList()
                content.blocks.append(.paragraph(text))
            }
            lastParagraphText = text
        }
        for embed in DocxBuilder.imageEmbeds(in: element) {
            flushList()
            try image(relationshipId: embed)
        }
        if pageBreakFollows(element) { flushList() }
    }

    private mutating func table(_ element: Element) throws {
        flushList()
        var rows: [[String]] = []
        for row in OfficeXML.children(of: element, named: "w:tr") {
            let cells = OfficeXML.children(of: row, named: "w:tc").map { cell -> String in
                OfficeXML.children(of: cell, named: "w:p")
                    .map { ParserSupport.normalizeWhitespace(OfficeXML.runText(of: $0)) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            rows.append(cells)
        }
        if rows.contains(where: { $0.contains { !$0.isEmpty } }) {
            content.blocks.append(.table(rows))
            lastParagraphText = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
        }
        for embed in DocxBuilder.imageEmbeds(in: element) {
            try image(relationshipId: embed)
        }
    }

    private mutating func image(relationshipId: String) throws {
        guard let relationship = relationships[relationshipId], !relationship.isExternal else {
            content.warnings.append("Image relationship \(relationshipId) not found.")
            return
        }
        guard let data = try archive.data(at: relationship.target) else {
            content.warnings.append("Image \(relationship.target) is missing from the package.")
            return
        }
        guard let png = ImageCodec.pngData(fromImageData: data) else {
            content.warnings.append("Image \(relationship.target) could not be decoded.")
            return
        }
        let index = content.appendFigure(pngData: png, nearbyText: String(lastParagraphText.suffix(600)))
        content.blocks.append(.image(index: index))
    }

    mutating func flushList() {
        guard !pendingList.isEmpty else { return }
        content.blocks.append(.list(pendingList))
        pendingList.removeAll()
    }

    /// `Heading1`…`Heading6` (and localized `heading 1` forms) map to levels; `Title` is level 1.
    static func headingLevel(forStyle style: String) -> Int? {
        let lowered = style.lowercased().replacingOccurrences(of: " ", with: "")
        if lowered == "title" { return 1 }
        if lowered == "subtitle" { return 2 }
        guard lowered.hasPrefix("heading"), let level = Int(lowered.dropFirst("heading".count)), (1...6).contains(level) else {
            return nil
        }
        return level
    }

    /// Relationship ids of every DrawingML blip and legacy VML image below `element`, in order.
    static func imageEmbeds(in element: Element) -> [String] {
        var ids: [String] = []
        for blip in OfficeXML.descendants(of: element, named: "a:blip") {
            let id = OfficeXML.attribute(blip, "embed")
            if !id.isEmpty { ids.append(id) }
        }
        for imageData in OfficeXML.descendants(of: element, named: "v:imagedata") {
            let id = OfficeXML.attribute(imageData, "id")
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private func pageBreakFollows(_ paragraph: Element) -> Bool {
        OfficeXML.descendants(of: paragraph, named: "w:br").contains { OfficeXML.attribute($0, "type") == "page" }
    }
}
