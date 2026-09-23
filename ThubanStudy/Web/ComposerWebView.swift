import SwiftUI
import ThubanCore

/// The tutor composer (`web/composer/composer.html`): text with inline, rendered math fields. The message it
/// produces is plain text with each formula as `$…$` LaTeX.
struct ComposerWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "composer/composer.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        /// The editor's content height reported by the page (CSS pixels).
        private(set) var contentHeight: CGFloat = 38
        var isPageReady: Bool { bridge.isPageReady }

        var onInput: ((String) -> Void)?
        var onSubmit: ((String) -> Void)?
        var onReady: (() -> Void)?

        init() {
            bridge = WebBridge(name: "composer")
            bridge.on("ready") { [weak self] _ in self?.onReady?() }
            bridge.on("input") { [weak self] payload in self?.onInput?(payload["text"]?.stringValue ?? "") }
            bridge.on("submit") { [weak self] payload in self?.onSubmit?(payload["text"]?.stringValue ?? "") }
            bridge.on("height") { [weak self] payload in
                guard let self, let px = payload["px"]?.doubleValue else { return }
                self.contentHeight = CGFloat(px)
            }
        }

        func clear() { bridge.send("clear", [:]) }
        func setText(_ text: String) { bridge.send("setText", ["text": .string(text)]) }
        func focus() { bridge.send("focus", [:]) }
        func insertMath(_ latex: String = "") { bridge.send("insertMath", ["latex": .string(latex)]) }
    }
}
