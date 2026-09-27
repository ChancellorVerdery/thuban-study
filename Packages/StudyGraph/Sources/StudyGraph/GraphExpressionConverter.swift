import Foundation
internal import GraphModel
internal import GraphTypes

/// The Desmos-era Study graph row (`GraphExpression`, removed from the app), in its Codable shape. Nothing on disk
/// holds these today (the Desmos grapher kept its rows in memory), but any exported or future-found copy stays
/// readable through `GraphExpressionConverter`.
public struct LegacyGraphExpression: Codable, Equatable, Sendable {
    public var id: String
    public var latex: String
    /// Hex; nil = theme default (accent, or signal / accentDeep for tutor rows).
    public var color: String?
    public var dashed: Bool
    public var dotted: Bool
    public var label: String?
    public var hidden: Bool
    public var fromTutor: Bool
    public var sliderBounds: SliderBounds?
    /// "2d" | "3d".
    public var mode: String
    public var fillOpacity: Double?
    public var parametricDomain: Domain?
    public var showsPoints: Bool?
    public var lineWidth: Double?
    public var lineOpacity: Double?

    public struct Domain: Codable, Equatable, Sendable {
        public var min: Double
        public var max: Double
    }

    public struct SliderBounds: Codable, Equatable, Sendable {
        public var min: Double?
        public var max: Double?
        public var step: Double?
    }

    public init(id: String, latex: String, color: String? = nil, dashed: Bool = false, dotted: Bool = false,
                label: String? = nil, hidden: Bool = false, fromTutor: Bool = false, sliderBounds: SliderBounds? = nil,
                mode: String = "2d", fillOpacity: Double? = nil, parametricDomain: Domain? = nil, showsPoints: Bool? = nil,
                lineWidth: Double? = nil, lineOpacity: Double? = nil) {
        self.id = id
        self.latex = latex
        self.color = color
        self.dashed = dashed
        self.dotted = dotted
        self.label = label
        self.hidden = hidden
        self.fromTutor = fromTutor
        self.sliderBounds = sliderBounds
        self.mode = mode
        self.fillOpacity = fillOpacity
        self.parametricDomain = parametricDomain
        self.showsPoints = showsPoints
        self.lineWidth = lineWidth
        self.lineOpacity = lineOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case id, latex, color, dashed, dotted, label, hidden, fromTutor, sliderBounds, mode, fillOpacity,
             parametricDomain, showsPoints, lineWidth, lineOpacity
    }

    /// Lenient: every field but `id` and `latex` may be missing (Swift's synthesized decoding required all of them).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        latex = try c.decode(String.self, forKey: .latex)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
        dotted = try c.decodeIfPresent(Bool.self, forKey: .dotted) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        fromTutor = try c.decodeIfPresent(Bool.self, forKey: .fromTutor) ?? false
        sliderBounds = try c.decodeIfPresent(SliderBounds.self, forKey: .sliderBounds)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "2d"
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity)
        parametricDomain = try c.decodeIfPresent(Domain.self, forKey: .parametricDomain)
        showsPoints = try c.decodeIfPresent(Bool.self, forKey: .showsPoints)
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth)
        lineOpacity = try c.decodeIfPresent(Double.self, forKey: .lineOpacity)
    }
}

/// Theme hex values a Desmos-era row may carry as its color (Study resolved `nil` colors to these before sending
/// them to Desmos). They map back to theme-relative series so converted rows re-tint with the scheme.
public struct LegacyThemeColors: Equatable, Sendable {
    public var accent: String
    public var signal: String
    public var accentDeep: String

    public init(accent: String, signal: String, accentDeep: String) {
        self.accent = accent
        self.signal = signal
        self.accentDeep = accentDeep
    }
}

/// Desmos-shaped graph state → Thuban Graph (STUDY_INTEGRATION.md §7). One conversion path: every row goes through
/// GraphModel's `DesmosImport.item(fromRow:preserveID:)`, the function Thuban Graph's File → Import uses.
enum GraphExpressionConverter {
    struct Converted {
        var item: ExpressionItem
        var fromTutor: Bool
        var mode: StudyGraphMode
        /// Payload keys the importer does not map (never fatal).
        var skipped: Int
    }

    /// Keys a Study payload row may carry; any other key counts as skipped.
    static let knownPayloadKeys: Set<String> = [
        "id", "latex", "color", "lineStyle", "label", "showLabel", "hidden", "fillOpacity", "parametricDomain",
        "points", "lineWidth", "lineOpacity", "sliderBounds", "fromTutor", "mode", "type",
    ]

    /// A Desmos-era Study row (the `GraphExpression` Codable form).
    static func convert(_ row: LegacyGraphExpression, theme: LegacyThemeColors? = nil) -> Converted {
        var payload: [String: Any] = ["id": row.id, "latex": row.latex, "hidden": row.hidden, "fromTutor": row.fromTutor,
                                      "mode": row.mode]
        if let color = row.color { payload["color"] = color }
        payload["lineStyle"] = row.dotted ? "DOTTED" : (row.dashed ? "DASHED" : "SOLID")
        if let label = row.label, !label.isEmpty {
            payload["label"] = label
            payload["showLabel"] = true
        }
        if let fillOpacity = row.fillOpacity { payload["fillOpacity"] = fillOpacity }
        if let domain = row.parametricDomain {
            payload["parametricDomain"] = ["min": number(domain.min), "max": number(domain.max)]
        }
        if let points = row.showsPoints { payload["points"] = points }
        if let width = row.lineWidth { payload["lineWidth"] = width }
        if let opacity = row.lineOpacity { payload["lineOpacity"] = opacity }
        if let bounds = row.sliderBounds {
            var object: [String: Any] = [:]
            if let min = bounds.min { object["min"] = number(min) }
            if let max = bounds.max { object["max"] = number(max) }
            if let step = bounds.step { object["step"] = number(step) }
            payload["sliderBounds"] = object
        }
        return convert(payload: payload, theme: theme)
    }

    /// A Desmos payload row as Study sent it to the page (`desmosPayload`: `{id, latex, color, lineStyle, label?,
    /// showLabel, hidden, fillOpacity?, parametricDomain?, points?, lineWidth?, lineOpacity?, sliderBounds?}`, plus
    /// `fromTutor` / `mode` when present). Numbers may be JSON numbers or strings.
    static func convert(payload: [String: Any], theme: LegacyThemeColors? = nil) -> Converted {
        var row = payload
        // The importer reads bounds and domains as strings (Desmos' own state); Study sent numbers.
        if let bounds = row["sliderBounds"] as? [String: Any] { row["sliderBounds"] = bounds.mapValues(numberText) }
        if let domain = row["parametricDomain"] as? [String: Any] { row["parametricDomain"] = domain.mapValues(numberText) }
        if let width = row["lineWidth"], !(width is String) { row["lineWidth"] = numberText(width) }
        let fromTutor = row["fromTutor"] as? Bool ?? false
        let dashed = (row["lineStyle"] as? String) == "DASHED"
        var item = DesmosImport.item(fromRow: row, preserveID: true)

        // Colors: theme defaults map back to series tokens so they follow the scheme.
        let hex = (row["color"] as? String)?.lowercased()
        if let hex, hex.count == 7, hex.hasPrefix("#") {
            if let theme, hex == theme.accent.lowercased() {
                item.color = .brass
            } else if let theme, hex == theme.signal.lowercased() {
                item.color = .teal
            } else if let theme, hex == theme.accentDeep.lowercased() {
                item.color = .teal
                item.style.lineDash = .dashed
            } else {
                item.color = .custom(hex)
            }
        } else if let named = (row["color"] as? String).flatMap(StudyGraphTools.seriesColor(named:)) {
            item.color = named
        } else {
            item.color = fromTutor ? .teal : .brass
            if fromTutor, dashed { item.style.lineDash = .dashed }
        }
        // `points: true` (a point list drawn as dots) is Thuban Graph's default point style; `false` (lines only)
        // has no expression-row equivalent and is counted as skipped.
        var unmapped = 0
        if let points = row["points"] as? Bool {
            if points { item.style.pointShape = .dot } else { unmapped += 1 }
        }
        // Slider bounds given as plain numbers (the importer only reads strings from a Desmos state).
        if var slider = item.slider, let bounds = payload["sliderBounds"] as? [String: Any] {
            if let min = number(bounds["min"]) { slider.min = min }
            if let max = number(bounds["max"]) { slider.max = max }
            if let step = number(bounds["step"]), step > 0 { slider.step = step }
            item.slider = slider
        }
        let mode = StudyGraphMode(rawValue: row["mode"] as? String ?? "2d") ?? .twoD
        let skipped = Set(payload.keys).subtracting(knownPayloadKeys).count + unmapped
        return Converted(item: item, fromTutor: fromTutor, mode: mode, skipped: skipped)
    }

    /// A whole Desmos-era row list (JSON array of `GraphExpression`) → both documents and the tutor ids.
    static func contents(fromLegacyRows data: Data, theme: LegacyThemeColors? = nil) throws -> StudyGraphRecord.Contents {
        let rows = try JSONDecoder().decode([LegacyGraphExpression].self, from: data)
        var twoD = StudyGraphHost.emptyDocument(.twoD), threeD = StudyGraphHost.emptyDocument(.threeD)
        twoD.items = []
        threeD.items = []
        var tutor: Set<String> = []
        for row in rows {
            let converted = convert(row, theme: theme)
            if converted.mode == .threeD { threeD.items.append(converted.item) } else { twoD.items.append(converted.item) }
            if converted.fromTutor { tutor.insert(row.id) }
        }
        if twoD.items.isEmpty { twoD = StudyGraphHost.emptyDocument(.twoD) }
        if threeD.items.isEmpty { threeD = StudyGraphHost.emptyDocument(.threeD) }
        return StudyGraphRecord.Contents(twoD: twoD, threeD: threeD, tutorIDs: tutor)
    }

    /// A full Desmos `Calculator.getState()` / `Calculator3D.getState()` JSON → a document (GraphModel's importer).
    static func document(fromDesmosState data: Data, mode: StudyGraphMode? = nil) throws -> (document: GraphDocument, skipped: Int) {
        let result = try DesmosImport.document(from: data, title: "", mode: mode.map { $0 == .threeD ? .threeD : .twoD })
        return (result.document, result.skipped)
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let text = any as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func numberText(_ any: Any) -> Any {
        if let text = any as? String { return text }
        if let value = number(any) { return number(value) }
        return any
    }
}
