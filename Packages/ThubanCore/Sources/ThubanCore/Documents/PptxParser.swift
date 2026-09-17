import Foundation
import SwiftSoup

/// PowerPoint decks (.pptx): one `pageBreak` per slide in presentation order, titles as headings, body text as
/// paragraphs or lists, tables, pictures from `ppt/media`, and speaker notes.
public struct PptxParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.pptx]

    public init() {}

    public func parse(url: URL) async throws -> DocumentContent {
        let archive = try OfficeArchive(url: url)
        let slidePaths = try Self.orderedSlidePaths(in: archive)
        guard !slidePaths.isEmpty else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" has no slides.")
        }
        var content = DocumentContent(pageCount: slidePaths.count)
        for (offset, path) in slidePaths.enumerated() {
            try ParserSupport.checkCancellation()
            var slide = SlideBuilder(archive: archive, slidePath: path, slideNumber: offset + 1, content: content)
            try slide.run()
            content = slide.content
        }
        return content
    }

    /// Slide part paths in the order `presentation.xml` lists them; falls back to numeric order of `slideN.xml`.
    static func orderedSlidePaths(in archive: OfficeArchive) throws -> [String] {
        let presentationPath = "ppt/presentation.xml"
        if archive.contains(presentationPath) {
            let presentation = try archive.xml(at: presentationPath)
            let relationships = try archive.relationships(for: presentationPath)
            let ordered = OfficeXML.descendants(of: presentation, named: "p:sldId")
                .compactMap { relationships[OfficeXML.attribute($0, "id")]?.target }
                .filter { archive.contains($0) }
            if !ordered.isEmpty { return ordered }
        }
        return archive.entryPaths
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
    }

    private static func slideNumber(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        return Int(name.dropFirst("slide".count).dropLast(".xml".count)) ?? 0
    }
}

/// Extracts one slide's shapes in order.
private struct SlideBuilder {
    let archive: OfficeArchive
    let slidePath: String
    let slideNumber: Int
    var content: DocumentContent
    private var relationships: [String: OfficeRelationship] = [:]
    private var lastText = ""

    init(archive: OfficeArchive, slidePath: String, slideNumber: Int, content: DocumentContent) {
        self.archive = archive
        self.slidePath = slidePath
        self.slideNumber = slideNumber
        self.content = content
    }

    mutating func run() throws {
        content.blocks.append(.pageBreak(slideNumber))
        let slide = try archive.xml(at: slidePath)
        relationships = try archive.relationships(for: slidePath)
        guard let tree = OfficeXML.first(in: slide, named: "p:spTree") else { return }
        try walk(tree)
        try notes()
    }

    private mutating func walk(_ container: Element) throws {
        for child in container.children() {
            switch child.tagNameNormal() {
            case "p:sp": shape(child)
            case "p:pic": try picture(child)
            case "p:graphicframe": try graphicFrame(child)
            case "p:grpsp": try walk(child)
            default: continue
            }
        }
    }

    private mutating func shape(_ shape: Element) {
        guard let body = OfficeXML.first(in: shape, named: "p:txBody") else { return }
        let paragraphs = OfficeXML.children(of: body, named: "a:p")
            .map { ParserSupport.normalizeWhitespace(OfficeXML.runText(of: $0)) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return }
        let placeholder = OfficeXML.first(in: shape, named: "p:ph").map { OfficeXML.attribute($0, "type") } ?? ""
        if ["title", "ctrTitle"].contains(placeholder) {
            content.blocks.append(.heading(paragraphs.joined(separator: " "), level: 1))
        } else if placeholder == "subTitle" {
            content.blocks.append(.heading(paragraphs.joined(separator: " "), level: 2))
        } else if paragraphs.count > 1 {
            content.blocks.append(.list(paragraphs))
        } else {
            content.blocks.append(.paragraph(paragraphs[0]))
        }
        lastText = paragraphs.joined(separator: "\n")
    }

    private mutating func graphicFrame(_ frame: Element) throws {
        if let table = OfficeXML.first(in: frame, named: "a:tbl") {
            let rows = OfficeXML.children(of: table, named: "a:tr").map { row in
                OfficeXML.children(of: row, named: "a:tc").map { cell in
                    OfficeXML.descendants(of: cell, named: "a:p")
                        .map { ParserSupport.normalizeWhitespace(OfficeXML.runText(of: $0)) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
            }
            if !rows.isEmpty { content.blocks.append(.table(rows)) }
        }
        for blip in OfficeXML.descendants(of: frame, named: "a:blip") {
            try image(relationshipId: OfficeXML.attribute(blip, "embed"))
        }
    }

    private mutating func picture(_ picture: Element) throws {
        for blip in OfficeXML.descendants(of: picture, named: "a:blip") {
            try image(relationshipId: OfficeXML.attribute(blip, "embed"))
        }
    }

    private mutating func image(relationshipId: String) throws {
        guard let relationship = relationships[relationshipId], !relationship.isExternal else { return }
        guard let data = try archive.data(at: relationship.target) else {
            content.warnings.append("Slide \(slideNumber): image \(relationship.target) is missing.")
            return
        }
        guard let png = ImageCodec.pngData(fromImageData: data) else {
            content.warnings.append("Slide \(slideNumber): image \(relationship.target) could not be decoded.")
            return
        }
        guard let index = content.appendFigure(page: slideNumber, pngData: png, nearbyText: String(lastText.suffix(600))) else { return }
        content.blocks.append(.image(index: index))
    }

    /// Speaker notes, when the slide links a notes part.
    private mutating func notes() throws {
        guard let notesPath = relationships.values.first(where: { $0.kind == "notesSlide" })?.target,
              archive.contains(notesPath) else { return }
        let notes = try archive.xml(at: notesPath)
        let text = OfficeXML.descendants(of: notes, named: "a:p")
            .map { ParserSupport.normalizeWhitespace(OfficeXML.runText(of: $0)) }
            .filter { !$0.isEmpty && Int($0) == nil }   // drop the slide-number placeholder
            .joined(separator: "\n")
        if !text.isEmpty { content.blocks.append(.paragraph("Notes: " + text)) }
    }
}
