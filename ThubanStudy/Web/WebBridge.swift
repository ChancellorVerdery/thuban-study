import Foundation
import WebKit
import ThubanCore
import os

/// Swift ⇄ JS message plumbing for one hosted page. JS posts `{type, payload}` to `webkit.messageHandlers.thuban`;
/// Swift calls `window.thuban.receive(type, payloadJSON)`. Sends are queued until the page posts `ready`, and the
/// resolved theme is pushed on `ready` and whenever `setTheme` changes it.
@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "thuban"
    private static let logger = Logger(subsystem: "com.thuban.study", category: "bridge")

    /// Debug label ("graph", "question", …) for logs.
    let name: String

    private(set) weak var webView: WKWebView?
    private(set) var isReady = false
    private var handlers: [String: [(JSONValue) -> Void]] = [:]
    private var queue: [(type: String, payload: JSONValue)] = []
    /// Messages re-sent on every `ready` (one per type), e.g. a page's `config`: the hosting view may be
    /// re-created (pane toggled, section switched), which reloads the page and would otherwise lose them.
    private var sticky: [(type: String, payload: JSONValue)] = []
    private var theme: ResolvedTheme?

    init(name: String = "page") {
        self.name = name
        super.init()
    }

    // MARK: Wiring

    /// Called by `BridgeWebView` once the web view exists.
    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Called when the page (re)loads: sends are queued again until the next `ready`.
    func pageWillLoad() {
        isReady = false
    }

    // MARK: Handlers (JS → Swift)

    /// Registers a handler for a message type. Several handlers per type are allowed; they run in registration order.
    func on(_ type: String, _ handler: @escaping (JSONValue) -> Void) {
        handlers[type, default: []].append(handler)
    }

    /// Replaces every handler for a type.
    func set(_ type: String, _ handler: ((JSONValue) -> Void)?) {
        if let handler { handlers[type] = [handler] } else { handlers[type] = nil }
    }

    func removeHandlers(for type: String) {
        handlers[type] = nil
    }

    // MARK: Sending (Swift → JS)

    /// Sends a message to the page, queueing it until the page is ready.
    func send(_ type: String, _ payload: JSONValue = .object([:])) {
        guard isReady, let webView else {
            queue.append((type, payload))
            return
        }
        evaluate(type: type, payload: payload, on: webView)
    }

    /// Sends an `Encodable` payload.
    func send<T: Encodable>(_ type: String, encodable payload: T) {
        send(type, Self.jsonValue(payload))
    }

    /// Sends a message now (if ready) and again after every future page load, replacing any earlier sticky
    /// message of the same type. Sticky messages go out before the regular queue on `ready`.
    func sendSticky(_ type: String, _ payload: JSONValue = .object([:])) {
        sticky.removeAll { $0.type == type }
        sticky.append((type, payload))
        guard isReady, let webView else { return }
        evaluate(type: type, payload: payload, on: webView)
    }

    /// Pushes the theme css now (if ready) and remembers it for the next `ready`.
    func setTheme(_ theme: ResolvedTheme) {
        self.theme = theme
        guard isReady, let webView else { return }
        evaluate(type: "theme", payload: Self.themePayload(theme), on: webView)
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers on the main thread; assert that rather than assume it.
        MainActor.assumeIsolated {
            let body = message.body
            guard let dict = body as? [String: Any], let type = dict["type"] as? String else {
                Self.logger.error("[\(self.name, privacy: .public)] malformed message: \(String(describing: body), privacy: .public)")
                return
            }
            let payload = dict["payload"].flatMap { JSONValue(any: $0) } ?? .object([:])
            self.dispatch(type: type, payload: payload)
        }
    }

    private func dispatch(type: String, payload: JSONValue) {
        if type == "ready" {
            isReady = true
            if let webView {
                if let theme { evaluate(type: "theme", payload: Self.themePayload(theme), on: webView) }
                for item in sticky { evaluate(type: item.type, payload: item.payload, on: webView) }
                let pending = queue
                queue.removeAll()
                for item in pending { evaluate(type: item.type, payload: item.payload, on: webView) }
            }
        }
        guard let list = handlers[type], !list.isEmpty else {
            if type != "ready" {
                Self.logger.debug("[\(self.name, privacy: .public)] unhandled message '\(type, privacy: .public)'")
            }
            return
        }
        for handler in list { handler(payload) }
    }

    // MARK: JS

    private func evaluate(type: String, payload: JSONValue, on webView: WKWebView) {
        let js = "window.thuban && window.thuban.receive(\(Self.jsLiteral(type)), \(Self.jsLiteral(payload.jsonString())));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                Self.logger.error("[\(self.name, privacy: .public)] receive('\(type, privacy: .public)') failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A JS string literal for `string` (JSON string encoding is a valid JS literal; U+2028/2029 are escaped too).
    static func jsLiteral(_ string: String) -> String {
        let data = (try? JSONEncoder().encode([string])) ?? Data("[\"\"]".utf8)
        var literal = String(decoding: data, as: UTF8.self)
        literal.removeFirst()
        literal.removeLast()
        return literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func themePayload(_ theme: ResolvedTheme) -> JSONValue {
        .object(["css": .string(theme.cssVariables), "isDark": .bool(theme.isDark)])
    }

    /// Encodes any `Encodable` into a `JSONValue` (dates as ISO 8601).
    static func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let json = try? JSONValue(data: data) else { return .null }
        return json
    }
}
