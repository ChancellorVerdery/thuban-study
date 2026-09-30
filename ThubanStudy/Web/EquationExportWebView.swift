import AppKit
import SwiftUI
import ThubanCore
import UniformTypeIdentifiers
import WebKit

/// The equation sheet export workbench (`web/equations/export.html`, ported from Atlas's print sheet): choose what to
/// include, the paper and the fit, preview the sheets, then export a PDF or print. The page lays the sheets out at
/// paper size; Swift runs the PDF export or the print dialog with the matching paper.
struct EquationExportWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "equations/export.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge = WebBridge(name: "equations-export")
        /// Settings and selection to keep (per class).
        var onSave: ((JSONValue) -> Void)?
        var onDone: (() -> Void)?
        /// Where the last PDF went (for the harness and the "Show in Finder" note).
        private(set) var lastPDF: URL?
        /// Set by the smoke harness: export straight to this file, no save panel.
        @ObservationIgnored var pdfDestinationOverride: URL?
        @ObservationIgnored private var runner: PrintRunner?

        init() {
            bridge.on("save") { [weak self] payload in self?.onSave?(payload) }
            bridge.on("done") { [weak self] _ in self?.onDone?() }
            bridge.on("output") { [weak self] payload in
                guard let self else { return }
                self.output(
                    pdf: payload["mode"]?.stringValue == "pdf",
                    widthIn: payload["widthIn"]?.doubleValue ?? 8.5,
                    heightIn: payload["heightIn"]?.doubleValue ?? 11,
                    fileName: payload["fileName"]?.stringValue ?? "Equation sheet.pdf"
                )
            }
        }

        func load(className: String, sheet: EquationSheet, saved: JSONValue?) {
            bridge.sendSticky("load", [
                "className": .string(className),
                "groups": EquationSheetWebView.Controller.payload(sheet, mode: .sheet, collapsed: [], emptyMessage: "")["groups"] ?? .array([]),
                "saved": saved ?? .null,
            ])
        }

        /// Asks the page for a PDF of the current sheets (the harness; the page answers with `output`).
        func requestPDF() {
            bridge.send("exportPDF")
        }

        // MARK: Output

        private func output(pdf: Bool, widthIn: Double, heightIn: Double, fileName: String) {
            guard let webView = bridge.webView, let window = webView.window else { finish(nil); return }
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            info.orientation = widthIn > heightIn ? .landscape : .portrait
            info.paperSize = NSSize(width: widthIn * 72, height: heightIn * 72)
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.horizontalPagination = .automatic
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            if pdf {
                if let url = pdfDestinationOverride {
                    run(info: info, saveTo: url, in: webView, window: window)
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = fileName
                panel.canCreateDirectories = true
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    guard response == .OK, let url = panel.url else { self.finish(nil); return }
                    self.run(info: info, saveTo: url, in: webView, window: window)
                }
            } else {
                run(info: info, saveTo: nil, in: webView, window: window)
            }
        }

        private func run(info: NSPrintInfo, saveTo url: URL?, in webView: WKWebView, window: NSWindow) {
            if let url {
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            }
            let operation = webView.printOperation(with: info)
            operation.showsPrintPanel = url == nil
            operation.showsProgressPanel = url == nil
            operation.jobTitle = url?.deletingPathExtension().lastPathComponent ?? "Equation sheet"
            // WKWebView prints blank unless the operation's view has a frame.
            operation.view?.frame = webView.bounds
            let runner = PrintRunner { [weak self] success in
                self?.runner = nil
                self?.finish(success ? url : nil, printed: url == nil && success)
            }
            self.runner = runner
            operation.runModal(for: window, delegate: runner, didRun: #selector(PrintRunner.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }

        private func finish(_ savedTo: URL?, printed: Bool = false) {
            if let savedTo { lastPDF = savedTo }
            var message = ""
            if let savedTo { message = "Saved “\(savedTo.lastPathComponent)”" } else if printed { message = "Sent to the printer" }
            bridge.send("afterOutput", ["message": .string(message)])
        }
    }
}

/// Receives the print operation's completion (AppKit calls back through a selector).
final class PrintRunner: NSObject {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(success)
    }
}

/// The workbench as a sheet over the Equations section, as large as the window allows.
struct EquationExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession
    private var controller: EquationExportWebView.Controller { session.equations.exportPage }

    private var size: CGSize {
        let window = NSApp.mainWindow?.contentLayoutRect.size ?? CGSize(width: 1280, height: 820)
        return CGSize(width: max(980, window.width - 60), height: max(640, window.height - 50))
    }

    var body: some View {
        EquationExportWebView(controller: controller)
            .frame(width: size.width, height: size.height)
            .background(theme.bgColor)
            .task { await load() }
    }

    private func load() async {
        let session = session
        controller.onDone = { dismiss() }
        controller.onSave = { value in Task { await session.saveEquationExportChoices(value) } }
        if let destination = ProcessInfo.processInfo.environment["THUBAN_SMOKE_EXPORT_PDF"], !destination.isEmpty {
            controller.pdfDestinationOverride = URL(fileURLWithPath: destination)
        }
        controller.load(
            className: session.studyClass?.name ?? "",
            sheet: session.equations.sheet,
            saved: await session.equationExportChoices()
        )
    }
}
