import AppKit
import SwiftUI
import ThubanCore
import os

/// Development harness driven by `THUBAN_FIGURE_DUMP=<output dir>`: renders every stored chart through the native
/// renderer next to its original, writes one PNG per figure plus `timings.txt`, and quits. Point `THUBAN_HOME` at a
/// copy of the app's data so the live bank is never touched.
@MainActor
enum FigureDump {
    static let variable = "THUBAN_FIGURE_DUMP"
    private static let logger = Logger(subsystem: "com.thuban.study", category: "figure-dump")

    static func startIfEnabled(app: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment[variable], !raw.isEmpty else { return }
        let directory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        Task { @MainActor in
            await run(app: app, directory: directory)
            NSApp.terminate(nil)
        }
    }

    private static func run(app: AppModel, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [String] = []
        var pairs: [DumpPair] = []
        var statusCounter = 0
        let only = ProcessInfo.processInfo.environment["THUBAN_FIGURE_DUMP_ONLY"]?
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        do {
            for studyClass in try await app.store.allClasses() {
                let questions = (try? await app.store.questions(in: studyClass.id, filter: QuestionFilter())) ?? []
                for figure in try await app.store.figures(in: studyClass.id) {
                    var number = figure.pageOrIndex + 1
                    // THUBAN_FIGURE_DUMP_STATUS=reviewing,pending: only figures in those review states, numbered in order
                    // (page numbers collide across documents).
                    if let statuses = ProcessInfo.processInfo.environment["THUBAN_FIGURE_DUMP_STATUS"]?.split(separator: ",").map(String.init) {
                        guard statuses.contains(figure.status.rawValue) else { continue }
                        statusCounter += 1
                        number = statusCounter
                        lines.append(String(format: "#%03d = %@ %@ p%d", number, studyClass.name, figure.id.raw, figure.pageOrIndex))
                    } else if let only, !only.isEmpty, !only.contains(number) { continue }
                    var stored = figure.chart
                    if ProcessInfo.processInfo.environment["THUBAN_FIGURE_DUMP_RECONCILE"] != nil, stored == nil || FigureAgent.isThin(stored!),
                       let png = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath)), let phase = await PhaseLineReader.read(png: png, caption: figure.caption) {
                        stored = phase.chart
                    }
                    guard var chart = stored else { continue }
                    if ProcessInfo.processInfo.environment["THUBAN_FIGURE_DUMP_RECONCILE"] != nil,
                       let png = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath)) {
                        let text = questions.filter { $0.figureIds.contains(figure.id) }.map(FigureWorkflow.questionText).joined(separator: "\n\n")
                        chart = await FigureAgent.check(chart, png: png, engine: app.engine, questionText: text)
                        if FigureAgent.isThin(chart) {
                            lines.append(String(format: "#%03d diagram (kept original)", number))
                            continue
                        }
                    }
                    let started = Date()
                    let scene = await FigureScene.build(chart, engine: app.engine)
                    let elapsed = Date().timeIntervalSince(started)
                    let original = NSImage(contentsOf: AppPaths.figureURL(figure.originalPath))
                    let aspect: CGFloat = {
                        guard let original, original.size.height > 0 else { return 1 }
                        return max(0.4, min(3, original.size.width / original.size.height))
                    }()
                    let height: CGFloat = 300, width = height * aspect
                    let view = DumpPair(original: original, scene: scene, theme: app.theme, size: CGSize(width: width, height: height),
                                        title: "#\(number) · \(chart.chartType) · \(figure.caption?.prefix(90) ?? "")", phase: chart.phaseLine)
                    pairs.append(view)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent(String(format: "%03d.png", number)))
                    }
                    let marks = scene.marks.map { "\($0.kind)(\($0.pieces.count)p/\($0.pieces.reduce(0) { $0 + $1.count })pts)" }.joined(separator: " ")
                    lines.append(String(format: "#%03d build %.3fs arrows %d marks %@ window x[%g,%g] y[%g,%g]", number, elapsed, scene.arrows.count, marks,
                                        scene.window.x.lowerBound, scene.window.x.upperBound, scene.window.y.lowerBound, scene.window.y.upperBound)
                                 + " xl " + (chart.xAxisLabels.map { $0.map(\.text).joined(separator: ",") } ?? "auto")
                                 + " yl " + (chart.yAxisLabels.map { $0.map(\.text).joined(separator: ",") } ?? "auto")
                                 + " field " + (chart.fieldFromPicture == true ? "picture" : "formula")
                                 + " | " + (chart.verification?.summary.prefix(700).description ?? "-")
                                 + " || def " + (chart.definition ?? "-"))
                }
            }
        } catch {
            lines.append("error: \(error.localizedDescription)")
        }
        // Contact sheets: four pairs per image, for reviewing every figure quickly.
        for (sheet, start) in stride(from: 0, to: pairs.count, by: 4).enumerated() {
            let group = Array(pairs[start..<min(pairs.count, start + 4)])
            let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 4) { ForEach(group.indices, id: \.self) { group[$0] } }.background(Color.white))
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(String(format: "sheet-%02d.png", sheet + 1)))
            }
        }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
        logger.notice("figure dump wrote \(lines.count) figure(s)")
    }
}

/// Original and native redraw side by side at the same size.
private struct DumpPair: View {
    var original: NSImage?
    var scene: FigureScene
    var theme: ResolvedTheme
    var size: CGSize
    var title: String
    var phase: PhaseLine? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.black).lineLimit(1).frame(width: size.width * 2 + 12, alignment: .leading)
            HStack(spacing: 12) {
                Group {
                    if let original { Image(nsImage: original).resizable().interpolation(.high).scaledToFit() } else { Color.gray }
                }
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                Canvas { context, canvasSize in
                    if let phase = phase {
                        PhaseLineRenderer(phase: phase, theme: theme).draw(in: &context, size: canvasSize)
                    } else {
                        FigureCanvasRenderer(scene: scene, theme: theme).draw(in: &context, size: canvasSize)
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(Color(hex: theme.panel))
            }
        }
        .padding(8)
        .background(Color.white)
    }
}
