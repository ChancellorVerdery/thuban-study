import AppKit
import SwiftUI
import ThubanCore

/// Pictures for answer options that are figures (`QuestionPart.choiceFigures`), as PNG data URLs for the answer
/// form's web page: the standardized redraw of an accepted chart in the current theme, else the original clipping.
@MainActor
enum ChoiceFigureImages {
    /// Rendered width in points (drawn at 2× for sharpness); the height follows the original's proportions.
    static let width: CGFloat = 280

    private static var cache: [String: String] = [:]

    static func dataURLs(for figures: [Figure], theme: ResolvedTheme, engine: MathEngine) async -> [FigureID: String] {
        var urls: [FigureID: String] = [:]
        for figure in figures {
            if let url = await dataURL(for: figure, theme: theme, engine: engine) { urls[figure.id] = url }
        }
        return urls
    }

    static func dataURL(for figure: Figure, theme: ResolvedTheme, engine: MathEngine) async -> String? {
        let standardized = figure.status == .accepted ? figure.chart : nil
        var hasher = Hasher()
        hasher.combine(figure.id)
        hasher.combine(standardized.flatMap { try? JSONEncoder().encode($0) })
        hasher.combine(theme.panelColor.description)
        hasher.combine(theme.inkColor.description)
        let key = String(hasher.finalize())
        if let cached = cache[key] { return cached }
        let png: Data?
        if let chart = standardized {
            png = await render(chart, aspect: FigureCache.aspect(figure.originalPath), theme: theme, engine: engine)
        } else {
            png = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath))
        }
        guard let png, !png.isEmpty else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        cache[key] = url
        return url
    }

    private static func render(_ chart: StandardChart, aspect: CGFloat, theme: ResolvedTheme, engine: MathEngine) async -> Data? {
        // Drawn near the size the answer form shows them (about 240 pt tall), so labels stay legible: a phase
        // line at a fixed height with its own narrow proportions, a graph at a fixed width.
        let size = chart.isPhaseLine
            ? CGSize(width: max(70, 300 * max(0.1, min(3, aspect))), height: 300)
            : CGSize(width: width, height: width / max(0.4, min(3, aspect)))
        let content: AnyView
        if let phase = chart.phaseLine, chart.isPhaseLine {
            content = AnyView(Canvas { context, canvas in
                PhaseLineRenderer(phase: phase, theme: theme).draw(in: &context, size: canvas)
            })
        } else {
            let scene = await FigureCache.scene(for: chart, engine: engine)
            content = AnyView(Canvas { context, canvas in
                FigureCanvasRenderer(scene: scene, theme: theme).draw(in: &context, size: canvas)
            })
        }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height).background(theme.panelColor))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
