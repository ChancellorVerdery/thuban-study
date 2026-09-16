import Foundation
import SwiftSoup
import ZIPFoundation

/// Read access to an Office Open XML package (.docx / .pptx / .xlsx): zip entries, parsed XML parts and
/// relationship files.
struct OfficeArchive {
    private let archive: Archive
    let filename: String

    /// Opens the package; a file that is not a zip throws `unsupportedDocument`.
    init(url: URL) throws {
        filename = url.lastPathComponent
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is not an Office document (\(error)).")
        }
    }

    /// True when the package holds an entry at `path`.
    func contains(_ path: String) -> Bool { archive[path] != nil }

    /// All entry paths, in archive order.
    var entryPaths: [String] { archive.map(\.path) }

    /// The bytes of the entry at `path`, or `nil` when absent.
    func data(at path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            throw ThubanError.parse("Could not read \(path) in \(filename): \(error)")
        }
        return data
    }

    /// The bytes of a required entry.
    func requiredData(at path: String) throws -> Data {
        guard let data = try data(at: path) else {
            throw ThubanError.unsupportedDocument("\"\(filename)\" is missing \(path).")
        }
        return data
    }

    /// Parses an XML part with SwiftSoup's XML parser (tag case preserved, namespaces kept as prefixes).
    func xml(at path: String) throws -> Document {
        let data = try requiredData(at: path)
        let text = String(decoding: data, as: UTF8.self)
        do {
            return try Parser.xmlParser().parseInput(text, "")
        } catch {
            throw ThubanError.parse("Invalid XML in \(path) of \(filename): \(error)")
        }
    }

    /// The relationships declared by the `.rels` file for `partPath`, keyed by Id; targets are resolved to package
    /// paths. Missing rels files yield an empty map.
    func relationships(for partPath: String) throws -> [String: OfficeRelationship] {
        let directory = (partPath as NSString).deletingLastPathComponent
        let name = (partPath as NSString).lastPathComponent
        let relsPath = (directory.isEmpty ? "_rels" : directory + "/_rels") + "/" + name + ".rels"
        guard try data(at: relsPath) != nil else { return [:] }
        let document = try xml(at: relsPath)
        var result: [String: OfficeRelationship] = [:]
        for element in OfficeXML.descendants(of: document, named: "Relationship") {
            let id = OfficeXML.attribute(element, "Id")
            let target = OfficeXML.attribute(element, "Target")
            guard !id.isEmpty, !target.isEmpty else { continue }
            let external = OfficeXML.attribute(element, "TargetMode").lowercased() == "external"
            let resolved = external ? target : OfficeArchive.resolve(target: target, relativeTo: directory)
            result[id] = OfficeRelationship(id: id, type: OfficeXML.attribute(element, "Type"), target: resolved, isExternal: external)
        }
        return result
    }

    /// Resolves a relationship target against the part's directory, handling `/absolute` and `../` segments.
    static func resolve(target: String, relativeTo directory: String) -> String {
        var components: [String] = target.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case "", ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }
}

/// One entry of a `.rels` file.
struct OfficeRelationship {
    let id: String
    let type: String
    /// Package path (or the URL for external targets).
    let target: String
    let isExternal: Bool

    /// The last segment of `type`, e.g. "image", "slide", "notesSlide".
    var kind: String { type.split(separator: "/").last.map(String.init) ?? type }
}

/// Namespace-tolerant traversal for OOXML documents parsed with SwiftSoup.
enum OfficeXML {
    /// Elements anywhere below `root` whose tag matches `name` (with or without namespace prefix), in document order.
    static func descendants(of root: Node, named name: String) -> [Element] {
        var found: [Element] = []
        collect(root, name: name.lowercased(), into: &found)
        return found
    }

    private static func collect(_ node: Node, name: String, into found: inout [Element]) {
        for child in node.getChildNodes() {
            guard let element = child as? Element else { continue }
            if matches(element, name) { found.append(element) }
            collect(element, name: name, into: &found)
        }
    }

    /// Direct child elements of `element` whose tag matches `name`.
    static func children(of element: Element, named name: String) -> [Element] {
        let lowered = name.lowercased()
        return element.children().filter { matches($0, lowered) }
    }

    /// The first descendant with tag `name`.
    static func first(in root: Node, named name: String) -> Element? {
        descendants(of: root, named: name).first
    }

    /// Tag comparison ignoring case and namespace prefix (`w:p` matches `p`, and `w:p`).
    static func matches(_ element: Element, _ loweredName: String) -> Bool {
        let tag = element.tagNameNormal()
        if tag == loweredName { return true }
        guard !loweredName.contains(":") else { return false }
        return tag.hasSuffix(":" + loweredName)
    }

    /// Attribute lookup that tolerates namespace prefixes (`r:embed` also matches `embed`).
    static func attribute(_ element: Element, _ name: String) -> String {
        if let value = try? element.attr(name), !value.isEmpty { return value }
        guard let attributes = element.getAttributes() else { return "" }
        let suffix = ":" + name.lowercased()
        for attribute in attributes where attribute.getKey().lowercased().hasSuffix(suffix) {
            return attribute.getValue()
        }
        return ""
    }

    /// Text of a DrawingML/WordprocessingML paragraph: `t` runs joined, tabs and breaks kept.
    static func runText(of paragraph: Element) -> String {
        var text = ""
        appendRunText(paragraph, into: &text)
        return text
    }

    private static func appendRunText(_ node: Node, into text: inout String) {
        // Only `t` elements carry text; whitespace text nodes between elements are formatting, not content.
        for child in node.getChildNodes() {
            guard let element = child as? Element else { continue }
            let tag = element.tagNameNormal()
            switch tag {
            case "w:t", "a:t", "t": text += element.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
            case "w:tab", "a:tab": text += "\t"
            case "w:br", "a:br", "w:cr": text += "\n"
            case "w:deltext", "w:instrtext": continue
            case "w:sym": text += " "
            default: appendRunText(element, into: &text)
            }
        }
    }
}
