import AppKit
import SwiftUI
import WebKit
import ThubanCore
import os

/// A web view that can hand the scroll wheel to the scroll view it sits in. WebKit keeps wheel events even when
/// the page has nothing to scroll, so a page sized to its content inside a SwiftUI `ScrollView` would otherwise
/// never let that view scroll.
final class PaneWebView: WKWebView {
    var scrollsWithParent = false

    override func scrollWheel(with event: NSEvent) {
        if scrollsWithParent, let parent = enclosingScrollView {
            parent.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Hosts one bundled page (`thuban://bundle/<page>`) in a transparent WKWebView wired to a `WebBridge`.
/// Navigation stays inside `thuban://` and Desmos; any other link opens in the default browser.
struct BridgeWebView: NSViewRepresentable {
    /// Path under `Resources/web`, e.g. "question/question.html".
    var page: String
    var bridge: WebBridge
    var theme: ResolvedTheme
    /// The page is laid out at its full height inside a native scroll view: the scroll wheel scrolls that view
    /// instead of the (unscrollable) page.
    var scrollsWithParent = false

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(context: Context) -> PaneWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ThubanSchemeHandler(), forURLScheme: ThubanSchemeHandler.scheme)
        configuration.userContentController.add(bridge, name: WebBridge.messageHandlerName)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = PaneWebView(frame: .zero, configuration: configuration)
        webView.scrollsWithParent = scrollsWithParent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.pageZoom = AppZoom.shared.scale
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif

        bridge.attach(webView)
        bridge.setTheme(theme)
        context.coordinator.lastTheme = theme
        context.coordinator.load(page: page, in: webView)
        return webView
    }

    func updateNSView(_ webView: PaneWebView, context: Context) {
        webView.scrollsWithParent = scrollsWithParent
        // The page follows the app zoom (⌘+ / ⌘−); reading it here re-runs this update when it changes.
        let zoom = AppZoom.shared.scale
        if context.coordinator.lastZoom != zoom {
            context.coordinator.lastZoom = zoom
            webView.pageZoom = zoom
        }
        if context.coordinator.lastTheme != theme {
            context.coordinator.lastTheme = theme
            bridge.setTheme(theme)
        }
        if context.coordinator.loadedPage != page {
            context.coordinator.load(page: page, in: webView)
        }
    }

    static func dismantleNSView(_ webView: PaneWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebBridge.messageHandlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    // MARK: Coordinator

    /// Not actor-isolated: WebKit's delegate callbacks are nonisolated. Only `load` touches the bridge, on the main actor.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private static let logger = Logger(subsystem: "com.thuban.study", category: "webview")
        let bridge: WebBridge
        var lastTheme: ResolvedTheme?
        var lastZoom: CGFloat?
        var loadedPage: String?

        init(bridge: WebBridge) {
            self.bridge = bridge
        }

        @MainActor
        func load(page: String, in webView: WKWebView) {
            loadedPage = page
            guard let url = ThubanSchemeHandler.url(forPage: page) else { return }
            bridge.pageWillLoad()
            webView.load(URLRequest(url: url))
        }

        /// Hosts the page may navigate to (frames included): our bundle and Desmos.
        static func isAllowed(_ url: URL) -> Bool {
            if url.scheme == ThubanSchemeHandler.scheme { return true }
            if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return true }
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "desmos.com" || host.hasSuffix(".desmos.com")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if Self.isAllowed(url) {
                decisionHandler(.allow)
                return
            }
            // External link: hand it to the system browser and keep the page where it is.
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Self.logger.error("navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Self.logger.error("provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // target=_blank links: open externally instead of spawning a window.
            if let url = navigationAction.request.url, !Self.isAllowed(url) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return nil
        }
    }
}
