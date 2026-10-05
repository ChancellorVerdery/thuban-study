import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ThubanCore

/// Development harness: recognises the family of one picture's curves (`FAMILY_REPORT_PNG`) from the picture alone
/// and, when its stored chart is given (`FAMILY_REPORT_CHART`), through the full check; prints each one's family,
/// levels, window and verdict. With `FAMILY_REPORT_OUT` (a path prefix) set, each redraw is stamped in red over the
/// picture there; with `FAMILY_REPORT_F` and `FAMILY_REPORT_SCALE`, that family's level fit at that scale is printed
/// too. Skipped unless the picture is set.
final class FamilyReportTests: XCTestCase {
    func testReportFamily() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pngPath = env["FAMILY_REPORT_PNG"] else { throw XCTSkip("set FAMILY_REPORT_PNG") }
        let png = try Data(contentsOf: URL(fileURLWithPath: pngPath))
        let engine = MathEngine()
        if let picture = await ShapeVerifier.Picture(png: png, hints: StandardChart(chartType: "function", provenance: StandardChart.traced)) {
            let samples = FamilyRecognizer.levelSamples(picture)
            print("FAMILY REPORT \(picture.curves.count) runs, \(samples.curves.count) strands, \(samples.axes.count) drawn axes")
            // FAMILY_REPORT_F at FAMILY_REPORT_SCALE: the level fit of that family at that scale.
            if let f = env["FAMILY_REPORT_F"], let scale = env["FAMILY_REPORT_SCALE"].flatMap(Double.init) {
                let maps = FamilyRecognizer.axisMaps(picture)
                let all = (samples.curves + samples.axes).flatMap { $0 }.map { [maps.x.value(Double($0.0)) * scale, maps.y.value(Double($0.1)) * scale] }
                if let values = try await engine.values(of: [f], variables: ["x", "y"], at: all).first ?? nil,
                   let fit = ShapeFitter.levelFit(values, sizes: samples.curves.map(\.count), axes: samples.axes.map(\.count)) {
                    print("FAMILY REPORT fit dispersion \(fit.dispersion) levels \(fit.levels)")
                }
            }
        }
        let recognised = await FamilyRecognizer.recognise(png: png, engine: engine)
        try await report("recognise", recognised, png: png, engine: engine)
        if let stored = env["FAMILY_REPORT_CHART"].flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) })
            .flatMap({ try? JSONDecoder().decode(StandardChart.self, from: $0) }) {
            try await report("check", await FigureAgent.check(stored, png: png, engine: engine), png: png, engine: engine)
        }
    }

    private func report(_ label: String, _ chart: StandardChart?, png: Data, engine: MathEngine) async throws {
        guard let chart else { print("FAMILY REPORT \(label) none"); return }
        for series in chart.series {
            print("FAMILY REPORT \(label) series \(series.kind ?? "curve") \(series.latex ?? series.name) levels \(series.levels ?? [])")
        }
        print("FAMILY REPORT \(label) window \(chart.xRange ?? []) \(chart.yRange ?? [])")
        print("FAMILY REPORT \(label) verdict \(chart.verification?.summary ?? "-")")
        guard let out = ProcessInfo.processInfo.environment["FAMILY_REPORT_OUT"], let image = ImageCodec.image(from: png),
              let picture = await ShapeVerifier.Picture(png: png, hints: chart),
              let x = chart.xRange, let y = chart.yRange, x.count == 2, y.count == 2 else { return }
        let scene = await FigureScene.build(chart, engine: engine)
        let context = try XCTUnwrap(ImageCodec.rgbaContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 0.8)
        context.setLineWidth(1.5)
        func point(_ p: [Double]) -> CGPoint {
            let c = Double(picture.columns.lowerBound) + (p[0] - x[0]) / (x[1] - x[0]) * Double(picture.columns.count)
            let r = Double(picture.rows.lowerBound) + (y[1] - p[1]) / (y[1] - y[0]) * Double(picture.rows.count)
            return CGPoint(x: c, y: Double(image.height) - r)
        }
        for mark in scene.marks where mark.kind == .line {
            for piece in mark.pieces where piece.count >= 2 {
                context.move(to: point(piece[0]))
                for p in piece.dropFirst() { context.addLine(to: point(p)) }
                context.strokePath()
            }
        }
        let drawn = try XCTUnwrap(context.makeImage())
        let url = URL(fileURLWithPath: "\(out)-\(label).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, drawn, nil)
        CGImageDestinationFinalize(destination)
    }
}
