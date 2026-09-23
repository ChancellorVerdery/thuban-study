import SwiftUI
import ThubanCore

/// A `StandardChart` drawn natively (no web view, no network): the geometry comes from `FigureScene`, and this
/// view maps it into its own frame and strokes it in the theme's colours — grid and axes in ink, the slope field
/// in the signal colour, curves in the accent palette (never the field's colour).
struct FigureCanvasView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var chart: StandardChart
    @State private var scene: FigureScene?
    @State private var sceneChart: StandardChart?

    var body: some View {
        ZStack {
            theme.panelColor
            if let scene {
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    FigureCanvasRenderer(scene: scene, theme: theme).draw(in: &context, size: size)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous).stroke(theme.lineColor, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .task(id: chart) {
            // Keep the previous drawing on screen until the new one is ready (no flash between figures).
            let built = await FigureScene.build(chart, engine: app.engine)
            guard !Task.isCancelled else { return }
            scene = built
            sceneChart = chart
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [chart.isSlopeField ? "Direction field" : "Graph"]
        if let slope = chart.slope, chart.isSlopeField { parts.append("dy/dx = \(slope)") }
        parts += chart.series.map(\.name).filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

/// Draws a `FigureScene` into a `GraphicsContext`.
struct FigureCanvasRenderer {
    var scene: FigureScene
    var theme: ResolvedTheme

    private let labelFont = Font.system(size: 10, weight: .regular, design: .default).monospacedDigit()
    private let axisNameFont = Font.system(size: 13, weight: .regular, design: .serif).italic()

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let window = scene.window
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let sx = size.width / xSpan, sy = size.height / ySpan
        func px(_ x: Double) -> CGFloat { CGFloat((x - window.x.lowerBound) * sx) }
        func py(_ y: Double) -> CGFloat { CGFloat(size.height - (y - window.y.lowerBound) * sy) }
        func point(_ p: [Double]) -> CGPoint { CGPoint(x: px(p[0]), y: py(p[1])) }

        let ink = Color(hex: theme.ink)
        let line = Color(hex: theme.line)
        let dim = Color(hex: theme.inkDim)

        // Grid: minor at half steps, major at the tick spacing.
        var minor = Path(), major = Path()
        for x in FigureScene.ticks(in: window.x, step: scene.xStep / 2) {
            let isMajor = abs((x / scene.xStep).rounded() * scene.xStep - x) < scene.xStep * 1e-6
            var path = isMajor ? major : minor
            path.move(to: CGPoint(x: px(x), y: 0)); path.addLine(to: CGPoint(x: px(x), y: size.height))
            if isMajor { major = path } else { minor = path }
        }
        for y in FigureScene.ticks(in: window.y, step: scene.yStep / 2) {
            let isMajor = abs((y / scene.yStep).rounded() * scene.yStep - y) < scene.yStep * 1e-6
            var path = isMajor ? major : minor
            path.move(to: CGPoint(x: 0, y: py(y))); path.addLine(to: CGPoint(x: size.width, y: py(y)))
            if isMajor { major = path } else { minor = path }
        }
        context.stroke(minor, with: .color(line.opacity(0.35)), lineWidth: 0.5)
        context.stroke(major, with: .color(line.opacity(0.9)), lineWidth: 0.75)

        // Axes through the origin when it is in view; labels ride the axis or the nearest edge.
        let xAxisY = min(max(py(0), 0), size.height), yAxisX = min(max(px(0), 0), size.width)
        var axes = Path()
        if window.y.contains(0) { axes.move(to: CGPoint(x: 0, y: py(0))); axes.addLine(to: CGPoint(x: size.width, y: py(0))) }
        if window.x.contains(0) { axes.move(to: CGPoint(x: px(0), y: 0)); axes.addLine(to: CGPoint(x: px(0), y: size.height)) }
        context.stroke(axes, with: .color(ink), lineWidth: 1.2)

        // The field under the curves.
        if scene.hasField {
            let field = Color(hex: theme.signal).opacity(0.85)
            let cell = min(size.width / CGFloat(scene.fieldColumns), size.height / CGFloat(scene.fieldRows))
            let half = cell * 0.4
            var segments = Path(), heads = Path()
            for arrow in scene.arrows {
                guard let m = arrow.slope else { continue }
                // Direction (1, m) in data space, taken to pixels (y grows downwards) and normalised.
                var dx = CGFloat(sx), dy = CGFloat(-sy * m)
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0, length.isFinite else { continue }
                dx /= length; dy /= length
                let c = CGPoint(x: px(arrow.x), y: py(arrow.y))
                let tail = CGPoint(x: c.x - dx * half, y: c.y - dy * half), tip = CGPoint(x: c.x + dx * half, y: c.y + dy * half)
                segments.move(to: tail); segments.addLine(to: tip)
                if scene.arrowheads {
                    // A head a draughtsman would draw: 45 % of the half-length long, as wide as it is long, never
                    // smaller than a few pixels so it stays readable in a dense field.
                    let headLength = max(4, half * 0.55)
                    let base = CGPoint(x: tip.x - dx * headLength, y: tip.y - dy * headLength)
                    let w = max(2.4, headLength * 0.5)
                    heads.move(to: tip)
                    heads.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    heads.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    heads.closeSubpath()
                }
            }
            context.stroke(segments, with: .color(field), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            context.fill(heads, with: .color(field))
        }

        // Curves, dots and bars.
        let palette: [String] = scene.hasField
            ? [theme.accent, theme.neg, theme.pos, theme.accentDeep]
            : [theme.accent, theme.signal, theme.neg, theme.pos, theme.accentDeep]
        for mark in scene.marks {
            let color = Color(hex: mark.color ?? palette[mark.paletteIndex % palette.count])
            switch mark.kind {
            case .line:
                var path = Path()
                for piece in mark.pieces where piece.count >= 2 {
                    path.move(to: point(piece[0]))
                    for p in piece.dropFirst() { path.addLine(to: point(p)) }
                }
                let dash: [CGFloat] = mark.style == .dashed ? [8, 5] : mark.style == .dotted ? [1.5, 4] : []
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dash))
            case .dots:
                for p in mark.pieces.flatMap({ $0 }) {
                    let c = point(p)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(color))
                }
            case .bars:
                for p in mark.pieces.flatMap({ $0 }) {
                    let left = px(p[0] - 0.4), right = px(p[0] + 0.4)
                    let top = min(py(p[1]), py(0)), bottom = max(py(p[1]), py(0))
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    context.fill(Path(rect), with: .color(color.opacity(0.55)))
                    context.stroke(Path(rect), with: .color(color), lineWidth: 1)
                }
            }
        }

        // Tick labels, on a halo so curves never hide them.
        let halo = Color(hex: theme.panel)
        func label(_ text: String, at position: CGPoint, anchor: UnitPoint) {
            var resolved = context.resolve(Text(text).font(labelFont).foregroundColor(dim))
            let measured = resolved.measure(in: CGSize(width: 200, height: 40))
            let origin = CGPoint(x: position.x - measured.width * anchor.x, y: position.y - measured.height * anchor.y)
            context.fill(Path(roundedRect: CGRect(origin: origin, size: measured).insetBy(dx: -2, dy: 0), cornerRadius: 2), with: .color(halo.opacity(0.85)))
            resolved.shading = .color(dim)
            context.draw(resolved, at: position, anchor: anchor)
        }
        let xLabelY = min(xAxisY + 3, size.height - 13)
        for x in FigureScene.ticks(in: window.x, step: scene.xStep) where abs(x) > scene.xStep * 1e-6 {
            // A label at the very edge is kept, nudged inside the frame.
            let at = min(max(px(x), 10), size.width - 10)
            label(ChartGeometry.number(x), at: CGPoint(x: at, y: xLabelY), anchor: .top)
        }
        let yLabelX = max(yAxisX - 4, 14)
        for y in FigureScene.ticks(in: window.y, step: scene.yStep) where abs(y) > scene.yStep * 1e-6 {
            let at = min(max(py(y), 8), size.height - 8)
            label(ChartGeometry.number(y), at: CGPoint(x: yLabelX, y: at), anchor: yAxisX - 4 < 14 ? .leading : .trailing)
        }
        if window.x.contains(0), window.y.contains(0) {
            label("0", at: CGPoint(x: px(0) - 4, y: py(0) + 3), anchor: .topTrailing)
        }

        // Axis names at the ends of the axes.
        if let name = scene.xLabel ?? "x" as String? {
            context.draw(Text(name).font(axisNameFont).foregroundColor(ink), at: CGPoint(x: size.width - 6, y: min(xAxisY + 16, size.height - 10)), anchor: .trailing)
        }
        if let name = scene.yLabel ?? "y" as String? {
            context.draw(Text(name).font(axisNameFont).foregroundColor(ink), at: CGPoint(x: min(yAxisX + 8, size.width - 12), y: 10), anchor: .leading)
        }
    }
}
