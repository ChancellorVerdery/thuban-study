import AppKit
import SwiftUI
import ThubanCore

/// A chart drawn the way the app shows it, as a PNG the size of its original (the reviewer compares the two).
enum FigureRedrawImage {
    @MainActor
    static func png(chart: StandardChart, original: Data, engine: MathEngine, theme: ResolvedTheme) async -> Data? {
        let scene = await FigureScene.build(chart, engine: engine)
        var panels: [FigureScene] = []
        for panel in chart.panels ?? [] where chart.hasPanels { panels.append(await FigureScene.build(panel, engine: engine)) }
        let aspect: CGFloat = {
            guard let image = NSImage(data: original), image.size.height > 0 else { return 1 }
            return max(0.4, min(3, image.size.width / image.size.height))
        }()
        let height: CGFloat = 360, width = height * aspect
        let view = RedrawCanvas(scene: scene, panels: panels, phase: chart.phaseLine, theme: theme)
            .frame(width: width, height: height)
            .background(Color(hex: theme.panel))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// The redraw alone: a phase line, panels side by side, or one chart.
private struct RedrawCanvas: View {
    var scene: FigureScene
    var panels: [FigureScene]
    var phase: PhaseLine?
    var theme: ResolvedTheme

    var body: some View {
        Canvas { context, size in
            if let phase {
                PhaseLineRenderer(phase: phase, theme: theme).draw(in: &context, size: size)
            } else if !panels.isEmpty {
                let w = size.width / CGFloat(panels.count)
                for (k, panel) in panels.enumerated() {
                    var sub = context
                    sub.translateBy(x: w * CGFloat(k), y: 0)
                    FigureCanvasRenderer(scene: panel, theme: theme).draw(in: &sub, size: CGSize(width: w - 6, height: size.height))
                }
            } else {
                FigureCanvasRenderer(scene: scene, theme: theme).draw(in: &context, size: size)
            }
        }
    }
}

/// `THUBAN_SELFREVIEW_CLASS=<class name>` at launch: every figure of that class is drawn, shown to the reviewer
/// beside its original and corrected until the reviewer confirms it (`FigureWorkflow.selfReview`), with the app's
/// own Claude connection. `THUBAN_SELFREVIEW_ONLY=doc:<prefix>` limits it to one document,
/// `THUBAN_SELFREVIEW_FORCE=1` reviews confirmed figures again, and `THUBAN_SELFREVIEW_REPORT=<file>` receives a line
/// per figure and a final "DONE".
@MainActor
enum FigureSelfReviewLaunch {
    static func startIfEnabled(app: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["THUBAN_SELFREVIEW_CLASS"], !name.isEmpty else { return }
        let reportPath = env["THUBAN_SELFREVIEW_REPORT"]
        let only = env["THUBAN_SELFREVIEW_ONLY"] ?? ""
        let force = env["THUBAN_SELFREVIEW_FORCE"] == "1"
        let store = app.store, engine = app.engine, theme = app.theme
        let reviewer = FigureReviewer(client: app.claudeClient, model: .opus)
        let render: @Sendable (StandardChart, Data) async -> Data? = { chart, original in
            await FigureRedrawImage.png(chart: chart, original: original, engine: engine, theme: theme)
        }
        Task.detached(priority: .utility) {
            let lines = LineLog(path: reportPath)
            do {
                for studyClass in try await store.allClasses() where studyClass.name == name {
                    for document in try await store.documents(in: studyClass.id) {
                        if only.hasPrefix("doc:"), !document.filename.hasPrefix(String(only.dropFirst(4))) { continue }
                        lines.append("DOC \(document.filename)")
                        _ = try await FigureWorkflow.selfReview(
                            document: document, store: store, reviewer: reviewer, engine: engine, render: render, force: force,
                            // fig:<id prefix>: that one figure only.
                            only: only.hasPrefix("fig:") ? { $0.id.raw.hasPrefix(String(only.dropFirst(4))) } : nil,
                            report: { figure, result, problems in
                                lines.append("#\(figure.pageOrIndex + 1) \(figure.id.raw.prefix(8)) \(result.rawValue)"
                                             + (problems.isEmpty ? "" : " | " + problems.joined(separator: " / ").prefix(1500)))
                            })
                    }
                }
                lines.append("DONE")
            } catch {
                lines.append("ERROR \(error.localizedDescription)")
            }
        }
    }
}

/// Report lines written to a file as they come.
private final class LineLog: @unchecked Sendable {
    private let path: String?
    private var lines: [String] = []
    private let lock = NSLock()

    init(path: String?) { self.path = path }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if let path { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
