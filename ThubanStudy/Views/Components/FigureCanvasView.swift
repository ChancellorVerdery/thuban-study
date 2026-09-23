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

    var body: some View {
        ZStack {
            theme.panelColor
            if let scene = FigureCache.cachedScene(for: chart) ?? scene {
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
            let built = await FigureCache.scene(for: chart, engine: app.engine)
            guard !Task.isCancelled else { return }
            scene = built
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
            let standardHalf = cell * 0.4
            var segments = Path(), heads = Path()
            for arrow in scene.arrows {
                guard let m = arrow.slope else { continue }
                // Direction (1, m) in data space, taken to pixels (y grows downwards) and normalised.
                var dx = CGFloat(sx), dy = CGFloat(-sy * m)
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0, length.isFinite else { continue }
                dx /= length; dy /= length
                let c = CGPoint(x: px(arrow.x), y: py(arrow.y))
                let half = scene.variesInLength ? cell * 0.5 * CGFloat(min(1, max(0.2, arrow.length ?? 0.8))) : standardHalf
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

        // Tick labels, plain like the original's, over the curves so none is hidden.
        func label(_ text: String, at position: CGPoint, anchor: UnitPoint) {
            // Symbols ("c") are set in italic like the original's; numbers in the label font.
            let symbolic = text.count == 1 && text.first!.isLetter
            let font = symbolic ? Font.system(size: 12, design: .serif).italic() : labelFont
            context.draw(Text(text).font(font).foregroundColor(dim), at: position, anchor: anchor)
        }
        let xLabelY = min(xAxisY + 3, size.height - 13)
        let xTicks: [ChartTick] = scene.xTickLabels ?? FigureScene.ticks(in: window.x, step: scene.xStep)
            .filter { abs($0) > scene.xStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastX = -CGFloat.infinity
        for tick in xTicks.sorted(by: { $0.value < $1.value }) where window.x.contains(tick.value) {
            // A label at the very edge is kept, nudged inside the frame; crowded labels are thinned.
            let at = min(max(px(tick.value), 10), size.width - 10)
            guard at - lastX >= 26 else { continue }
            lastX = at
            label(tick.text, at: CGPoint(x: at, y: xLabelY), anchor: .top)
        }
        let yLabelX = max(yAxisX - 4, 14)
        let yTicks: [ChartTick] = scene.yTickLabels ?? FigureScene.ticks(in: window.y, step: scene.yStep)
            .filter { abs($0) > scene.yStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastY = CGFloat.infinity
        for tick in yTicks.sorted(by: { $0.value < $1.value }) where window.y.contains(tick.value) {
            let at = min(max(py(tick.value), 8), size.height - 8)
            guard lastY - at >= 14 else { continue }
            lastY = at
            let text = tick.text
            label(text, at: CGPoint(x: yLabelX, y: at), anchor: yAxisX - 4 < 14 ? .leading : .trailing)
        }
        if scene.xTickLabels == nil, scene.yTickLabels == nil, window.x.contains(0), window.y.contains(0) {
            label("0", at: CGPoint(x: px(0) - 4, y: py(0) + 3), anchor: .topTrailing)
        }

        // Axis names at the ends of the axes, on whichever side has room.
        let xName = scene.xLabel ?? "x", yName = scene.yLabel ?? "y"
        let xNameY = xAxisY < 26 ? min(xAxisY + 12, size.height - 10) : xAxisY - 12
        context.draw(Text(xName).font(axisNameFont).foregroundColor(ink), at: CGPoint(x: size.width - 6, y: xNameY), anchor: .trailing)
        let yNameLeft = yAxisX > size.width - 26
        context.draw(Text(yName).font(axisNameFont).foregroundColor(ink),
                     at: CGPoint(x: yNameLeft ? yAxisX - 8 : min(yAxisX + 8, size.width - 12), y: xAxisY < 26 ? 30 : 10),
                     anchor: yNameLeft ? .trailing : .leading)
    }
}
