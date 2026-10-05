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
            if chart.hasPanels, let panels = chart.panels {
                HStack(spacing: 8) {
                    ForEach(panels.indices, id: \.self) { k in
                        ZStack(alignment: .topLeading) {
                            AnyView(FigureCanvasView(chart: panels[k]))
                            if let title = panels[k].title, !title.isEmpty {
                                Text(title).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(Color(hex: theme.ink))
                                    .padding(6)
                            }
                        }
                    }
                }
                .padding(6)
            } else if let phase = chart.phaseLine, chart.isPhaseLine {
                let zoom = AppZoom.shared.scale
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    PhaseLineRenderer(phase: phase, theme: theme, zoom: zoom).draw(in: &context, size: size)
                }
            } else if let scene = FigureCache.cachedScene(for: chart) ?? scene {
                let zoom = AppZoom.shared.scale
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    FigureCanvasRenderer(scene: scene, theme: theme, zoom: zoom).draw(in: &context, size: size)
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
            guard !chart.hasPanels else { return }
            // Keep the previous drawing on screen until the new one is ready (no flash between figures).
            let built = await FigureCache.scene(for: chart, engine: app.engine)
            guard !Task.isCancelled else { return }
            scene = built
        }
    }

    private var accessibilityText: String {
        // Series names and the equation describe what the figure shows: spoken only when descriptions are on.
        guard app.showFigureDescriptions else { return chart.isSlopeField ? "Direction field" : "Graph" }
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
    /// The app zoom (`AppZoom`): label sizes are design points at 100 %.
    var zoom: CGFloat = 1

    private var labelFont: Font { Font.system(size: 10 * zoom, weight: .regular, design: .default).monospacedDigit() }
    private var axisNameFont: Font { Font.system(size: 13 * zoom, weight: .regular, design: .serif).italic() }

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
        // Nothing is drawn outside the plot (a curve leaving the window stops at its edge).
        context.clip(to: Path(CGRect(origin: .zero, size: size)))

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
        context.stroke(axes, with: .color(ink), lineWidth: 1.8)

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
                    let headLength = max(6, half * 0.55)
                    let base = CGPoint(x: tip.x - dx * headLength, y: tip.y - dy * headLength)
                    let w = max(3.6, headLength * 0.5)
                    heads.move(to: tip)
                    heads.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    heads.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    heads.closeSubpath()
                }
            }
            context.stroke(segments, with: .color(field), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            context.fill(heads, with: .color(field))
        }

        // Curves, dots and bars.
        let palette: [String] = scene.hasField
            ? [theme.accent, theme.neg, theme.pos, theme.accentDeep]
            : [theme.accent, theme.signal, theme.neg, theme.pos, theme.accentDeep]
        // Shaded regions first, translucent, so every curve and axis stays visible through them.
        for mark in scene.marks where mark.kind == .fill {
            let color = Color(hex: mark.color ?? palette[mark.paletteIndex % palette.count])
            var path = Path()
            for rect in mark.pieces where rect.count == 2 {
                let a = point(rect[0]), b = point(rect[1])
                // Rows overlap by a hair so no seam shows between them.
                path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y) - 0.25, width: abs(b.x - a.x), height: abs(b.y - a.y) + 0.5))
            }
            context.fill(path, with: .color(color.opacity(0.28)))
        }
        for mark in scene.marks where mark.kind != .fill {
            let color = Color(hex: mark.color ?? palette[mark.paletteIndex % palette.count])
            switch mark.kind {
            case .fill:
                break
            case .vector:
                // A straight arrow from its tail to its head.
                for piece in mark.pieces where piece.count >= 2 {
                    let a = point(piece[0]), b = point(piece[1])
                    var dx = b.x - a.x, dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()
                    guard length > 1 else { continue }
                    dx /= length; dy /= length
                    let headLength = min(16, length * 0.4), w = headLength * 0.45
                    let base = CGPoint(x: b.x - dx * headLength, y: b.y - dy * headLength)
                    var shaft = Path()
                    shaft.move(to: a); shaft.addLine(to: base)
                    context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    var head = Path()
                    head.move(to: b)
                    head.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    head.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                }
            case .arrows:
                // Filled heads on the curve, pointing the way the parameter runs.
                var heads = Path()
                for a in mark.pieces.flatMap({ $0 }) where a.count >= 4 {
                    var dx = CGFloat(a[2] * sx), dy = CGFloat(-a[3] * sy)
                    let length = (dx * dx + dy * dy).squareRoot()
                    guard length > 0, length.isFinite else { continue }
                    dx /= length; dy /= length
                    let c = point(a)
                    let headLength: CGFloat = 15, w: CGFloat = 7
                    let tip = CGPoint(x: c.x + dx * headLength / 2, y: c.y + dy * headLength / 2)
                    let base = CGPoint(x: c.x - dx * headLength / 2, y: c.y - dy * headLength / 2)
                    heads.move(to: tip)
                    heads.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    heads.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    heads.closeSubpath()
                }
                context.fill(heads, with: .color(color))
            case .line:
                var path = Path()
                for piece in mark.pieces where piece.count >= 2 {
                    path.move(to: point(piece[0]))
                    for p in piece.dropFirst() { path.addLine(to: point(p)) }
                }
                let dash: [CGFloat] = mark.style == .dashed ? [12, 7.5] : mark.style == .dotted ? [2.25, 6] : []
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3.75, lineCap: .round, lineJoin: .round, dash: dash))
            case .dots:
                for (k, p) in mark.pieces.flatMap({ $0 }).enumerated() {
                    let c = point(p)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 5.25, y: c.y - 5.25, width: 10.5, height: 10.5)), with: .color(color))
                    if let text = mark.labels?[safe: k], !text.isEmpty {
                        // Beside the dot, on the side with room.
                        let right = c.x < size.width - 60
                        context.draw(Text(text).font(Font.system(size: 12 * zoom, design: .serif).italic()).foregroundColor(ink),
                                     at: CGPoint(x: c.x + (right ? 9 : -9), y: c.y - 9), anchor: right ? .bottomLeading : .bottomTrailing)
                    }
                }
            case .bars:
                for p in mark.pieces.flatMap({ $0 }) {
                    let left = px(p[0] - 0.4), right = px(p[0] + 0.4)
                    let top = min(py(p[1]), py(0)), bottom = max(py(p[1]), py(0))
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    context.fill(Path(rect), with: .color(color.opacity(0.55)))
                    context.stroke(Path(rect), with: .color(color), lineWidth: 1.5)
                }
            }
        }

        // Tick labels, plain like the original's, over the curves so none is hidden.
        func label(_ text: String, at position: CGPoint, anchor: UnitPoint) {
            // Symbols ("c") are set in italic like the original's; numbers in the label font.
            let symbolic = text.count == 1 && text.first!.isLetter
            let font = symbolic ? Font.system(size: 12 * zoom, design: .serif).italic() : labelFont
            context.draw(Text(text).font(font).foregroundColor(dim), at: position, anchor: anchor)
        }
        let xLabelY = min(xAxisY + 3, size.height - 13)
        let xTicks: [ChartTick] = scene.xTickLabels ?? FigureScene.ticks(in: window.x, step: scene.xStep)
            .filter { abs($0) > scene.xStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastX = -CGFloat.infinity
        let xSlack = (window.x.upperBound - window.x.lowerBound) * 0.02, ySlack = (window.y.upperBound - window.y.lowerBound) * 0.02
        for tick in xTicks.sorted(by: { $0.value < $1.value }) where tick.value >= window.x.lowerBound - xSlack && tick.value <= window.x.upperBound + xSlack {
            // A label at the very edge is kept, nudged inside the frame; crowded labels are thinned.
            let at = min(max(px(tick.value), 10), size.width - 10)
            guard at - lastX >= 26 else { continue }
            lastX = at
            label(tick.text, at: CGPoint(x: at, y: xLabelY), anchor: .top)
        }
        // Too little room left of the axis for a number ("0.8" would be cut to ".8"): numbers go on its right.
        let yLabelsRight = yAxisX < 34
        let yLabelX = yLabelsRight ? yAxisX + 5 : yAxisX - 4
        let yTicks: [ChartTick] = scene.yTickLabels ?? FigureScene.ticks(in: window.y, step: scene.yStep)
            .filter { abs($0) > scene.yStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastY = CGFloat.infinity
        for tick in yTicks.sorted(by: { $0.value < $1.value }) where tick.value >= window.y.lowerBound - ySlack && tick.value <= window.y.upperBound + ySlack {
            let at = min(max(py(tick.value), 8), size.height - 8)
            guard lastY - at >= 14 else { continue }
            // On the right of the axis the top number would run into the axis name.
            if yLabelsRight, at < 26 { continue }
            lastY = at
            let text = tick.text
            label(text, at: CGPoint(x: yLabelX, y: at), anchor: yLabelsRight ? .leading : .trailing)
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

/// Draws a phase line: the axis in ink at the original's position and extent, a tick and label at each marked
/// point, and a filled arrowhead on each stretch pointing the way solutions move.
struct PhaseLineRenderer {
    var phase: PhaseLine
    var theme: ResolvedTheme
    var zoom: CGFloat = 1

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let ink = Color(hex: theme.ink), dim = Color(hex: theme.inkDim), accent = Color(hex: theme.accent)
        let vertical = phase.vertical
        let length = vertical ? size.height : size.width
        let across = vertical ? size.width : size.height
        let a = CGFloat(phase.start) * length, b = CGFloat(phase.end) * length
        let offset = CGFloat(phase.offset) * across
        // Position along the line (fraction of the drawn line) to a point in the view.
        func point(_ t: Double, _ shift: CGFloat = 0) -> CGPoint {
            let along = a + CGFloat(t) * (b - a)
            return vertical ? CGPoint(x: offset + shift, y: along) : CGPoint(x: along, y: offset + shift)
        }
        var axis = Path()
        axis.move(to: point(0)); axis.addLine(to: point(1))
        context.stroke(axis, with: .color(ink), lineWidth: 1.8)

        let scale = min(across * 0.12, 16)
        for mark in phase.marks {
            var tick = Path()
            tick.move(to: point(mark.position, -scale * 0.45)); tick.addLine(to: point(mark.position, scale * 0.45))
            context.stroke(tick, with: .color(ink), lineWidth: 1.8)
            guard !mark.text.isEmpty else { continue }
            let symbolic = mark.text.count == 1 && mark.text.first!.isLetter
            let font = symbolic ? Font.system(size: 14 * zoom, design: .serif).italic() : Font.system(size: 12 * zoom).monospacedDigit()
            context.draw(Text(mark.text).font(font).foregroundColor(dim), at: point(mark.position, -scale * 0.9), anchor: vertical ? .trailing : .top)
        }
        for arrow in phase.arrows {
            // Up the screen (smaller y) is increasing on a vertical line; right is increasing on a horizontal one.
            let forward: CGFloat = vertical ? (arrow.increasing ? -1 : 1) : (arrow.increasing ? 1 : -1)
            let centre = point(arrow.position)
            let headLength = scale * 1.4, halfWidth = scale * 0.55
            var head = Path()
            if vertical {
                head.move(to: CGPoint(x: centre.x, y: centre.y + forward * headLength / 2))
                head.addLine(to: CGPoint(x: centre.x - halfWidth, y: centre.y - forward * headLength / 2))
                head.addLine(to: CGPoint(x: centre.x + halfWidth, y: centre.y - forward * headLength / 2))
            } else {
                head.move(to: CGPoint(x: centre.x + forward * headLength / 2, y: centre.y))
                head.addLine(to: CGPoint(x: centre.x - forward * headLength / 2, y: centre.y - halfWidth))
                head.addLine(to: CGPoint(x: centre.x - forward * headLength / 2, y: centre.y + halfWidth))
            }
            head.closeSubpath()
            context.fill(head, with: .color(accent))
        }
    }
}
