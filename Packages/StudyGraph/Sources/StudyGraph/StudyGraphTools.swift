import Foundation
import ThubanCore
internal import GraphModel
internal import GraphTypes
internal import ThubanGraphKit

/// The tutor's graph tools on the class's graph sessions (STUDY_INTEGRATION.md §6). Names, parameter schemas and
/// `required` lists are ThubanCore's `TutorTools` specs, unchanged (a golden test locks them). Execution touches no
/// views and no network, so it runs headless in tests. `show_calculator` and `get_student_work` stay with the class
/// session (they are not graph edits); `execute` returns nil for them.
@MainActor
public enum StudyGraphTools {
    /// The tools executed here.
    public static let names: Set<String> = [
        TutorTools.showGraph, TutorTools.hideGraph, TutorTools.graphAddExpression, TutorTools.graphRemoveExpression,
        TutorTools.graphClear, TutorTools.graphSetViewport,
    ]

    /// How long `graph_add_expression` waits for the engine's verdict on the new row before replying.
    static var warningTimeout: Duration = .milliseconds(1500)

    /// Runs one graph tool call. Nil for a tool that is not a graph tool. A reply object with an `"error"` key is sent
    /// back to the tutor as an error result.
    public static func execute(name: String, arguments input: JSONValue, host: StudyGraphHost, mayEditGraph: Bool) async -> JSONValue? {
        guard names.contains(name) else { return nil }
        if TutorTools.graphEditingTools.contains(name), !mayEditGraph {
            return error("The student has disabled tutor graph edits.")
        }
        if name != TutorTools.hideGraph, let failure = host.engineError {
            return error("The graph engine failed to start (\(failure)), so nothing can be drawn.")
        }
        // The class's saved graphs must be in the sessions before an edit, or the load would replace it.
        await host.waitUntilLoaded()

        switch name {
        case TutorTools.showGraph:
            let mode = StudyGraphMode(rawValue: input["mode"]?.stringValue ?? "2d") ?? .twoD
            host.onShowGraph?(true)
            host.mode = mode
            host.stampTutorEdit()
            return reply(host)

        case TutorTools.hideGraph:
            host.onShowGraph?(false)
            return ["ok": true]

        case TutorTools.graphAddExpression:
            guard let id = trimmedID(input), let raw = input["latex"]?.stringValue,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return error("id and latex are required.") }
            let latex = normalizedLatex(raw)
            let embed = host.current
            // Ids are unique across both modes (as on the Desmos-era list): a row the other mode holds moves here.
            let other = host.session(host.mode == .twoD ? .threeD : .twoD)
            let existing = embed.document.item(ExpressionID(id))
            let item = tutorItem(id: id, latex: latex, color: input["color"]?.stringValue,
                                 dashed: input["dashed"]?.boolValue ?? false, label: input["label"]?.stringValue,
                                 hidden: input["hidden"]?.boolValue ?? false,
                                 existing: existing ?? other.document.item(ExpressionID(id)))
            host.markTutor(id)
            if existing == nil, other.document.item(ExpressionID(id)) != nil {
                other.perform(.deleteItem(ExpressionID(id)), origin: .host)
                host.markTutor(id)
            }
            embed.perform(placement(of: item, in: embed.document), origin: .host)
            host.stampTutorEdit()
            host.onShowGraph?(true)
            var object = reply(host).objectValue ?? [:]
            let verdict = await problems(in: embed, timeout: warningTimeout)
            let problems = verdict.problems.filter { host.tutorIDs.contains($0.id) }
            if !problems.isEmpty {
                object["warnings"] = .array(problems.map { .object(["id": .string($0.id), "message": .string($0.message)]) })
            }
            if verdict.pending { object["analysisPending"] = true }
            return .object(object)

        case TutorTools.graphRemoveExpression:
            guard let id = trimmedID(input) else { return error("id is required.") }
            // The mode on screen first, then the other one (ids are unique across modes).
            let other: StudyGraphMode = host.mode == .twoD ? .threeD : .twoD
            guard let embed = [host.current, host.session(other)].first(where: { $0.document.item(ExpressionID(id)) != nil }) else {
                return error("No expression with id '\(id)'.")
            }
            embed.perform(.deleteItem(ExpressionID(id)), origin: .host)
            host.unmarkTutor(id)
            host.stampTutorEdit()
            return reply(host)

        case TutorTools.graphClear:
            let embed = host.current
            let removable = embed.document.items.filter { !isBlank($0) }
            if !removable.isEmpty {
                embed.perform(.batch(removable.map { .deleteItem($0.id) }), origin: .host)
            }
            for item in removable { host.unmarkTutor(item.id.rawValue) }
            host.stampTutorEdit()
            return reply(host)

        case TutorTools.graphSetViewport:
            guard let xmin = input["xmin"]?.doubleValue, let xmax = input["xmax"]?.doubleValue,
                  let ymin = input["ymin"]?.doubleValue, let ymax = input["ymax"]?.doubleValue,
                  xmin < xmax, ymin < ymax, [xmin, xmax, ymin, ymax].allSatisfy(\.isFinite)
            else { return error("xmin < xmax and ymin < ymax are required.") }
            guard host.mode == .twoD else { return error("The viewport can only be set in 2D mode; the graph is in 3D.") }
            let viewport = Viewport2D(xMin: xmin, xMax: xmax, yMin: ymin, yMax: ymax)
            guard viewport.isValid else { return error("That region is too large to show.") }
            var settings = host.twoD.document.settings
            settings.equalAxes = false   // the bounds are shown exactly (as Desmos' setMathBounds did)
            host.twoD.perform(.batch([.setSettings(settings), .setViewport(viewport)]), origin: .host)
            host.onShowGraph?(true)
            host.stampTutorEdit()
            return reply(host)

        default:
            return nil
        }
    }

    // MARK: - Rows

    /// The tutor's row: signal (`.teal`, palette series 1) unless the tutor names a color; `dashed` dashes it;
    /// `label` shows a label. Keeps what the tutor did not specify of an existing row (slider settings, domain).
    static func tutorItem(id: String, latex: String, color: String?, dashed: Bool, label: String?, hidden: Bool,
                          existing: ExpressionItem?) -> ExpressionItem {
        var item = existing ?? ExpressionItem(id: ExpressionID(id))
        item.kind = .expression
        item.latex = latex
        item.isHidden = hidden
        item.color = color.flatMap(seriesColor(named:)) ?? .teal
        item.style.lineDash = dashed ? .dashed : .solid
        if let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            item.style.labelLatex = label
            item.style.showLabel = true
        } else {
            item.style.labelLatex = nil
            item.style.showLabel = false
        }
        if existing == nil, let parsed = SliderLatex.parse(latex) {
            item.slider = SliderSettings(value: parsed.value)
        }
        return item
    }

    /// `DocumentCommand.upsert`, except that a new row goes above the list's trailing blank rows (the empty row the
    /// student types into stays last).
    nonisolated static func placement(of item: ExpressionItem, in document: GraphDocument) -> DocumentCommand {
        guard document.item(item.id) == nil else { return .upsert(item, in: document) }
        var firstTrailingBlank = document.items.count
        while firstTrailingBlank > 0, isBlank(document.items[firstTrailingBlank - 1]) { firstTrailingBlank -= 1 }
        if firstTrailingBlank == document.items.count { return .addItem(item, after: document.items.last?.id) }
        if firstTrailingBlank > 0 { return .addItem(item, after: document.items[firstTrailingBlank - 1].id) }
        // Only blank rows: add, then move the new row to the top.
        return .batch([.addItem(item, after: nil), .reorder([item.id] + document.items.map(\.id))])
    }

    nonisolated static func isBlank(_ item: ExpressionItem) -> Bool {
        item.kind == .expression && item.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A tutor `color`: a series token (`brass`, `teal`, `blue`, `rust`, `violet`, `green`) as is, `#rrggbb` as a
    /// custom color, a CSS / Desmos color name as the nearest preset. Nil for anything else (then the default).
    nonisolated static func seriesColor(named raw: String) -> SeriesColor? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("#") {
            let hex = String(name.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count == 6 { return .custom("#" + hex) }
            if hex.count == 3 { return .custom("#" + hex.map { "\($0)\($0)" }.joined()) }
            return nil
        }
        switch name {
        case "brass", "accent", "gold", "yellow", "orange", "amber": return .brass
        case "teal", "signal", "cyan", "aqua", "turquoise": return .teal
        case "blue", "navy", "indigo": return .blue
        case "rust", "red", "crimson", "maroon", "brown": return .rust
        case "violet", "purple", "magenta", "pink": return .violet
        case "green", "lime", "olive": return .green
        default: return nil
        }
    }

    /// The `id` argument without surrounding spaces; nil when missing or blank (add and remove agree on it).
    nonisolated static func trimmedID(_ input: JSONValue) -> String? {
        guard let id = input["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }

    /// Desmos reads a top-level comma-separated run of points (`(1,2),(3,4)`) as a point list; Thuban Graph wants
    /// the list brackets, so such a row is wrapped (`\left[(1,2),(3,4)\right]`). Everything else is kept as sent.
    nonisolated static func normalizedLatex(_ latex: String) -> String {
        let text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = topLevelCommaParts(text)
        guard parts.count >= 2, parts.allSatisfy(isParenthesizedTuple) else { return latex }
        return "\\left[" + text + "\\right]"
    }

    /// Splits at commas outside every (), [] and {} (and \left( … \right) pairs, which use the same characters).
    private nonisolated static func topLevelCommaParts(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0, current = ""
        for character in text {
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            if depth < 0 { return [] }
        }
        parts.append(current)
        return depth == 0 ? parts.map { $0.trimmingCharacters(in: .whitespaces) } : []
    }

    /// `(a,b)` / `\left(a,b\right)` (or three components) as one balanced group.
    private nonisolated static func isParenthesizedTuple(_ part: String) -> Bool {
        var body = part
        if body.hasPrefix("\\left("), body.hasSuffix("\\right)") {
            body = String(body.dropFirst(6).dropLast(7))
        } else if body.hasPrefix("("), body.hasSuffix(")") {
            body = String(body.dropFirst().dropLast())
        } else {
            return false
        }
        // The outer parentheses must enclose the whole part ("(1)+(2)" is not a tuple) and hold 2 or 3 components.
        let components = topLevelCommaParts(body)
        guard (2 ... 3).contains(components.count), components.allSatisfy({ !$0.isEmpty }) else { return false }
        var depth = 0
        for character in body {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if depth < 0 { return false }
        }
        return depth == 0
    }

    // MARK: - Warnings

    struct Verdict {
        var problems: [(id: String, message: String)]
        /// The engine had not analysed the edit when the timeout passed: `problems` is empty rather than stale.
        var pending: Bool
    }

    /// Rows the engine could not use (errors, not warnings), once the analysis the edit started has been published.
    /// When it has not finished within `timeout`, nothing is reported (the previous analysis would flag a row the
    /// tutor just fixed, or miss a new one) and `pending` is set. Empty when headless.
    static func problems(in embed: GraphEmbedSession, timeout: Duration) async -> Verdict {
        let session = embed.session
        guard session.engine != nil else { return Verdict(problems: [], pending: false) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // `isAnalyzing` is set when the edit schedules its analysis and cleared once the last pass is published.
        while session.isAnalyzing, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard !session.isAnalyzing else { return Verdict(problems: [], pending: true) }
        let problems = session.document.items.compactMap { item -> (id: String, message: String)? in
            guard let error = session.analyses[item.id]?.error, !error.isWarning else { return nil }
            return (item.id.rawValue, error.message)
        }
        return Verdict(problems: problems, pending: false)
    }

    // MARK: - Replies

    private static func reply(_ host: StudyGraphHost) -> JSONValue {
        ["ok": true, "mode": .string(host.mode.rawValue), "count": .number(Double(host.rowCount(host.mode)))]
    }

    private static func error(_ message: String) -> JSONValue {
        ["error": .string(message)]
    }
}
