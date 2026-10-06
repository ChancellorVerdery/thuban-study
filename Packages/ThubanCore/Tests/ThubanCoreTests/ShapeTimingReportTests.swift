import XCTest
@testable import ThubanCore

/// Development harness: times each step of the picture check on one stored chart
/// (`SHAPE_TIMING_CHART` = its JSON, `SHAPE_TIMING_PNG` = its picture). Skipped unless both are set.
final class ShapeTimingReportTests: XCTestCase {
    func testTimeTheCheck() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let chartPath = env["SHAPE_TIMING_CHART"], let pngPath = env["SHAPE_TIMING_PNG"] else { throw XCTSkip("set SHAPE_TIMING_CHART and SHAPE_TIMING_PNG") }
        let chart = try JSONDecoder().decode(StandardChart.self, from: Data(contentsOf: URL(fileURLWithPath: chartPath)))
        let png = try Data(contentsOf: URL(fileURLWithPath: pngPath))
        let engine = MathEngine()
        func time<T>(_ label: String, _ work: () async -> T) async -> T {
            let start = Date()
            let value = await work()
            print(String(format: "TIMING %@ %.3fs", label, Date().timeIntervalSince(start)))
            return value
        }
        _ = await time("graphReader") { await GraphReader.read(png: png, hints: chart) }
        let picture = await time("picture") { await ShapeVerifier.Picture(png: png, hints: chart) }
        print("TIMING curves \(picture?.curves.count ?? -1)")
        _ = await time("monochrome") { PictureInk.isMonochrome(png: png) }
        _ = await time("shaded") { PictureInk.shadedShare(png: png) }
        let scene = await time("scene") { await FigureScene.build(chart, engine: engine) }
        if let picture {
            _ = await time("verify") { ShapeVerifier.verify(scene: scene, picture: picture) }
            _ = await time("fit") { await ShapeFitter.fit(chart, picture: picture, engine: engine) }
            _ = await time("recognise") { await FamilyRecognizer.recognise(chart, picture: picture, engine: engine) }
        }
        if let picture {
            let markers = MarkerReader.read(scene: scene, picture: picture)
            print("TIMING markers arrows \(markers.arrows.mapValues { $0.map { $0.map { ($0 * 100).rounded() / 100 } } }) dots \(markers.dots.map { $0.map { ($0 * 100).rounded() / 100 } })")
        }
        let checked = await time("check") { await FigureAgent.check(chart, png: png, engine: engine) }
        print("TIMING verdict \(checked.verification?.summary ?? "-")")
        print("TIMING param \(checked.series.filter { $0.seriesKind == .parametric }.map { "\($0.xt ?? ""),\($0.yt ?? "") t0=\($0.markAt ?? .nan)" })")
        print("TIMING marks \(checked.series.filter { $0.seriesKind == .vector || $0.seriesKind == .point }.map { "\($0.kind ?? ""):\($0.points ?? [])\($0.labels.map { " \($0)" } ?? "")\($0.label.map { " '\($0)'" } ?? "")" }) notes \(checked.annotations?.map(\.text) ?? [])")
        print("TIMING window \(checked.xRange ?? []) \(checked.yRange ?? []) series \(checked.series.map { "\($0.kind ?? "curve"):\($0.arrowMarks?.count ?? 0)" })")
    }
}
