import Foundation
import WebKit
import os

/// Serves `thuban://bundle/<path>` from the app bundle's `web/` folder reference so the WKWebView pages can load
/// ES modules, fonts and sounds without file:// restrictions. Anything outside `web/` (or a missing file) is a 404.
final class ThubanSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "thuban"
    static let host = "bundle"

    private static let logger = Logger(subsystem: "com.thuban.study", category: "scheme")

    /// Root of the bundled web resources (`Thuban Study.app/Contents/Resources/web`).
    static var webRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
    }

    /// `thuban://bundle/<path>` for a path under `web/`.
    static func url(forPage path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        lock.withLock { _ = activeTasks.insert(id) }
        guard let requestURL = urlSchemeTask.request.url else {
            finish(urlSchemeTask, id: id, status: 400, data: Data(), mime: "text/plain")
            return
        }
        guard requestURL.host == Self.host, let fileURL = Self.fileURL(for: requestURL) else {
            Self.logger.debug("404 \(requestURL.absoluteString, privacy: .public)")
            finish(urlSchemeTask, id: id, status: 404, data: Data("Not found".utf8), mime: "text/plain")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
            DispatchQueue.main.async {
                guard let data else {
                    self.finish(urlSchemeTask, id: id, status: 404, data: Data("Not found".utf8), mime: "text/plain")
                    return
                }
                self.finish(urlSchemeTask, id: id, status: 200, data: data, mime: Self.mimeType(for: fileURL))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.withLock { _ = activeTasks.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    // MARK: Internals

    private func finish(_ task: WKURLSchemeTask, id: ObjectIdentifier, status: Int, data: Data, mime: String) {
        // WebKit traps when a task is touched after `stop`, so only respond while it is still active.
        let stillActive = lock.withLock { activeTasks.remove(id) != nil }
        guard stillActive, let url = task.request.url else { return }
        var headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
        ]
        if mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") || mime.contains("svg") {
            headers["Content-Type"] = mime + "; charset=utf-8"
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }

    /// Resolves a request URL to a file under `web/`, rejecting traversal outside it.
    static func fileURL(for url: URL) -> URL? {
        guard let root = webRoot else { return nil }
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        guard !relative.isEmpty else { return nil }
        let components = relative.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs", "cjs": return "text/javascript"
        case "css": return "text/css"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "json", "map": return "application/json"
        case "txt", "md": return "text/plain"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
