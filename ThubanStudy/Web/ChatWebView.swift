import AppKit
import SwiftUI
import ThubanCore

/// Tutor transcript renderer (`web/chat/chat.html`): Markdown + LaTeX bubbles, streaming deltas, tool-event lines.
struct ChatWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "chat/chat.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        private(set) var isPageReady = false

        /// A link inside a message was clicked. Default behaviour (when nil): open it in the browser.
        var onLinkClicked: ((URL) -> Void)?
        var onReady: (() -> Void)?

        init() {
            bridge = WebBridge(name: "chat")
            bridge.on("ready") { [weak self] _ in
                self?.isPageReady = true
                self?.onReady?()
            }
            bridge.on("linkClicked") { [weak self] payload in
                let raw = payload["url"]?.stringValue ?? payload["href"]?.stringValue ?? ""
                guard let url = URL(string: raw) else { return }
                if let handler = self?.onLinkClicked { handler(url) } else { NSWorkspace.shared.open(url) }
            }
        }

        // MARK: Swift → JS

        /// Replaces the transcript. `streamingId` marks the message still being streamed (caret shown).
        func setTranscript(_ messages: [TutorMessage], streamingId: MessageID? = nil) {
            bridge.send("setTranscript", ["messages": .array(messages.map { Self.payload(for: $0, streaming: $0.id == streamingId) })])
        }

        /// Appends (or replaces, by id) one message.
        func appendMessage(_ message: TutorMessage, streaming: Bool = false) {
            bridge.send("appendMessage", ["message": Self.payload(for: message, streaming: streaming)])
        }

        /// Appends streamed text to a message; an unknown id starts a new streaming tutor bubble.
        func appendDelta(id: MessageID, text: String) {
            bridge.send("appendDelta", ["id": .string(id.raw), "text": .string(text), "role": "tutor"])
        }

        /// Ends streaming for a message; `markdown` optionally replaces the accumulated text with the final version.
        func finish(id: MessageID, markdown: String? = nil) {
            var payload: [String: JSONValue] = ["id": .string(id.raw)]
            if let markdown { payload["markdown"] = .string(markdown) }
            bridge.send("finish", .object(payload))
        }

        func clear() {
            bridge.send("clear")
        }

        /// `{id, role, markdown, toolEvents:[{name, summary}], streaming}` as chat.js expects.
        static func payload(for message: TutorMessage, streaming: Bool) -> JSONValue {
            .object([
                "id": .string(message.id.raw),
                "role": .string(message.role.rawValue),
                "markdown": .string(message.content),
                "toolEvents": .array(message.toolEvents.map { event in
                    .object(["id": .string(event.id), "name": .string(event.name), "summary": .string(event.summary), "kind": .string(Self.kind(for: event.name))])
                }),
                "streaming": .bool(streaming),
                "solutionRequested": .bool(message.solutionRequested),
            ])
        }

        private static func kind(for toolName: String) -> String {
            if toolName.hasPrefix("graph") || toolName == TutorTools.showGraph || toolName == TutorTools.hideGraph { return "graph" }
            if toolName == TutorTools.showCalculator { return "calculator" }
            return "tool"
        }
    }
}
