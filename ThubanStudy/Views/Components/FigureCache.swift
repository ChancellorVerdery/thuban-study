import AppKit
import ThubanCore

/// Figure images and built scenes, kept so a figure view redraws without reading its PNG again or re-running
/// the math: the review page and the study pane re-evaluate their bodies often (every resize, every hover).
@MainActor
enum FigureCache {
    private static var images: [String: NSImage] = [:]
    private static var scenes: [Data: FigureScene] = [:]
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// The original PNG of a figure (nil when the file is missing).
    static func image(_ originalPath: String) -> NSImage? {
        if let cached = images[originalPath] { return cached }
        guard let image = NSImage(contentsOf: AppPaths.figureURL(originalPath)) else { return nil }
        if images.count > 300 { images.removeAll() }
        images[originalPath] = image
        return image
    }

    /// Width ÷ height of a figure's original (1 when unknown), bounded to sensible proportions.
    static func aspect(_ originalPath: String) -> CGFloat {
        guard let image = image(originalPath), image.size.height > 0 else { return 1 }
        return max(0.4, min(3, image.size.width / image.size.height))
    }

    /// The scene for a chart, built once per distinct chart.
    static func scene(for chart: StandardChart, engine: MathEngine) async -> FigureScene {
        let key = (try? encoder.encode(chart)) ?? Data()
        if let cached = scenes[key] { return cached }
        let built = await FigureScene.build(chart, engine: engine)
        if scenes.count > 200 { scenes.removeAll() }
        scenes[key] = built
        return built
    }

    /// The scene already built for a chart, if any (drawn on the first frame instead of a spinner).
    static func cachedScene(for chart: StandardChart) -> FigureScene? {
        guard let key = try? encoder.encode(chart) else { return nil }
        return scenes[key]
    }
}
