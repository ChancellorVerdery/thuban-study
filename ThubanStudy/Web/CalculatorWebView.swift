import SwiftUI
import ThubanCore

/// Desmos scientific calculator with a MathLive fallback (`web/calc/calc.html`). The fallback asks Swift to
/// evaluate LaTeX (`onEvaluate`) and expects `sendResult` back; "copy to answer" arrives via `onCopyToAnswer`.
struct CalculatorWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "calc/calc.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        private(set) var isPageReady = false
        private(set) var lastError: String?

        /// The fallback calculator wants `latex` evaluated; answer with `sendResult(id:latex:)` or `sendResult(id:error:)`.
        var onEvaluate: ((_ id: String, _ latex: String) -> Void)?
        /// The student pressed "copy to answer".
        var onCopyToAnswer: ((String) -> Void)?
        var onError: ((String) -> Void)?
        var onReady: (() -> Void)?

        /// - Parameter forceFallback: skip Desmos and show the MathLive calculator (tests / no key).
        init(desmosKey: String, forceFallback: Bool = false) {
            bridge = WebBridge(name: "calc")
            bridge.on("ready") { [weak self] _ in
                self?.isPageReady = true
                self?.onReady?()
            }
            bridge.on("evaluate") { [weak self] payload in
                guard let latex = payload["latex"]?.stringValue else { return }
                let id = payload["id"]?.stringValue ?? (payload["id"]?.doubleValue).map { String(Int($0)) } ?? ""
                self?.onEvaluate?(id, latex)
            }
            bridge.on("copyToAnswer") { [weak self] payload in
                guard let latex = payload["latex"]?.stringValue else { return }
                self?.onCopyToAnswer?(latex)
            }
            bridge.on("error") { [weak self] payload in
                let message = payload["message"]?.stringValue ?? "Calculator error"
                self?.lastError = message
                self?.onError?(message)
            }
            configure(desmosKey: desmosKey, forceFallback: forceFallback)
        }

        func configure(desmosKey: String, forceFallback: Bool = false) {
            var payload: [String: JSONValue] = ["desmosKey": .string(desmosKey)]
            if forceFallback { payload["forceFallback"] = .bool(true) }
            bridge.send("config", .object(payload))
        }

        /// Delivers an evaluation result to the fallback calculator.
        func sendResult(id: String, latex: String) {
            bridge.send("result", ["id": .string(id), "latex": .string(latex)])
        }

        func sendResult(id: String, error: String) {
            bridge.send("result", ["id": .string(id), "error": .string(error)])
        }
    }
}
