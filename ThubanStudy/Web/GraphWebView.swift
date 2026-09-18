import SwiftUI
import ThubanCore
import os

/// Graph mode of the Desmos page.
enum GraphMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case twoD = "2d"
    case threeD = "3d"

    var id: String { rawValue }
    var label: String { self == .twoD ? "2D" : "3D" }
    var iconName: String { self == .twoD ? "graph-2d" : "graph-3d" }
}

/// One row of the grapher's expression list, as the app tracks it (Desmos ids are the same `id`).
struct GraphExpression: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var latex: String
    /// Hex; `nil` = theme accent (or the tutor colors when `fromTutor`).
    var color: String?
    var dashed: Bool = false
    /// Dotted stroke (wins over `dashed`).
    var dotted: Bool = false
    var label: String?
    var hidden: Bool = false
    var fromTutor: Bool = false
    var sliderBounds: SliderBounds?
    /// The calculator this row lives in; Desmos keeps a separate list per mode.
    var mode: GraphMode = .twoD
    /// Polygons: fill opacity (nil = Desmos default).
    var fillOpacity: Double?
    /// Parametric rows: the range of t.
    var parametricDomain: Domain?
    /// Point lists: draw the dots (true) or only lines/curves (false). nil = Desmos default.
    var showsPoints: Bool?
    /// Stroke width in px; nil = Desmos default.
    var lineWidth: Double?
    /// Stroke opacity 0–1; nil = Desmos default.
    var lineOpacity: Double?

    struct Domain: Codable, Hashable, Sendable {
        var min: Double
        var max: Double
    }

    struct SliderBounds: Codable, Hashable, Sendable {
        var min: Double?
        var max: Double?
        var step: Double?
    }

    init(id: String, latex: String, color: String? = nil, dashed: Bool = false, label: String? = nil,
         hidden: Bool = false, fromTutor: Bool = false, sliderBounds: SliderBounds? = nil, mode: GraphMode = .twoD) {
        self.id = id
        self.latex = latex
        self.color = color
        self.dashed = dashed
        self.label = label
        self.hidden = hidden
        self.fromTutor = fromTutor
        self.sliderBounds = sliderBounds
        self.mode = mode
    }

    /// The `{id, latex, color, lineStyle, label?, hidden, sliderBounds?}` object graph.js expects. `lineStyle` and
    /// `hidden` are always present so a replace-by-id fully overrides the row's previous styling.
    func desmosPayload(theme: ResolvedTheme) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "latex": .string(latex)]
        let resolvedColor = color ?? (fromTutor ? (dashed ? theme.accentDeep : theme.signal) : theme.accent)
        object["color"] = .string(resolvedColor)
        object["lineStyle"] = .string(dotted ? "DOTTED" : (dashed ? "DASHED" : "SOLID"))
        if let label, !label.isEmpty {
            object["label"] = .string(label)
            object["showLabel"] = .bool(true)
        } else {
            object["showLabel"] = .bool(false)
        }
        object["hidden"] = .bool(hidden)
        if let fillOpacity { object["fillOpacity"] = .number(fillOpacity) }
        if let parametricDomain {
            object["parametricDomain"] = .object(["min": .number(parametricDomain.min), "max": .number(parametricDomain.max)])
        }
        if let showsPoints { object["points"] = .bool(showsPoints) }
        if let lineWidth { object["lineWidth"] = .number(lineWidth) }
        if let lineOpacity { object["lineOpacity"] = .number(lineOpacity) }
        if let sliderBounds {
            var bounds: [String: JSONValue] = [:]
            if let min = sliderBounds.min { bounds["min"] = .number(min) }
            if let max = sliderBounds.max { bounds["max"] = .number(max) }
            if let step = sliderBounds.step { bounds["step"] = .number(step) }
            object["sliderBounds"] = .object(bounds)
        }
        return .object(object)
    }
}

struct GraphViewport: Codable, Hashable, Sendable {
    var xmin: Double
    var xmax: Double
    var ymin: Double
    var ymax: Double
}

/// Desmos 2D/3D grapher (`web/graph/graph.html`). Drive it through `Controller`; keep one controller per pane.
struct GraphWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "graph/graph.html", bridge: controller.bridge, theme: theme)
            .onChange(of: theme, initial: true) { _, newTheme in controller.theme = newTheme }
    }

    @MainActor
    @Observable
    final class Controller {
        private static let logger = Logger(subsystem: "com.thuban.study", category: "graph")
        let bridge: WebBridge
        /// Theme used to resolve default expression colors; kept current by the view.
        var theme: ResolvedTheme = ThemeResolver.resolve(.default, systemIsDark: false)
        private(set) var mode: GraphMode = .twoD
        private(set) var desmosKey: String = ""
        /// Set by the page when the Desmos script fails or an operation errors.
        private(set) var lastError: String?
        /// True while the page that is currently attached has posted `ready`.
        var isPageReady: Bool { bridge.isPageReady }

        /// Expression rows the student edited inside Desmos (debounced by the page): `[(id, latex)]` of the
        /// calculator in `mode` — the other mode's rows are untouched.
        var onExpressionsChanged: ((_ rows: [(id: String, latex: String)], _ mode: GraphMode) -> Void)?
        var onError: ((String) -> Void)?
        /// Reply to `getState`: the raw Desmos state object and the mode it belongs to.
        var onState: ((JSONValue, GraphMode) -> Void)?
        var onReady: (() -> Void)?

        /// True for figure panes: the paper only — no expression list, settings menu or zoom buttons, and the
        /// viewport is locked to what the figure shows.
        private(set) var isFigure = false

        init(desmosKey: String, mode: GraphMode = .twoD, isFigure: Bool = false) {
            self.bridge = WebBridge(name: "graph")
            self.desmosKey = desmosKey
            self.mode = mode
            self.isFigure = isFigure
            bridge.on("ready") { [weak self] _ in
                self?.onReady?()
            }
            bridge.on("expressionsChanged") { [weak self] payload in
                guard let self else { return }
                let rows = (payload["expressions"]?.arrayValue ?? []).compactMap { row -> (id: String, latex: String)? in
                    guard let id = row["id"]?.stringValue else { return nil }
                    return (id, row["latex"]?.stringValue ?? "")
                }
                let mode = payload["mode"]?.stringValue.flatMap(GraphMode.init(rawValue:)) ?? self.mode
                self.onExpressionsChanged?(rows, mode)
            }
            bridge.on("error") { [weak self] payload in
                let message = payload["message"]?.stringValue ?? "Graph error"
                self?.lastError = message
                self?.onError?(message)
            }
            bridge.on("rowAnalysis") { payload in
                if ProcessInfo.processInfo.environment["THUBAN_SMOKE"] != nil { print("graph: analysis: \(payload["summary"]?.stringValue ?? "")") }
            }
            bridge.on("rowErrors") { payload in
                // Rows Desmos could not graph; a developer diagnostic (the page draws whatever else it can).
                let rows = payload["rows"]?.arrayValue?.compactMap(\.stringValue) ?? []
                Self.logger.error("Desmos rejected \(rows.count) row(s): \(rows.joined(separator: " | "), privacy: .public)")
                if ProcessInfo.processInfo.environment["THUBAN_SMOKE"] != nil { print("graph: rejected rows: \(rows.joined(separator: " | "))") }
            }
            bridge.on("state") { [weak self] payload in
                let mode = GraphMode(rawValue: payload["mode"]?.stringValue ?? "2d") ?? .twoD
                self?.onState?(payload["state"] ?? .null, mode)
            }
            configure(desmosKey: desmosKey, mode: mode)
        }

        // MARK: Swift → JS

        /// Injects (or re-sends) the API key; must precede everything else and is sent from `init`.
        func configure(desmosKey: String, mode: GraphMode? = nil) {
            self.desmosKey = desmosKey
            if let mode { self.mode = mode }
            var payload: [String: JSONValue] = ["desmosKey": .string(desmosKey)]
            payload["mode"] = .string(self.mode.rawValue)
            payload["figure"] = .bool(isFigure)
            // Sticky: the page is reloaded whenever its hosting view is re-created and needs the key again.
            bridge.sendSticky("config", .object(payload))
        }

        func setMode(_ mode: GraphMode) {
            self.mode = mode
            bridge.send("setMode", ["mode": .string(mode.rawValue)])
        }

        /// Replaces the whole expression list.
        func setExpressions(_ expressions: [GraphExpression]) {
            bridge.send("setExpressions", ["expressions": .array(expressions.map { $0.desmosPayload(theme: theme) })])
        }

        /// Adds or replaces (by id) one expression.
        func addExpression(_ expression: GraphExpression) {
            bridge.send("addExpression", expression.desmosPayload(theme: theme))
        }

        func removeExpression(id: String) {
            bridge.send("removeExpression", ["id": .string(id)])
        }

        func clear() {
            bridge.send("clear")
        }

        /// Axis presentation for a figure: tick spacing and labels (nil leaves Desmos's choice).
        func setAxes(xStep: Double?, yStep: Double?, xLabel: String?, yLabel: String?) {
            var payload: [String: JSONValue] = [:]
            if let xStep, xStep > 0 { payload["xStep"] = .number(xStep) }
            if let yStep, yStep > 0 { payload["yStep"] = .number(yStep) }
            if let xLabel, !xLabel.isEmpty { payload["xLabel"] = .string(xLabel) }
            if let yLabel, !yLabel.isEmpty { payload["yLabel"] = .string(yLabel) }
            bridge.send("setAxes", .object(payload))
        }

        func setViewport(_ viewport: GraphViewport) {
            bridge.send("setViewport", [
                "xmin": .number(viewport.xmin), "xmax": .number(viewport.xmax),
                "ymin": .number(viewport.ymin), "ymax": .number(viewport.ymax),
            ])
        }

        /// Asks the page for its Desmos state; the answer arrives through `onState`.
        func getState() {
            bridge.send("getState")
        }

        func setState(_ state: JSONValue) {
            bridge.send("setState", ["state": state])
        }

        func resetView() {
            bridge.send("resetView")
        }
    }
}
