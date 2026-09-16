import SwiftUI
import ThubanCore

/// The MathLive answer form (`web/question/question.html`): renders the stem and one input per part, reports
/// typed input (debounced), submit (Enter / ⌘⏎) and its content height.
struct QuestionFormWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "question/question.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        private(set) var isPageReady = false
        /// Content height reported by the page, for a scroll view that hugs the form.
        private(set) var contentHeight: CGFloat = 0
        private(set) var isKeyboardVisible = false

        /// Debounced (150 ms) input in a part: LaTeX plus an ASCII-math echo.
        var onInput: ((_ partId: String, _ latex: String, _ ascii: String) -> Void)?
        /// Enter on the last field or ⌘⏎ inside the form.
        var onSubmit: (() -> Void)?
        var onHeight: ((CGFloat) -> Void)?
        var onKeyboardVisible: ((Bool) -> Void)?
        var onReady: (() -> Void)?

        init() {
            bridge = WebBridge(name: "question")
            bridge.on("ready") { [weak self] _ in
                self?.isPageReady = true
                self?.onReady?()
            }
            bridge.on("input") { [weak self] payload in
                guard let partId = payload["partId"]?.stringValue else { return }
                self?.onInput?(partId, payload["latex"]?.stringValue ?? "", payload["ascii"]?.stringValue ?? "")
            }
            bridge.on("submit") { [weak self] _ in self?.onSubmit?() }
            bridge.on("height") { [weak self] payload in
                guard let self, let px = payload["px"]?.doubleValue else { return }
                self.contentHeight = CGFloat(px)
                self.onHeight?(CGFloat(px))
            }
            bridge.on("keyboardVisible") { [weak self] payload in
                guard let self else { return }
                let visible = payload["visible"]?.boolValue ?? false
                self.isKeyboardVisible = visible
                self.onKeyboardVisible?(visible)
            }
        }

        // MARK: Swift → JS

        /// Renders an instance. `inputs` / `verdicts` restore what the student already typed / was told.
        func load(instance: QuestionInstance, inputs: [String: String] = [:], verdicts: [String: Verdict] = [:]) {
            bridge.send("load", ["instance": Self.instanceView(instance, inputs: inputs, verdicts: verdicts)])
        }

        /// Shows verdict badges for the given parts.
        func setVerdicts(_ verdicts: [String: Verdict]) {
            bridge.send("setVerdicts", ["verdicts": .object(verdicts.mapValues { WebBridge.jsonValue($0) })])
        }

        func focus(partId: String) {
            bridge.send("focusPart", ["partId": .string(partId)])
        }

        /// Inserts LaTeX at the caret of the focused math field (calculator "copy to answer").
        func insert(latex: String) {
            bridge.send("insert", ["latex": .string(latex)])
        }

        func setKeyboardVisible(_ visible: Bool) {
            isKeyboardVisible = visible
            bridge.send("setKeyboardVisible", ["visible": .bool(visible)])
        }

        /// `{stem, seed, parts:[{id, prompt, answerKind, choices?, conditionsText, value?, verdict?}]}` — never the answers.
        static func instanceView(_ instance: QuestionInstance, inputs: [String: String], verdicts: [String: Verdict]) -> JSONValue {
            .object([
                "questionId": .string(instance.questionId.raw),
                "seed": .string(instance.seed),
                "stem": .string(instance.stem),
                "parts": .array(instance.parts.map { part in
                    var object: [String: JSONValue] = [
                        "id": .string(part.id),
                        "prompt": .string(part.prompt),
                        "answerKind": .string(part.answerKind.rawValue),
                        "conditionsText": .string(part.answerKind == .freeResponse ? "" : part.conditions.summary),
                    ]
                    if let choices = part.choices { object["choices"] = .array(choices.map { .string($0) }) }
                    if let value = inputs[part.id] { object["value"] = .string(value) }
                    if let verdict = verdicts[part.id] { object["verdict"] = WebBridge.jsonValue(verdict) }
                    return .object(object)
                }),
            ])
        }
    }
}
