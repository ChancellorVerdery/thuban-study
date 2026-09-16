import SwiftUI
import ThubanCore

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
    var label: String?
    var hidden: Bool = false
    var fromTutor: Bool = false
    var sliderBounds: SliderBounds?

    struct SliderBounds: Codable, Hashable, Sendable {
        var min: Double?
        var max: Double?
        var step: Double?
    }

    init(id: String, latex: String, color: String? = nil, dashed: Bool = false, label: String? = nil,
         hidden: Bool = false, fromTutor: Bool = false, sliderBounds: SliderBounds? = nil) {
        self.id = id
        self.latex = latex
        self.color = color
        self.dashed = dashed
        self.label = label
        self.hidden = hidden
        self.fromTutor = fromTutor
        self.sliderBounds = sliderBounds
    }

    /// The `{id, latex, color?, lineStyle?, label?, hidden?, sliderBounds?}` object graph.js expects.
    func desmosPayload(theme: ResolvedTheme) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "latex": .string(latex)]
        let resolvedColor = color ?? (fromTutor ? (dashed ? theme.accentDeep : theme.signal) : theme.accent)
        object["color"] = .string(resolvedColor)
        if dashed { object["lineStyle"] = .string("DASHED") }
        if let label, !label.isEmpty {
            object["label"] = .string(label)
            object["showLabel"] = .bool(true)
        }
        if hidden { object["hidden"] = .bool(true) }
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
        let bridge: WebBridge
        /// Theme used to resolve default expression colors; kept current by the view.
        var theme: ResolvedTheme = ThemeResolver.resolve(.default, systemIsDark: false)
        private(set) var mode: GraphMode = .twoD
        private(set) var desmosKey: String = ""
        /// Set by the page when the Desmos script fails or an operation errors.
        private(set) var lastError: String?
        private(set) var isPageReady = false

        /// Expression rows the student edited inside Desmos (debounced by the page): `[(id, latex)]`.
        var onExpressionsChanged: (([(id: String, latex: String)]) -> Void)?
        var onError: ((String) -> Void)?
        /// Reply to `getState`: the raw Desmos state object and the mode it belongs to.
        var onState: ((JSONValue, GraphMode) -> Void)?
        var onReady: (() -> Void)?

        init(desmosKey: String, mode: GraphMode = .twoD) {
            self.bridge = WebBridge(name: "graph")
            self.desmosKey = desmosKey
            self.mode = mode
            bridge.on("ready") { [weak self] _ in
                guard let self else { return }
                self.isPageReady = true
                self.onReady?()
            }
            bridge.on("expressionsChanged") { [weak self] payload in
                let rows = (payload["expressions"]?.arrayValue ?? []).compactMap { row -> (id: String, latex: String)? in
                    guard let id = row["id"]?.stringValue else { return nil }
                    return (id, row["latex"]?.stringValue ?? "")
                }
                self?.onExpressionsChanged?(rows)
            }
            bridge.on("error") { [weak self] payload in
                let message = payload["message"]?.stringValue ?? "Graph error"
                self?.lastError = message
                self?.onError?(message)
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
            bridge.send("config", .object(payload))
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
